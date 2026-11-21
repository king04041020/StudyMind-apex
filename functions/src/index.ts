import { initializeApp } from 'firebase-admin/app';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { defineSecret } from 'firebase-functions/params';
import { HttpsError, onCall } from 'firebase-functions/v2/https';

initializeApp();
const db = getFirestore();
const geminiApiKey = defineSecret('GEMINI_API_KEY');

function requireUser(request: { auth?: { uid: string } }) {
  if (!request.auth?.uid) throw new HttpsError('unauthenticated', 'Connexion requise.');
  return request.auth.uid;
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
