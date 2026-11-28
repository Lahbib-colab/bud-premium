import Cocoa
import QuartzCore

// ═══════════════════════════════════════════════════════════
//  La pilule Outils et son menu
//
//  La pilule se tient au début de la rangée de suggestions,
//  juste au-dessus du champ : là où l'œil est déjà quand on
//  écrit à BUD. Un clic ouvre le menu vers le haut, par-dessus
//  la conversation, depuis le coin de la pilule — il en sort,
//  il ne tombe pas du ciel. Un clic ailleurs ou Échap le
//  referme.
//
//  Le menu ne connaît aucun outil : il lit `BudToolManager`
//  par catégorie. Un outil ajouté apparaît à sa place.
// ═══════════════════════════════════════════════════════════

/// Le verre sombre commun à la pilule, au menu et à la barre de
/// confirmation : un dégradé presque transparent, un liseré clair, et un
/// reflet d'un point en haut — ce qui donne l'épaisseur.
func drawLiquidGlass(_ path: NSBezierPath, in r: NSRect, active: Bool, hover: CGFloat) {
    let top = TH.dark ? NSColor(calibratedWhite: 1, alpha: 0.13 + hover * 0.06)
                      : NSColor(calibratedWhite: 1, alpha: 0.75)
    let bottom = TH.dark ? NSColor(calibratedWhite: 1, alpha: 0.04 + hover * 0.03)
                         : NSColor(calibratedWhite: 0.94, alpha: 0.70)
    NSGradient(colors: [bottom, top])?.draw(in: path, angle: 90)
    if active {
        TH.accent.withAlphaComponent(0.20).setFill()
        path.fill()
    }
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    // Le reflet : une ligne claire posée sur le bord haut, intérieur.
    let hl = NSBezierPath()
    hl.move(to: NSPoint(x: r.minX + r.height / 2, y: r.maxY - 0.75))
    hl.line(to: NSPoint(x: r.maxX - r.height / 2, y: r.maxY - 0.75))
    hl.lineWidth = 1
    NSColor(calibratedWhite: 1, alpha: TH.dark ? 0.28 : 0.9).setStroke()
    hl.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()
    (active ? TH.accent.withAlphaComponent(0.65) : TH.fill(0.22)).setStroke()
    path.lineWidth = 0.9
    path.stroke()
}

// ─────────────────────────────────────────────────────────
//  La pilule
// ─────────────────────────────────────────────────────────

final class ToolPillView: NSView {
    var open = false { didSet { animate() } }
    var onClick: (() -> Void)?

    private var hoverT: CGFloat = 0, hovering = false
    private var spin: CGFloat = 0          // 0 fermé, 1 ouvert : le chevron se retourne
    private var pressed = false
    private var timer: Timer?

    static let label = "Outils"
    static func idealWidth() -> CGFloat { textWidth(label, size: 12, weight: .semibold) + 62 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Outils de BUD")
        toolTip = "Capture, veille, agents…"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; animate() }
    override func mouseExited(with e: NSEvent) { hovering = false; animate() }
    override func mouseDown(with e: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
    }

    private func animate() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tm in
            guard let s = self else { tm.invalidate(); return }
            let h: CGFloat = s.hovering ? 1 : 0, o: CGFloat = s.open ? 1 : 0
            s.hoverT += (h - s.hoverT) * 0.25
            s.spin += (o - s.spin) * 0.28
            if abs(h - s.hoverT) < 0.01 && abs(o - s.spin) < 0.01 {
                s.hoverT = h; s.spin = o
                tm.invalidate(); s.timer = nil
            }
            s.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func draw(_ dirty: NSRect) {
        var r = bounds.insetBy(dx: 1, dy: 1)
        if pressed { r = r.insetBy(dx: 1.5, dy: 1) }
        drawLiquidGlass(capsule(r), in: r, active: open, hover: hoverT)

        let ink = open ? TH.accent : TH.text
        drawSymbol("square.grid.2x2.fill", center: NSPoint(x: r.minX + 17, y: r.midY),
                   size: 11, weight: .semibold, color: ink)
        drawString(ToolPillView.label, in: NSRect(x: r.minX + 30, y: r.midY - 8, width: r.width - 50, height: 16),
                   size: 12, weight: .semibold, color: TH.text)

        // Le chevron tourne d'un demi-tour à l'ouverture : il pointe vers
        // le menu, qui s'ouvre vers le haut.
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = NSPoint(x: r.maxX - 15, y: r.midY)
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: .pi * spin)
        drawSymbol("chevron.down", center: .zero, size: 8.5, weight: .bold, color: TH.dim(0.7))
        ctx.restoreGState()
    }
}

