import Cocoa

// ═══════════════════════════════════════════════════════════
//  Conversation avec BUD
//  Assistant local : aucune requête réseau, aucune clé d'API.
//  BUD comprend des intentions et agit sur la machine.
// ═══════════════════════════════════════════════════════════

struct ChatMsg {
    let fromBud: Bool
    var text: String
    let date: Date

    // ── Les bulles d'outil ──
    //  Une bulle d'outil est une bulle de BUD avec une pastille à gauche,
    //  qui tourne pendant le travail, puis dit oui ou non. Elle peut porter
    //  une miniature, et un geste au clic.
    var id = UUID()
    var tool: ToolBubble? = nil
    var image: NSImage? = nil
    var tapLabel: String? = nil
    var tap: (() -> Void)? = nil
}

struct ToolBubble {
    enum Phase { case waiting, working, ok, failed }
    var icon: String
    var tint: NSColor
    var phase: Phase
}

/// Actions que le délégué expose au cerveau de BUD.
struct ChatActions {
    var storageReport: () -> String = { "" }
    var agentsReport: () -> String = { "" }
    var vitalsReport: () -> String = { "" }
    var focusReport: () -> String = { "" }
    var startFocus: (Int) -> String = { _ in "" }
    var stopFocus: () -> String = { "" }
    var emptyTrash: (@escaping (String) -> Void) -> Void = { _ in }
    var runCleanup: () -> String = { "" }
    var ejectAll: () -> String = { "" }
    var addNote: (String) -> String = { _ in "" }
    var listSnippets: () -> String = { "" }
    var copySnippet: (String) -> String = { _ in "" }
    var openCapture: () -> String = { "" }
    var openFolder: (String) -> String = { _ in "" }
    var tellJoke: () -> String = { "" }
    var mailReport: () -> String = { "" }
    var composeMail: (String, String, String) -> String = { _, _, _ in "" }
    var addReminder: (String) -> String = { _ in "" }
    var remindersReport: () -> String = { "" }
    var music: (String) -> String = { _ in "" }
    var giveTip: () -> String = { "" }
    // ── Ajouts 23.6 ──
    var batteryReport: () -> String = { "" }
    var networkReport: () -> String = { "" }
    var lockScreen: () -> String = { "" }
    var sleepDisplay: () -> String = { "" }
    /// « dark », « light » ou « toggle ».
    var setAppearance: (String) -> String = { _ in "" }
    /// « screen », « window » ou « selection ».
    var screenshot: (String) -> String = { _ in "" }
    /// Durée en minutes, et la phrase d'origine pour l'intitulé.
    var startTimer: (Int, String) -> String = { _, _ in "" }
    var webSearch: (String) -> String = { _ in "" }
    // ── Sous-agents ──
    /// Lance un sous-agent. Le résultat arrive plus tard, par `late`.
    var runAgent: (String, [String: String], @escaping (String) -> Void) -> Void = { _, _, _ in }
    var listAgents: () -> String = { "" }
    // ── Météo et maison (25.3) ──
    /// La météo en une phrase ; `late` reçoit le relevé s'il faut l'attendre.
    var weather: (@escaping (String) -> Void) -> String = { _ in "" }
    /// Lance la commande de la maison qui correspond à la phrase, ou rend
    /// `nil` si aucune ne correspond — la phrase suit alors son chemin.
    var home: (String, @escaping (String) -> Void) -> String? = { _, _ in nil }
}

enum BudBrain {

    /// L'aveu d'incompréhension, écrit une seule fois. Le panneau le
    /// compare au début de la réponse pour savoir s'il faut prendre l'air
    /// perplexe : une phrase dupliquée aurait fini par diverger, et le
    /// visage aurait souri en disant « je n'ai pas saisi ».
    static let lostReply = "Je n'ai pas saisi."


