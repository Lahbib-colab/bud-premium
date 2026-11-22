import Foundation

// ═══════════════════════════════════════════════════════════
//  Trois sous-agents d'exemple
//
//  Posés dans ~/Library/Application Support/BUD-Assistant/
//  scripts/ au premier lancement, jamais écrasés ensuite : vos
//  modifications survivent aux mises à jour de BUD.
//
//  Ils sont écrits en Python 3, présent dès que les outils en
//  ligne de commande le sont — ce que BUD exige déjà pour
//  compiler. Ils servent autant d'exemples que d'outils : les
//  copier est la façon la plus courte d'en écrire un quatrième.
//
//  Chacun se teste seul, sans lancer BUD :
//      echo '{"contract":1,"agent":"tidy-downloads"}' | ./run
// ═══════════════════════════════════════════════════════════

extension ScriptAgents {

    /// (dossier, manifeste, exécutable)
    static let examples: [(String, String, String)] = [

        // ─────────────────────────────────────────────────────
        //  1. Les actions en attente, extraites du courrier
        //
        //  Il lit le cache que BUD écrit déjà. Aucun accès au
        //  réseau, aucun identifiant : le travail coûteux est
        //  fait une fois par BUD, les sous-agents le relisent.
        // ─────────────────────────────────────────────────────
        ("mail-actions",
         """
         {
           "title": "Actions en attente",
           "detail": "Relit la boîte déjà relevée et en extrait ce qui demande une réponse, un paiement ou une échéance.",
           "timeout": 15,
           "every": 30,
           "contract": 1
         }
         """,
         #"""
         #!/usr/bin/env python3
         # -*- coding: utf-8 -*-
         """Extrait les actions en attente du cache de courrier de BUD.

         Entrée : le contrat AgentInput sur stdin.
         Sortie : le contrat AgentOutput sur stdout.

         Ne touche ni au réseau ni aux identifiants : BUD a déjà relevé la
         boîte, ce script ne fait que relire ce qu'il a écrit.
         """
         import json, os, re, sys, unicodedata

         def fold(s):
             s = (s or "").lower()
             return "".join(c for c in unicodedata.normalize("NFD", s)
                            if unicodedata.category(c) != "Mn")

         # Chaque règle : (genre, niveau, expressions). L'ordre compte — la
         # première qui correspond l'emporte, et les plus engageantes
         # viennent en premier.
         RULES = [
             ("Paiement",     "action",  [r"\ba regler\b", r"\bmontant du\b", r"\bimpaye\b",
                                          r"\bechec de (?:paiement|prelevement)\b",
                                          r"\bfacture (?:a|en attente)", r"\bpayer avant\b"]),
             ("Échéance",     "action",  [r"\bavant le \d", r"\bd ?ici le \d", r"\bexpire le \d",
                                          r"\bau plus tard\b", r"\bsous \d+ ?(?:h|heures|jours)\b",
                                          r"\bdate limite\b", r"\bderniers? jours?\b"]),
             ("Confirmation", "action",  [r"\bconfirmez\b", r"\bveuillez confirmer\b",
                                          r"\bvalidez votre\b", r"\bconfirmation requise\b"]),
             ("Réponse",      "action",  [r"\bdans l attente de (?:votre|ta) reponse\b",
                                          r"\bpeux-?tu\b", r"\bpourriez-?vous\b",
                                          r"\bmerci de (?:me )?(?:confirmer|repondre|revenir)\b",
                                          r"\brsvp\b", r"\bqu en penses?-?(?:tu|vous)\b"]),
         ]

         def classify(text):
             t = fold(text)
             for kind, level, pats in RULES:
                 for p in pats:
                     if re.search(p, t):
                         return kind, level
             return None, None

         def main():
             try:
                 json.load(sys.stdin)          # on valide l'entrée même sans s'en servir
             except Exception:
                 pass
             support = os.environ.get("BUD_SUPPORT", "")
             cache = os.path.join(support, "inbox-cache.json")
             if not os.path.exists(cache):
                 print(json.dumps({"contract": 1, "ok": True,
                                   "summary": "Aucune boîte relevée pour l'instant.",
                                   "items": []}, ensure_ascii=False))
                 return
             with open(cache, encoding="utf-8") as f:
                 box = json.load(f)

             items = []
             for m in box.get("messages", []):
                 subject = m.get("subject", "")
                 snippet = (m.get("snippet", "") or "")[:600]
                 kind, level = classify(subject + " " + snippet)
                 if not kind:
                     continue
                 sender = m.get("sender", "") or "(inconnu)"
                 score = (m.get("threat") or {}).get("score", 0)

                 # Un message signalé ne devient jamais une tâche. « Confirmez
                 # votre compte » dans un courriel dangereux n'est pas une
                 # action à faire : c'est exactement le piège. On le remonte
                 # en avertissement, pas en liste de choses à faire.
                 if score >= 25:
                     items.append({
                         "title": "Demande suspecte : %s" % subject[:70],
                         "detail": "%s — BUD a relevé un risque (score %d). "
                                   "Ne répondez pas sans vérifier." % (sender[:60], score),
                         "level": "warning", "open": ""})
                 else:
                     items.append({
                         "title": "%s — %s" % (kind, subject[:70]),
                         "detail": sender[:80],
                         "level": level, "open": ""})

             todo = sum(1 for i in items if i["level"] == "action")
             warn = len(items) - todo
             summary = "%d action(s) en attente" % todo
             if warn:
                 summary += ", %d demande(s) suspecte(s)" % warn
             print(json.dumps({"contract": 1, "ok": True, "summary": summary,
                               "items": items[:40]}, ensure_ascii=False))

         if __name__ == "__main__":
             main()
         """#),

        // ─────────────────────────────────────────────────────
        //  2. Le rangement des téléchargements
        //
        //  Par défaut il ne déplace rien : il dit ce qu'il
        //  ferait. Un agent qui range des fichiers tout seul au
        //  premier lancement est un agent qu'on désinstalle.
        // ─────────────────────────────────────────────────────
        ("tidy-downloads",
         """
         {
           "title": "Ranger les téléchargements",
           "detail": "Propose un classement par type des fichiers de Téléchargements. Ne déplace rien sans y être invité.",
           "timeout": 20,
           "every": 0,
           "contract": 1
         }
         """,
         #"""
         #!/usr/bin/env python3
         # -*- coding: utf-8 -*-
         """Classe les téléchargements par type.

         Par défaut, simulation : le script dit ce qu'il ferait. Pour
         exécuter réellement, BUD passe {"payload": {"apply": "yes"}}.

         Un agent qui déplace des fichiers dès son installation est un
         agent qu'on désinstalle : le défaut est donc l'inaction.
         """
         import json, os, shutil, sys

         GROUPS = {
             "Images":    {".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".tiff"},
             "Documents": {".pdf", ".docx", ".pages", ".txt", ".md", ".rtf", ".odt"},
             "Tableurs":  {".xlsx", ".numbers", ".csv", ".tsv"},
             "Archives":  {".zip", ".dmg", ".pkg", ".tar", ".gz", ".7z"},
             "Audio":     {".mp3", ".m4a", ".wav", ".aiff", ".flac"},
             "Vidéo":     {".mp4", ".mov", ".m4v", ".avi", ".mkv"},
         }

         def group_of(name):
             ext = os.path.splitext(name)[1].lower()
             for g, exts in GROUPS.items():
                 if ext in exts:
                     return g
             return None

         def main():
             try:
                 data = json.load(sys.stdin)
             except Exception:
                 data = {}
             apply = (data.get("payload") or {}).get("apply") == "yes"
             dl = os.path.expanduser("~/Downloads")
             if not os.path.isdir(dl):
                 print(json.dumps({"contract": 1, "ok": False,
                                   "error": "Dossier Téléchargements introuvable."}))
                 return

             items, moved = [], 0
             for name in sorted(os.listdir(dl)):
                 if name.startswith("."):
                     continue
                 src = os.path.join(dl, name)
                 if not os.path.isfile(src):
                     continue
                 # Un téléchargement en cours ne se range pas.
                 if name.endswith((".download", ".crdownload", ".part")):
                     continue
                 g = group_of(name)
                 if not g:
                     continue
                 dst_dir = os.path.join(dl, g)
                 dst = os.path.join(dst_dir, name)
                 if apply:
                     os.makedirs(dst_dir, exist_ok=True)
                     # Jamais d'écrasement : on numérote.
                     base, ext = os.path.splitext(name)
                     n = 1
                     while os.path.exists(dst):
                         dst = os.path.join(dst_dir, "%s-%d%s" % (base, n, ext))
                         n += 1
                     shutil.move(src, dst)
                     moved += 1
                     items.append({"title": "Rangé : %s" % name[:60],
                                   "detail": "→ Téléchargements/%s" % g,
                                   "level": "info", "open": dst_dir})
                 else:
                     items.append({"title": name[:60],
                                   "detail": "irait dans Téléchargements/%s" % g,
                                   "level": "info", "open": src})

             if apply:
                 summary = "%d fichier(s) rangé(s)." % moved
             elif items:
                 summary = "%d fichier(s) à ranger. Relancez avec « appliquer »." % len(items)
             else:
                 summary = "Rien à ranger."
             print(json.dumps({"contract": 1, "ok": True, "summary": summary,
                               "items": items[:40]}, ensure_ascii=False))

         if __name__ == "__main__":
             main()
         """#),

        // ─────────────────────────────────────────────────────
        //  3. La veille locale
        //
        //  Ce qu'on vérifierait soi-même de temps en temps et
        //  qu'on oublie toujours.
        // ─────────────────────────────────────────────────────
        ("watch-local",
         """
         {
           "title": "Veille locale",
           "detail": "Disque, corbeille, caches, sauvegardes : ce qu'on vérifierait de temps en temps et qu'on oublie.",
           "timeout": 25,
           "every": 180,
           "contract": 1
         }
         """,
         #"""
         #!/usr/bin/env python3
         # -*- coding: utf-8 -*-
         """Quelques vérifications locales, sans réseau ni privilèges.

         Chaque contrôle est indépendant et protégé : un disque absent ou
         une commande indisponible ne doit pas faire échouer le reste.
         """
         import json, os, shutil, subprocess, sys, time

         def human(n):
             for u in ("o", "Ko", "Mo", "Go", "To"):
                 if n < 1024:
                     return "%.0f %s" % (n, u)
                 n /= 1024.0
             return "%.0f To" % n

         def dir_size(path, cap_seconds=4):
             """Taille d'un dossier, avec une limite de temps : parcourir une
             corbeille de cent mille fichiers ne doit pas tenir l'agent."""
             total, stop = 0, time.time() + cap_seconds
             for root, dirs, files in os.walk(path, onerror=lambda e: None):
                 for f in files:
                     try:
                         total += os.lstat(os.path.join(root, f)).st_size
                     except OSError:
                         pass
                 if time.time() > stop:
                     return total, True
             return total, False

         def main():
             try:
                 json.load(sys.stdin)
             except Exception:
                 pass
             items = []

             # Espace du disque de démarrage
             try:
                 u = shutil.disk_usage("/")
                 pct = u.free * 100 // u.total
                 items.append({
                     "title": "Disque : %s libres (%d %%)" % (human(u.free), pct),
                     "detail": "sur %s" % human(u.total),
                     "level": "warning" if pct <= 10 else "info", "open": ""})
             except Exception:
                 pass

             # Corbeille
             try:
                 trash = os.path.expanduser("~/.Trash")
                 if os.path.isdir(trash):
                     size, partial = dir_size(trash)
                     if size > 512 * 1024 * 1024:
                         items.append({
                             "title": "Corbeille : %s%s" % (human(size), " ou plus" if partial else ""),
                             "detail": "Vider la corbeille libérerait cette place.",
                             "level": "action", "open": trash})
             except Exception:
                 pass

             # Caches utilisateur
             try:
                 caches = os.path.expanduser("~/Library/Caches")
                 if os.path.isdir(caches):
                     size, partial = dir_size(caches)
                     if size > 2 * 1024 ** 3:
                         items.append({
                             "title": "Caches : %s%s" % (human(size), " ou plus" if partial else ""),
                             "detail": "Les applications les reconstruiront au besoin.",
                             "level": "info", "open": caches})
             except Exception:
                 pass

             # Dernière sauvegarde Time Machine
             try:
                 out = subprocess.run(["/usr/bin/tmutil", "latestbackup"],
                                      capture_output=True, text=True, timeout=6)
                 if out.returncode == 0 and out.stdout.strip():
                     items.append({"title": "Dernière sauvegarde Time Machine",
                                   "detail": os.path.basename(out.stdout.strip()),
                                   "level": "info", "open": ""})
                 else:
                     items.append({"title": "Aucune sauvegarde Time Machine",
                                   "detail": "Aucun instantané trouvé sur ce Mac.",
                                   "level": "warning", "open": ""})
             except Exception:
                 pass

             warn = sum(1 for i in items if i["level"] in ("warning", "action"))
             summary = "%d point(s) d'attention" % warn if warn else "Rien à signaler."
             print(json.dumps({"contract": 1, "ok": True, "summary": summary,
                               "items": items}, ensure_ascii=False))

         if __name__ == "__main__":
             main()
         """#),
    ]
}
