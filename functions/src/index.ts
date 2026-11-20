import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { defineSecret, defineString } from 'firebase-functions/params';
import { HttpsError, onCall } from 'firebase-functions/v2/https';

initializeApp();
const db = getFirestore();
const geminiApiKey = defineSecret('GEMINI_API_KEY');
const founderUid = defineString('STUDYMIND_FOUNDER_UID');

function requireUser(request: { auth?: { uid: string } }) {
  if (!request.auth?.uid) throw new HttpsError('unauthenticated', 'Connexion requise.');
  return request.auth.uid;
}

function requireFounder(uid: string) {
  if (!founderUid.value() || uid !== founderUid.value()) {
    throw new HttpsError('permission-denied', 'Action réservée à la fondatrice.');
  }
}

export const generateStudyContent = onCall(
  { secrets: [geminiApiKey], timeoutSeconds: 120, memory: '512MiB', enforceAppCheck: false },
  async (request) => {
    const uid = requireUser(request);
    const text = String(request.data?.text ?? '').trim();
    const task = String(request.data?.task ?? 'summary');
    if (text.length < 40 || text.length > 30000) {
      throw new HttpsError('invalid-argument', 'Le texte doit contenir entre 40 et 30 000 caractères.');
    }
    if (!['summary', 'revision', 'quiz', 'explain'].includes(task)) {
      throw new HttpsError('invalid-argument', 'Type de génération non reconnu.');
    }

    const prompt = `Tu es StudyMind, assistant pédagogique. Réponds en français, clairement et sans inventer.\nTâche: ${task}\nÀ partir du cours ci-dessous, produis uniquement un contenu fidèle au cours, structuré avec titres et listes. Pour quiz, donne 5 questions puis un corrigé séparé.\nCOURS:\n${text}`;
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${geminiApiKey.value()}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }] }),
      },
    );
    if (!response.ok) {
      console.error('Gemini request failed', response.status, await response.text());
      throw new HttpsError('unavailable', 'Le service pédagogique est temporairement indisponible.');
    }
    const payload = await response.json() as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
    };
    const output = payload.candidates?.[0]?.content?.parts?.map((part) => part.text ?? '').join('\n').trim();
    if (!output) throw new HttpsError('internal', 'Aucun contenu généré.');

    await db.collection('users').doc(uid).collection('ai_history').add({
      task, createdAt: FieldValue.serverTimestamp(), inputLength: text.length,
    });
    return { content: output };
  },
);

export const requestAdminRole = onCall(async (request) => {
  const uid = requireUser(request);
  const note = String(request.data?.note ?? '').slice(0, 1000);
  await db.collection('adminCandidates').doc(uid).set({
    uid, note, status: 'pending', requestedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  return { status: 'pending' };
});

export const approveAdminRole = onCall(async (request) => {
  const uid = requireUser(request);
  requireFounder(uid);
  const targetUid = String(request.data?.targetUid ?? '').trim();
  if (!targetUid || targetUid === uid) throw new HttpsError('invalid-argument', 'Candidat invalide.');
  const candidate = db.collection('adminCandidates').doc(targetUid);
  const snapshot = await candidate.get();
  if (!snapshot.exists || snapshot.data()?.status !== 'pending') {
    throw new HttpsError('failed-precondition', 'Aucune candidature en attente pour ce compte.');
  }
  await getAuth().setCustomUserClaims(targetUid, { ...(await getAuth().getUser(targetUid)).customClaims, studymindAdmin: true });
  await candidate.set({ status: 'approved', approvedAt: FieldValue.serverTimestamp(), approvedBy: uid }, { merge: true });
  await db.collection('adminAudit').add({ action: 'approve_admin', targetUid, actorUid: uid, at: FieldValue.serverTimestamp() });
  return { status: 'approved' };
});

export const revokeAdminRole = onCall(async (request) => {
  const uid = requireUser(request);
  requireFounder(uid);
  const targetUid = String(request.data?.targetUid ?? '').trim();
  if (!targetUid || targetUid === uid) throw new HttpsError('invalid-argument', 'Cible invalide.');
  const user = await getAuth().getUser(targetUid);
  const claims = { ...(user.customClaims ?? {}) };
  delete claims.studymindAdmin;
  await getAuth().setCustomUserClaims(targetUid, claims);
  await db.collection('adminCandidates').doc(targetUid).set({ status: 'revoked', revokedAt: FieldValue.serverTimestamp(), revokedBy: uid }, { merge: true });
  await db.collection('adminAudit').add({ action: 'revoke_admin', targetUid, actorUid: uid, at: FieldValue.serverTimestamp() });
  return { status: 'revoked' };
});


// Founder-only exception: direct appointment without candidate training/exam.
export const founderDirectAppointAdmin = onCall(async (request) => {
  const uid = requireUser(request);
  requireFounder(uid);
  const targetUid = String(request.data?.targetUid ?? '').trim();
  if (!targetUid || targetUid === uid) throw new HttpsError('invalid-argument', 'Compte cible invalide.');
  const target = await getAuth().getUser(targetUid);
  await getAuth().setCustomUserClaims(targetUid, { ...(target.customClaims ?? {}), studymindAdmin: true });
  await db.collection('adminCandidates').doc(targetUid).set({
    uid: targetUid, status: 'approved_directly_by_founder', approvedAt: FieldValue.serverTimestamp(), approvedBy: uid,
  }, { merge: true });
  await db.collection('adminAudit').add({ action: 'founder_direct_appoint_admin', targetUid, actorUid: uid, at: FieldValue.serverTimestamp() });
  return { status: 'approved_directly_by_founder' };
});