    private static func norm(_ s: String) -> String {
        let lowered = s.lowercased()
        let folded = lowered.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        return folded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func has(_ t: String, _ words: [String]) -> Bool {
        words.contains { t.contains($0) }
    }

    private static func firstNumber(in t: String) -> Int? {
        let parts = t.split(whereSeparator: { !$0.isNumber })
        return parts.first.flatMap { Int($0) }
    }

    static let suggestions = ["Mes mails",
                              "Batterie",
                              "20 % de 480",
                              "Capture la fenêtre",
                              "Que sais-tu faire ?"]

    /// Renvoie la réponse de BUD. `async` : certaines actions répondent plus tard.
    static func reply(to raw: String, actions: ChatActions,
                      late: @escaping (String) -> Void) -> String {
        let t = norm(raw)
        guard !t.isEmpty else { return "Je t'écoute." }

        // La maison d'abord : seule une commande du dossier qui correspond
        // nettement à la phrase la déclenche. « Bonjour » peut être une
        // scène, et doit alors l'emporter sur la salutation.
        if let r = actions.home(raw, late) { return r }
        if has(t, ["meteo", "quel temps", "temps fait", "temps fera", "temps qu il fait",
                   "pleut", "pleuvoir", "pluie", "parapluie", "va neiger", "il neige",
                   "fait chaud", "fait froid", "fait il chaud", "fait il froid", "temperature dehors"]) {
            return actions.weather(late)
        }

        if has(t, ["bonjour", "salut", "coucou", "hello", "bonsoir", "hey"]) {
            let g = timeGreeting()
            return "\(g.0) ! \(g.1)"
        }
        if has(t, ["merci", "super", "parfait", "genial", "bravo"]) {
            return "Avec plaisir. Autre chose ?"
        }
        if has(t, ["aide", "help", "que sais tu", "que sais-tu", "capacites", "tu peux faire", "commandes"]) {
            return """
            Voilà ce que je sais faire, en langage courant :
            • « combien d'espace reste-t-il ? » — état des disques
            • « vide la corbeille » ou « nettoie les résidus »
            • « éjecte les disques externes »
            • « lance un focus de 30 minutes » / « arrête le focus »
            • « note : rappeler le dentiste » — ajoute une note
            • « mes snippets » / « copie le snippet signature »
            • « ouvre les téléchargements » (bureau, documents, rangement…)
            • « mes mails », « envoie un mail à paul@exemple.fr pour dire bonjour »
            • « rappelle-moi d'appeler Paul à 17h30 », « mes rappels »
            • « musique », « morceau suivant », « monte le volume », « aléatoire »
            • « où en sont mes agents ? », « cpu », « l'heure », « une blague »
            • « batterie », « mon adresse IP », « verrouille l'écran »
            • « passe en mode sombre », « capture la fenêtre »
            • « préviens-moi dans 15 minutes »
            • « quel temps fait-il ? », « va-t-il pleuvoir ? » — la météo
            • « lumière salon », « bonne nuit » — vos commandes Maison
            • « cherche la recette du pain perdu » — ouvre une recherche web
            • « 23 × 7 », « (120 + 80) / 4 », « 20 % de 480 » — je calcule
            Et le micro, à côté du champ : je transcris sur votre Mac, \
            sans envoyer votre voix nulle part.
            """
        }
        if has(t, ["heure", "quelle heure"]) {
            return "Il est \(clockString()), nous sommes \(longDateString().lowercased())."
        }
        if has(t, ["blague", "rigole", "drole", "fais moi rire"]) {
            return actions.tellJoke()
        }
        if has(t, ["conseil", "astuce", "motive"]) {
            return actions.giveTip()
        }

        // ── Stockage et nettoyage ──
        if has(t, ["ejecte", "ejecter", "demonte", "debranche"]) {
            return actions.ejectAll()
        }
        if has(t, ["corbeille"]) && has(t, ["vide", "vider", "purge", "efface"]) {
            actions.emptyTrash { msg in late("Corbeille vidée : \(msg)") }
            return "Je vide la corbeille, un instant…"
        }
        if has(t, ["nettoie", "nettoyage", "residus", "fais du menage", "menage", "cache"]) {
            return actions.runCleanup()
        }
        if has(t, ["espace", "place", "disque", "stockage", "plein", "libre", "go ", "ssd"]) {
            return actions.storageReport()
        }
        if has(t, ["cpu", "memoire", "ram", "processeur", "charge", "uptime", "veille"]) {
            return actions.vitalsReport()
        }

        // ── Focus ──
        if has(t, ["focus", "concentration", "pomodoro", "minuteur"]) {
            if has(t, ["arrete", "stop", "annule", "fini"]) { return actions.stopFocus() }
            if has(t, ["lance", "demarre", "commence", "start", "mets"]) {
                return actions.startFocus(firstNumber(in: t) ?? 0)
            }
            return actions.focusReport()
        }

        // ── Notes et snippets ──
        if t.hasPrefix("note") || has(t, ["note :", "note:", "retiens", "souviens", "rappelle moi", "ajoute une note"]) {
            var body = raw
            for marker in ["note :", "note:", "Note :", "Note:", "retiens", "souviens-toi", "rappelle-moi"] {
                if let r = body.range(of: marker) { body = String(body[r.upperBound...]); break }
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return "Dis-moi quoi noter, par exemple « note : appeler le garage »." }
            return actions.addNote(body)
        }
        if has(t, ["snippet", "extrait", "modele"]) {
            if has(t, ["copie", "colle", "donne", "mets"]) {
                let words = raw.split(separator: " ").map(String.init)
                let key = words.last ?? ""
                return actions.copySnippet(key)
            }
            return actions.listSnippets()
        }
        if has(t, ["dictee", "dicte", "capture", "ecrire vite"]) {
            return actions.openCapture()
        }

        // ── Courrier ──
        if has(t, ["mail", "mail", "courrier", "message", "boite", "gmail", "inbox"]) {
            if has(t, ["envoie", "envoyer", "ecris", "ecrire", "redige", "rediger"]) {
                // « envoie un mail à paul@x.fr pour dire que je serai en retard »
                var to = ""
                for w in raw.split(whereSeparator: { " \n\t,;:".contains($0) }) where w.contains("@") {
                    to = String(w).trimmingCharacters(in: CharacterSet(charactersIn: "<>«»\""))
                    break
                }
                var body = ""
                for marker in [" pour dire ", " pour lui dire ", " disant ", " avec ", " : "] {
                    if let r = raw.range(of: marker) { body = String(raw[r.upperBound...]); break }
                }
                return actions.composeMail(to, body.isEmpty ? "" : String(body.prefix(60)), body)
            }
            return actions.mailReport()
        }

        // ── Rappels ──
        if has(t, ["rappelle", "rappel", "alarme", "n'oublie pas", "pense a", "reveille"]) {
            if has(t, ["mes rappels", "liste", "quels rappels", "prevu"]) { return actions.remindersReport() }
            return actions.addReminder(raw)
        }

        // ── Musique ──
        if has(t, ["musique", "chanson", "morceau", "joue", "pause", "volume",
                   "suivant", "precedent", "lecture", "aleatoire"]) {
            if has(t, ["aleatoire", "shuffle"]) { return actions.music("shuffle") }
            if has(t, ["suivant", "next", "passe"]) { return actions.music("next") }
            if has(t, ["precedent", "retour", "avant"]) { return actions.music("prev") }
            if has(t, ["monte", "plus fort", "augmente"]) { return actions.music("up") }
            if has(t, ["baisse", "moins fort", "diminue"]) { return actions.music("down") }
            if has(t, ["joue", "pause", "lance", "arrete", "stop", "reprend"]) { return actions.music("play") }
            return actions.music("status")
        }

        // ── Agents ──
        if has(t, ["agent", "validation", "demande", "approbation", "claude code"]) {
            return actions.agentsReport()
        }

        // ── Dossiers ──
        if has(t, ["ouvre", "montre", "affiche"]) {
            for (keys, name) in [(["telechargement", "download"], "Downloads"),
                                 (["bureau", "desktop"], "Desktop"),
                                 (["document"], "Documents"),
                                 (["image", "photo"], "Pictures"),
                                 (["rangement", "classe"], "SORT"),
                                 (["application"], "Applications")] {
                if has(t, keys) { return actions.openFolder(name) }
            }
        }

        // ── Batterie, réseau, écran ──
        if has(t, ["batterie", "charge restante", "autonomie", "secteur"]) {
            return actions.batteryReport()
        }
        if has(t, ["wifi", "wi-fi", "reseau", "ip", "adresse locale", "connexion"]) {
            return actions.networkReport()
        }
        if has(t, ["verrouille", "verrouiller", "ecran de veille", "bloque l ecran", "bloque la session"]) {
            return actions.lockScreen()
        }
        if has(t, ["eteins l ecran", "veille ecran", "coupe l ecran", "endors l ecran"]) {
            return actions.sleepDisplay()
        }

        // ── Apparence ──
        if has(t, ["mode sombre", "passe en sombre", "theme sombre", "nuit"]) {
            return actions.setAppearance("dark")
        }
        if has(t, ["mode clair", "passe en clair", "theme clair", "jour"]) {
            return actions.setAppearance("light")
        }
        if has(t, ["apparence", "clair sombre", "bascule le theme"]) {
            return actions.setAppearance("toggle")
        }

        // ── Capture ──
        if has(t, ["capture", "copie d ecran", "screenshot", "photo de l ecran"]) {
            if has(t, ["fenetre"]) { return actions.screenshot("window") }
            if has(t, ["selection", "zone", "morceau"]) { return actions.screenshot("selection") }
            return actions.screenshot("screen")
        }

        // ── Compte à rebours ──
        //
        //  « minuteur » appartient déjà au focus, plus haut : employer le
        //  même mot ici ferait une intention morte, que la première
        //  attraperait toujours.
        if has(t, ["chrono", "compte a rebours", "reveille moi", "previens moi"]),
           let n = firstNumber(in: t), n > 0, n <= 600 {
            let unit = has(t, ["heure"]) ? 60 : 1
            return actions.startTimer(n * unit, raw)
        }

        // ── Recherche web ──
        if has(t, ["cherche", "recherche", "google", "trouve moi", "c est quoi"]) {
            // On retire le verbe pour ne pas chercher « cherche la recette ».
            var q = raw
            for w in ["cherche sur le web", "cherche sur internet", "recherche sur le web",
                      "cherche moi", "cherche", "recherche", "google", "trouve moi",
                      "c'est quoi", "c est quoi"] {
                q = q.replacingOccurrences(of: w, with: "", options: .caseInsensitive)
            }
            q = q.trimmingCharacters(in: CharacterSet(charactersIn: " ?!.,:;«»\"'"))
            if q.count >= 2 { return actions.webSearch(q) }
        }

        if has(t, ["comment vas tu", "ca va", "tu vas bien"]) {
            return "Je tourne à \(clockString()) sans un accroc. " + actions.vitalsReport()
        }

        // ── Sous-agents ──
        //
        //  Le chat est la surface de commande de BUD : tout sous-agent
        //  installé s'y lance par son nom, sans qu'il faille ajouter un
        //  bouton ni un panneau. C'est ce qui rend le système extensible
        //  côté utilisateur, et pas seulement côté code.
        if has(t, ["mes actions", "a faire", "ce qui m attend", "actions en attente"]) {
            actions.runAgent("mail-actions", [:]) { late($0) }
            return "Je regarde ce qui attend une réponse…"
        }
        if has(t, ["range", "trie"]) && has(t, ["telechargement", "download"]) {
            let apply = has(t, ["applique", "vraiment", "fais le", "confirme"])
            actions.runAgent("tidy-downloads", apply ? ["apply": "yes"] : [:]) { late($0) }
            return apply ? "Je range…" : "Je regarde ce qu'il y aurait à ranger…"
        }
        if has(t, ["veille", "verifie mon mac", "etat du mac"]) {
            actions.runAgent("watch-local", [:]) { late($0) }
            return "Je fais le tour…"
        }
        if has(t, ["mes scripts", "mes sous agents", "quels agents", "liste des agents"]) {
            return actions.listAgents()
        }

        // ── Calcul ──
        //
        //  En dernier, et sous condition : une phrase quelconque contenant
        //  un nombre ne doit pas être prise pour une opération. Il faut un
        //  chiffre ET un opérateur, sinon « mes 5 mails » deviendrait un
        //  calcul.
        if let r = Calc.answer(raw) { return r }

        return lostReply + """
         Essaie par exemple « combien d'espace me reste-t-il ? », \
        « vide la corbeille », « lance un focus de 25 minutes » ou « que sais-tu faire ? ».
        """
    }
}

// ═══════════════════════════════════════════════════════════
//  Calcul
//
//  Écrit à la main, et non confié à `NSExpression` : celui-ci
//  évalue bien plus qu'une opération — il sait instancier des
//  classes et appeler des méthodes par leur nom. Lui passer
//  une chaîne venue du champ de saisie serait lui donner les
//  clés de l'application pour additionner deux nombres.
//
//  Grammaire, par priorité croissante :
//      expr   := terme (('+' | '-') terme)*
//      terme  := puiss (('*' | '/' | '%') puiss)*
//      puiss  := unaire ('^' puiss)?        — associatif à droite
//      unaire := '-'? primaire
//      prim   := nombre | '(' expr ')'
// ═══════════════════════════════════════════════════════════

enum Calc {

