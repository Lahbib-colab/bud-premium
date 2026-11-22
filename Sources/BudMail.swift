import Cocoa

// ═══════════════════════════════════════════════════════════
//  Courrier
//  BUD s'appuie sur Mail.app, déjà configuré avec votre compte
//  Gmail : aucun mot de passe ne transite par BUD, aucune clé
//  d'API, aucune connexion sortante de notre fait.
// ═══════════════════════════════════════════════════════════

struct MailMessage {
    let subject: String
    let sender: String
    let date: String

    // Enrichissements IMAP. Valeurs par défaut : la passerelle Mail.app
    // ne les fournit pas, et l'initialiseur à trois champs reste valable.
    var uid: String = ""
    var messageID: String = ""
    var replyTo: String = ""
    var returnPath: String = ""
    var authResults: String = ""
    var spf: String = ""
    var snippet: String = ""
    var attachments: [String] = []
    var unread: Bool = true
    var threat = MailThreat()

    /// Adresse seule, sans le nom affiché.
    var address: String { MailGuard.address(in: sender) }

    /// Ce qu'on montre dans la liste : le nom s'il existe, sinon l'adresse.
    var shortSender: String {
        let n = MailGuard.displayName(in: sender)
        return n.isEmpty ? address : n
    }
}

enum MailBridge {

    @discardableResult
    static func osa(_ script: String) -> String {
        runShell("/usr/bin/osascript", ["-e", script])
    }

