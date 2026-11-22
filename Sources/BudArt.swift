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
    static let wordmark = load("bud-wordmark")

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
//  Il a une seule justification : la première compilation des
//  vues et le chargement des réglages prennent un instant, et
//  sans rien à l'écran on clique deux fois sur l'icône.
//
//  Donc il est court — une seconde et demie — et il ne retient
//  jamais l'application : BUD finit de se construire derrière
//  lui, et le splash s'efface tout seul. Il ne prend pas le
//  clavier non plus. Un écran de démarrage qui fait attendre
//  est pire que pas d'écran du tout.
// ═══════════════════════════════════════════════════════════

final class SplashWindow: NSWindowController {

    private var art: SplashView!
    private var timer: Timer?
    private var t: CGFloat = 0

    static func present() {
        guard BudArt.wordmark != nil else { return }
        let s = SplashWindow()
        keep = s
        s.run()
    }

    init() {
        let size = NSSize(width: 420, height: 260)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        // Ni clic ni clavier : le splash est une image, pas une étape.
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
    }
    required init?(coder: NSCoder) { fatalError() }

    private func run() {
        window?.alphaValue = 0
        window?.orderFrontRegardless()
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    /// Trois temps : l'apparition, la respiration, l'effacement. La
    /// progression est portée par une horloge et non par des animations
    /// enchaînées, pour que le splash sache toujours où il en est si une
    /// trame saute.
    private func step() {
        t += 1.0 / 60.0
        art.phase = t
        art.needsDisplay = true

        let fadeIn: CGFloat = 0.32, hold: CGFloat = 1.05, fadeOut: CGFloat = 0.40
        if t < fadeIn {
            window?.alphaValue = Double(ease(t / fadeIn))
        } else if t < fadeIn + hold {
            window?.alphaValue = 1
        } else if t < fadeIn + hold + fadeOut {
            window?.alphaValue = Double(1 - ease((t - fadeIn - hold) / fadeOut))
        } else {
            timer?.invalidate(); timer = nil
            window?.orderOut(nil)
            SplashWindow.keep = nil
        }
    }

    /// Une fenêtre sans propriétaire disparaît avec sa dernière référence.
    /// Celle-ci se tient elle-même le temps de l'animation.
    private static var keep: SplashWindow?

    private func ease(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }
}

/// Le dessin du splash : le mot monte de quelques points en s'ouvrant,
/// et une lueur passe derrière lui.
final class SplashView: NSView {
    var phase: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        guard let img = BudArt.wordmark else { return }
        let b = bounds

        // La lueur, derrière : un disque qui respire. Elle donne au mot
        // l'air d'être allumé plutôt que posé sur du vide.
        let pulse = 0.5 + 0.5 * sin(phase * 2.6)
        let r = b.width * (0.42 + 0.05 * pulse)
        let glow = NSGradient(colors: [TH.accent.withAlphaComponent(0.22 + 0.10 * pulse),
                                       TH.accent.withAlphaComponent(0)])
        glow?.draw(in: NSRect(x: b.midX - r, y: b.midY - r * 0.62,
                              width: r * 2, height: r * 1.24), relativeCenterPosition: .zero)

        // Le mot : il monte de douze points et grandit d'un centième
        // pendant l'apparition. Au-delà, il est posé.
        let p = min(1, phase / 0.42)
        let e = p * p * (3 - 2 * p)
        let w = b.width * 0.78 * (0.99 + 0.01 * e)
        let h = w * (img.size.height / max(1, img.size.width))
        let rect = NSRect(x: b.midX - w / 2,
                          y: b.midY - h / 2 + 16 - 12 * (1 - e),
                          width: w, height: h)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: Double(e))

        // La version, discrète, sous le mot.
        drawString("Premium \(budVersion)",
                   in: NSRect(x: 0, y: rect.minY - 22, width: b.width, height: 16),
                   size: 11, weight: .medium,
                   color: TH.dim(0.45).withAlphaComponent(0.45 * e), align: .center)
    }
}