    /// La réponse en français, ou `nil` si ce n'était pas un calcul.
    static func answer(_ raw: String) -> String? {
        if let (part, whole) = percentOf(raw) {
            return "\(format(part / 100 * whole)) — soit \(format(part)) % de \(format(whole))."
        }
        guard let expr = sanitize(raw), looksLikeMath(expr) else { return nil }
        var p = Parser(Array(expr))
        guard let v = p.parseExpression(), p.atEnd else { return nil }
        guard v.isFinite else { return "Cette opération ne donne pas de nombre fini." }
        return "\(format(v))"
    }

    /// « 20 % de 480 », « 7% du 250 ».
    private static func percentOf(_ raw: String) -> (Double, Double)? {
        let pattern = "(-?[0-9]+(?:[.,][0-9]+)?)\\s*%\\s*(?:de|du|des|of)\\s+(-?[0-9]+(?:[.,][0-9]+)?)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let r = NSRange(raw.startIndex..., in: raw)
        guard let m = re.firstMatch(in: raw, range: r), m.numberOfRanges >= 3,
              let r1 = Range(m.range(at: 1), in: raw),
              let r2 = Range(m.range(at: 2), in: raw),
              let a = number(String(raw[r1])), let b = number(String(raw[r2])) else { return nil }
        return (a, b)
    }

    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }

    /// Traduit les mots en symboles, puis ne garde que ce qui compose une
    /// opération. Tout le reste disparaît — un mot inconnu ne doit pas
    /// pouvoir atteindre l'analyseur.
    private static func sanitize(_ raw: String) -> String? {
        var s = raw.lowercased()
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        for (word, sym) in [("multiplie par", "*"), ("multiplier par", "*"),
                            ("divise par", "/"), ("diviser par", "/"),
                            ("puissance", "^"), ("modulo", "%"),
                            ("plus", "+"), ("moins", "-"), ("fois", "*")] {
            s = s.replacingOccurrences(of: word, with: sym)
        }
        s = s.replacingOccurrences(of: ",", with: ".")
        let kept = s.filter { "0123456789.+-*/^%() ".contains($0) }
        let compact = kept.replacingOccurrences(of: " ", with: "")
        return compact.isEmpty ? nil : compact
    }

    /// Un chiffre et un opérateur au minimum : sans cette garde, « mes 5
    /// mails » arriverait ici réduit à « 5 » et serait annoncé comme un
    /// résultat de calcul.
    private static func looksLikeMath(_ s: String) -> Bool {
        let hasDigit = s.contains { $0.isNumber }
        let ops = s.filter { "+-*/^%".contains($0) }
        return hasDigit && !ops.isEmpty && s.count >= 3
    }