// ─────────────────────────────────────────────────────────
//  Le menu
// ─────────────────────────────────────────────────────────

private final class ToolRowView: NSView {
    let tool: BudTool
    var onPick: ((BudTool) -> Void)?
    private var hover = false

    init(frame: NSRect, tool: BudTool) {
        self.tool = tool
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tool.title)
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
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onPick?(tool) }
    }

    override func draw(_ dirty: NSRect) {
        let b = bounds
        let busy = BudToolManager.shared.isRunning(tool.id)
        if hover && !busy {
            TH.fill(0.10).setFill()
            NSBezierPath(roundedRect: b.insetBy(dx: 6, dy: 1), xRadius: 10, yRadius: 10).fill()
        }
        let tile = NSRect(x: 14, y: b.midY - 14, width: 28, height: 28)
        NSGradient(colors: [tool.tint, tool.tint.blended(withFraction: 0.35, of: .black) ?? tool.tint])?
            .draw(in: NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8), angle: -90)
        drawSymbol(tool.icon, center: NSPoint(x: tile.midX, y: tile.midY), size: 12.5, weight: .semibold, color: .white)

        let tx = tile.maxX + 11
        drawString(tool.title, in: NSRect(x: tx, y: b.midY, width: b.width - tx - 40, height: 16),
                   size: 12.5, weight: .semibold, color: TH.text.withAlphaComponent(busy ? 0.5 : 1))
        drawString(busy ? "En cours…" : tool.subtitle,
                   in: NSRect(x: tx, y: b.midY - 15, width: b.width - tx - 40, height: 14),
                   size: 10.5, weight: .medium, color: TH.dim(0.5))

        // À droite, ce qui attend avant d'agir : une main pour une
        // question, un sablier pour un compte à rebours.
        let mark: String?
        switch tool.risk {
        case .none: mark = nil
        case .confirm: mark = "hand.raised.fill"
        case .countdown: mark = "timer"
        }
        if let m = mark {
            drawSymbol(m, center: NSPoint(x: b.maxX - 24, y: b.midY), size: 10, weight: .semibold, color: TH.dim(0.45))
        }
    }
}

final class ToolMenuView: NSView {
    var onPick: ((BudTool) -> Void)?
    private let glass = NSVisualEffectView()

    static let width: CGFloat = 300
    private static let rowH: CGFloat = 46, headH: CGFloat = 24

    /// La hauteur qu'il faut pour tout montrer, plafonnée par l'appelant.
    static func contentHeight() -> CGFloat {
        let m = BudToolManager.shared
        var h: CGFloat = 12
        for c in ToolCategory.allCases {
            let n = m.tools(in: c).count
            if n > 0 { h += headH + CGFloat(n) * rowH }
        }
        return h + 6
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true

        // Le flou du système, puis notre teinte par-dessus : le flou seul
        // est trop clair sur un fond de conversation sombre.
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        addSubview(glass)
        let tint = GlassTint(frame: bounds)
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)

        let scroll = NSScrollView(frame: bounds.insetBy(dx: 0, dy: 4))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: bounds.width,
                                            height: max(scroll.frame.height, ToolMenuView.contentHeight() - 8)))
        var y: CGFloat = 4
        let m = BudToolManager.shared
        for c in ToolCategory.allCases {
            let list = m.tools(in: c)
            guard !list.isEmpty else { continue }
            let head = mkLabel(c.title, NSRect(x: 18, y: y + 6, width: 200, height: 14), 9.5, .bold, alpha: 0.45)
            doc.addSubview(head)
            y += ToolMenuView.headH
            for t in list {
                let row = ToolRowView(frame: NSRect(x: 0, y: y, width: bounds.width, height: ToolMenuView.rowH), tool: t)
                row.onPick = { [weak self] t in self?.onPick?(t) }
                doc.addSubview(row)
                y += ToolMenuView.rowH
            }
        }
        scroll.documentView = doc
        addSubview(scroll)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Outils")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Sort de la pilule : du coin bas gauche, avec un ressort. Le calque
    /// d'une vue AppKit a son point d'ancrage en bas à gauche, ce qui est
    /// justement le coin de la pilule.
    func present() {
        guard let l = layer else { return }
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.88
        scale.toValue = 1
        scale.damping = 20
        scale.stiffness = 320
        scale.mass = 1
        scale.duration = scale.settlingDuration
        let lift = CABasicAnimation(keyPath: "transform.translation.y")
        lift.fromValue = -10
        lift.toValue = 0
        lift.duration = 0.22
        lift.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        l.add(scale, forKey: "pop")
        l.add(lift, forKey: "lift")
        l.add(fade, forKey: "fade")
    }

    /// Rentre dans la pilule, plus vite qu'il n'en est sorti.
    func dismiss(_ done: @escaping () -> Void) {
        guard let l = layer else { removeFromSuperview(); done(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview(); done() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.94
        let g = CAAnimationGroup()
        g.animations = [fade, shrink]
        g.duration = 0.13
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        l.add(g, forKey: "out")
        CATransaction.commit()
    }
}

/// La teinte sombre et le liseré, par-dessus le flou.
private final class GlassTint: NSView {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
        (TH.dark ? NSColor(calibratedWhite: 0.06, alpha: 0.55) : NSColor(calibratedWhite: 1, alpha: 0.45)).setFill()
        p.fill()
        NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0), NSColor(calibratedWhite: 1, alpha: TH.dark ? 0.06 : 0.2)])?
            .draw(in: p, angle: 90)
        TH.fill(0.20).setStroke()
        p.lineWidth = 0.9
        p.stroke()
    }
}

