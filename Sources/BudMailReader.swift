import Cocoa

// ═══════════════════════════════════════════════════════════
//  Le lecteur de courrier, en panneau
//
//  Il était un troisième onglet, « Lecture », et c'était une
//  mauvaise idée pour deux raisons.
//
//  La première est visible : trois jeux de vues se partageaient
//  la même bande d'écran, montrés à tour de rôle. Il suffisait
//  d'en oublier un à la bascule pour que la barre des types se
//  retrouve par-dessus l'en-tête du message — ce qui est
//  arrivé. Un mode qui cache des vues est un mode qui en
//  oubliera une.
//
//  La seconde est d'usage : lire un message et garder la liste
//  sous les yeux sont deux choses qu'on veut faire ensemble, et
//  un onglet force à choisir.
//
//  Le panneau règle les deux. Il vit au-dessus du panneau de
//  BUD, se rétracte sur son en-tête d'un clic, et se referme
//  sur Échap. La liste reste derrière, intacte.
// ═══════════════════════════════════════════════════════════

final class MailReaderWindow: NSWindowController {

    /// Hauteurs des deux états. Rétracté, il ne reste que l'en-tête :
    /// de quoi savoir quel message est ouvert sans qu'il occupe l'écran.
    private static let fullHeight: CGFloat = 560
    private static let retractedHeight: CGFloat = 132
    private static let width: CGFloat = 620

    private var body: NSTextView!
    private var bodyScroll: NSScrollView!
    private var disc: InitialsDisc!
    private var fromLabel: NSTextField!
    private var addressLabel: NSTextField!
    private var subjectLabel: NSTextField!
    private var metaLabel: NSTextField!
    private var attachHost: NSView!
    private var retractBtn: GlassButton!
    private var actionRow: NSView!
    private var statusLabel: NSTextField!

    private var retracted = false
    private(set) var message: MailMessage?

    var onReply: ((MailMessage) -> Void)?
    var onDelete: ((MailMessage) -> Void)?
    var onQuarantine: ((MailMessage) -> Void)?
    /// Envoi demandé : le destinataire, l'objet et le corps approuvé.
    var onSend: ((MailMessage, String, String) -> Void)?

    // ─────────────────────────────────────────────────────────
    //  Le tiroir de réponse
    // ─────────────────────────────────────────────────────────

    private static let drawerHeight: CGFloat = 286

    private var drawer: NSView!
    private var draftText: NSTextView!
    private var draftScroll: NSScrollView!
    private var variantBtns: [GlassButton] = []
    private var phraseHost: NSView!
    private var approveBtn: GlassButton!
    private var editBtn: GlassButton!
    private var sendBtn: GlassButton!
    private var drawerOpen = false
    private var drafts: [ReplyWriter.Draft] = []
    private var chosen = 0
    /// Rien ne part sans deux gestes. Une réponse née d'une phrase dite à
    /// voix haute mérite une confirmation de plus qu'un texte tapé : un
    /// « Réponds au mail de Free » mal entendu ne doit jamais pouvoir
    /// atteindre un destinataire.
    private var approved = false