    private static func format(_ v: Double) -> String {
        if abs(v.rounded() - v) < 1e-9 && abs(v) < 1e15 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = Locale(identifier: "fr_FR")
            f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: v)) ?? String(Int(v))
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "fr_FR")
        f.maximumFractionDigits = 6
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    private struct Parser {
        let c: [Character]
        var i = 0
        init(_ chars: [Character]) { c = chars }

        var atEnd: Bool { i >= c.count }
        private func peek() -> Character? { i < c.count ? c[i] : nil }

        mutating func parseExpression() -> Double? {
            guard var lhs = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                i += 1
                guard let rhs = parseTerm() else { return nil }
                lhs = (op == "+") ? lhs + rhs : lhs - rhs
            }
            return lhs
        }

        mutating func parseTerm() -> Double? {
            guard var lhs = parsePower() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                i += 1
                guard let rhs = parsePower() else { return nil }
                switch op {
                case "*": lhs *= rhs
                case "/":
                    // On ne rend pas d'infini : la division par zéro fait
                    // échouer le calcul, et l'appelant le dira.
                    guard rhs != 0 else { return nil }
                    lhs /= rhs
                default:
                    guard rhs != 0 else { return nil }
                    lhs = lhs.truncatingRemainder(dividingBy: rhs)
                }
            }
            return lhs
        }

        mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if let op = peek(), op == "^" {
                i += 1
                guard let e = parsePower() else { return nil }
                // Un exposant démesuré bloquerait le calcul : on refuse.
                guard abs(e) <= 64 else { return nil }
                return pow(base, e)
            }
            return base
        }

        mutating func parseUnary() -> Double? {
            if let op = peek(), op == "-" { i += 1; return parseUnary().map { -$0 } }
            if let op = peek(), op == "+" { i += 1; return parseUnary() }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Double? {
            guard let ch = peek() else { return nil }
            if ch == "(" {
                i += 1
                guard let v = parseExpression(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            var digits = ""
            while let d = peek(), d.isNumber || d == "." {
                digits.append(d)
                i += 1
            }
            return digits.isEmpty ? nil : Double(digits)
        }
    }
}

/// Bulle de conversation, hauteur calculée sur le contenu réel.
final class ChatBubble: NSView {
    private let msg: ChatMsg
    private var textRect = NSRect.zero
    private var imageRect = NSRect.zero
    private var tapRect = NSRect.zero
    private var spin: CGFloat = 0
    private var timer: Timer?

    private static let iconW: CGFloat = 34
    private static let imageMaxH: CGFloat = 150

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        let r = (text as NSString).boundingRect(
            with: NSSize(width: width, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .paragraphStyle: p])
        return ceil(r.height)
    }

    private static func imageHeight(_ img: NSImage?, width: CGFloat) -> CGFloat {
        guard let i = img, i.size.width > 0 else { return 0 }
        return min(imageMaxH, width * i.size.height / i.size.width)
    }

    static func height(for m: ChatMsg, width: CGFloat) -> CGFloat {
        let inner = width - 32 - (m.tool == nil ? 0 : iconW)
        var h = textHeight(m.text, width: inner) + 26
        let ih = imageHeight(m.image, width: inner)
        if ih > 0 { h += ih + 10 }
        if m.tapLabel != nil { h += 20 }
        return h
    }

    init(frame: NSRect, msg: ChatMsg) {
        self.msg = msg
        super.init(frame: frame)
        wantsLayer = true
        // Du bas vers le haut : le geste, la miniature, le texte.
        let x: CGFloat = 16 + (msg.tool == nil ? 0 : ChatBubble.iconW)
        let w = frame.width - 16 - x
        var y: CGFloat = 13
        if msg.tapLabel != nil {
            tapRect = NSRect(x: x, y: y - 2, width: w, height: 16)
            y += 20
        }
        let ih = ChatBubble.imageHeight(msg.image, width: w)
        if ih > 0, let img = msg.image {
            let iw = min(w, ih * img.size.width / img.size.height)
            imageRect = NSRect(x: x, y: y, width: iw, height: ih)
            y += ih + 10
        }
        textRect = NSRect(x: x, y: y, width: w, height: frame.height - y - 13)
        if msg.tap != nil { toolTip = msg.tapLabel }
        setAccessibilityLabel(msg.text)
    }
    required init?(coder: NSCoder) { fatalError() }

    // La pastille tourne pendant le travail, et seulement à l'écran.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let busy = msg.tool?.phase == .working || msg.tool?.phase == .waiting
        if window != nil, busy, timer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.spin += 0.2
                self?.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if window == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    override func resetCursorRects() {
        if msg.tap != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func mouseUp(with e: NSEvent) {
        guard let tap = msg.tap, bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        tap()
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        if msg.fromBud {
            TH.fill(0.07).setFill()
            path.fill()
            let edge: NSColor
            switch msg.tool?.phase {
            case .some(.failed): edge = dangerColor.withAlphaComponent(0.45)
            case .some(.waiting): edge = (msg.tool?.tint ?? TH.accent).withAlphaComponent(0.45)
            default: edge = TH.fill(0.07)
            }
            edge.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            TH.accent.withAlphaComponent(0.22).setFill()
            path.fill()
            TH.accent.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        if let t = msg.tool {
            let c = NSPoint(x: 16 + 11, y: r.maxY - 13 - 10)
            let disc = NSRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)
            switch t.phase {
            case .working, .waiting:
                t.tint.withAlphaComponent(0.25).setFill()
                NSBezierPath(ovalIn: disc).fill()
                let a = NSBezierPath()
                let start = t.phase == .working ? spin * 57.3 : 90
                a.appendArc(withCenter: c, radius: 8, startAngle: start, endAngle: start + (t.phase == .working ? 260 : 360))
                a.lineWidth = 2
                a.lineCapStyle = .round
                t.tint.setStroke()
                a.stroke()
                if t.phase == .waiting {
                    drawSymbol("hand.raised.fill", center: c, size: 8, weight: .bold, color: t.tint)
                }
            case .ok:
                t.tint.setFill()
                NSBezierPath(ovalIn: disc).fill()
                drawSymbol("checkmark", center: c, size: 9, weight: .bold, color: .white)
            case .failed:
                dangerColor.setFill()
                NSBezierPath(ovalIn: disc).fill()
                drawSymbol("exclamationmark", center: c, size: 9, weight: .bold, color: .white)
            }
        }

        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        (msg.text as NSString).draw(
            with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                         .foregroundColor: TH.text.withAlphaComponent(msg.fromBud ? 0.92 : 1),
                         .paragraphStyle: p])

        if let img = msg.image, imageRect.width > 0 {
            NSGraphicsContext.current?.saveGraphicsState()
            let clip = NSBezierPath(roundedRect: imageRect, xRadius: 9, yRadius: 9)
            clip.addClip()
            img.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
            TH.fill(0.18).setStroke()
            clip.lineWidth = 0.8
            clip.stroke()
        }
        if let label = msg.tapLabel {
            drawString(label + "  ›", in: tapRect, size: 11.5, weight: .semibold, color: TH.accent)
        }
    }
}

