import AppKit
import CoreImage
import Foundation
import QuartzCore

// ═══════════════════════════════════════════════════════════
//  Appairage Gmail par téléphone
//
//  BUD affiche un QR code, vous le scannez, l'application Google
//  de votre téléphone vous identifie. Rien n'est tapé au clavier
//  du Mac, aucun serveur tiers n'intervient.
//
//  Note technique honnête : le « device flow » de Google — le code
//  à six lettres sur google.com/device — n'accepte PAS les scopes
//  Gmail. Google le restreint à email, openid, profile, deux scopes
//  Drive et deux YouTube. D'où les deux voies ci-dessous.
//
//    Voie 1 · Mot de passe d'application (recommandée)
//      Le téléphone ouvre la page des mots de passe d'application,
//      déjà authentifié. Seize lettres à recopier dans BUD.
//
//    Voie 2 · OAuth Google
//      Le téléphone ouvre le consentement. La redirection pointe
//      vers le Mac et échoue donc sur le téléphone : son adresse
//      contient le code d'autorisation, qu'il suffit de coller.
//      Le vérificateur PKCE n'a jamais quitté le Mac, le code seul
//      ne vaut donc rien pour un tiers.
// ═══════════════════════════════════════════════════════════

let appPasswordURL = "https://myaccount.google.com/apppasswords"

enum QRCode {
    /// Rendu net : un module occupe un nombre entier de pixels,
    /// agrandi sans interpolation pour garder des arêtes franches.
    static func image(_ text: String, scale: CGFloat = 12) -> NSImage? {
        guard !text.isEmpty, let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        // Une charge longue grossit la matrice : on baisse la redondance
        // pour garder des modules assez larges à l'écran.
        f.setValue(text.count > 180 ? "L" : "M", forKey: "inputCorrectionLevel")
        guard var out = f.outputImage else { return nil }

        if let fc = CIFilter(name: "CIFalseColor") {
            fc.setValue(out, forKey: kCIInputImageKey)
            fc.setValue(CIColor(red: 0.04, green: 0.04, blue: 0.05), forKey: "inputColor0")
            fc.setValue(CIColor(red: 1, green: 1, blue: 1), forKey: "inputColor1")
            if let o = fc.outputImage { out = o }
        }

        let big = out.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: big)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// ═══════════════════════════════════════════════════════════
//  La plaque : fond blanc, QR net, équerres d'accent, balayage
// ═══════════════════════════════════════════════════════════

final class QRPlate: NSView {
    var payload: String = "" {
        didSet {
            guard payload != oldValue else { return }
            qr = QRCode.image(payload)
            needsDisplay = true
        }
    }
    var paired = false { didSet { needsDisplay = true } }

    private var qr: NSImage?
    private var scanT: CGFloat = 0
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    func startScan() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            // Inutile de peindre un panneau masqué : le balayage dort.
            guard s.window != nil, !s.isHiddenOrHasHiddenAncestor else { return }
            s.scanT += 1.0 / 30.0
            if s.scanT > 2.6 { s.scanT = 0 }
            s.needsDisplay = true
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    func stopScan() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)

