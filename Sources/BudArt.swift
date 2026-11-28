import Cocoa

// ═══════════════════════════════════════════════════════════
//  BUDs — le compagnon rendu
//
//  Sept expressions, rendues une à une : neutre, content,
//  réfléchi, déçu, en colère, étourdi, cool. Chacune est une
//  image complète, visage compris — on ne repeint plus rien en
//  code, on choisit le bon rendu et on l'anime.
//
//  Les sept partagent exactement le même cadrage, au pixel
//  près. C'est ce qui rend les transitions possibles : en
//  posant le nouveau visage par-dessus l'ancien, en fondu, la
//  silhouette ne bouge pas, seul le visage change.
//
//  Trois calques par dessin : la bille gauche, la bille
//  droite, le corps. Les billes sont séparées l'une de
//  l'autre pour rebondir chacune avec son déphasage — deux
//  antennes qui bougent ensemble ont l'air d'un seul objet,
//  décalées elles ont l'air vivantes.
// ═══════════════════════════════════════════════════════════

/// Les sept rendus, par leur nom de fichier.
enum BudsFace: String, CaseIterable {
    case neutral, happy, thinking, sad, angry, dizzy, cool
}

enum BudArt {

    /// Le suffixe d'encre des pièces du mot, pour le démarrage.
    static var ink: String { TH.dark ? "light" : "dark" }

    static func body(_ f: BudsFace) -> NSImage? { letter("buds-\(f.rawValue)") }
    static var dotL: NSImage? { letter("buds-dotL") }
    static var dotR: NSImage? { letter("buds-dotR") }

    /// Vrai quand le paquet porte les neuf calques. Sinon l'habillage
    /// retombe sur le dessin vectoriel, jamais sur une case vide.
    static var hasCompanion: Bool {
        dotL != nil && dotR != nil && BudsFace.allCases.allSatisfy { body($0) != nil }
    }

    /// Rapport largeur / hauteur de la toile commune (282 × 320).
    static let ratio: CGFloat = 282.0 / 320.0

    // ─────────────────────────────────────────────────────────
    //  Quelle tête pour quelle humeur
    //
    //  Treize humeurs, sept rendus. Le visage dit l'émotion, la
    //  posture dit le reste : « écoute » et « alerte » partagent
    //  le visage neutre, mais l'une se dresse et l'autre tremble.
    //
    //  Au repos, BUDs sourit. Le rendu neutre, avec sa bouche
    //  plate, est un visage d'attention — le montrer en
    //  permanence donnerait un compagnon qui boude.
    // ─────────────────────────────────────────────────────────

    static func face(for mood: BudMood, music: Bool) -> BudsFace {
        switch mood {
        case .calm, .happy, .wink, .speaking:
            // La musique met les lunettes. C'est le seul cas où le décor
            // décide du visage : une humeur passagère — une colère, un
            // échec — reste prioritaire pendant qu'elle dure.
            return music ? .cool : .happy
        case .proud:               return .cool
        case .listening, .alert, .working: return .neutral
        case .thinking, .confused: return .thinking
        case .sad, .sleepy:        return .sad
        case .angry:               return .angry
        case .dizzy:               return .dizzy
        }
    }

    // ─────────────────────────────────────────────────────────
    //  Le dessin
    // ─────────────────────────────────────────────────────────

    struct Pose {
        var face: BudsFace = .happy
        /// Le visage d'avant, et l'avancement du fondu vers le nouveau.
        var previous: BudsFace = .happy
        var mix: CGFloat = 1
        /// Rebond des billes, 0 à 1, et leur décalage l'une par rapport à
        /// l'autre.
        var liftL: CGFloat = 0
        var liftR: CGFloat = 0
        /// Inclinaison de la tête, en degrés, autour du haut du corps.
        var tilt: CGFloat = 0
        /// Tassement du corps, 0 à 0,16. Négatif : il s'étire.
        var squash: CGFloat = 0
    }

    static func drawBuds(in rect: NSRect, pose p: Pose) {
        guard let dl = dotL, let dr = dotR,
              let now = body(p.face) else { return }

        // L'ombre, en thème clair seulement. Les rendus sont blancs : sur
        // un fond clair, sans elle, le corps se confond avec le panneau et
        // on ne voit plus que le visage. En thème sombre elle salirait le
        // contour au lieu de le détacher.
        let shadow: NSShadow? = TH.dark ? nil : {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.26)
            s.shadowBlurRadius = max(2, rect.height * 0.05)
            s.shadowOffset = NSSize(width: 0, height: -max(1, rect.height * 0.018))
            return s
        }()