final class ChatPanelView: NSView, NSTextFieldDelegate {
    private let hero: HeroHeader
    private let scroll = NSScrollView(frame: .zero)
    private let listHost = NSView(frame: .zero)
    private var input: NSTextField!
    private var bubbles: [NSView] = []
    private var messages: [ChatMsg] = []
    private var chips: [GlassButton] = []
    private var mic: MicButton!
    private var pill: ToolPillView!
    private var toolMenu: ToolMenuView?
    private var menuMonitor: Any?
    private var confirmBar: ToolConfirmBar?

    var actions = ChatActions()
    var onStatus: ((String) -> Void)?
    /// BUD vient de répondre. `understood` est faux quand la réponse est
    /// l'aveu d'incompréhension : c'est ce qui permet au compagnon de
    /// prendre l'air perplexe plutôt que de sourire en disant non.
    var onSpoke: ((_ understood: Bool) -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Chat", subtitle: "Parlez-moi normalement, j'agis sur votre Mac.")
        super.init(frame: frame)
        build()
        let g = timeGreeting()
        append(ChatMsg(fromBud: true,
                       text: "\(g.0) ! Demandez-moi de l'espace disque, un focus, un nettoyage… ou tapez « que sais-tu faire ? ».",
                       date: Date()))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height

        scroll.frame = NSRect(x: 0, y: 104, width: W, height: H - 196)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        // La pilule Outils ouvre la rangée ; les suggestions suivent.
        let pw = ToolPillView.idealWidth()
        pill = ToolPillView(frame: NSRect(x: 0, y: 62, width: pw, height: 32))
        pill.onClick = { [weak self] in self?.toggleToolMenu() }
        addSubview(pill)

        // Suggestions rapides
        var x: CGFloat = pw + 8
        for s in BudBrain.suggestions {
            let w = min(W - x, textWidth(s, size: 11.5, weight: .semibold) + 28)
            if x + w > W { break }
            let b = GlassButton(frame: NSRect(x: x, y: 62, width: w, height: 32), title: s, compact: true)
            b.onClick = { [weak self] _ in self?.send(s) }
            addSubview(b)
            chips.append(b)
            x += w + 8
        }

        input = NSTextField(frame: NSRect(x: 0, y: 6, width: W - 158, height: 44))
        input.placeholderString = "Écrivez à BUD, ou dictez…"
        input.font = NSFont.systemFont(ofSize: 13)
        input.bezelStyle = .roundedBezel
        input.focusRingType = .none
        input.delegate = self
        input.target = self
        input.action = #selector(sendFromField)
        addSubview(input)

        mic = MicButton(frame: NSRect(x: W - 148, y: 6, width: 44, height: 44))
        mic.onClick = { [weak self] in self?.toggleDictation() }
        addSubview(mic)

        let sendBtn = GlassButton(frame: NSRect(x: W - 96, y: 6, width: 96, height: 44),
                                  title: "Envoyer", icon: "paperplane.fill", prominent: true)
        sendBtn.onClick = { [weak self] _ in self?.sendFromField() }
        addSubview(sendBtn)

        wireVoice()
    }