        // Plaque claire : un QR se lit mal sur fond sombre.
        let plate = NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20)
        NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
        plate.fill()
        TH.accent.withAlphaComponent(0.22).setStroke()
        plate.lineWidth = 1
        plate.stroke()

        let inner = r.insetBy(dx: 16, dy: 16)

        if let img = qr {
            ctx.saveGraphicsState()
            ctx.imageInterpolation = .none
            // Côté entier : évite qu'un module soit coupé en deux pixels.
            let side = floor(min(inner.width, inner.height))
            let box = NSRect(x: inner.midX - side / 2, y: inner.midY - side / 2,
                             width: side, height: side)
            img.draw(in: box, from: .zero, operation: .sourceOver, fraction: paired ? 0.18 : 1)
            ctx.restoreGraphicsState()

            // Équerres d'accent aux quatre angles. Les bornes sont
            // calculées une par une : un tuple mixte CGFloat/Double
            // rend l'inférence ambiguë sur x86_64.
            let arm: CGFloat = 20, thick: CGFloat = 2.5
            TH.accent.setFill()
            let c = box.insetBy(dx: -7, dy: -7)
            let corners: [NSRect] = [
                NSRect(x: c.minX, y: c.maxY - thick, width: arm, height: thick),
                NSRect(x: c.minX, y: c.maxY - arm, width: thick, height: arm),
                NSRect(x: c.maxX - arm, y: c.maxY - thick, width: arm, height: thick),
                NSRect(x: c.maxX - thick, y: c.maxY - arm, width: thick, height: arm),
                NSRect(x: c.minX, y: c.minY, width: arm, height: thick),
                NSRect(x: c.minX, y: c.minY, width: thick, height: arm),
                NSRect(x: c.maxX - arm, y: c.minY, width: arm, height: thick),
                NSRect(x: c.maxX - thick, y: c.minY, width: thick, height: arm)
            ]
            for bracket in corners { NSBezierPath(rect: bracket).fill() }

            // Balayage : une bande d'accent descend puis disparaît.
            if !paired {
                let p = min(1, scanT / 1.5)
                if scanT < 1.5 {
                    let y = box.maxY - p * box.height
                    let band = NSRect(x: box.minX, y: y - 26, width: box.width, height: 26)
                    ctx.saveGraphicsState()
                    NSBezierPath(rect: box).setClip()
                    let fade = sin(p * .pi)
                    let g = NSGradient(colors: [TH.accent.withAlphaComponent(0),
                                                TH.accent.withAlphaComponent(0.30 * fade)])
                    g?.draw(in: band, angle: 90)
                    TH.accent.withAlphaComponent(0.65 * fade).setFill()
                    NSBezierPath(rect: NSRect(x: box.minX, y: y - 1.2, width: box.width, height: 1.2)).fill()
                    ctx.restoreGraphicsState()
                }
            }
        } else {
            drawString("QR indisponible", in: NSRect(x: inner.minX, y: inner.midY + 8,
                                                     width: inner.width, height: 18),
                       size: 12.5, weight: .semibold,
                       color: NSColor(calibratedWhite: 0.25, alpha: 1), align: .center)
            drawString("Utilisez « Copier le lien »", in: NSRect(x: inner.minX, y: inner.midY - 12,
                                                                 width: inner.width, height: 16),
                       size: 11, weight: .regular,
                       color: NSColor(calibratedWhite: 0.45, alpha: 1), align: .center)
        }

        if paired {
            let d: CGFloat = 76
            let ring = NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            TH.accent.setFill()
            NSBezierPath(ovalIn: ring).fill()
            drawSymbol("checkmark", center: NSPoint(x: r.midX, y: r.midY),
                       size: 36, weight: .bold, color: NSColor(calibratedWhite: 0.07, alpha: 0.95))
        }
    }
}

/// Fenêtre d'agrandissement : un QR confortable à scanner de loin.
final class QRZoom {
    static var panel: NSPanel?

    static func show(_ payload: String, title: String) {
        close()
        // 460 pt : l'URL de consentement fait ~69 modules, il faut
        // au moins 5 pt par module pour un appareil photo de téléphone.
        let side: CGFloat = 460
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side + 54),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = title
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side + 54))
        let plate = QRPlate(frame: NSRect(x: 18, y: 54, width: side - 36, height: side - 36))
        plate.payload = payload
        host.addSubview(plate)

        let hint = NSTextField(labelWithString: "Scannez avec l'appareil photo du téléphone.")
        hint.frame = NSRect(x: 0, y: 20, width: side, height: 18)
        hint.alignment = .center
        hint.font = NSFont.systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        host.addSubview(hint)

        p.contentView = host
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// ═══════════════════════════════════════════════════════════
//  OAuth démarré sur le Mac, consenti sur le téléphone
// ═══════════════════════════════════════════════════════════

