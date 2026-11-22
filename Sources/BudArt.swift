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
//  Le visage est peint dans le corps. On ne peut donc pas le
//  faire cligner sans l'effacer d'abord, ce qui demanderait de
//  reconstituer ce qu'il y a dessous. BUD anime donc ce qui se
//  déplace, et laisse l'expression telle qu'elle a été dessinée.
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

    /// Dessine le Ü dans un cadre, billes animées.
    ///
    /// `beat` va de 0 à 1 et commande le rebond ; `tilt` penche les billes
    /// comme une tête qu'on incline. Les deux calques partagent la même
    /// toile : le cadre est donc le même pour les deux, au décalage près.
    static func drawCompanion(in rect: NSRect, beat: CGFloat, tilt: CGFloat,
                              squash: CGFloat = 0) {
        guard let dots = dots, let body = body else { return }

        // Le corps se tasse par le bas : une forme qui s'écrase garde les
        // pieds au sol, sinon elle flotte.
        let s = max(0, min(0.14, squash))
        let bodyRect = NSRect(x: rect.minX - rect.width * s * 0.5,
                              y: rect.minY,
                              width: rect.width * (1 + s),
                              height: rect.height * (1 - s))
        body.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1)

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
