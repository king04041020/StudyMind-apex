export default {
  async fetch(request, env) {
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization"
    };
    const respond = (data, status = 200) => new Response(JSON.stringify(data), {
      status, headers: { ...cors, "Content-Type": "application/json" }
    });
    const parseUpstream = async (response) => {
      const raw = await response.text();
      try { return JSON.parse(raw); }
      catch (_) { return { _raw: raw.slice(0, 1200) }; }
    };
    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") {
      return respond({ status: "ok", service: "StudyMind AI" });
    }
    if (!["/api/chat", "/api/generate"].includes(url.pathname) || request.method !== "POST") {
      return respond({ error: "Route introuvable" }, 404);
    }
    try {
      const authorization = request.headers.get("Authorization") || "";
      const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
      if (!token) return respond({ error: "Connexion Firebase requise" }, 401);
      if (!env.FIREBASE_WEB_API_KEY || !env.GEMINI_API_KEY) {
        return respond({ error: "Configuration serveur incomplète" }, 500);
      }
      const authResponse = await fetch(
        `https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=${env.FIREBASE_WEB_API_KEY}`,
        { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ idToken: token }) }
      );
      if (!authResponse.ok) return respond({ error: "Session Firebase invalide" }, 401);
      const authData = await parseUpstream(authResponse);
      const user = authData.users?.[0];
      if (!user || user.disabled) return respond({ error: "Compte non autorisé" }, 403);

      let body;
      try { body = await request.json(); } catch (_) { return respond({ error: "Corps JSON invalide" }, 400); }

      // La limite est appliquée lorsqu'un Durable Object est configuré.
      // Son absence ne doit pas rendre l'assistant inutilisable.
      // Ne jamais faire échouer toutes les requêtes IA à cause d'un binding de limite mal configuré.
      if (env.CHAT_USER_LIMITER && typeof env.CHAT_USER_LIMITER.limit === "function") {
        try {
          const { success } = await env.CHAT_USER_LIMITER.limit({ key: user.localId });
          if (!success) return respond({ error: "Limite atteinte. Réessaie dans une minute.", code: "RATE_LIMITED" }, 429);
        } catch (limitError) {
          console.warn("StudyMind limiter indisponible; requête autorisée", limitError);
        }
      }

      if (url.pathname === "/api/generate") {
        const task = String(body.task || "").toLowerCase();
        const course = String(body.course || "Matière non précisée").slice(0, 120);
        const difficulty = String(body.difficulty || "Moyen").slice(0, 30);
        const source = String(body.text || "").trim().slice(0, 24000);
        const answer = String(body.answer || "").trim().slice(0, 6000);
        const allowed = ["revision", "exercise", "correction", "summary", "quests"];
        if (!allowed.includes(task)) return respond({ error: "Type de génération inconnu." }, 400);
        if (source.length < 20) return respond({ error: "Ajoute d'abord le contenu du cours (au moins 20 caractères)." }, 400);
        let prompt;
        if (task === "quests") {
          prompt = 'Génère 6 quêtes pédagogiques personnalisées, 3 principales et 3 secondaires, réparties entre les matières du contenu. Réponds uniquement en JSON valide : {"quests":[{"id":"id-stable","title":"...","description":"...","course":"...","type":"Principale ou Secondaire","reward":5}]}. Les quêtes doivent être concrètes, variées et réalisables par un élève. Récompenses entières de 3 à 10 PR.';
        } else if (task === "revision" || task === "summary") {
          prompt = task === "revision"
            ? "Crée une fiche de révision complète et pédagogique avec titre, objectifs, notions clés, définitions, explications, exemples et mini-récapitulatif."
            : "Fais un résumé fidèle, clair et structuré du cours avec les idées essentielles.";
        } else if (task === "exercise") {
          prompt = "Crée un exercice original basé uniquement sur le cours. Respecte la difficulté demandée. Donne la consigne, les données utiles et une correction détaillée dans une section séparée intitulée CORRECTION (à ne pas confondre avec la consigne).";
        } else {
          prompt = "Corrige la réponse de l'élève à partir du cours. Explique ce qui est juste, ce qui manque ou est faux, puis donne une réponse modèle. Termine par une ligne exactement au format RESULTAT: BONNE ou RESULTAT: A_REVOIR. N'accorde pas automatiquement la réussite.";
        }
        const userPrompt = task === "correction"
          ? `Matière: ${course}\nCours:\n${source}\nRéponse de l'élève:\n${answer}\n\nTâche: ${prompt}`
          : `Matière: ${course}\nDifficulté: ${difficulty}\nCours:\n${source}\n\nTâche: ${prompt}`;
        const generated = await fetch(
          "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
          { method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
            body: JSON.stringify({ contents: [{ role: "user", parts: [{ text: userPrompt }] }], generationConfig: { temperature: 0.45, maxOutputTokens: 3000 } }) }
        );
        const generatedData = await parseUpstream(generated);
        if (!generated.ok) {
          const detail = generatedData.error?.message || generatedData.message || generatedData._raw || "Réponse Gemini invalide.";
          console.error("StudyMind Gemini generation error", generated.status, detail);
          return respond({ error: `Gemini (HTTP ${generated.status}) : ${String(detail).slice(0, 700)}` }, 502);
        }
        const content = generatedData.candidates?.[0]?.content?.parts?.map(part => part.text || "").join("\n").trim();
        if (!content) return respond({ error: "Gemini n'a renvoyé aucun contenu." }, 502);
        return respond({ content });
      }
      const message = String(body.message || "").trim();
      const requestedMode = String(body.mode || "KING").toUpperCase();
      const mode = ["KING", "QUEEN", "PERSONNALISÉ"].includes(requestedMode) ? requestedMode : "KING";
      const style = String(body.style || "Mentor").slice(0, 80);
      const course = String(body.course || "").slice(0, 120);
      const assistantName = String(body.assistantName || mode).slice(0, 80);
      const context = String(body.context || "").slice(0, 18000);
      if (!message || message.length > 6000) return respond({ error: "Message vide ou trop long" }, 400);
      const identities = {
        KING: "Tu es KING, un assistant pédagogique stratégique, exigeant et motivant.",
        QUEEN: "Tu es QUEEN, une assistante pédagogique attentive, claire et encourageante.",
        "PERSONNALISÉ": `Tu es ${assistantName}, l'assistant pédagogique personnalisé de l'utilisateur.`
      };
      const styleInstructions = {
        "Mentor": "Agis comme un mentor : guide avec méthode, fixe des objectifs clairs, explique les étapes et encourage l'autonomie.",
        "Professeur": "Agis comme un professeur : structure les explications, définis les notions, donne des exemples et vérifie la compréhension.",
        "Rival": "Agis comme un rival stimulant : propose des défis adaptés et pousse l'élève à se dépasser sans l'humilier ni le décourager.",
        "Génie": "Agis comme un génie pédagogue : raisonne en profondeur, trouve des liens pertinents et explique les idées complexes simplement.",
        "Meilleur ami": "Agis comme un meilleur ami de confiance : chaleureux, naturel, loyal, à l'écoute, encourageant et parfois drôle avec tact. Parle simplement, sans juger ni flatter artificiellement. Aide aussi sérieusement pour les cours. Reste un compagnon d'étude, jamais romantique, et ne prétends pas être humain."
      };
      const styleInstruction = styleInstructions[style] || styleInstructions["Mentor"];
      const systemInstruction = `${identities[mode]}\nStyle de personnalité : ${styleInstruction}\nTu travailles dans StudyMind, une application d'apprentissage. Explique avec précision, adapte ton niveau à l'élève et privilégie les exemples. Ne prétends pas connaître un cours qui ne t'a pas été fourni.\nMatière : ${course || "Non précisée"}.\nContenu du cours fourni :\n${context || "Aucun document de cours fourni."}`;
      const aiResponse = await fetch(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        { method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
          body: JSON.stringify({ systemInstruction: { parts: [{ text: systemInstruction }] }, contents: [{ role: "user", parts: [{ text: message }] }], generationConfig: { temperature: 0.7, maxOutputTokens: 2048 } }) }
      );
      const result = await parseUpstream(aiResponse);
      if (!aiResponse.ok) {
        const detail = result.error?.message || result.message || result._raw || "Réponse Gemini invalide.";
        console.error("StudyMind Gemini chat error", aiResponse.status, detail);
        return respond({ error: `Gemini (HTTP ${aiResponse.status}) : ${String(detail).slice(0, 700)}` }, 502);
      }
      const answer = result.candidates?.[0]?.content?.parts?.map(part => part.text || "").join("").trim();
      if (!answer) return respond({ error: "Réponse IA indisponible" }, 502);
      return respond({ answer, assistant: mode, course });
    } catch (error) {
      console.error("StudyMind Worker internal error", error);
      return respond({
        error: "Erreur interne du service StudyMind",
        code: "WORKER_INTERNAL",
        diagnostic: String(error?.message || error || "Erreur inconnue").slice(0, 500)
      }, 500);
    }
  }
};
