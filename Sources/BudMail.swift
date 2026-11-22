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

    /// La date telle qu'une liste la montre.
    var shortDate: String { MailDate.short(header: date) }

    /// Première ligne du corps, pour l'aperçu : les retours à la ligne, les
    /// tabulations et les espaces insécables d'un courriel HTML converti
    /// deviennent un seul espace, sinon l'aperçu affiche des trous.
    var preview: String {
        let flat = snippet
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            // L'espace insécable est écrit en échappement Swift, et non en
            // « \u » d'expression régulière, qu'ICU n'accepte pas entre
            // accolades : la classe reçoit donc le caractère lui-même.
            .replacingOccurrences(of: "[\\s\u{00A0}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flat.prefix(200))
    }

    /// Les deux lettres de la pastille : initiales du nom si on en a un,
    /// sinon les deux premières de l'adresse.
    var initials: String {
        let src = MailGuard.displayName(in: sender)
        let words = src.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            .filter { $0.first?.isLetter == true }
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return String(a).uppercased() + String(b).uppercased()
        }
        let base = words.first.map(String.init) ?? address
        let letters = base.filter { $0.isLetter }
        return letters.isEmpty ? "?" : String(letters.prefix(2)).uppercased()
    }

    /// La teinte de la pastille, tirée de l'adresse : le même correspondant
    /// garde sa couleur d'une session à l'autre, ce qui est tout l'intérêt —
    /// on reconnaît l'expéditeur avant d'avoir lu son nom.
    ///
    /// Les teintes sont prises dans une roue de douze, et non en continu :
    /// deux adresses voisines sur le cercle donneraient deux couleurs
    /// qu'on ne distingue pas.
    var tint: NSColor {
        let key = address.isEmpty ? sender : address
        var h: UInt64 = 5381
        for b in key.lowercased().utf8 { h = (h << 5) &+ h &+ UInt64(b) }
        let hue = CGFloat(h % 12) / 12.0
        return NSColor(calibratedHue: hue, saturation: 0.52, brightness: 0.92, alpha: 1)
    }

    /// Le corps, prêt à lire. Beaucoup de courriels n'ont qu'une version
    /// HTML : affiché tel quel, on lirait des balises. On ne rend pas le
    /// HTML — on en extrait le texte, en gardant les sauts de paragraphe.
    var readableBody: String {
        var s = snippet
        if s.range(of: "<(br|p|div|table|html|body)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            // Les balises de bloc deviennent des sauts de ligne avant que
            // tout le reste ne disparaisse, sinon le texte se recollerait
            // en un seul paragraphe illisible.
            s = s.replacingOccurrences(of: "<(br|/p|/div|/tr|/h[1-6])\\s*/?>", with: "\n",
                                       options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<(script|style)\\b[^>]*>[\\s\\S]*?</\\1>", with: "",
                                       options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        for (e, c) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                       ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&eacute;", "é"),
                       ("&egrave;", "è"), ("&agrave;", "à"), ("&ccedil;", "ç"), ("&euro;", "€")] {
            s = s.replacingOccurrences(of: e, with: c, options: .caseInsensitive)
        }
        // Les espaces en fin de ligne et les lignes vides en rafale : un
        // courriel HTML converti en produit des dizaines.
        s = s.replacingOccurrences(of: "[ \\t\u{00A0}]+\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ═══════════════════════════════════════════════════════════
//  Les dates d'en-tête
//
//  « Sun, 22 Nov 2026 09:41:00 +0100 » tronqué à 17 caractères
//  donnait « Sun, 22 Nov 2026 », coupé au milieu d'un mot dès
//  que le fuseau s'écrivait autrement. On analyse donc la date
//  pour de bon, puis on l'écrit comme une liste de courrier :
//  l'heure aujourd'hui, le jour et le mois cette année.
//
//  L'analyse se fait en locale POSIX, jamais celle du système :
//  un Mac en français ne reconnaîtrait ni « Sun » ni « Nov ».
//  L'affichage, lui, suit la langue de l'utilisateur.
// ═══════════════════════════════════════════════════════════

enum MailDate {
    private static let parsers: [DateFormatter] = {
        [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm Z",
            "EEE, d MMM yyyy HH:mm:ss",
            "d MMM yyyy HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss"
        ].map { f -> DateFormatter in
            let d = DateFormatter()
            d.locale = Locale(identifier: "en_US_POSIX")
            d.dateFormat = f
            return d
        }
    }()

    private static func display(_ format: String) -> DateFormatter {
        let d = DateFormatter()
        d.setLocalizedDateFormatFromTemplate(format)
        return d
    }
    private static let hhmm = display("Hm")
    private static let dayMonth = display("dMMM")
    private static let full = display("dMMMyy")

    static func parse(_ s: String) -> Date? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // La RFC 5322 autorise un commentaire en queue : « +0100 (CET) ».
        if let i = t.firstIndex(of: "(") {
            t = String(t[t.startIndex..<i]).trimmingCharacters(in: .whitespaces)
        }
        for p in parsers {
            if let d = p.date(from: t) { return d }
        }
        return nil
    }

    static func short(header s: String) -> String {
        guard let d = parse(s) else {
            // Analyse impossible : on garde les mots entiers du jour et du
            // mois plutôt que de couper la chaîne au hasard.
            let w = s.split(separator: " ")
            return w.count >= 3 ? w[1...2].joined(separator: " ") : String(s.prefix(12))
        }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return hhmm.string(from: d) }
        if cal.isDateInYesterday(d) { return "hier" }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            return dayMonth.string(from: d)
        }
        return full.string(from: d)
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
                    -- Le corps est coupé à 200 caractères du côté
                    -- d'AppleScript : un message de plusieurs mégaoctets
                    -- ne doit pas traverser la sortie d'osascript pour
                    -- qu'on n'en garde qu'une ligne d'aperçu.
                    set c to ""
                    try
                        set c to (content of m)
                        if (count of c) > 200 then set c to (text 1 thru 200 of c)
                    end try
                    set res to res & (subject of m) & "|~|" & (sender of m) & "|~|" & ((date received of m) as string) & "|~|" & c & "|#|"
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
            var m = MailMessage(subject: p[0].trimmingCharacters(in: .whitespacesAndNewlines),
                                sender: p[1].trimmingCharacters(in: .whitespacesAndNewlines),
                                date: p[2].trimmingCharacters(in: .whitespacesAndNewlines))
            if p.count >= 4 { m.snippet = p[3] }
            return m
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

    /// Met des messages à la corbeille du compte. Rien n'est effacé :
    /// le serveur les garde, et ils se reprennent depuis la corbeille.
    static func trash(_ uids: [String]) -> String? {
        guard let (user, auth) = mode() else {
            return "Reliez un compte Gmail pour supprimer des messages."
        }
        return GmailClient.trash(user: user, auth: auth, uids: uids)
    }
}

/// La pastille d'initiales de l'expéditeur, en grand pour le lecteur.
final class InitialsDisc: NSView {
    var message: MailMessage? { didSet { needsDisplay = true } }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let b = bounds
        guard let m = message else { return }
        let t = m.tint
        t.withAlphaComponent(0.24).setFill()
        NSBezierPath(ovalIn: b).fill()
        t.withAlphaComponent(0.55).setStroke()
        let ring = NSBezierPath(ovalIn: b.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        drawString(m.initials, in: NSRect(x: b.minX, y: b.midY - 9, width: b.width, height: 19),
                   size: 15.5, weight: .bold, color: t, align: .center)
    }
}

/// Une ligne de la boîte de réception : expéditeur, objet, date et
/// verdict d'analyse. Dessinée à la main pour tenir en 46 pt sans
/// rien tronquer et pour réagir au survol.
final class MailRow: NSView {
    let message: MailMessage
    var selected = false { didSet { needsDisplay = true } }
    var onSelect: ((MailMessage) -> Void)?
    var onSwipeDelete: ((MailMessage) -> Void)?
    var onSwipeReply: ((MailMessage) -> Void)?
    private var hover = false
    private var track: NSTrackingArea?

    /// Décalage horizontal de la carte pendant un balayage, en points.
    /// Négatif vers la gauche, ce qui découvre « Supprimer » à droite.
    private var dragX: CGFloat = 0
    private var swiping = false
    private var springT: Timer?
    /// Au-delà de ce décalage, le geste déclenche son action au relâchement.
    private let trigger: CGFloat = 78

    init(frame: NSRect, message: MailMessage) {
        self.message = message
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { springT?.invalidate() }

    // ═══════════ Balayage ═══════════
    //
    //  Un trackpad n'envoie pas de « geste de balayage » : il envoie des
    //  événements de défilement avec une phase. On lit donc scrollWheel,
    //  et toute la difficulté est de ne pas voler le défilement vertical
    //  de la liste qui nous contient.
    //
    //  La direction est décidée une fois, au début du geste, et tenue
    //  jusqu'au relâchement : arbitrer à chaque événement ferait sauter
    //  la carte entre défilement et balayage au moindre tremblement.

    override func scrollWheel(with e: NSEvent) {
        // Une molette de souris n'a pas de phase et ne doit pas balayer.
        guard e.hasPreciseScrollingDeltas else { super.scrollWheel(with: e); return }

        switch e.phase {
        case .began:
            swiping = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.4
            if !swiping { super.scrollWheel(with: e) }
        case .changed:
            guard swiping else { super.scrollWheel(with: e); return }
            springT?.invalidate()
            dragX += e.scrollingDeltaX * swipeSign
            // Au-delà du seuil, le geste résiste : on sent qu'on est allé
            // au bout, sans pouvoir tirer la carte hors du panneau.
            let limit: CGFloat = 132
            if abs(dragX) > limit { dragX = dragX < 0 ? -limit : limit }
            needsDisplay = true
        case .ended, .cancelled:
            guard swiping else { super.scrollWheel(with: e); return }
            swiping = false
            let d = dragX
            if d <= -trigger { onSwipeDelete?(message) }
            else if d >= trigger { onSwipeReply?(message) }
            springBack()
        default:
            if !swiping { super.scrollWheel(with: e) }
        }
    }

    /// Retour élastique à zéro. La carte revient toujours en place, même
    /// quand l'action part : la liste se recharge derrière, et une carte
    /// restée ouverte sur une rangée qui n'existe plus serait un fantôme.
    private func springBack() {
        springT?.invalidate()
        guard dragX != 0 else { return }
        springT = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let s = self else { t.invalidate(); return }
            s.dragX *= 0.76
            if abs(s.dragX) < 0.6 { s.dragX = 0; t.invalidate(); s.springT = nil }
            s.needsDisplay = true
        }
    }

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
        if dragX != 0 { drawSwipeBackdrop(r) }

        let ctx = NSGraphicsContext.current
        ctx?.saveGraphicsState()
        // La carte glisse, le fond d'action reste : c'est ce décalage du
        // repère qui donne l'impression de tirer la carte de côté.
        if dragX != 0 { ctx?.cgContext.translateBy(x: dragX, y: 0) }
        drawCard(r)
        ctx?.restoreGraphicsState()
    }

    /// Ce qu'on découvre sous la carte pendant le balayage : rouge et
    /// « Supprimer » à droite quand on tire vers la gauche, bleu et
    /// « Répondre » à gauche quand on tire vers la droite. La couleur
    /// s'affirme au passage du seuil, pour qu'on sache que ça va partir.
    private func drawSwipeBackdrop(_ r: NSRect) {
        let left = dragX > 0
        let armed = abs(dragX) >= trigger
        let col = left ? TH.accent : dangerColor
        let strip = left ? NSRect(x: r.minX, y: r.minY, width: dragX, height: r.height)
                         : NSRect(x: r.maxX + dragX, y: r.minY, width: -dragX, height: r.height)

        let p = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
        NSGraphicsContext.current?.saveGraphicsState()
        p.addClip()
        col.withAlphaComponent(armed ? 0.92 : 0.45).setFill()
        strip.fill()

        // L'étiquette reste au milieu de la bande découverte, mais jamais
        // collée au bord : sans cette marge elle serait coupée au départ
        // du geste, quand la bande ne fait que quelques points.
        let cx = left ? min(strip.midX, r.minX + 54) : max(strip.midX, r.maxX - 54)
        if abs(dragX) > 26 {
            drawSymbol(left ? "arrowshape.turn.up.left.fill" : "trash.fill",
                       center: NSPoint(x: cx, y: r.midY + 7), size: 15, weight: .semibold,
                       color: .white)
            drawString(left ? "Répondre" : "Supprimer",
                       in: NSRect(x: cx - 48, y: r.midY - 20, width: 96, height: 13),
                       size: 9.5, weight: .bold, color: .white, align: .center)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawCard(_ r: NSRect) {
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
        let bar = NSBezierPath(roundedRect: NSRect(x: 5, y: 10, width: 3, height: r.height - 20),
                               xRadius: 1.5, yRadius: 1.5)
        lvl.color.withAlphaComponent(lvl == .clean ? 0.45 : 0.95).setFill()
        bar.fill()

        // Pastille d'initiales, teinte tirée de l'adresse : le même
        // correspondant garde sa couleur, et on le reconnaît avant
        // d'avoir lu son nom.
        let av = NSRect(x: 14, y: r.midY - 17, width: 34, height: 34)
        let tint = message.tint
        tint.withAlphaComponent(0.26).setFill()
        NSBezierPath(ovalIn: av).fill()
        tint.withAlphaComponent(0.55).setStroke()
        let ring = NSBezierPath(ovalIn: av.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        drawString(message.initials,
                   in: NSRect(x: av.minX, y: av.midY - 7.5, width: av.width, height: 15),
                   size: 12.5, weight: .bold, color: tint, align: .center)

        // Trois lignes : expéditeur, objet, aperçu. Les ordonnées descendent
        // d'un pas régulier depuis le haut, ce qui garde le même interligne
        // quelle que soit la hauteur de la ligne.
        let top = r.height
        let line1 = NSRect(x: 0, y: top - 23, width: 0, height: 17)   // expéditeur
        let line2 = NSRect(x: 0, y: top - 41, width: 0, height: 16)   // objet
        let line3 = NSRect(x: 0, y: top - 58, width: 0, height: 14)   // aperçu

        // Le texte commence après la pastille, toujours à la même abscisse :
        // le non-lu se marque sur la pastille, pas en décalant la colonne,
        // qui ondulait d'une ligne à l'autre quand la puce prenait sa place.
        let x: CGFloat = av.maxX + 10
        if message.unread {
            let d = NSRect(x: av.minX - 1, y: av.maxY - 9, width: 10, height: 10)
            // Un liseré sombre détache la puce du disque coloré, sinon les
            // deux teintes se touchent et la puce disparaît.
            TH.base.setFill()
            NSBezierPath(ovalIn: d.insetBy(dx: -1.5, dy: -1.5)).fill()
            TH.accent.setFill()
            NSBezierPath(ovalIn: d).fill()
        }

        // Date et verdict à droite de la première ligne.
        var rightEdge = r.width - 14
        if lvl != .clean {
            let txt = lvl.label
            let w = textWidth(txt, size: 9.5, weight: .bold) + 18
            let box = NSRect(x: rightEdge - w, y: line1.midY - 9, width: w, height: 18)
            lvl.color.withAlphaComponent(0.20).setFill()
            capsule(box).fill()
            lvl.color.withAlphaComponent(0.75).setStroke()
            let c = capsule(box); c.lineWidth = 1; c.stroke()
            drawString(txt, in: NSRect(x: box.minX, y: box.midY - 6.5, width: box.width, height: 13),
                       size: 9.5, weight: .bold, color: lvl.color, align: .center)
            rightEdge -= w + 8
        }
        let when = message.shortDate
        if !when.isEmpty {
            // Même rectangle que l'expéditeur : le texte étant dessiné
            // depuis le haut, les deux lignes partent du même bord.
            let dw = min(textWidth(when, size: 10, weight: .medium) + 4, 96)
            drawString(when,
                       in: NSRect(x: rightEdge - dw, y: line1.minY, width: dw, height: line1.height),
                       size: 10, weight: .medium, color: TH.dim(0.40), align: .right)
            rightEdge -= dw + 10
        }

        drawString(message.shortSender.isEmpty ? "(inconnu)" : message.shortSender,
                   in: NSRect(x: x, y: line1.minY, width: max(60, rightEdge - x), height: line1.height),
                   size: 12.5, weight: message.unread ? .bold : .semibold, color: TH.text)

        // L'objet et l'aperçu courent sur toute la largeur : la réserve de
        // la date ne vaut que pour la première ligne, et l'objet héritait
        // d'une largeur amputée pour rien.
        var wide = r.width - 14 - x
        if !message.attachments.isEmpty {
            drawSymbol("paperclip", center: NSPoint(x: r.width - 20, y: line2.midY),
                       size: 10.5, weight: .semibold, color: TH.dim(0.45))
            wide -= 20
        }
        drawString(message.subject.isEmpty ? "(sans objet)" : message.subject,
                   in: NSRect(x: x, y: line2.minY, width: max(60, wide), height: line2.height),
                   size: 11.5, weight: message.unread ? .semibold : .regular,
                   color: TH.dim(message.unread ? 0.78 : 0.62))

        let preview = message.preview
        if !preview.isEmpty {
            drawString(preview,
                       in: NSRect(x: x, y: line3.minY, width: max(60, r.width - 14 - x),
                                  height: line3.height),
                       size: 10.5, weight: .regular, color: TH.dim(0.34))
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
    private var modeSeg: SegmentedBar!
    private var bodyScrollView: NSScrollView!
    private var mode = 0                  // 0 boîte · 1 lecture · 2 rédaction
    // ── Lecture ──
    private var readerCard: NSView!
    private var readerDisc: InitialsDisc!
    private var readerFrom: NSTextField!
    private var readerAddress: NSTextField!
    private var readerSubject: NSTextField!
    private var readerMeta: NSTextField!
    private var readerScroll: NSScrollView!
    private var readerText: NSTextView!
    private var deleteBtn: GlassButton!
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

        // Deux modes plutôt qu'un empilement : la liste et le formulaire
        // se disputaient 570 pt et se retrouvaient tous deux à l'étroit.
        // Chacun occupe maintenant toute la hauteur disponible.
        modeSeg = SegmentedBar(frame: NSRect(x: 0, y: 436, width: W, height: 36),
                               items: [SegmentedBar.Item(title: "Boîte", icon: "tray.full.fill"),
                                       SegmentedBar.Item(title: "Lecture", icon: "doc.text"),
                                       SegmentedBar.Item(title: "Rédiger", icon: "square.and.pencil")],
                               selected: 0)
        modeSeg.onSelect = { [weak self] i in self?.setMode(i) }
        addSubview(modeSeg)

        // Les deux modes partagent le même cadre — bord haut à 424, bord bas
        // à 66 — pour que la bascule ne décale rien à l'écran.
        scroll.frame = NSRect(x: 0, y: 134, width: W, height: 290)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        // Carte de verdict du message sélectionné.
        threatCard = mkCard(self, NSRect(x: 0, y: 66, width: W, height: 60), radius: 13, alpha: 0.07)
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

        isolateBtn = GlassButton(frame: NSRect(x: W - 110, y: 12, width: 96, height: 34),
                                 title: "Isoler", icon: "tray.and.arrow.down.fill")
        isolateBtn.destructive = true
        isolateBtn.enabledFlag = false
        isolateBtn.onClick = { [weak self] _ in self?.quarantineSelected() }
        threatCard.addSubview(isolateBtn)

        toField = NSTextField(frame: NSRect(x: 0, y: 394, width: W * 0.48, height: 30))
        toField.placeholderString = "Destinataire"
        toField.font = NSFont.systemFont(ofSize: 12.5)
        subjectField = NSTextField(frame: NSRect(x: W * 0.48 + 10, y: 394, width: W * 0.52 - 10, height: 30))
        subjectField.placeholderString = "Objet"
        subjectField.font = NSFont.systemFont(ofSize: 12.5)
        [toField, subjectField].forEach { addSubview($0) }

        accountLabel = mkLabel("", NSRect(x: 2, y: 374, width: W - 4, height: 14), 10, .regular, alpha: 0.38)
        addSubview(accountLabel)

        let bodyScroll = NSScrollView(frame: NSRect(x: 0, y: 66, width: W, height: 300))
        bodyScrollView = bodyScroll
        bodyScroll.hasVerticalScroller = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.wantsLayer = true
        bodyScroll.layer?.cornerRadius = 12
        bodyScroll.layer?.masksToBounds = true
        let big: CGFloat = 1_000_000
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: W, height: 300))
        tv.minSize = NSSize(width: 0, height: 300)
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

        // ── Mode Lecture ──
        //
        //  Le corps est déjà rapatrié et décodé lors du relevé de la boîte :
        //  lire un message ne demande donc aucun aller-retour réseau de
        //  plus, seulement de présenter proprement ce qu'on a.
        readerCard = mkCard(self, NSRect(x: 0, y: 318, width: W, height: 106), radius: 14, alpha: 0.06)

        readerDisc = InitialsDisc(frame: NSRect(x: 14, y: 48, width: 44, height: 44))
        readerCard.addSubview(readerDisc)
        readerFrom = mkLabel("", NSRect(x: 70, y: 72, width: W - 90, height: 20), 13.5, .bold)
        readerAddress = mkLabel("", NSRect(x: 70, y: 52, width: W - 90, height: 15), 10.5, .regular, alpha: 0.42)
        readerSubject = mkLabel("", NSRect(x: 14, y: 26, width: W - 28, height: 19), 12.5, .semibold, alpha: 0.82)
        readerMeta = mkLabel("", NSRect(x: 14, y: 6, width: W - 28, height: 15), 10, .medium, alpha: 0.5)
        readerCard.addSubview(readerFrom)
        readerCard.addSubview(readerAddress)
        readerCard.addSubview(readerSubject)
        readerCard.addSubview(readerMeta)

        readerScroll = NSScrollView(frame: NSRect(x: 0, y: 66, width: W, height: 240))
        readerScroll.hasVerticalScroller = true
        readerScroll.scrollerStyle = .overlay
        readerScroll.drawsBackground = false
        readerText = NSTextView(frame: NSRect(x: 0, y: 0, width: W, height: 240))
        readerText.isEditable = false
        // Sélectionnable : on veut pouvoir copier un code, une adresse,
        // un numéro de commande sans ouvrir Mail.
        readerText.isSelectable = true
        readerText.drawsBackground = false
        readerText.isRichText = false
        readerText.font = NSFont.systemFont(ofSize: 13)
        readerText.textColor = TH.dim(0.88)
        readerText.textContainerInset = NSSize(width: 14, height: 12)
        readerText.isVerticallyResizable = true
        readerText.isHorizontallyResizable = false
        readerText.autoresizingMask = [.width]
        readerText.minSize = NSSize(width: 0, height: 240)
        readerText.maxSize = NSSize(width: 10_000, height: 10_000)
        readerText.textContainer?.widthTracksTextView = true
        // Interligne large : c'est ce qui sépare un courriel qu'on lit
        // d'un bloc de texte qu'on déchiffre.
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.38
        para.paragraphSpacing = 7
        readerText.defaultParagraphStyle = para
        readerScroll.documentView = readerText
        addSubview(readerScroll)

        statusLabel = mkLabel("", NSRect(x: 0, y: 46, width: W, height: 16), 10.5, .regular, alpha: 0.45, .center)
        addSubview(statusLabel)

        let bw = (W - 60) / 6
        let specs: [(String, String, Bool, () -> Void)] = [
            ("Envoyer", "paperplane.fill", true, { [weak self] in self?.send() }),
            ("Répondre", "arrowshape.turn.up.left.fill", false, { [weak self] in self?.reply() }),
            ("Supprimer", "trash.fill", false, { [weak self] in self?.deleteSelected() }),
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
        deleteBtn = made[2]
        deleteBtn.enabledFlag = false
        deleteBtn.destructive = true
        setMode(0)
    }

    /// Bascule entre consulter et rédiger. Les deux jeux de vues occupent
    /// la même bande d'écran, on les montre à tour de rôle.
    private func setMode(_ i: Int) {
        mode = i
        modeSeg.selected = i
        let box = (i == 0), read = (i == 1), write = (i == 2)
        scroll.isHidden = !box
        // La carte d'analyse reste en place même sans sélection, avec sa
        // phrase d'attente : la faire apparaître et disparaître faisait
        // sursauter le bas du panneau à chaque clic.
        threatCard.isHidden = !box
        readerCard.isHidden = !read
        readerScroll.isHidden = !read
        toField.isHidden = !write
        subjectField.isHidden = !write
        bodyScrollView?.isHidden = !write
        accountLabel.isHidden = !write
        if write { window?.makeFirstResponder(toField.stringValue.isEmpty ? toField : bodyView) }
        if read { window?.makeFirstResponder(readerText) }
    }

    /// Ouvre un message en lecture. Appelé au clic sur une ligne : lire
    /// est ce qu'on veut faire d'un courriel, et il serait étrange de
    /// devoir viser un onglet pour y arriver.
    private func open(_ m: MailMessage) {
        select(m)
        fillReader(m)
        setMode(1)
    }

    private func fillReader(_ m: MailMessage) {
        readerDisc.message = m
        readerFrom.stringValue = m.shortSender.isEmpty ? "(expéditeur inconnu)" : m.shortSender
        readerAddress.stringValue = m.address
        readerSubject.stringValue = m.subject.isEmpty ? "(sans objet)" : m.subject

        let lvl = m.threat.level
        var meta = MailDate.parse(m.date).map { d -> String in
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("EEEEdMMMMyHm")
            return f.string(from: d)
        } ?? m.date
        if lvl != .clean { meta += "  ·  " + lvl.label }
        if !m.attachments.isEmpty {
            meta += "  ·  " + m.attachments.joined(separator: ", ")
        }
        readerMeta.stringValue = meta
        readerMeta.textColor = lvl == .clean ? TH.dim(0.5) : lvl.color

        let body = m.readableBody
        readerText.string = body.isEmpty
            ? "Le corps de ce message n'a pas pu être rapatrié. Ouvrez-le dans Mail pour le lire en entier."
            : body
        // Le style par défaut ne s'applique qu'à la saisie : un texte posé
        // d'un bloc garde ses propres attributs, et l'interligne large
        // serait perdu si on ne le réappliquait pas ici.
        if let para = readerText.defaultParagraphStyle {
            let all = NSRange(location: 0, length: readerText.string.utf16.count)
            readerText.textStorage?.addAttributes([.paragraphStyle: para,
                                                   .font: NSFont.systemFont(ofSize: 13),
                                                   .foregroundColor: TH.dim(0.88)], range: all)
        }
        readerText.scroll(NSPoint(x: 0, y: 0))
    }

    /// Met le message sélectionné à la corbeille du compte. Rien n'est
    /// effacé : le serveur le garde, et il se reprend depuis la corbeille.
    private func deleteSelected() {
        guard let m = selected else {
            statusLabel.stringValue = "Choisissez d'abord un message."
            return
        }
        guard !m.uid.isEmpty, MailRouter.gmailReady else {
            statusLabel.stringValue = "La suppression demande un compte relié — "
                + "par Mail.app, BUD ne fait que lire."
            return
        }
        statusLabel.stringValue = "Mise à la corbeille…"
        let uid = m.uid
        DispatchQueue.global(qos: .userInitiated).async {
            let err = MailRouter.trash([uid])
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                if let err = err {
                    s.statusLabel.stringValue = err
                } else {
                    s.statusLabel.stringValue = "Message mis à la corbeille."
                    s.selected = nil
                    s.replyBtn.enabledFlag = false
                    s.deleteBtn.enabledFlag = false
                    if s.mode == 1 { s.setMode(0) }
                    s.refresh()
                }
            }
        }
    }

    // ── Sélection d'un message ──

    /// Un balayage est vite fait, et parfois fait sans le vouloir : la
    /// suppression demande donc confirmation, alors que « Répondre » part
    /// directement — répondre ne détruit rien.
    private func confirmSwipeDelete(_ m: MailMessage) {
        let a = NSAlert()
        a.messageText = "Mettre ce message à la corbeille ?"
        a.informativeText = "\(m.shortSender) — \(m.subject.isEmpty ? "(sans objet)" : m.subject)\n\n"
            + "Il part dans la corbeille du compte, d'où vous pouvez le reprendre."
        a.addButton(withTitle: "Mettre à la corbeille")
        a.addButton(withTitle: "Annuler")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { deleteSelected() }
    }

    private func select(_ m: MailMessage) {
        selected = m
        replyBtn.enabledFlag = true
        deleteBtn.enabledFlag = !m.uid.isEmpty && MailRouter.gmailReady
        isolateBtn.enabledFlag = !m.uid.isEmpty && MailRouter.gmailReady
        for r in rows { (r as? MailRow)?.selected = (r as? MailRow)?.message.uid == m.uid }

        if mode == 0 { threatCard.isHidden = false }
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
        setMode(1)
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
        // 68 pt, dont 6 d'écart entre les cartes : il faut trois lignes —
        // expéditeur, objet, aperçu — là où 52 n'en tenaient que deux, et
        // encore collées l'une à l'autre.
        let rowH: CGFloat = 68
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
            row.onSelect = { [weak self] msg in self?.open(msg) }
            row.onSwipeDelete = { [weak self] msg in
                self?.select(msg)
                self?.confirmSwipeDelete(msg)
            }
            row.onSwipeReply = { [weak self] msg in
                self?.select(msg)
                self?.reply()
            }
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
            threatCard?.isHidden = (mode != 0)
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
                    self?.setMode(0)
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
