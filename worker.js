
export default {
  async fetch(request, env) {
    const cors = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization"
    };

    const respond = (data, status = 200) =>
      new Response(JSON.stringify(data), {
        status,
        headers: { ...cors, "Content-Type": "application/json" }
      });

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: cors });
    }

    const url = new URL(request.url);

    if (url.pathname === "/health" && request.method === "GET") {
      return respond({ status: "ok", service: "StudyMind AI" });
    }

    if (url.pathname !== "/api/chat" || request.method !== "POST") {
      return respond({ error: "Route introuvable" }, 404);
    }

    try {
      if (!env.FIREBASE_WEB_API_KEY || !env.GEMINI_API_KEY) {
        return respond({ error: "Configuration serveur incomplète" }, 500);
      }

      const authorization = request.headers.get("Authorization") || "";
      const token = authorization.startsWith("Bearer ")
        ? authorization.slice(7)
        : "";

      if (!token) {
        return respond({ error: "Connexion Firebase requise" }, 401);
      }

      const authResponse = await fetch(
        `https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=${env.FIREBASE_WEB_API_KEY}`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ idToken: token })
        }
      );

      if (!authResponse.ok) {
        return respond({ error: "Session Firebase invalide" }, 401);
      }

      const authData = await authResponse.json();
      const user = authData.users?.[0];

      if (!user || user.disabled || !user.localId) {
        return respond({ error: "Compte non autorisé" }, 403);
      }

      // Protection : 10 requêtes par utilisateur sur 60 secondes
      if (!env.CHAT_USER_LIMITER) {
        return respond({ error: "Protection anti-abus non configurée" }, 503);
      }

      const { success } = await env.CHAT_USER_LIMITER.limit({
        key: user.localId
      });

      if (!success) {
        return respond({
          error: "Limite atteinte. Réessaie dans une minute.",
          code: "RATE_LIMITED"
        }, 429);
      }

      let body;

      try {
        body = await request.json();
      } catch (_) {
        return respond({ error: "Corps JSON invalide" }, 400);
      }

      if (!body || typeof body !== "object" || Array.isArray(body)) {
        return respond({ error: "Données invalides" }, 400);
      }

      const message = String(body.message || "").trim();
      const requestedMode = String(body.mode || "KING").toUpperCase();

      const mode = ["KING", "QUEEN", "PERSONNALISÉ"].includes(requestedMode)
        ? requestedMode
        : "KING";

      const style = String(body.style || "Mentor").slice(0, 80);
      const course = String(body.course || "").slice(0, 120);
      const context = String(body.context || "").slice(0, 18000);

      if (!message || message.length > 6000) {
        return respond({ error: "Message vide ou trop long" }, 400);
      }

      const identities = {
        KING: "Tu es KING, un assistant pédagogique stratégique, exigeant et motivant.",
        QUEEN: "Tu es QUEEN, une assistante pédagogique attentive, claire et encourageante.",
        "PERSONNALISÉ": "Tu es l'assistant pédagogique personnalisé de l'utilisateur."
      };

      const systemInstruction =
        `${identities[mode]}\nPersonnalité : ${style}.\n` +
        "Tu travailles dans StudyMind, une application d'apprentissage. " +
        "Explique avec précision, adapte ton niveau à l'élève et privilégie les exemples. " +
        "Ne prétends pas connaître un cours qui ne t'a pas été fourni.\n" +
        `Matière : ${course || "Non précisée"}.\n` +
        `Contenu du cours fourni : ${context || "Aucun document de cours fourni."}`;

      const aiResponse = await fetch(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-goog-api-key": env.GEMINI_API_KEY
          },
          body: JSON.stringify({
            systemInstruction: {
              parts: [{ text: systemInstruction }]
            },
            contents: [{
              role: "user",
              parts: [{ text: message }]
            }],
            generationConfig: {
              temperature: 0.7,
              maxOutputTokens: 2048
            }
          })
        }
      );

      const result = await aiResponse.json();

      if (!aiResponse.ok) {
        return respond({ error: "Le service Gemini n'a pas pu répondre." }, 502);
      }

      const answer = result.candidates?.[0]?.content?.parts
        ?.map(part => part.text || "")
        .join("")
        .trim();

      if (!answer) {
        return respond({ error: "Réponse IA indisponible" }, 502);
      }

      return respond({ answer, assistant: mode, course });

    } catch (_) {
      return respond({ error: "Erreur interne du service StudyMind" }, 500);
    }
  }
};
                  
// Déploiement Git Cloudflare
