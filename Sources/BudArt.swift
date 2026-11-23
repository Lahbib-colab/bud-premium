import Cocoa

// ═══════════════════════════════════════════════════════════
//  Le logo
//
//  Trois images dans le paquet, et une raison pour le
//  découpage. Le mot entier sert au démarrage. Le Ü est coupé
//  en deux calques — les deux billes d'un côté, le U avec son
//  visage de l'autre — sur la même toile, aux mêmes
//  dimensions, de sorte qu'ils se superposent sans calcul.
//
//  C'est ce découpage qui rend l'animation possible sans
//  retoucher le dessin : les billes rebondissent et penchent
//  pendant que le corps se tasse, et le tout reste votre
//  illustration, pas une imitation vectorielle.
//
//  Et le visage, cette fois, n'est pas peint dans le corps :
//  les yeux et la bouche sont des îlots clairs qui flottent
//  dans l'ouverture du U, sans toucher l'anneau. On a donc pu
//  les retirer proprement et les repeindre en code — ce qui
//  fait la différence entre un compagnon qui bouge et un
//  compagnon qui a des humeurs.
//
//  Leur position n'est pas inventée : elle est relevée sur
//  votre illustration, en fractions de la boîte du visage.
//  L'œil gauche était à 23 % de sa largeur, le droit à 76 %,
//  la bouche à 51 %. Toutes les humeurs se posent là.
// ═══════════════════════════════════════════════════════════

enum BudArt {

    /// Chargées une fois. `nil` si le paquet ne les porte pas — une
    /// installation par les sources d'une version antérieure, par
    /// exemple : l'habillage retombe alors sur le dessin vectoriel plutôt
    /// que d'afficher un carré vide.
    static let dots = load("bud-dots")
    static let body = load("bud-body")

