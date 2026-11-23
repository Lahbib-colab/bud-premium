import Cocoa

// ═══════════════════════════════════════════════════════════
//  Conversation avec BUD
//  Assistant local : aucune requête réseau, aucune clé d'API.
//  BUD comprend des intentions et agit sur la machine.
// ═══════════════════════════════════════════════════════════

struct ChatMsg {
    let fromBud: Bool
    let text: String
    let date: Date
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

/// Bulle de conversation, hauteur calculée sur le texte réel.
final class ChatBubble: NSView {
    private let msg: ChatMsg
    private let textRect: NSRect

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        let r = (text as NSString).boundingRect(
            with: NSSize(width: width - 32, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: p])
        return ceil(r.height) + 26
    }

    init(frame: NSRect, msg: ChatMsg) {
        self.msg = msg
        self.textRect = NSRect(x: 16, y: 13, width: frame.width - 32, height: frame.height - 26)
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        if msg.fromBud {
            TH.fill(0.07).setFill()
            path.fill()
            TH.fill(0.07).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            TH.accent.withAlphaComponent(0.22).setFill()
            path.fill()
            TH.accent.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        (msg.text as NSString).draw(
            with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                         .foregroundColor: TH.text.withAlphaComponent(msg.fromBud ? 0.92 : 1),
                         .paragraphStyle: p])
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

        // Suggestions rapides
        var x: CGFloat = 0
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
        let answer = BudBrain.reply(to: text, actions: actions) { [weak self] late in
            self?.append(ChatMsg(fromBud: true, text: late, date: Date()))
        }
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
        for m in messages { heights.append(ChatBubble.height(for: m.text, width: maxW)) }
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
