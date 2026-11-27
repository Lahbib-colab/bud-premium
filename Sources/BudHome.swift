import Cocoa

// ═══════════════════════════════════════════════════════════
//  La maison
//
//  Pourquoi Raccourcis et pas HomeKit directement : le cadre
//  HomeKit n'est pas ouvert aux applications AppKit. Apple
//  ne le permet sur Mac qu'aux applications Catalyst, avec
//  un droit spécial délivré à un compte développeur payant.
//  BUD n'a ni l'un ni l'autre.
//
//  Raccourcis, lui, a l'action « Contrôler la maison », et
//  macOS fournit `/usr/bin/shortcuts` pour lancer un
//  raccourci depuis n'importe quel programme. Donc : on crée
//  dans Raccourcis un dossier « BUD Maison », un raccourci
//  par commande (« Lumière salon », « Bonne nuit »…), et BUD
//  les présente en tuiles, comme l'application Maison.
//
//  L'avantage caché : chaque commande a été construite par
//  vous, dans l'application d'Apple. BUD ne voit jamais vos
//  appareils, ne reçoit aucun accès à HomeKit, et ne peut
//  faire que ce que vous avez mis dans le dossier.
// ═══════════════════════════════════════════════════════════

struct HomeScene {
    let name: String
    var symbol: String { HomeShortcuts.symbol(for: name) }
    var tint: NSColor { HomeShortcuts.tint(for: name) }
}

final class HomeShortcuts {
    static let shared = HomeShortcuts()
    static let tool = "/usr/bin/shortcuts"

    private(set) var scenes: [HomeScene] = []
    /// Vrai quand le dossier n'existe pas encore dans Raccourcis.
    private(set) var folderMissing = false
    private(set) var loaded = false
    private(set) var trouble = ""
    var onChange: (() -> Void)?

    private let q = DispatchQueue(label: "fr.lahbib.bud.home")

    static var available: Bool { FileManager.default.isExecutableFile(atPath: tool) }

    /// Relit le dossier. La commande prend une demi-seconde : jamais sur
    /// le fil principal.
    func reload(folder: String) {
        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HomeShortcuts.available else {
            DispatchQueue.main.async {
                self.loaded = true
                self.trouble = "Raccourcis n'est pas disponible sur ce Mac."
                self.onChange?()
            }
            return
        }
        q.async {
            let folders = runShellDetailed(HomeShortcuts.tool, ["list", "--folders"])
            let names = folders.out.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let missing = !names.contains { $0.lowercased() == f.lowercased() }
            var scenes: [HomeScene] = []
            var trouble = ""
            if !missing {
                // Le nom exact du dossier, tel que Raccourcis l'écrit.
                let exact = names.first { $0.lowercased() == f.lowercased() } ?? f
                let r = runShellDetailed(HomeShortcuts.tool, ["list", "--folder-name", exact])
                if r.status != 0 { trouble = "Lecture du dossier impossible." }
                scenes = r.out.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { HomeScene(name: $0) }
            } else if folders.status != 0 {
                trouble = "Raccourcis ne répond pas."
            }
            DispatchQueue.main.async {
                self.scenes = scenes
                self.folderMissing = missing && trouble.isEmpty
                self.trouble = trouble
                self.loaded = true
                self.onChange?()
            }
        }
    }