    /// Vrai quand le paquet porte de quoi dessiner le compagnon.
    static var hasCompanion: Bool { dots != nil && body != nil }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        return img
    }

    // ─────────────────────────────────────────────────────────
    //  La boîte du visage, relevée sur l'illustration
    //
    //  En fractions de la toile, origine en bas comme AppKit.
    //  Les mesures ont été prises sur l'image d'origine avant
    //  effacement des traits : c'est pourquoi les humeurs se
    //  posent exactement où le visage était.
    // ─────────────────────────────────────────────────────────

    private static let faceX: CGFloat = 0.2750
    private static let faceY: CGFloat = 0.3020     // 1 − (0.4723 + 0.2257)
    private static let faceW: CGFloat = 0.4322
    private static let faceH: CGFloat = 0.2258

    /// Dessine le Ü dans un cadre, billes animées et visage peint.
    ///
    /// `beat` va de 0 à 1 et commande le rebond ; `tilt` penche les billes
    /// comme une tête qu'on incline. Les deux calques partagent la même
    /// toile : le cadre est donc le même pour les deux, au décalage près.
    static func drawCompanion(in rect: NSRect, beat: CGFloat, tilt: CGFloat,
                              squash: CGFloat = 0,
                              mood: BudMood = .calm, clock: CGFloat = 0) {
        guard let dots = dots, let body = body else { return }

        // Le corps se tasse par le bas : une forme qui s'écrase garde les
        // pieds au sol, sinon elle flotte.
        let s = max(0, min(0.14, squash))
        let bodyRect = NSRect(x: rect.minX - rect.width * s * 0.5,
                              y: rect.minY,
                              width: rect.width * (1 + s),
                              height: rect.height * (1 - s))
        body.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1)

        // Le visage suit le corps et non le cadre : quand BUD se tasse,
        // ses yeux se tassent avec lui. Peint après le corps, avant les
        // billes, comme dans l'illustration.
        let face = NSRect(x: bodyRect.minX + bodyRect.width * faceX,
                          y: bodyRect.minY + bodyRect.height * faceY,
                          width: bodyRect.width * faceW,
                          height: bodyRect.height * faceH)
        drawFace(in: face, mood: mood, clock: clock)

        // Les billes montent, et penchent autour du centre du cadre.
        let lift = beat * rect.height * 0.055
        let dotsRect = NSRect(x: rect.minX, y: rect.minY + lift,
                              width: rect.width, height: rect.height)
        guard abs(tilt) > 0.001 else {
            dots.draw(in: dotsRect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        NSGraphicsContext.current?.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: rect.midX, yBy: rect.midY)
        t.rotate(byDegrees: tilt)
        t.translateX(by: -rect.midX, yBy: -rect.midY)
        t.concat()
        dots.draw(in: dotsRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // ═══════════════════════════════════════════════════════════
    //  Le visage
    //
    //  Peint en vectoriel dans l'ouverture du U. Les traits sont
    //  blancs avec un dégradé vers le gris en bas, comme ceux de
    //  l'illustration : posés sur le fond sombre de la cavité,
    //  ils se lisent du premier coup d'œil.
    //
    //  Une règle tient tout : en dessous d'une certaine taille,
    //  on enlève du détail plutôt que de le rétrécir. Le
    //  compagnon vit dans un notch de vingt-huit points de haut
    //  — une spirale d'étourdi y deviendrait une tache grise,
    //  alors que deux croix s'y lisent encore.
    // ═══════════════════════════════════════════════════════════

    /// Repères relevés sur l'illustration, en fractions de la boîte du
    /// visage, `y` compté depuis le haut.
    private static let eyeL = CGPoint(x: 0.231, y: 0.220)
    private static let eyeR = CGPoint(x: 0.763, y: 0.217)
    private static let mouthC = CGPoint(x: 0.507, y: 0.784)
    private static let eyeW: CGFloat = 0.466       // largeur d'un œil
    private static let eyeH: CGFloat = 0.435
    private static let mouthW: CGFloat = 0.365
    private static let mouthH: CGFloat = 0.427

    static func drawFace(in box: NSRect, mood: BudMood, clock: CGFloat) {
        guard box.width > 6, box.height > 4 else { return }
        let fine = box.width >= 44          // assez grand pour du détail

        // Un point de la boîte, `y` depuis le haut comme les mesures.
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + box.width * fx,
                    y: box.maxY - box.height * fy)
        }
        let ew = box.width * eyeW, eh = box.height * eyeH
        let lc = p(eyeL.x, eyeL.y), rc = p(eyeR.x, eyeR.y)
        let mc = p(mouthC.x, mouthC.y)
        let mw = box.width * mouthW, mh = box.height * mouthH

        switch mood {

        case .calm, .happy:
            // Le visage d'origine : deux arches et une bouche ouverte.
            // L'humeur joyeuse ouvre un peu plus la bouche, rien d'autre —
            // votre dessin est déjà souriant, il n'y a pas à le refaire.
            let grow: CGFloat = mood == .happy ? 1.18 : 1
            arch(at: lc, w: ew, h: eh); arch(at: rc, w: ew, h: eh)
            smile(at: mc, w: mw * grow, h: mh * grow)

        case .wink:
            arch(at: lc, w: ew, h: eh)
            blob(at: rc, w: ew * 0.52, h: eh * 0.82)
            smile(at: mc, w: mw, h: mh)

        case .sleepy:
            // Paupières closes : deux traits, et une petite bouche molle.
            bar(at: lc, w: ew * 0.86, thick: eh * 0.30, angle: 0)
            bar(at: rc, w: ew * 0.86, thick: eh * 0.30, angle: 0)
            bar(at: mc, w: mw * 0.62, thick: mh * 0.26, angle: 0)

        case .alert:
            // Yeux grands ouverts, bouche en « o » : la surprise se lit à
            // l'ouverture, pas à la couleur.
            blob(at: lc, w: ew * 0.80, h: eh * 1.12)
            blob(at: rc, w: ew * 0.80, h: eh * 1.12)
            blob(at: mc, w: mw * 0.52, h: mh * 0.86)

        case .angry:
            // La colère est dans les sourcils, pas dans les yeux : deux
            // barres qui plongent vers le nez, et une bouche renversée.
            // C'est le seul trait qui se lise encore à seize points.
            bar(at: CGPoint(x: lc.x, y: lc.y + eh * 0.10),
                w: ew * 0.98, thick: eh * 0.34, angle: -17)
            bar(at: CGPoint(x: rc.x, y: rc.y + eh * 0.10),
                w: ew * 0.98, thick: eh * 0.34, angle: 17)
            frown(at: CGPoint(x: mc.x, y: mc.y - mh * 0.10), w: mw * 1.12, h: mh * 0.80)

        case .dizzy:
            // Étourdi : des spirales quand la place le permet, deux croix
            // sinon. Une spirale de six points de large n'est plus une
            // spirale, c'est une bavure.
            let wob = sin(clock * 7) * box.height * 0.045
            if fine {
                spiral(at: CGPoint(x: lc.x, y: lc.y + wob), r: eh * 0.56, turns: 2.1,
                       width: max(1.2, eh * 0.16), phase: clock * 2.4)
                spiral(at: CGPoint(x: rc.x, y: rc.y - wob), r: eh * 0.56, turns: 2.1,
                       width: max(1.2, eh * 0.16), phase: -clock * 2.4)
            } else {
                cross(at: CGPoint(x: lc.x, y: lc.y + wob), r: eh * 0.46,
                      width: max(1.4, eh * 0.26))
                cross(at: CGPoint(x: rc.x, y: rc.y - wob), r: eh * 0.46,
                      width: max(1.4, eh * 0.26))
            }
            wavy(at: mc, w: mw * 1.25, h: mh * 0.52, width: max(1.4, mh * 0.26),
                 phase: clock * 3)

        case .thinking:
            // Réfléchi : le regard part en haut à gauche et y reste. Ce
            // n'est pas un clin d'œil — les deux pupilles vont du même
            // côté, sinon on lit un strabisme et non une réflexion.
            let look = CGPoint(x: -ew * 0.17, y: -eh * 0.20)
            blob(at: CGPoint(x: lc.x + look.x, y: lc.y - look.y),
                 w: ew * 0.46, h: eh * 0.74)
            blob(at: CGPoint(x: rc.x + look.x, y: rc.y - look.y),
                 w: ew * 0.46, h: eh * 0.74)
            // Un sourcil levé au-dessus de l'œil droit : c'est lui qui
            // fait basculer la lecture de « distrait » à « il réfléchit ».
            if fine {
                bar(at: CGPoint(x: rc.x, y: rc.y + eh * 0.78),
                    w: ew * 0.82, thick: eh * 0.22, angle: 9)
            }
            // Bouche serrée, décalée : la moue de celui qui pèse le pour
            // et le contre.
            bar(at: CGPoint(x: mc.x - mw * 0.14, y: mc.y),
                w: mw * 0.74, thick: mh * 0.28, angle: -6)
        }
    }

    // ─────────────────────────────────────────────────────────
    //  Les primitives
    //
    //  Toutes remplies du même dégradé : blanc en haut, gris
    //  perle en bas. C'est ce léger poids vers le bas qui donne
    //  aux traits l'air d'appartenir à la même matière que le U.
    // ─────────────────────────────────────────────────────────

    private static func paint(_ path: NSBezierPath, in bounds: NSRect) {
        let g = NSGradient(colors: [NSColor(calibratedWhite: 1.00, alpha: 1),
                                    NSColor(calibratedWhite: 0.84, alpha: 1)])
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        g?.draw(in: bounds, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private static func fill(_ path: NSBezierPath) {
        paint(path, in: path.bounds.insetBy(dx: -1, dy: -1))
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat) {
        // On transforme le trait en surface avant de le peindre : un
        // dégradé ne s'applique pas à un contour, seulement à un
        // remplissage.
        let outline = path.cgPath(strokedWidth: width)
        paint(outline, in: outline.bounds.insetBy(dx: -1, dy: -1))
    }

    /// Une arche « ⌒ » : l'œil fermé et souriant de l'illustration.
    private static func arch(at c: CGPoint, w: CGFloat, h: CGFloat) {
        let r = w / 2
        let th = max(1.2, h * 0.52)
        let p = NSBezierPath()
        let base = CGPoint(x: c.x, y: c.y - h * 0.18)
        p.appendArc(withCenter: base, radius: r, startAngle: 0, endAngle: 180)
        p.appendArc(withCenter: base, radius: max(0.5, r - th),
                    startAngle: 180, endAngle: 0, clockwise: true)
        p.close()
        fill(p)
    }

    /// Un ovale plein : la pupille, ou une bouche en « o ».
    private static func blob(at c: CGPoint, w: CGFloat, h: CGFloat) {
        fill(NSBezierPath(ovalIn: NSRect(x: c.x - w / 2, y: c.y - h / 2,
                                         width: w, height: h)))
    }

    /// Une barre aux bouts arrondis, inclinée. Sert de sourcil, de
    /// paupière close et de bouche serrée.
    private static func bar(at c: CGPoint, w: CGFloat, thick: CGFloat, angle: CGFloat) {
        let t = max(1.2, thick)
        let r = NSRect(x: -w / 2, y: -t / 2, width: w, height: t)
        let p = NSBezierPath(roundedRect: r, xRadius: t / 2, yRadius: t / 2)
        let m = AffineTransform(translationByX: c.x, byY: c.y)
        var rot = AffineTransform(rotationByDegrees: angle)
        rot.append(m)
        p.transform(using: rot)
        fill(p)
    }

    /// La bouche ouverte de l'illustration : plate en haut, ronde en bas.
    private static func smile(at c: CGPoint, w: CGFloat, h: CGFloat) {
        let p = NSBezierPath()
        let left = CGPoint(x: c.x - w / 2, y: c.y + h / 2)
        let right = CGPoint(x: c.x + w / 2, y: c.y + h / 2)
        p.move(to: left)
        p.line(to: right)
        p.curve(to: left,
                controlPoint1: CGPoint(x: right.x, y: c.y - h * 0.95),
                controlPoint2: CGPoint(x: left.x, y: c.y - h * 0.95))
        p.close()
        fill(p)
    }

    /// La bouche renversée de la colère.
    private static func frown(at c: CGPoint, w: CGFloat, h: CGFloat) {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: c.x - w / 2, y: c.y - h * 0.30))
        p.curve(to: CGPoint(x: c.x + w / 2, y: c.y - h * 0.30),
                controlPoint1: CGPoint(x: c.x - w * 0.22, y: c.y + h * 0.62),
                controlPoint2: CGPoint(x: c.x + w * 0.22, y: c.y + h * 0.62))
        stroke(p, width: max(1.4, h * 0.42))
    }

    /// Une spirale, dessinée en segments : deux tours et un peu.
    private static func spiral(at c: CGPoint, r: CGFloat, turns: CGFloat,
                               width: CGFloat, phase: CGFloat) {
        let p = NSBezierPath()
        let steps = 48
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let a = phase + f * turns * 2 * .pi
            let rad = r * f
            let pt = CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        stroke(p, width: width)
    }

    /// Deux traits croisés : l'étourdi, quand la spirale ne tient plus.
    private static func cross(at c: CGPoint, r: CGFloat, width: CGFloat) {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: c.x - r, y: c.y - r))
        p.line(to: CGPoint(x: c.x + r, y: c.y + r))
        p.move(to: CGPoint(x: c.x - r, y: c.y + r))
        p.line(to: CGPoint(x: c.x + r, y: c.y - r))
        stroke(p, width: width)
    }

    /// Une bouche ondulée, qui se déplace lentement : le haut-le-cœur.
    private static func wavy(at c: CGPoint, w: CGFloat, h: CGFloat,
                             width: CGFloat, phase: CGFloat) {
        let p = NSBezierPath()
        let steps = 20
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let x = c.x - w / 2 + w * f
            let y = c.y + sin(phase + f * 3.4 * .pi) * h * 0.5
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.line(to: CGPoint(x: x, y: y)) }
        }
        stroke(p, width: width)
    }
}

