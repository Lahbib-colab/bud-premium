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
}

enum BudBrain {

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
                              "Rappelle-moi de partir à 18h",
                              "Musique suivante",
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
            • « musique », « morceau suivant », « monte le volume », « alexa »
            • « où en sont mes agents ? », « cpu », « l'heure », « une blague »
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
        if has(t, ["musique", "chanson", "morceau", "spotify", "alexa", "joue", "pause", "volume",
                   "suivant", "precedent", "lecture"]) {
            if has(t, ["alexa"]) { return actions.music("alexa") }
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

        if has(t, ["comment vas tu", "ca va", "tu vas bien"]) {
            return "Je tourne à \(clockString()) sans un accroc. " + actions.vitalsReport()
        }

        return """
        Je n'ai pas saisi. Essaie par exemple « combien d'espace me reste-t-il ? », \
        « vide la corbeille », « lance un focus de 25 minutes » ou « que sais-tu faire ? ».
        """
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

    var actions = ChatActions()
    var onStatus: ((String) -> Void)?

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

        input = NSTextField(frame: NSRect(x: 0, y: 6, width: W - 112, height: 44))
        input.placeholderString = "Écrivez à BUD…"
        input.font = NSFont.systemFont(ofSize: 13)
        input.bezelStyle = .roundedBezel
        input.focusRingType = .none
        input.delegate = self
        input.target = self
        input.action = #selector(sendFromField)
        addSubview(input)

        let sendBtn = GlassButton(frame: NSRect(x: W - 102, y: 6, width: 102, height: 44),
                                  title: "Envoyer", icon: "paperplane.fill", prominent: true)
        sendBtn.onClick = { [weak self] _ in self?.sendFromField() }
        addSubview(sendBtn)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.append(ChatMsg(fromBud: true, text: answer, date: Date()))
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
