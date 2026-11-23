// Kavelynt AI Worker — covered by automated authenticated end-to-end tests.
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

    // Les appels Gemini peuvent rester bloqués en cas de surcharge.
    // Chaque tentative est bornée pour qu'un fallback puisse être essayé
    // avant le timeout HTTP du client.
    const callGemini = async (payload, apiKey) => {
      const plan = [
        // Le modèle léger a répondu correctement lors des tests réels.
        // En cas de surcharge, essayer plusieurs familles Flash indépendantes.
        { model: "gemini-3.5-flash-lite", attempts: 2 },
        { model: "gemini-3.8-flash", attempts: 2 },
        { model: "gemini-3.5-flash", attempts: 1 },
        { model: "gemini-3.7-flash", attempts: 1 }
      ];
      let last = {
        ok: false, status: 503,
        data: { error: { message: "Service Gemini temporairement indisponible." } },
        model: "gemini-3.8-flash"
      };
      for (const item of plan) {
        for (let attempt = 0; attempt < item.attempts; attempt++) {
          try {
            const response = await fetch(
              `https://generativelanguage.googleapis.com/v1beta/models/${item.model}:generateContent`,
              {
                method: "POST",
                headers: { "Content-Type": "application/json", "x-goog-api-key": apiKey },
                body: JSON.stringify(payload),
                signal: AbortSignal.timeout(9000)
              }
            );
            const data = await parseUpstream(response);
            if (response.ok) return { ok: true, status: response.status, data, model: item.model };
            last = { ok: false, status: response.status, data, model: item.model };
            if (![429, 500, 502, 503, 504].includes(response.status)) return last;
          } catch (error) {
            last = {
              ok: false, status: 504,
              data: { error: { message: `Délai Gemini dépassé ou réseau indisponible : ${String(error?.message || error).slice(0, 250)}` } },
              model: item.model
            };
          }
          if (attempt + 1 < item.attempts || item !== plan[plan.length - 1]) {
            const backoffMs = Math.min(1200, 500 * (attempt + 1));
            await new Promise(resolve => setTimeout(resolve, backoffMs));
          }
        }
      }
      return last;
    };
    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") {
      return respond({ status: "ok", service: "Kavelynt AI" });
    }
    if (!["/api/chat", "/api/generate"].includes(url.pathname) || request.method !== "POST") {
      return respond({ error: "Route introuvable" }, 404);
    }
    try {
      const authorization = request.headers.get("Authorization") || "";
      const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
      if (!token) return respond({ error: "Connexion Firebase requise" }, 401);
      // Les secrets collés depuis un tableau de bord peuvent contenir des
      // espaces ou retours à la ligne invisibles, invalides dans un en-tête HTTP.
      const geminiApiKey = String(env.GEMINI_API_KEY || "").replace(/\s/g, "");
      const firebaseApiKey = String(env.FIREBASE_WEB_API_KEY || "").trim();
      if (!firebaseApiKey || !geminiApiKey) {
        return respond({ error: "Configuration serveur incomplète" }, 500);
      }
      const authResponse = await fetch(
        `https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=${firebaseApiKey}`,
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
          console.warn("Kavelynt limiter indisponible; requête autorisée", limitError);
        }
      }

      if (url.pathname === "/api/generate") {
        const task = String(body.task || "").toLowerCase();
        const course = String(body.course || "Matière non précisée").slice(0, 120);
        const difficulty = String(body.difficulty || "Moyen").slice(0, 30);
        const source = String(body.text || "").trim().slice(0, 24000);
        const answer = String(body.answer || "").trim().slice(0, 6000);
        const imageBase64 = String(body.imageBase64 || "");
        const mimeType = String(body.mimeType || "image/jpeg");
        const allowed = ["revision", "exercise", "worksheet", "extract_course", "correction", "summary", "quests", "secret_quest", "quest_validation"];
        if (!allowed.includes(task)) return respond({ error: "Type de génération inconnu." }, 400);
        if (task === "extract_course") {
          if (!imageBase64 || imageBase64.length > 11_000_000 || !["image/jpeg", "image/png", "image/webp", "image/heic"].includes(mimeType)) {
            return respond({ error: "Photo invalide ou trop volumineuse (8 Mo maximum)." }, 400);
          }
        } else if (source.length < 20) {
          return respond({ error: "Ajoute d'abord le contenu du cours (au moins 20 caractères)." }, 400);
        }
        let prompt;
        if (task === "extract_course") {
          prompt = "Lis fidèlement cette photo de cours. Transcris le texte lisible en conservant titres, définitions, exemples, formules et listes. N'invente pas les parties floues. Commence par TITRE: suivi d'un titre court, puis le cours transcrit. Indique [passage illisible] si nécessaire. Réponds en français.";
        } else if (task === "worksheet") {
          prompt = "Crée une feuille imprimable de 10 exercices progressifs strictement fondés sur le cours. Numérote les exercices, varie les questions, laisse de la place pour les réponses et n'ajoute aucune notion non étudiée. Termine par une section CORRIGÉ séparée avec réponses et brèves explications. Pas de texte de conversation.";
        } else if (task === "quests") {
          prompt = 'Génère 6 quêtes pédagogiques personnalisées, 3 principales et 3 secondaires, réparties entre les matières du contenu. Réponds uniquement en JSON valide : {"quests":[{"id":"id-stable","title":"...","description":"...","course":"...","type":"Principale ou Secondaire","reward":5}]}. Les quêtes doivent être concrètes, variées et réalisables par un élève. Récompenses entières de 3 à 10 PR.';
        } else if (task === "secret_quest") {
          prompt = "Crée une quête secrète originale, stimulante et faisable, strictement liée à la leçon fournie. Réponds uniquement en JSON valide avec les clés title, description, question, reward. La question doit demander une démonstration ou une explication précise fondée sur le cours. reward doit être 2. Ne donne jamais la solution.";
        } else if (task === "quest_validation") {
          prompt = "Évalue la réponse de l’élève à la quête décrite dans son message. Vérifie précisément qu’elle répond à l’objectif et s’appuie sur le contenu du cours. Une affirmation vague, une réponse vide, une répétition de la consigne ou une preuve insuffisante ne valide pas la quête. Donne exactement une seule ligne de verdict, tout à la fin de ta réponse : RESULTAT: BONNE si la réponse démontre réellement la compréhension, sinon RESULTAT: A_REVOIR. N'écris jamais les deux verdicts. Donne une explication courte et une piste pour progresser. N’accorde jamais la réussite par défaut.";
        } else if (task === "revision" || task === "summary") {
          prompt = task === "revision"
            ? "Crée une fiche de révision complète et pédagogique avec titre, objectifs, notions clés, définitions, explications, exemples et mini-récapitulatif."
            : "Fais un résumé fidèle, clair et structuré du cours avec les idées essentielles.";
        } else if (task === "exercise") {
          prompt = "Crée un exercice original strictement limité aux notions réellement expliquées dans le cours fourni. Avant de rédiger, identifie le sujet précis de la leçon et reste dans ce sujet : ne mélange jamais avec d’autres chapitres de la même matière et n’introduis aucune notion non enseignée. Pour un cours de mathématiques sur l’addition des nombres ronds, propose uniquement des additions de nombres ronds adaptées au niveau du cours (par exemple dizaines ou centaines rondes) : aucun x, aucune inconnue, aucune équation, aucune multiplication ni autre opération si elles ne figurent pas dans le cours. Respecte la difficulté demandée. Donne une consigne claire, les données utiles, puis une correction détaillée dans une section séparée intitulée CORRECTION. La réponse doit pouvoir être résolue en appliquant directement la leçon fournie.";
        } else {
          prompt = "Corrige la réponse de l'élève à partir du cours. Explique ce qui est juste, ce qui manque ou est faux, puis donne une réponse modèle. Termine par une ligne exactement au format RESULTAT: BONNE ou RESULTAT: A_REVOIR. N'accorde pas automatiquement la réussite.";
        }
        const userPrompt = task === "correction" || task === "quest_validation"
          ? `Matière: ${course}\nCours:\n${source}\nDonnées fournies par l'élève:\n${answer}\n\nTâche: ${prompt}`
          : `Matière: ${course}\nDifficulté: ${difficulty}\nCours:\n${source}\n\nTâche: ${prompt}`;
        const parts = task === "extract_course"
          ? [{ text: prompt }, { inlineData: { mimeType, data: imageBase64 } }]
          : [{ text: userPrompt }];
        const generated = await callGemini({
          contents: [{ role: "user", parts }],
          generationConfig: { temperature: 0.45, maxOutputTokens: 2200 }
        }, geminiApiKey);
        const generatedData = generated.data;
        if (!generated.ok && task !== "extract_course") {
          // Secours local pour que les fonctions pédagogiques restent utilisables
          // même pendant une panne temporaire de Gemini.
          const excerpt = source.replace(/\\s+/g, " ").trim();
          const shortExcerpt = excerpt.length > 900 ? excerpt.slice(0, 900) + "…" : excerpt;
          let fallbackContent = "";
          if (task === "worksheet") {
            fallbackContent = [
              "FEUILLE D’EXERCICES — " + course, "Difficulté : " + difficulty, "",
              "Consigne : réponds en utilisant uniquement le cours ci-dessous.", "",
              "COURS DE RÉFÉRENCE", shortExcerpt, "", "EXERCICES",
              "1. Quel est le sujet principal de ce cours ? Définis-le avec tes propres mots.",
              "2. Cite les notions ou mots-clés essentiels présentés dans le cours.",
              "3. Explique la première idée importante et reformule-la simplement.",
              "4. Présente les étapes, éléments ou caractéristiques décrits dans le cours.",
              "5. Quelle relation le cours établit-il entre ses notions principales ?",
              "6. Donne un exemple concret qui illustre une notion explicitement présentée.",
              "7. Distingue deux notions du cours et explique leur différence.",
              "8. Transforme une explication du cours en un schéma ou une liste structurée.",
              "9. Rédige trois affirmations sur le cours : deux exactes et une inexacte, puis identifie l’inexacte.",
              "10. Résume la leçon en cinq phrases.", "", "CORRIGÉ — éléments attendus",
              "Les réponses doivent reprendre fidèlement les définitions, notions, relations et exemples du cours de référence, sans ajouter de notion extérieure."
            ].join("\\n");
          } else if (task === "revision" || task === "summary") {
            fallbackContent = [
              (task === "revision" ? "FICHE DE RÉVISION — " : "RÉSUMÉ — ") + course, "",
              "CONTENU DU COURS", shortExcerpt, "",
              "À RETENIR", "• Identifie le sujet central et les notions essentielles du texte.",
              "• Apprends les définitions et les relations explicitement données.",
              "• Révise les exemples et les étapes dans leur ordre.",
              "", "AUTO-ÉVALUATION",
              "1. Explique le sujet avec tes propres mots.",
              "2. Définis les notions clés présentes dans le cours.",
              "3. Donne un exemple tiré du cours."
            ].join("\\n");
          } else if (task === "exercise") {
            fallbackContent = [
              "EXERCICE — " + course, "Difficulté : " + difficulty, "",
              "À partir du cours ci-dessous, réponds aux questions sans utiliser de notions extérieures.",
              shortExcerpt, "",
              "1. Définis le sujet principal.",
              "2. Explique deux notions importantes du cours.",
              "3. Donne un exemple fidèle au cours.",
              "4. Résume la méthode ou les étapes présentées.",
              "", "CORRECTION : les réponses doivent reprendre les définitions, explications et exemples du texte de référence."
            ].join("\\n");
          } else if (task === "quests") {
            fallbackContent = JSON.stringify({ quests: [
              {id:"fallback-main-1",title:"Comprendre la leçon",description:"Explique les notions principales de ce cours avec tes propres mots.",course,reward:5,type:"Principale"},
              {id:"fallback-main-2",title:"Retenir l’essentiel",description:"Présente les définitions et les idées importantes du cours.",course,reward:5,type:"Principale"},
              {id:"fallback-main-3",title:"Appliquer le cours",description:"Donne un exemple concret fondé sur le contenu étudié.",course,reward:5,type:"Principale"},
              {id:"fallback-side-1",title:"Mots-clés",description:"Retrouve et définis cinq mots-clés du cours.",course,reward:3,type:"Secondaire"},
              {id:"fallback-side-2",title:"Mini-résumé",description:"Résume le cours en cinq phrases.",course,reward:3,type:"Secondaire"},
              {id:"fallback-side-3",title:"Question de révision",description:"Écris puis réponds à une question importante sur la leçon.",course,reward:3,type:"Secondaire"}
            ]});
          } else if (task === "secret_quest") {
            fallbackContent = JSON.stringify({title:"Défi secret : transmettre la leçon",description:"Explique une notion essentielle sans recopier le cours.",question:"Choisis une notion importante du cours, définis-la et illustre-la avec un exemple tiré de la leçon.",reward:2});
          } else if (task === "correction" || task === "quest_validation") {
            fallbackContent = "La correction automatique est temporairement indisponible. Relis le cours et vérifie que ta réponse contient une définition exacte, une explication et un exemple pertinent. Ta réponse doit être revue lorsque le service IA sera rétabli.\\nRESULTAT: A_REVOIR";
          }
          if (fallbackContent) {
            console.warn("Kavelynt local educational fallback used", task, generated.status, generated.model);
            return respond({ content: fallbackContent, model: "local-fallback", fallback: true });
          }
        }
        if (!generated.ok) {
          const detail = generatedData.error?.message || generatedData.message || generatedData._raw || "Réponse du fournisseur IA invalide.";
          console.error("Kavelynt Gemini generation error", generated.status, generated.model, detail);
          if (generated.status === 429) {
            return respond({
              error: "Le quota temporaire du service IA est atteint. Réessaie plus tard.",
              code: "AI_QUOTA_EXCEEDED",
              retryable: true
            }, 429);
          }
          return respond({
            error: "La génération IA est momentanément indisponible. Réessaie dans quelques instants.",
            code: "AI_PROVIDER_UNAVAILABLE",
            retryable: true
          }, 503);
        }
        let content = generatedData.candidates?.[0]?.content?.parts?.map(part => part.text || "").join("\n").trim();
        if (!content) return respond({ error: "Gemini n'a renvoyé aucun contenu." }, 502);
        // Gemini peut entourer le JSON de balises Markdown ou d'une phrase.
        // Normaliser les quêtes avant de les transmettre à Flutter.
        if (task === "quests" || task === "secret_quest") {
          const extractJson = (value) => {
            const cleaned = String(value).replace(/\x60{3}(?:json)?/gi, "").trim();
            const first = cleaned.indexOf("{");
            const last = cleaned.lastIndexOf("}");
            if (first < 0 || last <= first) return null;
            try { return JSON.parse(cleaned.slice(first, last + 1)); }
            catch (_) { return null; }
          };
          const parsed = extractJson(content);
          if (task === "quests") {
            const list = Array.isArray(parsed?.quests) ? parsed.quests : [];
            const valid = list.filter(q =>
              q && typeof q.title === "string" && q.title.trim() &&
              typeof q.description === "string" && q.description.trim() &&
              ["Principale", "Secondaire"].includes(q.type)
            ).slice(0, 12);
            if (valid.length >= 2) {
              content = JSON.stringify({ quests: valid.map((q, index) => ({
                id: String(q.id || `quest-${index + 1}`).slice(0, 80),
                title: q.title.slice(0, 120),
                description: q.description.slice(0, 600),
                course: String(q.course || course).slice(0, 120),
                type: q.type,
                reward: Math.max(1, Math.min(10, Number.isFinite(Number(q.reward)) ? Math.round(Number(q.reward)) : 3))
              })) });
            } else {
              console.warn("Invalid Gemini quest JSON; using safe course-based fallback");
              content = JSON.stringify({ quests: [
                {id:"fallback-main-1",title:"Comprendre la leçon",description:"Explique les notions principales de ce cours avec tes propres mots.",course,reward:5,type:"Principale"},
                {id:"fallback-main-2",title:"Retenir l’essentiel",description:"Présente les définitions et les idées importantes du cours.",course,reward:5,type:"Principale"},
                {id:"fallback-main-3",title:"Appliquer le cours",description:"Donne un exemple concret fondé sur le contenu étudié.",course,reward:5,type:"Principale"},
                {id:"fallback-side-1",title:"Mots-clés",description:"Retrouve et définis cinq mots-clés du cours.",course,reward:3,type:"Secondaire"},
                {id:"fallback-side-2",title:"Mini-résumé",description:"Résume le cours en cinq phrases.",course,reward:3,type:"Secondaire"},
                {id:"fallback-side-3",title:"Question de révision",description:"Écris puis réponds à une question importante sur la leçon.",course,reward:3,type:"Secondaire"}
              ]});
            }
          } else {
            const valid = parsed && typeof parsed.title === "string" &&
              typeof parsed.description === "string" && typeof parsed.question === "string";
            if (valid) content = JSON.stringify({
              title: parsed.title.slice(0, 120),
              description: parsed.description.slice(0, 500),
              question: parsed.question.slice(0, 1000),
              reward: 2
            });
            else content = JSON.stringify({
              title:"Défi secret : transmettre la leçon",
              description:"Explique une notion essentielle sans recopier le cours.",
              question:"Choisis une notion importante du cours, définis-la et illustre-la avec un exemple tiré de la leçon.",
              reward:2
            });
          }
        }
        // Une correction doit toujours fournir un verdict explicite. En cas de
        // format manquant, on choisit prudemment A_REVOIR et aucun PR n'est attribué.
        if (task === "correction" || task === "quest_validation") {
          // Un verdict ambigu, absent ou multiple ne doit jamais attribuer de PR.
          const verdicts = [...content.matchAll(/^RESULTAT\s*:\s*(BONNE|A_REVOIR)\s*$/gim)];
          const finalLine = content.trimEnd().split(/\r?\n/).pop()?.trim() || "";
          const verdict = verdicts.length === 1 &&
            /^RESULTAT\s*:\s*(BONNE|A_REVOIR)$/i.test(finalLine)
            ? verdicts[0][1].toUpperCase()
            : "A_REVOIR";
          content = content.replace(/^RESULTAT\s*:\s*(?:BONNE|A_REVOIR)\s*$/gim, "").trimEnd();
          content += "\nRESULTAT: " + verdict;
        }
        return respond({ content, model: generated.model });
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
      const systemInstruction = `${identities[mode]}\nStyle de personnalité : ${styleInstruction}\nTu travailles dans Kavelynt, une application d'apprentissage. Explique avec précision, adapte ton niveau à l'élève et privilégie les exemples. Ne prétends pas connaître un cours qui ne t'a pas été fourni.\nMatière : ${course || "Non précisée"}.\nContenu du cours fourni :\n${context || "Aucun document de cours fourni."}`;
      const aiResponse = await callGemini({
        systemInstruction: { parts: [{ text: systemInstruction }] },
        contents: [{ role: "user", parts: [{ text: message }] }],
        generationConfig: { temperature: 0.7, maxOutputTokens: 2048 }
      }, geminiApiKey);
      const result = aiResponse.data;
      if (!aiResponse.ok) {
        const detail = result.error?.message || result.message || result._raw || "Réponse du fournisseur IA invalide.";
        console.error("Kavelynt Gemini chat error", aiResponse.status, aiResponse.model, detail);
        if (aiResponse.status === 429) {
          return respond({
            error: "Le quota temporaire du service IA est atteint. Réessaie plus tard.",
            code: "AI_QUOTA_EXCEEDED",
            retryable: true
          }, 429);
        }
        return respond({
          error: "L’assistant IA est momentanément indisponible. Réessaie dans quelques instants.",
          code: "AI_PROVIDER_UNAVAILABLE",
          retryable: true
        }, 503);
      }
      const answer = result.candidates?.[0]?.content?.parts?.map(part => part.text || "").join("").trim();
      if (!answer) return respond({ error: "Réponse IA indisponible" }, 502);
      return respond({ answer, assistant: mode, course, model: aiResponse.model });
    } catch (error) {
      console.error("Kavelynt Worker internal error", error);
      return respond({
        error: "Erreur interne du service Kavelynt",
        code: "WORKER_INTERNAL",
        diagnostic: String(error?.message || error || "Erreur inconnue").slice(0, 500)
      }, 500);
    }
  }
};