    init() {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0,
                                            width: MailReaderWindow.width,
                                            height: MailReaderWindow.fullHeight),
                        styleMask: [.titled, .closable, .utilityWindow, .resizable],
                        backing: .buffered, defer: false)
        w.title = "Message"
        w.isReleasedWhenClosed = false
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = false
        // Au-dessus du panneau de BUD, qui vit au niveau `.statusBar` :
        // sans cela le lecteur passerait dessous dès qu'on rouvre BUD.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        w.minSize = NSSize(width: 460, height: MailReaderWindow.retractedHeight)
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // ─────────────────────────────────────────────────────────
    //  Construction
    // ─────────────────────────────────────────────────────────

    private func build() {
        guard let content = window?.contentView else { return }
        let W = MailReaderWindow.width, H = MailReaderWindow.fullHeight
        content.autoresizesSubviews = true

        disc = InitialsDisc(frame: NSRect(x: 18, y: H - 66, width: 46, height: 46))
        disc.autoresizingMask = [.minYMargin]
        content.addSubview(disc)

        fromLabel = mkLabel("", NSRect(x: 76, y: H - 44, width: W - 200, height: 22),
                            Typo.heading.size, Typo.heading.weight)
        addressLabel = mkLabel("", NSRect(x: 76, y: H - 64, width: W - 200, height: 16),
                               Typo.caption.size, .regular, alpha: Typo.Ink.faint)
        subjectLabel = mkLabel("", NSRect(x: 18, y: H - 92, width: W - 36, height: 20),
                               Typo.body.size, .semibold, alpha: Typo.Ink.normal)
        metaLabel = mkLabel("", NSRect(x: 18, y: H - 112, width: W - 36, height: 16),
                            10.5, .medium, alpha: Typo.Ink.muted)
        for l in [fromLabel, addressLabel, subjectLabel, metaLabel] {
            l?.autoresizingMask = [.minYMargin, .width]
            content.addSubview(l!)
        }

        retractBtn = GlassButton(frame: NSRect(x: W - 118, y: H - 50, width: 100, height: 30),
                                 title: "Rétracter", icon: "chevron.up", compact: true)
        retractBtn.autoresizingMask = [.minXMargin, .minYMargin]
        retractBtn.onClick = { [weak self] _ in self?.toggleRetract() }
        content.addSubview(retractBtn)

        // Les pièces jointes vivent dans leur propre vue : elle se vide et
        // se remplit à chaque message, sans toucher au reste.
        attachHost = NSView(frame: NSRect(x: 18, y: H - 152, width: W - 36, height: 34))
        attachHost.autoresizingMask = [.minYMargin, .width]
        content.addSubview(attachHost)

        bodyScroll = NSScrollView(frame: NSRect(x: 12, y: 58, width: W - 24, height: H - 220))
        bodyScroll.autoresizingMask = [.width, .height]
        bodyScroll.hasVerticalScroller = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.drawsBackground = false
        body = NSTextView(frame: NSRect(x: 0, y: 0, width: W - 24, height: H - 220))
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.isRichText = false
        body.textContainerInset = NSSize(width: 16, height: 14)
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.40
        para.paragraphSpacing = 8
        body.defaultParagraphStyle = para
        bodyScroll.documentView = body
        content.addSubview(bodyScroll)

        statusLabel = mkLabel("", NSRect(x: 18, y: 40, width: W - 36, height: 15),
                              10.5, .regular, alpha: Typo.Ink.muted)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        statusLabel.isSelectable = false
        content.addSubview(statusLabel)

        actionRow = NSView(frame: NSRect(x: 12, y: 8, width: W - 24, height: 30))
        actionRow.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(actionRow)

        buildDrawer(content, W)
    }

    // ─────────────────────────────────────────────────────────
    //  Le tiroir de réponse
    //
    //  Il ne remplace pas le message : il s'ouvre dessous, et
    //  le message reste visible au-dessus. Répondre sans
    //  pouvoir relire ce à quoi on répond est une mauvaise
    //  façon de répondre.
    // ─────────────────────────────────────────────────────────

    private func buildDrawer(_ content: NSView, _ W: CGFloat) {
        let D = MailReaderWindow.drawerHeight
        drawer = NSView(frame: NSRect(x: 12, y: 58, width: W - 24, height: D))
        drawer.autoresizingMask = [.width, .maxYMargin]
        drawer.wantsLayer = true
        drawer.isHidden = true
        content.addSubview(drawer)

        let w = W - 24

        // Les trois propositions. On ne devine pas laquelle vous voulez :
        // l'accusé de réception, la réponse sur le fond et la demande de
        // délai répondent à trois intentions différentes.
        let labels = ["Accusé de réception", "Réponse sur le fond", "Demande de délai"]
        let bw = (w - 16) / 3
        for (i, t) in labels.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (bw + 8), y: D - 32,
                                              width: bw, height: 30),
                                title: t, icon: nil, compact: true)
            b.onClick = { [weak self] _ in self?.choose(i) }
            drawer.addSubview(b)
            variantBtns.append(b)
        }

        draftScroll = NSScrollView(frame: NSRect(x: 0, y: 84, width: w, height: D - 124))
        draftScroll.hasVerticalScroller = true
        draftScroll.scrollerStyle = .overlay
        draftScroll.drawsBackground = false
        draftScroll.autoresizingMask = [.width, .height]
        draftText = NSTextView(frame: NSRect(x: 0, y: 0, width: w, height: D - 124))
        draftText.isEditable = true
        draftText.isSelectable = true
        draftText.isRichText = false
        draftText.drawsBackground = false
        draftText.font = NSFont.systemFont(ofSize: 13)
        draftText.textContainerInset = NSSize(width: 12, height: 10)
        draftText.isVerticallyResizable = true
        draftText.isHorizontallyResizable = false
        draftText.autoresizingMask = [.width]
        draftText.textContainer?.widthTracksTextView = true
        draftScroll.documentView = draftText
        drawer.addSubview(draftScroll)

        // Vos propres tournures, relevées dans vos messages envoyés. Un
        // clic les insère au curseur. Elles ne sont pas placées d'office :
        // une phrase de vous au mauvais endroit reste au mauvais endroit.
        phraseHost = NSView(frame: NSRect(x: 0, y: 44, width: w, height: 30))
        phraseHost.autoresizingMask = [.width, .maxYMargin]
        drawer.addSubview(phraseHost)

        let aw = (w - 16) / 3
        editBtn = GlassButton(frame: NSRect(x: 0, y: 4, width: aw, height: 34),
                              title: "Modifier", icon: "pencil")
        editBtn.onClick = { [weak self] _ in self?.beginEditing() }
        approveBtn = GlassButton(frame: NSRect(x: aw + 8, y: 4, width: aw, height: 34),
                                 title: "Valider", icon: "checkmark")
        approveBtn.onClick = { [weak self] _ in self?.approve() }
        sendBtn = GlassButton(frame: NSRect(x: 2 * (aw + 8), y: 4, width: aw, height: 34),
                              title: "Envoyer", icon: "paperplane.fill", prominent: true)
        sendBtn.onClick = { [weak self] _ in self?.sendDraft() }
        [editBtn, approveBtn, sendBtn].forEach { drawer.addSubview($0) }
    }

    /// Ouvre le tiroir sur un message, avec les trois propositions prêtes.
    func compose(_ m: MailMessage, body: String, style: ReplyStyle) {
        if message?.uid != m.uid { show(m) }
        drafts = ReplyWriter.drafts(for: m, body: body, style: style)
        chosen = 0
        buildPhraseChips(style)
        choose(0)
        setDrawer(open: true)
    }

    private func choose(_ i: Int) {
        guard drafts.indices.contains(i) else { return }
        chosen = i
        for (j, b) in variantBtns.enumerated() { b.prominent = (j == i) }
        draftText.string = drafts[i].text
        // Le texte n'est plus celui qu'on a approuvé : l'envoi se referme.
        approved = false
        refreshSendState()
        selectPlaceholder()
    }

    /// Place le curseur là où BUD ne peut pas écrire à votre place, et
    /// sélectionne le marqueur : il suffit de taper par-dessus.
    private func selectPlaceholder() {
        guard let r = draftText.string.range(of: ReplyWriter.placeholder) else {
            draftText.setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        let ns = NSRange(r, in: draftText.string)
        draftText.setSelectedRange(ns)
        draftText.scrollRangeToVisible(ns)
    }

    private func buildPhraseChips(_ style: ReplyStyle) {
        phraseHost.subviews.forEach { $0.removeFromSuperview() }
        let mine = style.phrases
            .filter { $0.role == .ask || $0.role == .thanks || $0.role == .close }
            .sorted { $0.count > $1.count }
            .prefix(3)
        guard !mine.isEmpty else { return }
        var x: CGFloat = 0
        for p in mine {
            let short = p.text.count > 34 ? String(p.text.prefix(32)) + "…" : p.text
            let w = min(phraseHost.bounds.width - x - 4,
                        CGFloat(short.count) * 6.2 + 26)
            guard w > 60 else { break }
            let chip = GlassButton(frame: NSRect(x: x, y: 2, width: w, height: 26),
                                   title: short, icon: nil, compact: true)
            chip.onClick = { [weak self] _ in self?.insert(p.text) }
            phraseHost.addSubview(chip)
            x += w + 6
        }
    }

    private func insert(_ phrase: String) {
        let sel = draftText.selectedRange()
        if draftText.shouldChangeText(in: sel, replacementString: phrase) {
            draftText.replaceCharacters(in: sel, with: phrase)
            draftText.didChangeText()
        }
        approved = false
        refreshSendState()
    }

    private func beginEditing() {
        window?.makeFirstResponder(draftText)
        selectPlaceholder()
        approved = false
        refreshSendState()
        setStatus("Modifiez librement le texte, puis validez.")
    }

    private func approve() {
        let text = draftText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setStatus("Le message est vide.")
            return
        }
        // Le marqueur laissé en place partirait tel quel au destinataire.
        if text.contains(ReplyWriter.placeholder) {
            setStatus("Il reste « \(ReplyWriter.placeholder) » dans le texte : remplacez-le avant de valider.")
            selectPlaceholder()
            return
        }
        approved = true
        refreshSendState()
        setStatus("Validé. « Envoyer » est maintenant actif.")
    }

    private func refreshSendState() {
        sendBtn.enabledFlag = approved
        approveBtn.prominent = !approved
    }

    private func sendDraft() {
        guard approved, let m = message else {
            setStatus("Validez d'abord le texte.")
            return
        }
        let subject = m.subject.lowercased().hasPrefix("re")
            ? m.subject : "Re: \(m.subject)"
        onSend?(m, subject, draftText.string)
        setDrawer(open: false)
    }

    /// Ouvre ou ferme le tiroir, en agrandissant la fenêtre plutôt qu'en
    /// écrasant le message : le corps garde sa place.
    private func setDrawer(open: Bool) {
        guard drawerOpen != open, let w = window else { return }
        drawerOpen = open
        drawer.isHidden = !open

        var f = w.frame
        let top = f.maxY
        let base = retracted ? MailReaderWindow.retractedHeight : MailReaderWindow.fullHeight
        let target = open ? base + MailReaderWindow.drawerHeight : base
        f.size.height = target
        f.origin.y = top - target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.base
            ctx.timingFunction = Motion.enter
            w.animator().setFrame(f, display: true)
        }
        relayout()
        if open { window?.makeFirstResponder(draftText) }
    }

    /// Replace le corps et le tiroir dans la hauteur disponible.
    private func relayout() {
        guard let content = window?.contentView else { return }
        let H = content.bounds.height, W = content.bounds.width
        let D = drawerOpen ? MailReaderWindow.drawerHeight : 0
        drawer.frame = NSRect(x: 12, y: 58, width: W - 24,
                              height: MailReaderWindow.drawerHeight)
        let bodyTop = H - 152
        let bodyBottom = 66 + D
        bodyScroll.frame = NSRect(x: 12, y: bodyBottom, width: W - 24,
                                  height: max(60, bodyTop - bodyBottom))
    }

    // ─────────────────────────────────────────────────────────
    //  Afficher un message
    // ─────────────────────────────────────────────────────────

    func show(_ m: MailMessage) {
        message = m
        disc.message = m
        fromLabel.stringValue = m.shortSender.isEmpty ? "(expéditeur inconnu)" : m.shortSender
        addressLabel.stringValue = m.address
        subjectLabel.stringValue = m.subject.isEmpty ? "(sans objet)" : m.subject
        window?.title = m.subject.isEmpty ? "Message" : String(m.subject.prefix(60))

        var meta = MailDate.parse(m.date).map { d -> String in
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("EEEEdMMMMyHm")
            return f.string(from: d)
        } ?? m.date
        meta += "  ·  " + m.category.label
        let lvl = m.threat.level
        if lvl != .clean { meta += "  ·  " + lvl.label }
        metaLabel.stringValue = meta
        metaLabel.textColor = lvl == .clean ? TH.dim(Typo.Ink.muted) : lvl.color

        buildAttachments(m)
        buildActions(m)
        setBody(m.readableBody.isEmpty
                ? "Le corps de ce message n'a pas encore été rapatrié."
                : m.readableBody)

        if retracted { toggleRetract() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setBody(_ text: String) {
        body.string = text
        if let para = body.defaultParagraphStyle {
            let all = NSRange(location: 0, length: body.string.utf16.count)
            body.textStorage?.addAttributes([.paragraphStyle: para,
                                             .font: NSFont.systemFont(ofSize: 13),
                                             .foregroundColor: TH.dim(0.88)], range: all)
        }
        body.scroll(NSPoint(x: 0, y: 0))
    }

    func setStatus(_ s: String) { statusLabel.stringValue = s }

    // ─────────────────────────────────────────────────────────
    //  Pièces jointes
    // ─────────────────────────────────────────────────────────

    private func buildAttachments(_ m: MailMessage) {
        attachHost.subviews.forEach { $0.removeFromSuperview() }
        let joined = m.parts.filter { $0.isAttachment }
        guard !joined.isEmpty else {
            attachHost.isHidden = true
            return
        }
        attachHost.isHidden = false

        var x: CGFloat = 0
        for p in joined.prefix(6) {
            let label = p.readableSize.isEmpty ? p.name : "\(p.name)  ·  \(p.readableSize)"
            let w = min(240, textWidth(label, size: 11, weight: .medium) + 46)
            guard x + w < attachHost.bounds.width else { break }
            let b = GlassButton(frame: NSRect(x: x, y: 0, width: w, height: 30),
                                title: label, icon: p.icon, compact: true)
            let part = p
            let uid = m.uid
            b.onClick = { [weak self] _ in self?.open(part, uid: uid) }
            attachHost.addSubview(b)
            x += w + 8
        }
    }

    /// Rapatrie la pièce jointe et l'ouvre avec l'application du système.
    ///
    /// Elle est écrite dans un dossier temporaire à nous, et non dans les
    /// Téléchargements : une pièce jointe ouverte n'est pas un fichier
    /// qu'on a choisi de garder.
    private func open(_ part: MailPart, uid: String) {
        guard MailRouter.gmailReady else {
            setStatus("L'ouverture des pièces jointes demande un compte relié.")
            return
        }
        setStatus("Téléchargement de « \(part.name) »…")
        DispatchQueue.global(qos: .userInitiated).async {
            let data = MailRouter.attachment(uid: uid, part: part)
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                guard let d = data, !d.isEmpty else {
                    s.setStatus("« \(part.name) » n'a pas pu être rapatriée.")
                    return
                }
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BUD-pieces-jointes", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // Le nom vient du message : on n'en garde que le dernier
                // composant, pour qu'il ne puisse pas désigner un chemin.
                let safe = (part.name as NSString).lastPathComponent
                let url = dir.appendingPathComponent(safe.isEmpty ? "piece-jointe" : safe)
                do {
                    try d.write(to: url, options: .atomic)
                    s.setStatus("\(formatBytes(Int64(d.count))) · ouverte dans l'application du système.")
                    NSWorkspace.shared.open(url)
                } catch {
                    s.setStatus("Écriture impossible : \(error.localizedDescription)")
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    //  Actions
    // ─────────────────────────────────────────────────────────

    private func buildActions(_ m: MailMessage) {
        actionRow.subviews.forEach { $0.removeFromSuperview() }
        var specs: [(String, String, Bool, () -> Void)] = [
            ("Répondre", "arrowshape.turn.up.left.fill", false, { [weak self] in
                guard let s = self, let msg = s.message else { return }
                s.onReply?(msg)
            }),
            ("Supprimer", "trash.fill", true, { [weak self] in
                guard let s = self, let msg = s.message else { return }
                s.onDelete?(msg)
            }),
            ("Isoler", "shield.lefthalf.filled", false, { [weak self] in
                guard let s = self, let msg = s.message else { return }
                s.onQuarantine?(msg)
            })
        ]

        // Le désabonnement n'apparaît que si l'expéditeur l'a déclaré, et
        // jamais pour un message signalé : cliquer un lien de
        // désabonnement dans un courriel dangereux confirme à l'expéditeur
        // que l'adresse est lue. C'est le contraire du service rendu.
        if let link = unsubscribeLink(m), m.threat.level == .clean {
            specs.append(("Se désabonner", "bell.slash", false, { [weak self] in
                NSWorkspace.shared.open(link)
                self?.setStatus("Page de désabonnement ouverte dans le navigateur.")
            }))
        }

        let w = (actionRow.bounds.width - CGFloat(specs.count - 1) * 8) / CGFloat(specs.count)
        for (i, sp) in specs.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (w + 8), y: 0, width: w, height: 30),
                                title: sp.0, icon: sp.1, compact: true)
            b.destructive = sp.2
            b.onClick = { _ in sp.3() }
            actionRow.addSubview(b)
        }
    }

    /// L'adresse de désabonnement, si l'expéditeur en a déclaré une.
    /// On ne retient que `https` : un `mailto:` ferait écrire au nom de
    /// l'utilisateur, ce qui ne se fait pas sans le lui demander.
    private func unsubscribeLink(_ m: MailMessage) -> URL? {
        guard !m.bulkHeaders.isEmpty else { return nil }
        guard let re = try? NSRegularExpression(pattern: "<(https://[^>]+)>") else { return nil }
        let r = NSRange(m.bulkHeaders.startIndex..., in: m.bulkHeaders)
        guard let match = re.firstMatch(in: m.bulkHeaders, range: r),
              let rr = Range(match.range(at: 1), in: m.bulkHeaders) else { return nil }
        return URL(string: String(m.bulkHeaders[rr]))
    }

    // ─────────────────────────────────────────────────────────
    //  Rétraction
    // ─────────────────────────────────────────────────────────

    /// Replie le panneau sur son en-tête, ou le rouvre. Le bord **haut**
    /// reste en place : c'est ce qui donne l'impression d'un store qu'on
    /// baisse, et non d'une fenêtre qui saute.
    private func toggleRetract() {
        guard let w = window else { return }
        retracted.toggle()
        let base = retracted ? MailReaderWindow.retractedHeight : MailReaderWindow.fullHeight
        let target = base + (drawerOpen ? MailReaderWindow.drawerHeight : 0)
        var f = w.frame
        let top = f.maxY
        f.size.height = target
        f.origin.y = top - target

        bodyScroll.isHidden = retracted
        statusLabel.isHidden = retracted
        actionRow.isHidden = retracted
        attachHost.isHidden = retracted || attachHost.subviews.isEmpty
        drawer.isHidden = retracted || !drawerOpen
        retractBtn.title = retracted ? "Déplier" : "Rétracter"
        retractBtn.iconName = retracted ? "chevron.down" : "chevron.up"

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.base
            ctx.timingFunction = Motion.enter
            w.animator().setFrame(f, display: true)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.close(); return }   // Échap
        super.keyDown(with: event)
    }
}