        NSGraphicsContext.current?.saveGraphicsState()
        shadow?.set()

        // Le corps se tasse par le bas : pieds au sol. Négatif, il
        // s'étire vers le haut — c'est le petit bond d'un changement
        // d'expression.
        let s = max(-0.08, min(0.16, p.squash))
        let bodyRect = NSRect(x: rect.minX - rect.width * s * 0.5,
                              y: rect.minY,
                              width: rect.width * (1 + s),
                              height: rect.height * (1 - s))

        // Le fondu. L'ancien visage est posé plein, le nouveau par-dessus
        // avec une opacité croissante. Fondre les deux à demi creuserait
        // la silhouette au milieu de la transition ; comme elles sont
        // identiques, poser l'une sur l'autre la garde pleine.
        if p.mix < 1, p.previous != p.face, let before = body(p.previous) {
            before.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1)
            now.draw(in: bodyRect, from: .zero, operation: .sourceOver,
                     fraction: Double(max(0, min(1, p.mix))))
        } else {
            now.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        // Les billes : chacune monte de son côté, puis toutes deux
        // suivent l'inclinaison de la tête autour du haut du corps.
        let pivot = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.62)
        for (img, lift) in [(dl, p.liftL), (dr, p.liftR)] {
            let up = lift * rect.height * 0.055
            let dest = NSRect(x: rect.minX, y: rect.minY + up,
                              width: rect.width, height: rect.height)
            NSGraphicsContext.current?.saveGraphicsState()
            if abs(p.tilt) > 0.01 {
                let t = NSAffineTransform()
                t.translateX(by: pivot.x, yBy: pivot.y)
                t.rotate(byDegrees: p.tilt)
                t.translateX(by: -pivot.x, yBy: -pivot.y)
                t.concat()
            }
            img.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
// ═══════════════════════════════════════════════════════════
//  L'écran de démarrage
//
//  Il a une seule justification : la première construction des
//  vues prend un instant, et sans rien à l'écran on clique deux
//  fois sur l'icône.
//
//  Il ne retient donc jamais l'application. BUD se construit
//  derrière lui, le splash s'efface seul, et il ne prend ni le
//  clic ni le clavier. Un écran de démarrage qui fait attendre
//  est pire que pas d'écran du tout — c'est pourquoi celui-ci
//  tient en deux secondes et demie, musique comprise.
//
//  Le mot est découpé en cinq calques : B, U, D et les deux
//  billes. Chacun entre à son tour, et c'est le décalage qui
//  fait l'effet — un mot qui apparaît d'un bloc n'a pas de
//  mouvement, il a une transition.
// ═══════════════════════════════════════════════════════════

extension BudArt {

    /// Les cinq morceaux du mot, et leur place sur la toile commune.
    /// Les rectangles sont en fractions, `y` compté depuis le haut :
    /// relevés sur l'illustration, ils tiennent à n'importe quelle taille.
    struct Piece {
        let name: String
        let rect: NSRect          // x, y (depuis le haut), largeur, hauteur
        let delay: CGFloat        // quand il entre
        let fromAbove: Bool       // les billes tombent, les lettres montent
    }

    static let wordPieces: [Piece] = [
        Piece(name: "bud-w-B",    rect: NSRect(x: 0.00000, y: 0.14822,
                                               width: 0.32233, height: 0.84091),
              delay: 0.00, fromAbove: false),
        Piece(name: "bud-w-U",    rect: NSRect(x: 0.31147, y: 0.25791,
                                               width: 0.35855, height: 0.74209),
              delay: 0.10, fromAbove: false),
        Piece(name: "bud-w-D",    rect: NSRect(x: 0.67485, y: 0.16008,
                                               width: 0.32515, height: 0.83004),
              delay: 0.20, fromAbove: false),
        Piece(name: "bud-w-dotL", rect: NSRect(x: 0.35332, y: 0.00000,
                                               width: 0.11066, height: 0.26285),
              delay: 0.44, fromAbove: true),
        Piece(name: "bud-w-dotR", rect: NSRect(x: 0.51187, y: 0.00000,
                                               width: 0.11147, height: 0.26285),
              delay: 0.52, fromAbove: true)
    ]

    /// Rapport largeur / hauteur de la toile du mot.
    static let wordRatio: CGFloat = 900.0 / 367.0

    private static var letterCache: [String: NSImage?] = [:]

    /// Charge une illustration, une fois. Le cache est indexé par le nom
    /// complet, suffixe compris : changer de thème en cours de route
    /// change le suffixe, pas le cache, et les deux jeux coexistent.
    static func letter(_ name: String) -> NSImage? {
        if let hit = letterCache[name] { return hit }
        let img = Bundle.main.url(forResource: name, withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
        letterCache[name] = img
        return img
    }

    /// La pièce du mot dans l'encre du thème courant.
    static func wordLetter(_ base: String) -> NSImage? { letter("\(base)-\(ink)") }

    /// Vrai quand le paquet porte de quoi animer le mot.
    static var hasWordmark: Bool {
        wordPieces.allSatisfy { wordLetter($0.name) != nil }
    }
}

final class SplashWindow: NSWindowController {

    private var art: SplashView!
    private var timer: Timer?
    private var chime: NSSound?
    private var t: CGFloat = 0

    /// Durées, en un seul endroit : la musique a été taillée pour elles.
    private static let fadeIn: CGFloat = 0.26
    private static let hold: CGFloat = 1.74
    private static let fadeOut: CGFloat = 0.46
    static var total: CGFloat { fadeIn + hold + fadeOut }

    private static var keep: SplashWindow?

    /// `sound` suit votre réglage : le carillon se tait quand les sons de
    /// BUD sont coupés. Un son de démarrage qu'un réglage « sons » ne
    /// coupe pas est un son qu'on cherche à faire taire dans le noir.
    static func present(sound: Bool) {
        guard BudArt.hasWordmark else { return }
        let s = SplashWindow(sound: sound)
        keep = s
        s.run()
    }

    init(sound: Bool) {
        let size = NSSize(width: 460, height: 300)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        super.init(window: w)

        art = SplashView(frame: NSRect(origin: .zero, size: size))
        w.contentView = art
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                     y: f.midY - size.height / 2 + 40))
        }

        if sound, let u = Bundle.main.url(forResource: "bud-chime", withExtension: "wav") {
            chime = NSSound(contentsOf: u, byReference: false)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func run() {
        window?.alphaValue = 0
        window?.orderFrontRegardless()
        chime?.play()
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    /// La progression est portée par une horloge et non par des
    /// animations enchaînées : si une trame saute — et la première
    /// seconde d'un lancement en saute — le splash sait toujours où il
    /// en est, au lieu de prendre du retard.
    private func step() {
        t += 1.0 / 60.0
        art.phase = t
        art.needsDisplay = true

        let fi = SplashWindow.fadeIn, hd = SplashWindow.hold, fo = SplashWindow.fadeOut
        if t < fi {
            window?.alphaValue = Double(ease(t / fi))
        } else if t < fi + hd {
            window?.alphaValue = 1
        } else if t < fi + hd + fo {
            window?.alphaValue = Double(1 - ease((t - fi - hd) / fo))
        } else {
            timer?.invalidate(); timer = nil
            // Le carillon dure moins que l'animation : il est fini. On
            // l'arrête quand même, au cas où le réglage audio du système
            // l'aurait ralenti.
            chime?.stop()
            window?.orderOut(nil)
            SplashWindow.keep = nil
        }
    }

    private func ease(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }
}

/// Le dessin du splash.
final class SplashView: NSView {
    var phase: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Entrée élastique : la pièce dépasse sa place puis y revient.
    ///
    /// Une courbe qui s'arrête pile à l'arrivée a l'air freinée ; un
    /// léger dépassement a l'air d'avoir du poids. C'est une sinusoïde
    /// amortie, pas une approximation en trois segments — l'amortissement
    /// se règle d'un seul nombre.
    private func spring(_ x: CGFloat) -> CGFloat {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return 1 - exp(-6.2 * x) * cos(8.6 * x)
    }

    private func ease(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds

        // ── La carte ──
        //  La fenêtre est transparente : sans fond, le mot flottait sur
        //  le papier peint, lisible ou non selon ce qu'il y avait
        //  dessous. Une carte règle la question, et le choix de l'encre
        //  avec : BUD pose son illustration claire sur une carte sombre,
        //  la noire sur une carte claire, et le contraste est garanti.
        let card = b.insetBy(dx: 10, dy: 10)
        TH.base.withAlphaComponent(TH.dark ? 0.90 : 0.94).setFill()
        NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                     xRadius: Radius.xl, yRadius: Radius.xl).fill()
        drawGlass(in: card, radius: Radius.xl, level: 1)

        // La toile du mot, centrée et un peu haute : les deux lignes de
        // texte occupent le bas.
        let ww = b.width * 0.76
        let wh = ww / BudArt.wordRatio
        let canvas = NSRect(x: b.midX - ww / 2, y: b.midY - wh / 2 + 30,
                            width: ww, height: wh)

        // ── La lueur, derrière ──
        let pulse = 0.5 + 0.5 * sin(phase * 2.6)
        let r = b.width * (0.40 + 0.05 * pulse)
        let glow = NSGradient(colors: [TH.accent.withAlphaComponent(0.20 + 0.10 * pulse),
                                       TH.accent.withAlphaComponent(0)])
        glow?.draw(in: NSRect(x: canvas.midX - r, y: canvas.midY - r * 0.60,
                              width: r * 2, height: r * 1.20),
                   relativeCenterPosition: .zero)

        // ── Le mot, pièce par pièce, dans un calque ──
        //  Le calque de transparence sert au reflet : il lui donne une
        //  surface à laquelle s'accrocher. Sans lui, la bande de lumière
        //  passerait aussi sur le fond.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        var allIn = true
        for p in BudArt.wordPieces {
            guard let img = BudArt.wordLetter(p.name) else { continue }
            let local = phase - p.delay
            if local <= 0 { allIn = false; continue }
            let prog = min(1, local / 0.52)
            if prog < 1 { allIn = false }
            let s = spring(prog)
            let a = ease(local / 0.34)

            // Place finale sur la toile, `y` de la pièce comptée depuis
            // le haut : il faut la retourner pour AppKit.
            let dest = NSRect(x: canvas.minX + canvas.width * p.rect.minX,
                              y: canvas.maxY - canvas.height * (p.rect.minY + p.rect.height),
                              width: canvas.width * p.rect.width,
                              height: canvas.height * p.rect.height)

            // Elle arrive de vingt-deux points, et d'un peu plus petit.
            let travel: CGFloat = (p.fromAbove ? 1 : -1) * 22 * (1 - s)
            let grow = 0.86 + 0.14 * s
            let cx = dest.midX, cy = dest.midY + travel
            let w = dest.width * grow, h = dest.height * grow
            img.draw(in: NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                     from: .zero, operation: .sourceOver, fraction: Double(min(1, a)))
        }

        // ── Le reflet ──
        //  Une bande claire qui traverse le mot une fois posé. Elle est
        //  composée en « sourceAtop » : elle ne marque que ce qui est
        //  déjà dessiné, donc les lettres, et jamais le fond entre elles.
        let sweepStart: CGFloat = 0.78
        if allIn || phase > sweepStart {
            let sp = (phase - sweepStart) / 0.62
            if sp > 0 && sp < 1 {
                let bandW = canvas.width * 0.30
                let x = canvas.minX - bandW + (canvas.width + bandW * 2) * sp
                // Elle s'atténue aux deux bouts : une bande qui apparaît
                // et disparaît d'un coup se voit comme un rectangle.
                let edge = sin(sp * .pi)
                ctx.saveGState()
                ctx.setBlendMode(.sourceAtop)
                let g = NSGradient(colors: [NSColor(white: 1, alpha: 0),
                                            NSColor(white: 1, alpha: 0.55 * edge),
                                            NSColor(white: 1, alpha: 0)])
                // Inclinée : un reflet vertical a l'air d'un essuie-glace.
                let band = NSBezierPath()
                let lean = canvas.height * 0.42
                band.move(to: CGPoint(x: x - lean, y: canvas.minY - 10))
                band.line(to: CGPoint(x: x + bandW - lean, y: canvas.minY - 10))
                band.line(to: CGPoint(x: x + bandW + lean, y: canvas.maxY + 10))
                band.line(to: CGPoint(x: x + lean, y: canvas.maxY + 10))
                band.close()
                band.addClip()
                g?.draw(in: NSRect(x: x - lean, y: canvas.minY - 10,
                                   width: bandW + lean * 2,
                                   height: canvas.height + 20), angle: 0)
                ctx.restoreGState()
            }
        }

        ctx.endTransparencyLayer()

        // ── Les deux lignes ──
        //  Elles montent de six points en apparaissant : le même geste
        //  que les lettres, en plus discret, pour que le bas de l'écran
        //  appartienne au même mouvement.
        let tl = ease((phase - 1.18) / 0.40)
        if tl > 0 {
            let lift = 6 * (1 - tl)
            drawString("Premium \(budVersion)",
                       in: NSRect(x: 0, y: canvas.minY - 30 - lift,
                                  width: b.width, height: 17),
                       size: 12, weight: .semibold,
                       color: TH.text.withAlphaComponent(0.72 * tl), align: .center)
            drawString("by Lahbib.AI",
                       in: NSRect(x: 0, y: canvas.minY - 50 - lift,
                                  width: b.width, height: 15),
                       size: 11, weight: .medium,
                       color: TH.accent.withAlphaComponent(0.78 * tl), align: .center)
        }
    }
}