final class PhoneOAuth {
    static let shared = PhoneOAuth()

    private var verifier = ""
    private var stateTok = ""
    private var redirect = ""
    private var catcher: LoopbackCatcher?

    var authURL: String = ""
    var armed: Bool { !verifier.isEmpty && !authURL.isEmpty }

    /// Prépare l'URL de consentement. Le guetteur local reste actif :
    /// si vous ouvrez le lien sur le Mac, l'appairage se termine seul.
    func arm(clientID: String, onAuto: @escaping (GoogleTokens?, String?) -> Void) -> String? {
        cancel()
        verifier = GoogleOAuth.randomVerifier()
        stateTok = String(GoogleOAuth.randomVerifier().prefix(24))

        let c = LoopbackCatcher()
        catcher = c
        guard let port = c.start(timeout: 900, onResult: { [weak self] code, err in
            guard let s = self else { return }
            guard let code = code else {
                if let e = err, e != "délai dépassé" { onAuto(nil, e) }
                return
            }
            s.exchange(clientID: clientID, code: code, completion: onAuto)
        }) else {
            return nil
        }
        redirect = "http://127.0.0.1:\(port)"

        var u = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        u.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuth.scope),
            URLQueryItem(name: "code_challenge", value: GoogleOAuth.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: stateTok)
        ]
        authURL = u.url?.absoluteString ?? ""
        return authURL.isEmpty ? nil : authURL
    }

    /// Accepte l'adresse complète recopiée du téléphone, ou le code seul.
    func finish(pasted raw: String, clientID: String,
                completion: @escaping (GoogleTokens?, String?) -> Void) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { completion(nil, "Rien à coller."); return }
        guard armed else { completion(nil, "Relancez l'appairage : la demande a expiré."); return }

        var code = s
        var seenState: String?

        if s.contains("code=") {
            // Une adresse : on lit ses paramètres, avec ou sans « ? ».
            // Pas d'indexation directe : une adresse finissant par « ? »
            // ne produit qu'un seul morceau et ferait planter [1].
            let query = s.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? s
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let v = kv[1].removingPercentEncoding ?? kv[1]
                if kv[0] == "code" { code = v }
                if kv[0] == "state" { seenState = v }
                if kv[0] == "error" { completion(nil, "Google a répondu : \(v)"); return }
            }
        }

        if let st = seenState, st != stateTok {
            completion(nil, "Jeton d'état incohérent, appairage abandonné.")
            return
        }
        guard code.count > 12, !code.contains(" ") else {
            completion(nil, "Code d'autorisation introuvable dans ce texte.")
            return
        }
        exchange(clientID: clientID, code: code, completion: completion)
    }

    private func exchange(clientID: String, code: String,
                          completion: @escaping (GoogleTokens?, String?) -> Void) {
        let v = verifier, r = redirect
        cancel()
        GoogleOAuth.exchangeCode(clientID: clientID,
                                 clientSecret: GmailAuth.shared.clientSecret,
                                 code: code, verifier: v, redirect: r,
                                 completion: completion)
    }

    func cancel() {
        catcher?.stop()
        catcher = nil
        verifier = ""
        stateTok = ""
        authURL = ""
    }
}

// ═══════════════════════════════════════════════════════════
//  Le panneau
// ═══════════════════════════════════════════════════════════

final class PhonePanelView: NSView, NSTextFieldDelegate {
    private let hero: HeroHeader
    private var seg: SegmentedBar!
    private var plate: QRPlate!
    private var stepLabels: [NSTextField] = []
    private var hintLabel: NSTextField!
    private var statusLabel: NSTextField!

    private var emailField: NSTextField!
    private var passField: NSTextField!
    private var clientField: NSTextField!
    private var pasteField: NSTextField!
    private var actionBtn: GlassButton!
    private var zoomBtn: GlassButton!
    private var copyBtn: GlassButton!
    private var openBtn: GlassButton!
    private var disconnectBtn: GlassButton!
    private var linkedCard: NSView!
    private var linkedLabel: NSTextField!