    static func mailAppInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/System/Applications/Mail.app")
            || FileManager.default.fileExists(atPath: "/Applications/Mail.app")
    }

    static func mailRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.mail"
        }
    }

    /// Nombre de messages non lus, toutes boîtes de réception confondues.
    /// Renvoie -1 si Mail n'est pas joignable (fermé, ou autorisation refusée).
    static func unreadCount() -> Int {
        guard mailRunning() else { return -1 }
        let out = osa("""
        tell application "Mail"
            try
                set n to 0
                repeat with acc in every account
                    try
                        set n to n + (count of (messages of mailbox "INBOX" of acc whose read status is false))
                    end try
                end repeat
                if n = 0 then set n to (count of (messages of inbox whose read status is false))
                return n
            on error
                return -1
            end try
        end tell
        """)
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// Les derniers messages non lus de la boîte de réception.
    static func latestUnread(_ limit: Int = 5) -> [MailMessage] {
        guard mailRunning() else { return [] }
        let out = osa("""
        tell application "Mail"
            try
                set res to ""
                set msgs to (messages of inbox whose read status is false)
                set n to count of msgs
                if n > \(limit) then set n to \(limit)
                repeat with i from 1 to n
                    set m to item i of msgs
                    set res to res & (subject of m) & "|~|" & (sender of m) & "|~|" & ((date received of m) as string) & "|#|"
                end repeat
                return res
            on error
                return ""
            end try
        end tell
        """)
        return out.components(separatedBy: "|#|").compactMap { block in
            let p = block.components(separatedBy: "|~|")
            guard p.count >= 3 else { return nil }
            return MailMessage(subject: p[0].trimmingCharacters(in: .whitespacesAndNewlines),
                               sender: p[1].trimmingCharacters(in: .whitespacesAndNewlines),
                               date: p[2].trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Envoie par Mail.app. `from` vide : le compte par défaut est utilisé.
    static func send(to: String, subject: String, body: String, from: String) -> String {
        guard mailAppInstalled() else { return "Mail.app est introuvable sur ce Mac." }
        var props = "{subject:\"\(esc(subject))\", content:\"\(esc(body))\", visible:false"
        if !from.isEmpty { props += ", sender:\"\(esc(from))\"" }
        props += "}"
        let out = osa("""
        tell application "Mail"
            try
                set m to make new outgoing message with properties \(props)
                tell m
                    make new to recipient at end of to recipients with properties {address:"\(esc(to))"}
                    send
                end tell
                return "ok"
            on error errMsg
                return errMsg
            end try
        end tell
        """)
        if out.hasPrefix("ok") { return "Message envoyé à \(to)." }
        if out.isEmpty { return "Mail n'a pas répondu. Autorisez BUD dans Confidentialité → Automatisation." }
        return "Envoi refusé : \(out)"
    }

    /// Ouvre une fenêtre de rédaction pré-remplie, sans rien envoyer.
    static func compose(to: String, subject: String, body: String) {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = to
        c.queryItems = [URLQueryItem(name: "subject", value: subject),
                        URLQueryItem(name: "body", value: body)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    static func openInbox() {
        if mailAppInstalled() { runShell("/usr/bin/open", ["-a", "Mail"]) }
        else if let u = URL(string: "https://mail.google.com/") { NSWorkspace.shared.open(u) }
    }

    static func openGmailWeb() {
        if let u = URL(string: "https://mail.google.com/mail/u/0/#inbox") { NSWorkspace.shared.open(u) }
    }
}

/// Choisit la bonne voie : Gmail en direct quand un compte est enregistré,
/// Mail.app sinon.
enum MailRouter {
    /// Adresse du compte « mot de passe d'application », vide si aucun.
    static var account: String = ""
    static var appPassword: String? { account.isEmpty ? nil : BudKeychain.get(account) }

    static var oauthReady: Bool { GmailAuth.shared.isConnected }
    static var gmailReady: Bool { oauthReady || appPassword != nil }

    static var activeAddress: String {
        oauthReady ? GmailAuth.shared.email : account
    }
    static var sourceLabel: String {
        if oauthReady { return "Google" }
        if appPassword != nil { return "Gmail" }
        return "Mail.app"
    }

    private static func mode() -> (String, GmailAuthMode)? {
        if oauthReady, let x = GmailAuth.shared.xoauth2() {
            return (GmailAuth.shared.email, .oauth(x))
        }
        if let p = appPassword { return (account, .appPassword(p)) }
        return nil
    }

    static func snapshot(_ limit: Int = 5) -> (unread: Int, msgs: [MailMessage], source: String, error: String?) {
        if let (user, auth) = mode() {
            let s = GmailClient.fetchInbox(user: user, auth: auth, limit: limit)
            return (s.unread, s.messages, sourceLabel, s.error)
        }
        guard MailBridge.mailRunning() else { return (-1, [], "Mail.app", "Mail est fermé.") }
        return (MailBridge.unreadCount(), MailBridge.latestUnread(limit), "Mail.app", nil)
    }

    static func send(to: String, subject: String, body: String, mailFrom: String,
                     inReplyTo: String = "") -> String {
        if let (user, auth) = mode() {
            return GmailClient.send(user: user, auth: auth, to: to,
                                    subject: subject, body: body, inReplyTo: inReplyTo)
        }
        return MailBridge.send(to: to, subject: subject, body: body, from: mailFrom)
    }

    /// Déplace des messages vers le dossier indésirable. Possible
    /// uniquement en IMAP : la passerelle Mail.app ne l'expose pas.
    static func quarantine(_ uids: [String]) -> String? {
        guard let (user, auth) = mode() else {
            return "Reliez un compte Gmail pour isoler des messages."
        }
        return GmailClient.quarantine(user: user, auth: auth, uids: uids)
    }
}

/// Une ligne de la boîte de réception : expéditeur, objet, date et
/// verdict d'analyse. Dessinée à la main pour tenir en 46 pt sans
/// rien tronquer et pour réagir au survol.
final class MailRow: NSView {
    let message: MailMessage
    var selected = false { didSet { needsDisplay = true } }
    var onSelect: ((MailMessage) -> Void)?
    private var hover = false
    private var track: NSTrackingArea?

    init(frame: NSRect, message: MailMessage) {
        self.message = message
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = track { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        track = t
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { onSelect?(message) }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let card = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
        TH.fill(selected ? 0.16 : (hover ? 0.10 : 0.055)).setFill()
        card.fill()
        if selected {
            TH.accent.withAlphaComponent(0.55).setStroke()
            card.lineWidth = 1.5
            card.stroke()
        }

        let lvl = message.threat.level
        // Liseré de verdict à gauche : vert, ambre ou rouge.
        let bar = NSBezierPath(roundedRect: NSRect(x: 8, y: 9, width: 4, height: r.height - 18),
                               xRadius: 2, yRadius: 2)
        lvl.color.withAlphaComponent(lvl == .clean ? 0.45 : 0.95).setFill()
        bar.fill()

        // Pastille de non-lu.
        var x: CGFloat = 20
        if message.unread {
            TH.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: r.height / 2 - 3, width: 6, height: 6)).fill()
            x += 12
        }

        // Date à droite, et badge de menace s'il y a lieu.
        var rightEdge = r.width - 12
        if lvl != .clean {
            let txt = lvl.label
            let w = textWidth(txt, size: 9.5, weight: .bold) + 18
            let box = NSRect(x: rightEdge - w, y: r.height / 2 - 9, width: w, height: 18)
            lvl.color.withAlphaComponent(0.20).setFill()
            capsule(box).fill()
            lvl.color.withAlphaComponent(0.75).setStroke()
            let c = capsule(box); c.lineWidth = 1; c.stroke()
            drawString(txt, in: NSRect(x: box.minX, y: box.midY - 6.5, width: box.width, height: 13),
                       size: 9.5, weight: .bold, color: lvl.color, align: .center)
            rightEdge -= w + 8
        }
        let shortDate = String(message.date.prefix(17))
        if !shortDate.isEmpty {
            let dw = min(textWidth(shortDate, size: 9.5, weight: .regular), 110)
            drawString(shortDate,
                       in: NSRect(x: rightEdge - dw, y: r.height - 21, width: dw, height: 13),
                       size: 9.5, weight: .regular, color: TH.dim(0.38), align: .right)
            rightEdge -= dw + 10
        }

        let textW = max(60, rightEdge - x)
        drawString(message.shortSender.isEmpty ? "(inconnu)" : message.shortSender,
                   in: NSRect(x: x, y: r.height - 23, width: textW, height: 16),
                   size: 12, weight: message.unread ? .bold : .semibold, color: TH.text)
        drawString(message.subject.isEmpty ? "(sans objet)" : message.subject,
                   in: NSRect(x: x, y: 7, width: textW, height: 15),
                   size: 11, weight: .regular, color: TH.dim(0.55))

        if !message.attachments.isEmpty {
            drawSymbol("paperclip", center: NSPoint(x: r.width - 10, y: 14),
                       size: 10, weight: .semibold, color: TH.dim(0.45))
        }
    }
}

final class MailPanelView: NSView {
    private let hero: HeroHeader
    private var unreadTile: StatTile!
    private var riskTile: StatTile!
    private var stateTile: StatTile!
    private var threatCard: NSView!
    private var threatTitle: NSTextField!
    private var threatBody: NSTextField!
    private var isolateBtn: GlassButton!
    private var replyBtn: GlassButton!
    private var selected: MailMessage?
    private var lastMessages: [MailMessage] = []
    private var replyRef: String = ""
    private var listHost = NSView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var rows: [NSView] = []
    private var toField: NSTextField!
    private var subjectField: NSTextField!
    private var bodyView: NSTextView!
    private var statusLabel: NSTextField!
    private var accountLabel: NSTextField!

    var onStatus: ((String) -> Void)?
    var fromAddress: () -> String = { "" }
    var onAccountChange: ((String) -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Courrier", subtitle: "Vos messages non lus et un envoi rapide.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height

        // Trois compteurs : à lire, à surveiller, et la voie utilisée.
        unreadTile = StatTile(frame: NSRect(x: W - 384, y: H - 86, width: 118, height: 78),
                              caption: "Non lus", hint: "réception")
        riskTile = StatTile(frame: NSRect(x: W - 256, y: H - 86, width: 118, height: 78),
                            caption: "Suspects", hint: "analyse locale")
        stateTile = StatTile(frame: NSRect(x: W - 128, y: H - 86, width: 118, height: 78),
                             caption: "Voie", hint: "—")
        [unreadTile, riskTile, stateTile].forEach { addSubview($0) }

        mkSection(self, 456, W, "Boîte de réception — cliquez un message")
        scroll.frame = NSRect(x: 0, y: 278, width: W, height: 174)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        // Carte de verdict du message sélectionné.
        threatCard = mkCard(self, NSRect(x: 0, y: 210, width: W, height: 62), radius: 13, alpha: 0.07)
        threatTitle = mkLabel("Sélectionnez un message pour voir son analyse.",
                              NSRect(x: 14, y: 36, width: W - 130, height: 16), 11.5, .semibold, alpha: 0.72)
        threatCard.addSubview(threatTitle)
        threatBody = NSTextField(frame: NSRect(x: 14, y: 8, width: W - 130, height: 28))
        threatBody.isBezeled = false
        threatBody.drawsBackground = false
        threatBody.isEditable = false
        threatBody.isSelectable = true
        threatBody.font = NSFont.systemFont(ofSize: 10.5)
        threatBody.textColor = TH.dim(0.50)
        threatBody.lineBreakMode = .byWordWrapping
        threatBody.cell?.usesSingleLineMode = false
        threatBody.cell?.wraps = true
        threatBody.maximumNumberOfLines = 2
        ThemeRegistry.shared.register(threatBody, alpha: 0.50)
        threatCard.addSubview(threatBody)

        isolateBtn = GlassButton(frame: NSRect(x: W - 110, y: 14, width: 96, height: 34),
                                 title: "Isoler", icon: "tray.and.arrow.down.fill")
        isolateBtn.destructive = true
        isolateBtn.enabledFlag = false
        isolateBtn.onClick = { [weak self] _ in self?.quarantineSelected() }
        threatCard.addSubview(isolateBtn)

        mkSection(self, 190, W, "Rédiger")
        toField = NSTextField(frame: NSRect(x: 0, y: 156, width: W * 0.48, height: 30))
        toField.placeholderString = "Destinataire"
        toField.font = NSFont.systemFont(ofSize: 12.5)
        subjectField = NSTextField(frame: NSRect(x: W * 0.48 + 10, y: 156, width: W * 0.52 - 10, height: 30))
        subjectField.placeholderString = "Objet"
        subjectField.font = NSFont.systemFont(ofSize: 12.5)
        [toField, subjectField].forEach { addSubview($0) }

        accountLabel = mkLabel("", NSRect(x: 2, y: 62, width: W - 4, height: 14), 10, .regular, alpha: 0.38)
        addSubview(accountLabel)

        let bodyScroll = NSScrollView(frame: NSRect(x: 0, y: 80, width: W, height: 70))
        bodyScroll.hasVerticalScroller = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.wantsLayer = true
        bodyScroll.layer?.cornerRadius = 12
        bodyScroll.layer?.masksToBounds = true
        let big: CGFloat = 1_000_000
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: W, height: 70))
        tv.minSize = NSSize(width: 0, height: 70)
        tv.maxSize = NSSize(width: big, height: big)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: W, height: big)
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = true
        tv.backgroundColor = TH.fill(0.06)
        tv.textColor = TH.text
        tv.insertionPointColor = TH.text
        tv.font = NSFont.systemFont(ofSize: 12.5)
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 10, height: 10)
        bodyScroll.documentView = tv
        bodyView = tv
        addSubview(bodyScroll)

        statusLabel = mkLabel("", NSRect(x: 0, y: 46, width: W, height: 16), 10.5, .regular, alpha: 0.45, .center)
        addSubview(statusLabel)

        let bw = (W - 48) / 5
        let specs: [(String, String, Bool, () -> Void)] = [
            ("Envoyer", "paperplane.fill", true, { [weak self] in self?.send() }),
            ("Répondre", "arrowshape.turn.up.left.fill", false, { [weak self] in self?.reply() }),
            ("Analyser", "shield.lefthalf.filled", false, { [weak self] in self?.analyzeAll() }),
            ("Compte", "person.crop.circle", false, { [weak self] in self?.accountDialog() }),
            ("Actualiser", "arrow.clockwise", false, { [weak self] in self?.refresh() })
        ]
        var made: [GlassButton] = []
        for (i, sp) in specs.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (bw + 12), y: 0, width: bw, height: 42),
                                title: sp.0, icon: sp.1, prominent: sp.2)
            b.onClick = { _ in sp.3() }
            addSubview(b)
            made.append(b)
        }
        replyBtn = made[1]
        replyBtn.enabledFlag = false
    }

    // ── Sélection d'un message ──

    private func select(_ m: MailMessage) {
        selected = m
        replyBtn.enabledFlag = true
        isolateBtn.enabledFlag = !m.uid.isEmpty && MailRouter.gmailReady
        for r in rows { (r as? MailRow)?.selected = (r as? MailRow)?.message.uid == m.uid }

        let lvl = m.threat.level
        threatTitle.stringValue = "\(lvl.label) · \(m.shortSender) · \(m.address)"
        threatTitle.textColor = lvl == .clean ? TH.dim(0.72) : lvl.color
        var detail = m.threat.summary
        if !m.attachments.isEmpty {
            detail += "  —  pièces jointes : " + m.attachments.joined(separator: ", ")
        }
        threatBody.stringValue = detail
    }

    /// Prépare une réponse : objet préfixé, corps cité, et le Message-ID
    /// d'origine conservé pour que le fil reste groupé chez le destinataire.
    private func reply() {
        guard let m = selected else {
            statusLabel.stringValue = "Choisissez d'abord un message dans la liste."
            return
        }
        if m.threat.level == .dangerous {
            let a = NSAlert()
            a.messageText = "Répondre à un message dangereux ?"
            a.informativeText = "BUD a relevé : \(m.threat.summary)\n\n"
                + "Répondre confirme à l'expéditeur que votre adresse est active."
            a.addButton(withTitle: "Annuler")
            a.addButton(withTitle: "Répondre quand même")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertSecondButtonReturn else { return }
        }

        // Le Reply-To prime sur le From quand il est légitime ; s'il
        // pointe ailleurs, l'analyse l'a déjà signalé et on garde le From.
        var dest = m.address
        if !m.replyTo.isEmpty && m.threat.level == .clean {
            let r = MailGuard.address(in: m.replyTo)
            if r.contains("@") { dest = r }
        }
        toField.stringValue = dest
        let subj = m.subject.trimmingCharacters(in: .whitespaces)
        subjectField.stringValue = subj.lowercased().hasPrefix("re:") ? subj : "Re: \(subj)"

        let quoted = m.snippet
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(18)
            .map { "> " + $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        bodyView.string = "\n\nLe \(m.date), \(m.shortSender) a écrit :\n" + quoted
        bodyView.setSelectedRange(NSRange(location: 0, length: 0))
        replyRef = m.messageID
        window?.makeFirstResponder(bodyView)
        statusLabel.stringValue = "Réponse préparée pour \(dest)."
    }

    private func quarantineSelected() {
        guard let m = selected, !m.uid.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Isoler ce message ?"
        a.informativeText = "« \(m.subject) » de \(m.address) sera déplacé vers le dossier "
            + "des indésirables de votre compte. Rien n'est supprimé : vous pourrez l'y retrouver.\n\n"
            + m.threat.summary
        a.addButton(withTitle: "Isoler")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        statusLabel.stringValue = "Déplacement en cours…"
        let uid = m.uid
        DispatchQueue.global(qos: .userInitiated).async {
            let err = MailRouter.quarantine([uid])
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                if let e = err {
                    s.statusLabel.stringValue = e
                } else {
                    s.statusLabel.stringValue = "Message isolé dans les indésirables."
                    s.onStatus?("Message isolé")
                    s.selected = nil
                    s.refresh()
                }
            }
        }
    }

    /// Analyse complète : la boîte de réception, puis les fichiers déjà
    /// téléchargés. Le second volet interroge Gatekeeper, qui connaît les
    /// signatures qu'une heuristique ignore.
    private func analyzeAll() {
        statusLabel.stringValue = "Analyse en cours…"
        let msgs = lastMessages
        DispatchQueue.global(qos: .userInitiated).async {
            let files = MailGuard.scanDownloads()
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                let danger = msgs.filter { $0.threat.level == .dangerous }
                let suspect = msgs.filter { $0.threat.level == .suspect }

                var report = "Messages analysés : \(msgs.count)\n"
                report += "Dangereux : \(danger.count) · Suspects : \(suspect.count)\n"
                for m in (danger + suspect).prefix(6) {
                    report += "\n• \(m.threat.level.label) — \(m.shortSender)\n   \(m.threat.summary)"
                }
                if !files.isEmpty {
                    report += "\n\nTéléchargements douteux : \(files.count)"
                    for f in files.prefix(6) {
                        report += "\n• \(f.url.lastPathComponent) — \(f.reason)"
                    }
                }
                if danger.isEmpty && suspect.isEmpty && files.isEmpty {
                    report += "\nRien à signaler."
                }

                let a = NSAlert()
                a.messageText = "Analyse de sécurité"
                a.informativeText = report
                    + "\n\nBUD juge la forme des messages, pas le contenu des fichiers : "
                    + "ce n'est pas un antivirus."
                if !danger.isEmpty { a.addButton(withTitle: "Isoler les \(danger.count) dangereux") }
                if !files.isEmpty { a.addButton(withTitle: "Mettre \(files.count) fichier(s) à la corbeille") }
                a.addButton(withTitle: "Fermer")
                NSApp.activate(ignoringOtherApps: true)
                let r = a.runModal()

                var idx = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if !danger.isEmpty {
                    if r.rawValue == idx { s.isolate(danger.map { $0.uid }); return }
                    idx += 1
                }
                if !files.isEmpty, r.rawValue == idx {
                    let n = MailGuard.trash(files.map { $0.url })
                    s.statusLabel.stringValue = "\(n) fichier(s) mis à la corbeille."
                    s.onStatus?("\(n) fichier(s) douteux à la corbeille")
                }
            }
        }
    }

    private func isolate(_ uids: [String]) {
        let clean = uids.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        statusLabel.stringValue = "Isolement de \(clean.count) message(s)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let err = MailRouter.quarantine(clean)
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                s.statusLabel.stringValue = err ?? "\(clean.count) message(s) isolés."
                if err == nil { s.onStatus?("\(clean.count) message(s) isolés"); s.refresh() }
            }
        }
    }

    /// Fenêtre unique pour relier un compte : Google en un clic, ou
    /// mot de passe d'application si vous préférez.
    private func accountDialog() {
        let auth = GmailAuth.shared
        let a = NSAlert()
        a.messageText = "Compte de messagerie"
        a.informativeText = auth.isConnected
            ? "Connecté à \(auth.email) par Google OAuth."
            : (MailRouter.appPassword != nil
               ? "Connecté à \(MailRouter.account) par mot de passe d'application."
               : "Reliez votre compte Google, ou utilisez un mot de passe d'application. "
                 + "Pour tout faire depuis votre téléphone, passez par l'onglet Téléphone (⌘⌥P).")

        let v = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 176))
        func label(_ t: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.frame = NSRect(x: 0, y: y, width: 420, height: 14)
            l.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            l.textColor = .secondaryLabelColor
            v.addSubview(l)
        }
        label("IDENTIFIANT CLIENT GOOGLE (application de bureau)", 162)
        let idField = NSTextField(frame: NSRect(x: 0, y: 132, width: 420, height: 24))
        idField.placeholderString = "xxxxx.apps.googleusercontent.com"
        idField.stringValue = auth.clientID
        v.addSubview(idField)

        label("CODE SECRET CLIENT — facultatif avec PKCE", 110)
        let secretField = NSSecureTextField(frame: NSRect(x: 0, y: 80, width: 420, height: 24))
        secretField.placeholderString = "GOCSPX-… (laissez vide si non requis)"
        secretField.stringValue = auth.clientSecret
        v.addSubview(secretField)

        label("OU MOT DE PASSE D'APPLICATION", 58)
        let mailField = NSTextField(frame: NSRect(x: 0, y: 28, width: 210, height: 24))
        mailField.placeholderString = "adresse@gmail.com"
        mailField.stringValue = MailRouter.account
        let passField = NSSecureTextField(frame: NSRect(x: 218, y: 28, width: 202, height: 24))
        passField.placeholderString = "16 caractères"
        [mailField, passField].forEach { v.addSubview($0) }

        let note = NSTextField(labelWithString: "Les identifiants sont rangés dans le trousseau macOS, jamais sur disque.")
        note.frame = NSRect(x: 0, y: 4, width: 420, height: 16)
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)
        a.accessoryView = v

        a.addButton(withTitle: "Connexion Google")
        a.addButton(withTitle: "Mot de passe d'app")
        a.addButton(withTitle: auth.isConnected || MailRouter.appPassword != nil ? "Déconnecter" : "Fermer")
        a.addButton(withTitle: "Annuler")

        NSApp.activate(ignoringOtherApps: true)
        let choice = a.runModal()

        switch choice {
        case .alertFirstButtonReturn:
            let id = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.contains("apps.googleusercontent.com") else {
                statusLabel.stringValue = "Collez l'identifiant client Google (…apps.googleusercontent.com)."
                return
            }
            auth.clientID = id
            auth.clientSecret = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            startGoogleFlow()
        case .alertSecondButtonReturn:
            connectAppPassword(mail: mailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                               pass: passField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case .alertThirdButtonReturn:
            if auth.isConnected || MailRouter.appPassword != nil { disconnectAll() }
        default:
            break
        }
    }

    private func startGoogleFlow() {
        statusLabel.stringValue = "Votre navigateur s'ouvre pour le consentement Google…"
        onStatus?("Autorisation Google en cours")
        GoogleOAuth.authorize(clientID: GmailAuth.shared.clientID,
                              clientSecret: GmailAuth.shared.clientSecret) { [weak self] tokens, err in
            guard let s = self else { return }
            guard let t = tokens, !t.email.isEmpty else {
                s.statusLabel.stringValue = "Connexion Google échouée : \(err ?? "inconnu")"
                s.onStatus?("Google refusé")
                return
            }
            GmailAuth.shared.store(t)
            s.onAccountChange?(t.email)
            s.statusLabel.stringValue = "Connecté à \(t.email) — lecture et envoi directs."
            s.onStatus?("Gmail connecté")
            s.refresh()
        }
    }

    private func connectAppPassword(mail: String, pass: String) {
        guard mail.contains("@") else {
            statusLabel.stringValue = "Indiquez votre adresse Gmail complète."
            return
        }
        guard pass.count >= 12 else {
            statusLabel.stringValue = "Le mot de passe d'application fait 16 caractères."
            return
        }
        statusLabel.stringValue = "Vérification auprès de Gmail…"
        DispatchQueue.global(qos: .userInitiated).async {
            let err = GmailClient.testLogin(user: mail, password: pass)
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                if let e = err {
                    s.statusLabel.stringValue = e
                    s.onStatus?(e)
                    return
                }
                BudKeychain.set(GmailClient.normalizedPassword(pass), account: mail)
                MailRouter.account = mail
                s.onAccountChange?(mail)
                s.statusLabel.stringValue = "Compte connecté, mot de passe dans le trousseau."
                s.onStatus?("Gmail connecté")
                s.refresh()
            }
        }
    }

    private func disconnectAll() {
        GmailAuth.shared.disconnect()
        if !MailRouter.account.isEmpty {
            BudKeychain.delete(MailRouter.account)
            MailRouter.account = ""
        }
        onAccountChange?("")
        statusLabel.stringValue = "Compte déconnecté. BUD repasse par Mail.app."
        refresh()
    }

    func refresh() {
        let installed = MailBridge.mailAppInstalled()
        let running = MailBridge.mailRunning()
        let gmail = MailRouter.gmailReady

        accountLabel.stringValue = MailRouter.oauthReady
            ? "Google OAuth · \(GmailAuth.shared.email) · jetons dans le trousseau"
            : (gmail ? "Mot de passe d'application · \(MailRouter.account)"
                     : "Aucun compte relié — bouton Compte pour connecter Google.")

        stateTile.set(MailRouter.sourceLabel == "Mail.app"
                        ? (running ? "Mail.app" : (installed ? "Fermé" : "Absent"))
                        : MailRouter.sourceLabel,
                      hint: MailRouter.oauthReady ? "OAuth 2.0"
                          : (gmail ? "IMAP/SMTP" : (running ? "via Mail" : "ouvrez Mail")))

        guard gmail || running else {
            unreadTile.set("—", hint: "aucune source")
            riskTile.set("—", hint: "analyse locale")
            hero.set(subtitle: "Connectez votre compte Gmail, ou ouvrez Mail.", trailing: "")
            rebuildList([])
            return
        }

        unreadTile.set("…", hint: "lecture en cours")
        riskTile.set("…", hint: "analyse")
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = MailRouter.snapshot(8)
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                let n = snap.unread
                s.unreadTile.set(n < 0 ? "—" : "\(n)",
                                 hint: n < 0 ? (snap.error ?? "indisponible")
                                             : (n == 0 ? "boîte à jour" : "à lire"))
                s.hero.set(subtitle: n <= 0 ? "Rien à lire pour l'instant · \(snap.source)"
                                            : "\(n) message(s) non lus · \(snap.source)",
                           trailing: n > 0 ? "\(n) non lus" : "")
                let danger = snap.msgs.filter { $0.threat.level == .dangerous }.count
                let suspect = snap.msgs.filter { $0.threat.level == .suspect }.count
                s.riskTile.set(danger > 0 ? "\(danger)" : "\(suspect)",
                               hint: danger > 0 ? "dangereux" : (suspect > 0 ? "suspects" : "rien à signaler"))
                s.rebuildList(snap.msgs)
                if let e = snap.error { s.statusLabel.stringValue = e }
            }
        }
    }

    private func rebuildList(_ msgs: [MailMessage]) {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        ThemeRegistry.shared.prune()
        lastMessages = msgs

        let W = scroll.bounds.width - 6
        let rowH: CGFloat = 52
        let totalH = max(scroll.bounds.height, CGFloat(msgs.count) * rowH)
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: totalH)

        if msgs.isEmpty {
            let l = mkLabel(MailRouter.gmailReady || MailBridge.mailRunning()
                            ? "Boîte vide." : "Aucune source de courrier.",
                            NSRect(x: 0, y: totalH / 2 - 10, width: W, height: 20),
                            12, .medium, alpha: 0.35, .center)
            listHost.addSubview(l)
            rows.append(l)
            return
        }
        for (i, m) in msgs.enumerated() {
            let y = totalH - CGFloat(i + 1) * rowH + 6
            let row = MailRow(frame: NSRect(x: 0, y: y, width: W, height: rowH - 6), message: m)
            row.onSelect = { [weak self] msg in self?.select(msg) }
            listHost.addSubview(row)
            rows.append(row)
        }
        // On garde la sélection après un rafraîchissement.
        if let sel = selected, let again = msgs.first(where: { $0.uid == sel.uid && !sel.uid.isEmpty }) {
            select(again)
        } else {
            selected = nil
            replyBtn?.enabledFlag = false
            isolateBtn?.enabledFlag = false
            threatTitle?.stringValue = "Sélectionnez un message pour voir son analyse."
            threatTitle?.textColor = TH.dim(0.72)
            threatBody?.stringValue = ""
        }
    }

    private func send() {
        let to = toField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard to.contains("@") else {
            statusLabel.stringValue = "Indiquez une adresse de destinataire valide."
            return
        }
        let subject = subjectField.stringValue
        let body = bodyView.string
        let a = NSAlert()
        a.messageText = "Envoyer ce message ?"
        a.informativeText = "À : \(to)\nObjet : \(subject.isEmpty ? "(aucun)" : subject)"
            + "\nVoie : " + (MailRouter.gmailReady
                               ? "\(MailRouter.sourceLabel) (\(MailRouter.activeAddress))"
                               : "Mail.app")
        a.addButton(withTitle: "Envoyer")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        statusLabel.stringValue = "Envoi en cours…"
        let from = fromAddress()
        let ref = replyRef
        DispatchQueue.global(qos: .userInitiated).async {
            let res = MailRouter.send(to: to, subject: subject, body: body,
                                      mailFrom: from, inReplyTo: ref)
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.stringValue = res
                self?.onStatus?(res)
                if res.hasPrefix("Message envoyé") {
                    self?.toField.stringValue = ""
                    self?.subjectField.stringValue = ""
                    self?.bodyView.string = ""
                    self?.replyRef = ""
                }
            }
        }
    }

    private func composeExternally() {
        MailBridge.compose(to: toField.stringValue, subject: subjectField.stringValue, body: bodyView.string)
        statusLabel.stringValue = "Brouillon ouvert dans votre client de messagerie."
    }

    /// Pré-remplit la fenêtre depuis le chat.
    func prefill(to: String, subject: String, body: String) {
        toField.stringValue = to
        subjectField.stringValue = subject
        bodyView.string = body
    }
}