    // ═══════════ Dictée ═══════════

    private func wireVoice() {
        let v = BudVoice.shared
        // Le texte reconnu s'écrit dans le champ au fil des mots : on voit
        // ce que BUD a compris avant que ce soit envoyé, et on peut
        // corriger au clavier plutôt que de tout redire.
        v.onPartial = { [weak self] t in self?.input.stringValue = t }
        v.onFinal = { [weak self] t in
            guard let s = self else { return }
            s.input.stringValue = ""
            s.send(t)
        }
        v.onTrouble = { [weak self] why in
            self?.append(ChatMsg(fromBud: true, text: why, date: Date()))
        }
        v.onState = { [weak self] in
            guard let s = self else { return }
            s.mic.listening = v.listening
            s.onStatus?(v.listening ? "BUD écoute…" : "")
        }
    }

    private func toggleDictation() {
        if !BudVoice.shared.listening { window?.makeFirstResponder(input) }
        BudVoice.shared.toggle()
    }

    /// Ouvre la dictée de l'extérieur — raccourci clavier, menu.
    func startDictation() {
        if !BudVoice.shared.listening { toggleDictation() }
    }

    func focusInput() { window?.makeFirstResponder(input) }

    @objc private func sendFromField() {
        let t = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input.stringValue = ""
        send(t)
    }

    func send(_ text: String) {
        append(ChatMsg(fromBud: false, text: text, date: Date()))
        // Un outil demandé en toutes lettres passe par le même chemin que
        // la pilule : même confirmation, même bulle, mêmes expressions.
        if let tool = BudToolManager.shared.intent(for: text) {
            runTool(tool.id)
            return
        }
        let answer = BudBrain.reply(to: text, actions: actions) { [weak self] late in
            self?.append(ChatMsg(fromBud: true, text: late, date: Date()))
        }
        // Une réponse vide : l'action a déjà parlé dans le fil.
        if answer.isEmpty { return }
        // L'aveu d'incompréhension se reconnaît à sa première phrase, et
        // non au texte entier : elle est écrite une fois, au seul endroit
        // qui la produit, et comparer le début évite qu'un ajout d'exemple
        // à la fin fasse mentir le test.
        let lost = answer.hasPrefix(BudBrain.lostReply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.append(ChatMsg(fromBud: true, text: answer, date: Date()))
            self?.onSpoke?(!lost)
        }
        onStatus?("BUD réfléchit…")
    }

    // ═══════════ Les outils ═══════════

    private func toggleToolMenu() {
        if toolMenu == nil { openToolMenu() } else { closeToolMenu() }
    }