    private var mode = 0          // 0 = mot de passe d'app, 1 = OAuth
    private var busy = false

    var onStatus: ((String) -> Void)?
    var onAccountChange: ((String) -> Void)?
    var prefillAddress: () -> String = { "" }

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Téléphone",
                          subtitle: "Reliez Gmail depuis l'application Google de votre téléphone.")
        super.init(frame: frame)
        build()
        applyMode()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        addSubview(hero)

        seg = SegmentedBar(frame: NSRect(x: 0, y: H - 134, width: W, height: 36),
                           items: [SegmentedBar.Item(title: "Mot de passe d'app", icon: "key.fill"),
                                   SegmentedBar.Item(title: "OAuth Google", icon: "checkmark.shield.fill")])
        seg.onSelect = { [weak self] i in
            self?.mode = i
            self?.applyMode()
        }
        addSubview(seg)

        plate = QRPlate(frame: NSRect(x: 0, y: 226, width: 200, height: 200))
        addSubview(plate)

        // Colonne de droite : les trois étapes.
        let cx: CGFloat = 220, cw = W - 220
        addSubview(mkLabel("ÉTAPES", NSRect(x: cx, y: 408, width: cw, height: 14), 9.5, .bold, alpha: 0.32))
        var y: CGFloat = 348
        for i in 0..<3 {
            mkCard(self, NSRect(x: cx, y: y, width: cw, height: 56), radius: 12, alpha: 0.055)
            let dot = NSView(frame: NSRect(x: cx + 14, y: y + 17, width: 22, height: 22))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 11
            dot.layer?.backgroundColor = TH.accent.withAlphaComponent(0.18).cgColor
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = TH.accent.withAlphaComponent(0.35).cgColor
            addSubview(dot)
            addSubview(mkLabel("\(i + 1)", NSRect(x: cx + 14, y: y + 20, width: 22, height: 16),
                               11, .bold, alpha: 0.85, .center))

            let t = NSTextField(frame: NSRect(x: cx + 46, y: y + 8, width: cw - 60, height: 40))
            t.isBezeled = false
            t.drawsBackground = false
            t.isEditable = false
            t.isSelectable = false
            t.font = NSFont.systemFont(ofSize: 11.5)
            t.textColor = TH.dim(0.68)
            t.lineBreakMode = .byWordWrapping
            t.cell?.usesSingleLineMode = false
            t.cell?.wraps = true
            t.maximumNumberOfLines = 3
            ThemeRegistry.shared.register(t, alpha: 0.68)
            addSubview(t)
            stepLabels.append(t)
            y -= 64
        }

        hintLabel = NSTextField(frame: NSRect(x: 0, y: 186, width: W, height: 30))
        hintLabel.isBezeled = false
        hintLabel.drawsBackground = false
        hintLabel.isEditable = false
        hintLabel.isSelectable = false
        hintLabel.font = NSFont.systemFont(ofSize: 10.5)
        hintLabel.textColor = TH.dim(0.40)
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.cell?.usesSingleLineMode = false
        hintLabel.cell?.wraps = true
        hintLabel.maximumNumberOfLines = 2
        ThemeRegistry.shared.register(hintLabel, alpha: 0.40)
        addSubview(hintLabel)

        // Rangée 1 : adresse (voie 1) ou identifiant client (voie 2).
        emailField = NSTextField(frame: NSRect(x: 0, y: 150, width: 300, height: 30))
        emailField.placeholderString = "adresse@gmail.com"
        emailField.font = NSFont.systemFont(ofSize: 12.5)
        addSubview(emailField)

        passField = NSTextField(frame: NSRect(x: 310, y: 150, width: 190, height: 30))
        passField.placeholderString = "abcd efgh ijkl mnop"
        passField.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        addSubview(passField)

        clientField = NSTextField(frame: NSRect(x: 0, y: 150, width: 500, height: 30))
        clientField.placeholderString = "Identifiant client Google — …apps.googleusercontent.com"
        clientField.font = NSFont.systemFont(ofSize: 11.5)
        clientField.delegate = self
        addSubview(clientField)

        pasteField = NSTextField(frame: NSRect(x: 0, y: 112, width: 500, height: 30))
        pasteField.placeholderString = "Collez ici l'adresse copiée sur le téléphone"
        pasteField.font = NSFont.systemFont(ofSize: 11.5)
        addSubview(pasteField)

        actionBtn = GlassButton(frame: NSRect(x: 510, y: 148, width: W - 510, height: 34),
                                title: "Relier", icon: "link", prominent: true)
        actionBtn.onClick = { [weak self] _ in self?.commit() }
        addSubview(actionBtn)

        linkedCard = mkCard(self, NSRect(x: 0, y: 108, width: W, height: 44), radius: 12, alpha: 0.08)
        mkIcon(linkedCard, "checkmark.seal.fill", x: 14, y: 14, size: 15, alpha: 0.8)
        linkedLabel = mkLabel("", NSRect(x: 40, y: 13, width: W - 54, height: 18), 12, .semibold, alpha: 0.82)
        linkedCard.addSubview(linkedLabel)

        statusLabel = mkLabel("", NSRect(x: 0, y: 58, width: W, height: 34), 11, .medium, alpha: 0.55)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.usesSingleLineMode = false
        statusLabel.cell?.wraps = true
        statusLabel.maximumNumberOfLines = 2
        addSubview(statusLabel)

        let bw = (W - 36) / 4
        let specs: [(String, String, () -> Void)] = [
            ("Agrandir", "viewfinder", { [weak self] in self?.zoom() }),
            ("Copier le lien", "doc.on.doc", { [weak self] in self?.copyLink() }),
            ("Ouvrir ici", "arrow.up.right.square", { [weak self] in self?.openHere() }),
            ("Déconnecter", "xmark.circle", { [weak self] in self?.disconnect() })
        ]
        var btns: [GlassButton] = []
        for (i, s) in specs.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (bw + 12), y: 0, width: bw, height: 42),
                                title: s.0, icon: s.1)
            b.onClick = { _ in s.2() }
            addSubview(b)
            btns.append(b)
        }
        zoomBtn = btns[0]; copyBtn = btns[1]; openBtn = btns[2]; disconnectBtn = btns[3]
        disconnectBtn.destructive = true
    }

    // ── Bascule entre les deux voies ──

    private func applyMode() {
        let a = prefillAddress()
        if emailField.stringValue.isEmpty {
            emailField.stringValue = MailRouter.account.isEmpty ? a : MailRouter.account
        }
        if clientField.stringValue.isEmpty { clientField.stringValue = GmailAuth.shared.clientID }

        if mode == 0 {
            stepLabels[0].stringValue = "Scannez ce code avec l'appareil photo du téléphone."
            stepLabels[1].stringValue = "L'application Google vous identifie, puis créez un mot de passe nommé « BUD »."
            stepLabels[2].stringValue = "Recopiez les seize lettres affichées, les espaces sont ignorés."
            hintLabel.stringValue = "Demande la validation en deux étapes sur le compte Google. Aucun identifiant client n'est nécessaire."
            plate.payload = appPasswordURL
            actionBtn.title = "Relier"
            actionBtn.iconName = "link"
        } else {
            stepLabels[0].stringValue = "Collez votre identifiant client, puis scannez le code — « Agrandir » le rend plus facile à viser."
            stepLabels[1].stringValue = "Autorisez BUD sur le téléphone. La page suivante ne se chargera pas — c'est normal, elle pointe vers votre Mac."
            stepLabels[2].stringValue = "Copiez l'adresse de cette page et collez-la ci-dessous."
            hintLabel.stringValue = "Demande un identifiant client Google de type « application de bureau ». Le vérificateur PKCE ne quitte jamais le Mac."
            armOAuth()
            actionBtn.title = "Terminer"
            actionBtn.iconName = "checkmark"
        }
        refresh()
    }

    private func armOAuth() {
        let id = clientField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.contains("apps.googleusercontent.com") else {
            plate.payload = ""
            statusLabel.stringValue = "Collez l'identifiant client, le QR code apparaîtra aussitôt."
            return
        }
        GmailAuth.shared.clientID = id
        guard let url = PhoneOAuth.shared.arm(clientID: id, onAuto: { [weak self] t, err in
            self?.settle(t, err, source: "Mac")
        }) else {
            plate.payload = ""
            statusLabel.stringValue = "Port local indisponible, réessayez dans un instant."
            return
        }
        plate.payload = url
        statusLabel.stringValue = "Prêt. Scannez le code, ou cliquez « Ouvrir ici » pour rester sur le Mac."
    }

    // ── Actions ──

    private func commit() {
        guard !busy else { return }
        if mode == 0 { linkAppPassword() } else { linkOAuth() }
    }

    private func linkAppPassword() {
        let mail = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = GmailClient.normalizedPassword(passField.stringValue)
        guard mail.contains("@") else {
            statusLabel.stringValue = "Indiquez l'adresse Gmail complète."
            return
        }
        guard pass.count == 16 else {
            statusLabel.stringValue = "Un mot de passe d'application fait seize lettres — \(pass.count) saisie(s)."
            return
        }
        busy = true
        actionBtn.enabledFlag = false
        statusLabel.stringValue = "Vérification auprès de Gmail…"
        onStatus?("Vérification du compte Gmail")

        DispatchQueue.global(qos: .userInitiated).async {
            let err = GmailClient.testLogin(user: mail, password: pass)
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                s.busy = false
                s.actionBtn.enabledFlag = true
                if let e = err {
                    s.statusLabel.stringValue = e
                    s.onStatus?("Gmail a refusé le mot de passe")
                    return
                }
                _ = BudKeychain.set(pass, account: mail)
                GmailAuth.shared.disconnect()
                MailRouter.account = mail
                s.passField.stringValue = ""
                s.celebrate("Compte relié · \(mail)")
                s.onAccountChange?(mail)
            }
        }
    }

    private func linkOAuth() {
        let id = clientField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.contains("apps.googleusercontent.com") else {
            statusLabel.stringValue = "Collez d'abord l'identifiant client Google."
            return
        }
        guard PhoneOAuth.shared.armed else {
            armOAuth()
            statusLabel.stringValue = "Appairage relancé : scannez le nouveau code."
            return
        }
        busy = true
        actionBtn.enabledFlag = false
        statusLabel.stringValue = "Échange du code contre les jetons…"
        PhoneOAuth.shared.finish(pasted: pasteField.stringValue, clientID: id) { [weak self] t, err in
            self?.settle(t, err, source: "téléphone")
        }
    }

    private func settle(_ t: GoogleTokens?, _ err: String?, source: String) {
        busy = false
        actionBtn.enabledFlag = true
        guard let t = t, !t.email.isEmpty else {
            if let e = err {
                statusLabel.stringValue = "Échec : \(e)"
                onStatus?("Appairage refusé")
            }
            refresh()
            return
        }
        GmailAuth.shared.store(t)
        if !MailRouter.account.isEmpty {
            BudKeychain.delete(MailRouter.account)
            MailRouter.account = ""
        }
        pasteField.stringValue = ""
        PhoneOAuth.shared.cancel()
        celebrate("Compte relié par OAuth · \(t.email) · validé depuis le \(source)")
        onAccountChange?(t.email)
    }

    private func celebrate(_ msg: String) {
        statusLabel.stringValue = msg
        onStatus?("Gmail connecté")
        plate.paired = true
        plate.stopScan()
        refresh()
        // La coche arrive en fondu : l'ancrage du calque d'une NSView
        // est en bas à gauche, une mise à l'échelle décalerait la plaque.
        plate.alphaValue = 0.35
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            plate.animator().alphaValue = 1
        }
        linkedCard.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            linkedCard.animator().alphaValue = 1
        }
    }

    private func zoom() {
        guard !plate.payload.isEmpty else {
            statusLabel.stringValue = "Aucun code à agrandir pour l'instant."
            return
        }
        QRZoom.show(plate.payload, title: mode == 0 ? "Mots de passe d'application" : "Autorisation Google")
    }

    private func copyLink() {
        let link = mode == 0 ? appPasswordURL : PhoneOAuth.shared.authURL
        guard !link.isEmpty else {
            statusLabel.stringValue = "Aucun lien disponible pour l'instant."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        statusLabel.stringValue = "Lien copié. Envoyez-le à votre téléphone comme vous voulez."
        onStatus?("Lien d'appairage copié")
    }

    private func openHere() {
        let link = mode == 0 ? appPasswordURL : PhoneOAuth.shared.authURL
        guard !link.isEmpty, let u = URL(string: link) else {
            statusLabel.stringValue = "Aucun lien disponible pour l'instant."
            return
        }
        NSWorkspace.shared.open(u)
        statusLabel.stringValue = mode == 0
            ? "La page des mots de passe d'application s'ouvre sur le Mac."
            : "Consentement ouvert sur le Mac : BUD terminera tout seul."
    }

    private func disconnect() {
        GmailAuth.shared.disconnect()
        if !MailRouter.account.isEmpty {
            BudKeychain.delete(MailRouter.account)
            MailRouter.account = ""
        }
        PhoneOAuth.shared.cancel()
        plate.paired = false
        passField.stringValue = ""
        pasteField.stringValue = ""
        statusLabel.stringValue = "Compte déconnecté. BUD repasse par Mail.app."
        onStatus?("Compte Gmail déconnecté")
        onAccountChange?("")
        applyMode()
    }

    // ── Rafraîchissement ──

    func refresh() {
        // Le compte enregistré n'est restauré qu'après la construction
        // des panneaux : on complète les champs dès qu'il arrive.
        if emailField.stringValue.isEmpty {
            let known = MailRouter.account.isEmpty ? prefillAddress() : MailRouter.account
            emailField.stringValue = known
        }
        if clientField.stringValue.isEmpty { clientField.stringValue = GmailAuth.shared.clientID }

        let oauth = MailRouter.oauthReady
        let app = MailRouter.appPassword != nil
        let linked = oauth || app

        linkedCard.isHidden = !linked
        linkedLabel.stringValue = oauth
            ? "OAuth Google · \(GmailAuth.shared.email) · jetons dans le trousseau"
            : (app ? "Mot de passe d'application · \(MailRouter.account) · trousseau"
                   : "")
        disconnectBtn.enabledFlag = linked
        plate.paired = linked
        // En OAuth le code est dense : on met l'agrandissement en avant.
        zoomBtn.prominent = (mode == 1 && !linked)

        let showForm = !linked
        emailField.isHidden = !(showForm && mode == 0)
        passField.isHidden = !(showForm && mode == 0)
        clientField.isHidden = !(showForm && mode == 1)
        pasteField.isHidden = !(showForm && mode == 1)
        actionBtn.isHidden = !showForm
        zoomBtn.enabledFlag = !linked && !plate.payload.isEmpty
        copyBtn.enabledFlag = !linked

        if linked { plate.stopScan() } else { plate.startScan() }
        if linked && statusLabel.stringValue.isEmpty {
            statusLabel.stringValue = "Compte déjà relié. « Déconnecter » pour en changer."
        }
    }

    /// L'identifiant client vient d'être collé : on réarme le QR aussitôt.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === clientField, mode == 1 else { return }
        armOAuth()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { plate.stopScan() }
    }
}