// ═══════════════════════════════════════════════════════════
//  La barre de confirmation
//
//  Elle prend la place de la rangée de suggestions, juste au-
//  dessus du champ : on ne cherche pas où répondre. Pour un
//  compte à rebours, un anneau se vide et l'action part à zéro
//  — « Maintenant » n'attend pas, « Annuler » arrête tout.
//  Pour une question, rien ne part sans le bouton.
// ═══════════════════════════════════════════════════════════

final class ToolConfirmBar: NSView {
    private let tool: BudTool
    private let question: String
    private let seconds: Int?
    private var started = Date()
    private var timer: Timer?
    private var finished = false
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    init(frame: NSRect, tool: BudTool, question: String, seconds: Int?) {
        self.tool = tool
        self.question = question
        self.seconds = seconds
        super.init(frame: frame)
        wantsLayer = true
        let W = frame.width, H = frame.height
        let go = GlassButton(frame: NSRect(x: W - 104, y: 0, width: 104, height: H),
                             title: seconds == nil ? "Confirmer" : "Maintenant",
                             icon: seconds == nil ? "checkmark" : "bolt.fill", prominent: true, compact: true)
        go.destructive = seconds == nil
        go.onClick = { [weak self] _ in self?.confirm() }
        addSubview(go)
        let no = GlassButton(frame: NSRect(x: W - 196, y: 0, width: 86, height: H),
                             title: "Annuler", icon: "xmark", compact: true)
        no.onClick = { [weak self] _ in self?.cancel() }
        addSubview(no)
        setAccessibilityLabel(question)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, timer == nil, seconds != nil else { return }
        started = Date()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var remaining: Double {
        guard let s = seconds else { return 0 }
        return max(0, Double(s) - Date().timeIntervalSince(started))
    }

    private func tick() {
        needsDisplay = true
        if remaining <= 0 { confirm() }
    }

    private func confirm() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        onConfirm?()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        onCancel?()
    }

    override func draw(_ dirty: NSRect) {
        let r = NSRect(x: 0, y: 0, width: bounds.width - 204, height: bounds.height).insetBy(dx: 0.5, dy: 0.5)
        drawLiquidGlass(capsule(r), in: r, active: false, hover: 0)
        let c = NSPoint(x: r.minX + 17, y: r.midY)
        if let s = seconds {
            // L'anneau du temps qui reste, et le chiffre au centre.
            let left = remaining
            let track = NSBezierPath(ovalIn: NSRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22))
            TH.fill(0.15).setStroke()
            track.lineWidth = 2.4
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 11, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(left / Double(s)), clockwise: true)
            arc.lineWidth = 2.4
            arc.lineCapStyle = .round
            tool.tint.setStroke()
            arc.stroke()
            drawString("\(Int(ceil(left)))", in: NSRect(x: c.x - 11, y: c.y - 7.5, width: 22, height: 15),
                       size: 10.5, weight: .bold, color: TH.text, align: .center, mono: true)
        } else {
            tool.tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)).fill()
            drawSymbol(tool.icon, center: c, size: 10, weight: .semibold, color: .white)
        }
        let text = seconds == nil ? question : "\(question) dans \(Int(ceil(remaining))) s"
        drawString(text, in: NSRect(x: r.minX + 36, y: r.midY - 8, width: r.width - 46, height: 16),
                   size: 12, weight: .semibold, color: TH.text)
    }
}