extension NSBezierPath {
    /// Le contour d'un trait, rendu comme une surface remplissable.
    ///
    /// `NSGradient` ne sait peindre qu'un remplissage. Pour qu'une
    /// spirale ait la même matière que les autres traits, il faut donc
    /// transformer sa ligne en forme — ce que `CGPath` sait faire et
    /// `NSBezierPath` non.
    func cgPath(strokedWidth: CGFloat) -> NSBezierPath {
        let cg = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo:    cg.move(to: pts[0])
            case .lineTo:    cg.addLine(to: pts[0])
            case .curveTo:   cg.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: cg.closeSubpath()
            @unknown default: break
            }
        }
        let outline = cg.copy(strokingWithWidth: strokedWidth, lineCap: .round,
                              lineJoin: .round, miterLimit: 10)
        let out = NSBezierPath()
        outline.applyWithBlock { el in
            let p = el.pointee.points
            switch el.pointee.type {
            case .moveToPoint:         out.move(to: p[0])
            case .addLineToPoint:      out.line(to: p[0])
            case .addQuadCurveToPoint: out.curve(to: p[1], controlPoint1: p[0], controlPoint2: p[0])
            case .addCurveToPoint:     out.curve(to: p[2], controlPoint1: p[0], controlPoint2: p[1])
            case .closeSubpath:        out.close()
            @unknown default: break
            }
        }
        return out
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
        Piece(name: "bud-w-B",    rect: NSRect(x: 0.00000, y: 0.17195,
                                               width: 0.30531, height: 0.82805),
              delay: 0.00, fromAbove: false),
        Piece(name: "bud-w-U",    rect: NSRect(x: 0.31755, y: 0.30090,
                                               width: 0.34082, height: 0.68100),
              delay: 0.10, fromAbove: false),
        Piece(name: "bud-w-D",    rect: NSRect(x: 0.68286, y: 0.18665,
                                               width: 0.31714, height: 0.80204),
              delay: 0.20, fromAbove: false),
        Piece(name: "bud-w-dotL", rect: NSRect(x: 0.35184, y: 0.00000,
                                               width: 0.11143, height: 0.29864),
              delay: 0.44, fromAbove: true),
        Piece(name: "bud-w-dotR", rect: NSRect(x: 0.51184, y: 0.00000,
                                               width: 0.11265, height: 0.29864),
              delay: 0.52, fromAbove: true)
    ]

    /// Le visage du U, en fractions de la toile du mot. Mesuré sur les
    /// traits de l'illustration, puis peint par le même pinceau que le
    /// compagnon : c'est ce qui fait que le démarrage et le notch
    /// montrent exactement la même tête.
    static let wordFace = NSRect(x: 0.4176, y: 0.5407, width: 0.1469, height: 0.2500)

    /// Rapport largeur / hauteur de la toile du mot.
    static let wordRatio: CGFloat = 900.0 / 325.0

    private static var letterCache: [String: NSImage?] = [:]

    static func letter(_ name: String) -> NSImage? {
        if let hit = letterCache[name] { return hit }
        let img = Bundle.main.url(forResource: name, withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
        letterCache[name] = img
        return img
    }

    /// Vrai quand le paquet porte de quoi animer le mot.
    static var hasWordmark: Bool {
        wordPieces.allSatisfy { letter($0.name) != nil }
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

        // La toile du mot, centrée et un peu haute : les deux lignes de
        // texte occupent le bas.
        let ww = b.width * 0.80
        let wh = ww / BudArt.wordRatio
        let canvas = NSRect(x: b.midX - ww / 2, y: b.midY - wh / 2 + 34,
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
            guard let img = BudArt.letter(p.name) else { continue }
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

        // ── Le visage, une fois le mot assemblé ──
        if phase > 0.92 {
            let fa = ease((phase - 0.92) / 0.30)
            let f = BudArt.wordFace
            let face = NSRect(x: canvas.minX + canvas.width * f.minX,
                              y: canvas.maxY - canvas.height * (f.minY + f.height),
                              width: canvas.width * f.width,
                              height: canvas.height * f.height)
            ctx.saveGState()
            ctx.setAlpha(fa)
            BudArt.drawFace(in: face, mood: .calm, clock: phase)
            ctx.restoreGState()
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