    /// Lance un raccourci. `done` reçoit, sur le fil principal, vrai si
    /// tout s'est bien passé et la sortie éventuelle du raccourci — un
    /// raccourci qui se termine par « Afficher le résultat » peut ainsi
    /// répondre « Salon allumé ».
    ///
    /// Un raccourci peut attendre une réponse qu'on ne lui donnera jamais :
    /// au bout de vingt secondes, on l'arrête.
    func run(_ name: String, done: @escaping (Bool, String) -> Void) {
        q.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: HomeShortcuts.tool)
            p.arguments = ["run", name, "--output-path", "-"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                DispatchQueue.main.async { done(false, "Lancement impossible.") }
                return
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let text = (String(data: o, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let errText = (String(data: e, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async {
                done(ok, ok ? String(text.prefix(140))
                            : (p.terminationReason == .uncaughtSignal ? "Délai dépassé."
                                                                       : HomeShortcuts.clean(errText)))
            }
        }
    }

    /// Les messages de `shortcuts` sont en anglais et techniques ; on en
    /// garde l'idée.
    private static func clean(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("couldn’t find") || l.contains("couldn't find") || l.contains("not found") {
            return "Raccourci introuvable."
        }
        if l.contains("permission") || l.contains("not allowed") { return "Autorisation refusée." }
        return "Le raccourci a échoué."
    }

    // ─────────────────────────────────────────────────────────
    //  Retrouver une commande dite à voix haute
    //
    //  « Allume le salon » doit trouver « Lumière salon ». On ne
    //  compare pas des phrases mais des mots : celui qui
    //  partage le plus de mots significatifs gagne, et il faut
    //  au moins tous les mots du nom ou deux mots communs. Un
    //  seul mot vague comme « lumière » ne suffit pas quand
    //  trois raccourcis le contiennent.
    // ─────────────────────────────────────────────────────────

    private static let filler: Set<String> = [
        "le", "la", "les", "l", "de", "du", "des", "d", "un", "une", "et", "a", "au", "aux",
        "mets", "met", "lance", "active", "allume", "eteins", "ferme", "ouvre", "baisse",
        "monte", "en", "mode", "scene", "stp", "s", "il", "te", "plait", "bud", "hey", "dans"
    ]

    private static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    func match(_ phrase: String) -> HomeScene? {
        let said = Set(HomeShortcuts.words(phrase))
        let saidKey = said.subtracting(HomeShortcuts.filler)
        var best: (HomeScene, Int)? = nil
        var tie = false
        for s in scenes {
            let all = HomeShortcuts.words(s.name)
            let key = Set(all).subtracting(HomeShortcuts.filler)
            // Le nom en entier, verbe compris : « Allume salon » dit tel quel.
            if !all.isEmpty && Set(all).isSubset(of: said) {
                let score = 100 + all.count
                if best == nil || score > best!.1 { best = (s, score); tie = false }
                continue
            }
            let common = key.intersection(saidKey).count
            guard common > 0, common == key.count || common >= 2 else { continue }
            if best == nil || common > best!.1 { best = (s, common); tie = false }
            else if common == best!.1 { tie = true }
        }
        return tie ? nil : best?.0
    }

    // ─────────────────────────────────────────────────────────
    //  L'apparence d'une tuile, d'après son nom
    //
    //  Raccourcis ne dit pas ce que fait un raccourci ; son nom,
    //  si. Symboles présents depuis macOS 12.
    // ─────────────────────────────────────────────────────────

    private static let kinds: [([String], String, NSColor)] = [
        (["bonne nuit", "coucher", "nuit", "dodo"], "moon.fill",
         NSColor(srgbRed: 0.48, green: 0.45, blue: 0.98, alpha: 1)),
        (["bonjour", "reveil", "matin"], "sun.max.fill",
         NSColor(srgbRed: 1.00, green: 0.72, blue: 0.20, alpha: 1)),
        (["depart", "je pars", "absent", "quitte"], "figure.walk",
         NSColor(srgbRed: 0.30, green: 0.70, blue: 1.00, alpha: 1)),
        (["arrivee", "rentre", "maison", "retour"], "house.fill",
         NSColor(srgbRed: 1.00, green: 0.60, blue: 0.22, alpha: 1)),
        (["film", "cinema", "tele", "tv"], "tv.fill",
         NSColor(srgbRed: 0.56, green: 0.40, blue: 1.00, alpha: 1)),
        (["chauffage", "thermostat", "temperature", "radiateur", "clim"], "thermometer",
         NSColor(srgbRed: 1.00, green: 0.45, blue: 0.30, alpha: 1)),
        (["ventilateur", "ventilo", "air"], "fan.fill",
         NSColor(srgbRed: 0.30, green: 0.80, blue: 0.85, alpha: 1)),
        (["serrure", "porte", "verrou", "garage"], "lock.fill",
         NSColor(srgbRed: 0.35, green: 0.75, blue: 1.00, alpha: 1)),
        (["volet", "store", "rideau"], "arrow.up.and.down.square.fill",
         NSColor(srgbRed: 0.55, green: 0.70, blue: 0.85, alpha: 1)),
        (["prise", "multiprise"], "powerplug.fill",
         NSColor(srgbRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)),
        (["camera", "alarme", "securite"], "video.fill",
         NSColor(srgbRed: 1.00, green: 0.40, blue: 0.40, alpha: 1)),
        (["musique", "enceinte", "homepod"], "hifispeaker.fill",
         NSColor(srgbRed: 0.98, green: 0.40, blue: 0.62, alpha: 1)),
        (["lumiere", "lampe", "eclairage", "ampoule", "allume", "eteins", "led"], "lightbulb.fill",
         NSColor(srgbRed: 1.00, green: 0.80, blue: 0.26, alpha: 1))
    ]

    private static func kind(for name: String) -> (String, NSColor)? {
        let n = words(name).joined(separator: " ")
        for (keys, sym, col) in kinds where keys.contains(where: { n.contains($0) }) {
            return (sym, col)
        }
        return nil
    }
    static func symbol(for name: String) -> String { kind(for: name)?.0 ?? "house.fill" }
    static func tint(for name: String) -> NSColor { kind(for: name)?.1 ?? TH.accent }
}

// ═══════════════════════════════════════════════════════════
//  Le panneau Maison
//
//  Des tuiles carrées arrondies, comme l'application Maison :
//  une pastille de couleur avec le symbole, le nom dessous.
//  Un clic lance la commande ; la tuile tourne pendant
//  l'exécution, puis montre une coche ou une croix deux
//  secondes, avec le message rendu par le raccourci.
// ═══════════════════════════════════════════════════════════

final class HomeTile: NSView {
    enum State { case idle, running, done, failed }
    let scene: HomeScene
    var state: State = .idle { didSet { needsDisplay = true; animate() } }
    var note = "" { didSet { needsDisplay = true } }
    var onClick: ((HomeTile) -> Void)?

    private var hover = false
    private var spin: CGFloat = 0
    private var timer: Timer?

    init(frame: NSRect, scene: HomeScene) {
        self.scene = scene
        super.init(frame: frame)
        wantsLayer = true
        toolTip = scene.name
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        guard state != .running, bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        onClick?(self)
    }

    private func animate() {
        if state == .running, timer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.spin += 0.22; self?.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if state != .running {
            timer?.invalidate(); timer = nil
        }
    }

    override func draw(_ dirty: NSRect) {
        let b = bounds.insetBy(dx: 1, dy: 1)
        let active = state == .running || state == .done
        let shape = NSBezierPath(roundedRect: b, xRadius: 18, yRadius: 18)
        // Une tuile active s'éclaire, comme un accessoire allumé dans
        // l'application Maison : fond presque blanc, texte sombre.
        if active && TH.dark {
            NSColor(white: 0.96, alpha: 0.95).setFill()
        } else {
            TH.fill(hover ? 0.13 : 0.08).setFill()
        }
        shape.fill()
        TH.fill(0.10).setStroke()
        shape.lineWidth = 0.8
        shape.stroke()

        let ink: NSColor = (active && TH.dark) ? NSColor(white: 0.1, alpha: 1) : TH.text
        let c = NSPoint(x: b.minX + 30, y: b.maxY - 30)
        let disc = NSRect(x: c.x - 17, y: c.y - 17, width: 34, height: 34)
        scene.tint.withAlphaComponent(active ? 1 : 0.9).setFill()
        NSBezierPath(ovalIn: disc).fill()

        switch state {
        case .running:
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: 10, startAngle: spin * 57.3, endAngle: spin * 57.3 + 260)
            p.lineWidth = 2.4
            p.lineCapStyle = .round
            NSColor.white.setStroke()
            p.stroke()
        case .done:
            drawSymbol("checkmark", center: c, size: 15, weight: .bold, color: .white)
        case .failed:
            drawSymbol("exclamationmark", center: c, size: 15, weight: .bold, color: .white)
        case .idle:
            drawSymbol(scene.symbol, center: c, size: 15, weight: .semibold, color: .white)
        }

        drawString(scene.name, in: NSRect(x: b.minX + 14, y: b.minY + 28, width: b.width - 24, height: 17),
                   size: 13, weight: .semibold, color: ink)
        let sub: String
        switch state {
        case .idle: sub = "Toucher pour lancer"
        case .running: sub = "En cours…"
        case .done: sub = note.isEmpty ? "Fait" : note
        case .failed: sub = note.isEmpty ? "Échec" : note
        }
        drawString(sub, in: NSRect(x: b.minX + 14, y: b.minY + 12, width: b.width - 24, height: 15),
                   size: 11, weight: .medium,
                   color: state == .failed ? dangerColor : ink.withAlphaComponent(0.55))
    }
}

final class HomePanelView: NSView {
    private let scroll: NSScrollView
    private let grid = FlippedView()
    private var tiles: [HomeTile] = []
    private var info: NSTextField!
    private var folderField: NSTextField!
    private var emptyView: NSView?

    var folder: () -> String = { "BUD Maison" }
    var onFolder: ((String) -> Void)?
    /// Prévient l'application qu'une commande a tourné, pour BUDs.
    var onRan: ((String, Bool) -> Void)?

    override init(frame: NSRect) {
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height - 92))
        super.init(frame: frame)
        let W = frame.width, H = frame.height

        addSubview(mkLabel("Maison", NSRect(x: 0, y: H - 34, width: 300, height: 28), 22, .bold))
        info = mkLabel("Vos commandes HomeKit, lancées par Raccourcis.",
                       NSRect(x: 0, y: H - 58, width: W - 20, height: 18), 12, .medium, alpha: 0.55)
        addSubview(info)

        addSubview(mkLabel("Dossier", NSRect(x: 0, y: H - 86, width: 60, height: 18), 11.5, .semibold, alpha: 0.6))
        folderField = NSTextField(frame: NSRect(x: 58, y: H - 89, width: 170, height: 24))
        folderField.bezelStyle = .roundedBezel
        folderField.font = NSFont.systemFont(ofSize: 12)
        folderField.target = self
        folderField.action = #selector(folderEntered)
        addSubview(folderField)

        let reload = GlassButton(frame: NSRect(x: 238, y: H - 91, width: 100, height: 28),
                                 title: "Recharger", icon: "arrow.clockwise", compact: true)
        reload.onClick = { [weak self] _ in self?.reload() }
        addSubview(reload)
        let open = GlassButton(frame: NSRect(x: 346, y: H - 91, width: 150, height: 28),
                               title: "Ouvrir Raccourcis", icon: "square.on.square", compact: true)
        open.onClick = { _ in HomePanelView.openShortcuts() }
        addSubview(open)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        addSubview(scroll)

        HomeShortcuts.shared.onChange = { [weak self] in self?.rebuild() }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func openShortcuts() {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        }
    }