    private func openToolMenu() {
        guard toolMenu == nil else { return }
        // Vers le haut, par-dessus la conversation, depuis le coin de la
        // pilule. Plafonné à la hauteur du fil : au-delà, le menu défile.
        let maxH = scroll.frame.maxY - pill.frame.maxY - 8
        let h = min(maxH, ToolMenuView.contentHeight())
        let menu = ToolMenuView(frame: NSRect(x: pill.frame.minX, y: pill.frame.maxY + 8,
                                              width: ToolMenuView.width, height: h))
        menu.onPick = { [weak self] t in
            self?.closeToolMenu()
            self?.runTool(t.id)
        }
        addSubview(menu, positioned: .above, relativeTo: nil)
        menu.present()
        toolMenu = menu
        pill.open = true

        // Un clic hors du menu et de la pilule le referme ; Échap aussi.
        menuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] e in
            guard let s = self, let m = s.toolMenu else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { s.closeToolMenu(); return nil }
                return e
            }
            guard e.window == s.window else { s.closeToolMenu(); return e }
            let p = s.convert(e.locationInWindow, from: nil)
            if !m.frame.contains(p) && !s.pill.frame.contains(p) { s.closeToolMenu() }
            return e
        }
    }

    private func closeToolMenu() {
        if let mon = menuMonitor { NSEvent.removeMonitor(mon); menuMonitor = nil }
        guard let m = toolMenu else { return }
        toolMenu = nil
        pill.open = false
        m.dismiss {}
    }

    /// Le point d'entrée unique : pilule, phrase du chat, voix.
    func runTool(_ id: String) {
        let mgr = BudToolManager.shared
        guard let t = mgr.tool(id) else { return }
        guard !mgr.isRunning(id), confirmBar == nil else {
            append(ChatMsg(fromBud: true, text: "Un instant, « \(t.title) » est déjà en cours.", date: Date()))
            return
        }
        switch t.risk {
        case .none:
            start(t, bubble: nil)
        case .confirm(let q):
            ask(t, question: q, seconds: nil)
        case .countdown(let n):
            ask(t, question: t.title, seconds: n)
        }
    }

    private func ask(_ t: BudTool, question: String, seconds: Int?) {
        var m = ChatMsg(fromBud: true,
                        text: seconds.map { "\(t.title) dans \($0) secondes. Annulez si ce n'est pas le moment." }
                              ?? question,
                        date: Date())
        m.tool = ToolBubble(icon: t.icon, tint: t.tint, phase: .waiting)
        let id = m.id
        append(m)
        // BUDs attend votre réponse : l'air réfléchi, le temps de la question.
        mgr().onExpression?(.reflection, Double(seconds ?? 8) + 1)

        // La barre prend la place des suggestions, juste au-dessus du champ.
        let W = bounds.width
        let bar = ToolConfirmBar(frame: NSRect(x: 0, y: 62, width: W, height: 32),
                                 tool: t, question: question, seconds: seconds)
        bar.onConfirm = { [weak self] in
            self?.dismissConfirm()
            self?.start(t, bubble: id)
        }
        bar.onCancel = { [weak self] in
            guard let s = self else { return }
            s.dismissConfirm()
            s.update(id) {
                $0.text = "\(t.title) : annulé."
                $0.tool?.phase = .ok
                $0.tool?.tint = NSColor(calibratedWhite: 0.55, alpha: 1)
            }
            s.mgr().onExpression?(.neutral, 2)
        }
        pill.isHidden = true
        chips.forEach { $0.isHidden = true }
        bar.alphaValue = 0
        addSubview(bar)
        confirmBar = bar
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            bar.animator().alphaValue = 1
        }
    }

    private func dismissConfirm() {
        confirmBar?.removeFromSuperview()
        confirmBar = nil
        pill.isHidden = false
        chips.forEach { $0.isHidden = false }
    }

    private func mgr() -> BudToolManager { BudToolManager.shared }

    /// La bulle « au travail », puis la même bulle, transformée en résultat :
    /// le fil ne garde qu'une trace par outil.
    private func start(_ t: BudTool, bubble existing: UUID?) {
        let id: UUID
        if let e = existing {
            id = e
            update(e) {
                $0.text = t.working
                $0.tool = ToolBubble(icon: t.icon, tint: t.tint, phase: .working)
            }
        } else {
            var m = ChatMsg(fromBud: true, text: t.working, date: Date())
            m.tool = ToolBubble(icon: t.icon, tint: t.tint, phase: .working)
            id = m.id
            append(m)
        }
        onStatus?("\(t.title)…")
        mgr().execute(t, progress: { [weak self] line in
            self?.update(id) { $0.text = line }
        }, done: { [weak self] out in
            guard let s = self else { return }
            s.update(id) {
                $0.text = out.text
                $0.tool = ToolBubble(icon: t.icon, tint: t.tint, phase: out.ok ? .ok : .failed)
                $0.image = out.image
                $0.tapLabel = out.tapLabel
                $0.tap = out.tap
            }
            s.onStatus?(out.text.components(separatedBy: "\n").first ?? "")
        })
    }

    private func update(_ id: UUID, _ change: (inout ChatMsg) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
        rebuild()
    }

    private func append(_ m: ChatMsg) {
        messages.append(m)
        if messages.count > 60 { messages.removeFirst(messages.count - 60) }
        rebuild()
    }

    func rebuild() {
        bubbles.forEach { $0.removeFromSuperview() }
        bubbles.removeAll()

        let W = scroll.bounds.width - 6
        let maxW = W * 0.82
        var heights: [CGFloat] = []
        for m in messages { heights.append(ChatBubble.height(for: m, width: maxW)) }
        let gap: CGFloat = 10
        let total = max(scroll.bounds.height, heights.reduce(0, +) + gap * CGFloat(max(0, messages.count)))
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: total)

        var y = total
        for (i, m) in messages.enumerated() {
            let h = heights[i]
            y -= h + gap
            let x = m.fromBud ? 0 : (W - maxW)
            let b = ChatBubble(frame: NSRect(x: x, y: y, width: maxW, height: h), msg: m)
            listHost.addSubview(b)
            bubbles.append(b)
        }
        listHost.scroll(NSPoint(x: 0, y: 0))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