    @objc private func folderEntered() {
        let f = folderField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return }
        onFolder?(f)
        reload()
    }

    func reload() {
        if folderField.currentEditor() == nil { folderField.stringValue = folder() }
        HomeShortcuts.shared.reload(folder: folder())
    }

    private func rebuild() {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        emptyView?.removeFromSuperview()
        emptyView = nil
        let h = HomeShortcuts.shared
        let W = scroll.frame.width - 14

        if !h.trouble.isEmpty || h.folderMissing || h.scenes.isEmpty {
            showEmpty(h)
            grid.frame = NSRect(x: 0, y: 0, width: W, height: scroll.frame.height)
            return
        }
        info.stringValue = "\(h.scenes.count) commande\(h.scenes.count > 1 ? "s" : "") dans « \(folder()) »."

        let cols = max(2, Int((W + 12) / 168))
        let tw = (W - CGFloat(cols - 1) * 12) / CGFloat(cols)
        let th: CGFloat = 112
        for (i, s) in h.scenes.enumerated() {
            let r = i / cols, c = i % cols
            let t = HomeTile(frame: NSRect(x: CGFloat(c) * (tw + 12), y: CGFloat(r) * (th + 12),
                                           width: tw, height: th), scene: s)
            t.onClick = { [weak self] tile in self?.launch(tile) }
            grid.addSubview(t)
            tiles.append(t)
        }
        let rows = (h.scenes.count + cols - 1) / cols
        grid.frame = NSRect(x: 0, y: 0, width: W,
                            height: max(scroll.frame.height, CGFloat(rows) * (th + 12)))
    }

    /// Lance par son nom : depuis le chat, la voix ou une tuile, le même
    /// chemin, et la tuile montre ce qui se passe.
    func launch(named name: String, done: ((Bool, String) -> Void)? = nil) {
        if let t = tiles.first(where: { $0.scene.name == name }) {
            launch(t, done: done)
        } else {
            HomeShortcuts.shared.run(name) { [weak self] ok, msg in
                self?.onRan?(name, ok); done?(ok, msg)
            }
        }
    }

    private func launch(_ t: HomeTile, done: ((Bool, String) -> Void)? = nil) {
        t.state = .running
        HomeShortcuts.shared.run(t.scene.name) { [weak self, weak t] ok, msg in
            t?.note = msg
            t?.state = ok ? .done : .failed
            self?.onRan?(t?.scene.name ?? "", ok)
            done?(ok, msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 2.2 : 4)) {
                if t?.state != .running { t?.note = ""; t?.state = .idle }
            }
        }
    }

    /// Quand il n'y a rien à montrer, on explique comment faire — en
    /// quatre étapes, dans les mots de Raccourcis.
    private func showEmpty(_ h: HomeShortcuts) {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: scroll.frame.width - 14, height: 260))
        let card = mkCard(v, NSRect(x: 0, y: 0, width: v.frame.width, height: 236), radius: Radius.l)
        _ = card
        let title: String
        if !h.loaded { title = "Lecture de Raccourcis…" }
        else if !h.trouble.isEmpty { title = h.trouble }
        else if h.folderMissing { title = "Le dossier « \(folder()) » n'existe pas encore dans Raccourcis." }
        else { title = "Le dossier « \(folder()) » est vide." }
        info.stringValue = "Vos commandes HomeKit, lancées par Raccourcis."

        let steps = [
            "1. Ouvrez Raccourcis et créez un dossier nommé « \(folder()) ».",
            "2. Dans ce dossier, créez un raccourci par commande : « Lumière salon », « Bonne nuit »…",
            "3. Ajoutez-y l'action « Contrôler la maison » et choisissez la scène ou l'accessoire.",
            "4. Revenez ici et cliquez sur Recharger. Dites ensuite « Hey Bud, lumière salon »."
        ]
        let lbl = mkLabel(title, NSRect(x: 20, y: 22, width: v.frame.width - 40, height: 20), 14, .semibold)
        v.addSubview(lbl)
        for (i, s) in steps.enumerated() {
            let l = mkLabel(s, NSRect(x: 20, y: 60 + CGFloat(i) * 30, width: v.frame.width - 40, height: 18),
                            12.5, .medium, alpha: 0.75)
            v.addSubview(l)
        }
        let note = mkLabel("BUD ne voit jamais vos appareils : il ne lance que ce dossier.",
                           NSRect(x: 20, y: 190, width: v.frame.width - 40, height: 16), 11, .medium, alpha: 0.45)
        v.addSubview(note)
        grid.addSubview(v)
        emptyView = v
    }
}

/// Une vue dont l'origine est en haut : la grille se remplit de haut en
/// bas, comme on la lit.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
