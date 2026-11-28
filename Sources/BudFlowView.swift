import Cocoa

// ═══════════════════════════════════════════════════════════
//  La vue du Flux
//
//  En haut, le graphe : trois colonnes de nœuds sur une trame
//  de points, comme le plan de travail de n8n. Les liens sont
//  des courbes de Bézier qui partent horizontalement d'un port
//  et arrivent horizontalement sur le suivant ; quand un agent
//  travaille, ses liens s'animent — des tirets qui avancent et
//  une perle qui circule — dans sa couleur.
//
//  En bas, l'inspecteur du nœud choisi : ce qu'il fait, son
//  état, ses boutons, et les cartes de son dernier résultat,
//  compactes, à la manière des widgets iOS.
//
//  Par-dessus, quand il le faut, la fiche d'approbation.
//
//  Le graphe n'a aucune connaissance des agents : il lit le
//  registre. Un quatrième agent y apparaîtra avec ses sources
//  et ses liens sans qu'on touche à ce fichier.
// ═══════════════════════════════════════════════════════════

extension BudExpression {
    /// La teinte du halo du nœud BUDs pour chaque expression.
    var color: NSColor {
        switch self {
        case .neutral:    return NSColor(calibratedWhite: 0.70, alpha: 1)
        case .happy:      return NSColor(calibratedRed: 0.30, green: 0.82, blue: 0.55, alpha: 1)
        case .reflection: return NSColor(calibratedRed: 0.72, green: 0.52, blue: 1.00, alpha: 1)
        case .annoyed:    return NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.40, alpha: 1)
        case .dizzy:      return NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.25, alpha: 1)
        case .cool:       return NSColor(calibratedRed: 0.40, green: 0.78, blue: 1.00, alpha: 1)
        case .sad:        return NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.80, alpha: 1)
        case .working:    return NSColor(calibratedRed: 0.38, green: 0.66, blue: 1.00, alpha: 1)
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  Le graphe
// ═══════════════════════════════════════════════════════════

final class FlowCanvasView: NSView {

    enum Selection: Equatable { case agent(String), source(String), bud }

    var selection: Selection? { didSet { needsDisplay = true } }
    var onSelect: ((Selection) -> Void)?
    var onRun: ((String) -> Void)?

    /// Un BUDs à part entière, en miniature, dans le nœud de sortie.
    let sprite = BudSprite()
    var expression: BudExpression = .neutral { didSet { needsDisplay = true } }

    private var timer: Timer?
    private var t: CGFloat = 0
    private var hover: Selection?

    private var sourceRects: [(FlowSource, NSRect)] = []
    private var agentRects: [(BudAgent, NSRect)] = []
    private var budRect: NSRect = .zero

    // Les mesures du graphe. Les colonnes extrêmes sont fixes, celle des
    // agents prend le reste.
    private let pad: CGFloat = 14, gap: CGFloat = 54
    private let srcW: CGFloat = 140, budW: CGFloat = 138
    private let srcH: CGFloat = 30, srcGap: CGFloat = 8
    private let agentH: CGFloat = 64, agentGap: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// La hauteur qu'il faut pour tout montrer : la vue grandit dans son
    /// défilement quand les agents se multiplient.
    func neededHeight() -> CGFloat {
        let m = BudAgentManager.shared
        let s = CGFloat(m.sources.count) * (srcH + srcGap)
        let a = CGFloat(m.agents.count) * (agentH + agentGap)
        return max(s, a, 190) + pad * 2
    }

    private func layoutNodes() {
        let m = BudAgentManager.shared
        let b = bounds
        let agentW = b.width - pad * 2 - srcW - budW - gap * 2
        let srcX = pad, agentX = pad + srcW + gap, budX = agentX + agentW + gap

        let srcs = m.sources
        let sTotal = CGFloat(srcs.count) * srcH + CGFloat(max(0, srcs.count - 1)) * srcGap
        var y = b.midY + sTotal / 2 - srcH
        sourceRects = srcs.map { s in
            defer { y -= srcH + srcGap }
            return (s, NSRect(x: srcX, y: y, width: srcW, height: srcH))
        }

        let ags = m.agents
        let aTotal = CGFloat(ags.count) * agentH + CGFloat(max(0, ags.count - 1)) * agentGap
        y = b.midY + aTotal / 2 - agentH
        agentRects = ags.map { a in
            defer { y -= agentH + agentGap }
            return (a, NSRect(x: agentX, y: y, width: agentW, height: agentH))
        }

        let bh = min(b.height - pad * 2, 176)
        budRect = NSRect(x: budX, y: b.midY - bh / 2, width: budW, height: bh)
    }

    // ── L'horloge : seulement quand on regarde ──

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateClock() }
    override func viewDidHide() { super.viewDidHide(); updateClock() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateClock() }

    func updateClock() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        if visible && timer == nil {
            let tm = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(tm, forMode: .common)
            timer = tm
        } else if !visible {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        guard !isHiddenOrHasHiddenAncestor else { updateClock(); return }
        guard window?.isVisible == true, window?.occlusionState.contains(.visible) == true else { return }
        t += 1.0 / 30.0
        _ = sprite.step(follow: false, in: self, anchor: NSPoint(x: budRect.midX, y: budRect.midY))
        needsDisplay = true
    }

    // ── Souris ──

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func hit(_ p: NSPoint) -> Selection? {
        if let a = agentRects.first(where: { $0.1.contains(p) }) { return .agent(a.0.id) }
        if let s = sourceRects.first(where: { $0.1.contains(p) }) { return .source(s.0.id) }
        if budRect.contains(p) { return .bud }
        return nil
    }

    override func mouseMoved(with e: NSEvent) {
        let h = hit(convert(e.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
        if h != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; NSCursor.arrow.set(); needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        guard let h = hit(convert(e.locationInWindow, from: nil)) else { return }
        selection = h
        onSelect?(h)
        // Un double clic sur un agent le lance, comme « Execute node ».
        if e.clickCount == 2, case .agent(let id) = h { onRun?(id) }
    }

    // ═════════════ Le dessin ═════════════

    override func draw(_ dirty: NSRect) {
        layoutNodes()
        drawGrid()
        let m = BudAgentManager.shared

        // Les liens d'abord : les nœuds se posent dessus.
        for (a, ar) in agentRects {
            let st = m.state(a.id)
            let running = st.status == .running
            for s in a.sources {
                guard let sr = sourceRects.first(where: { $0.0.id == s.id })?.1 else { continue }
                edge(from: NSPoint(x: sr.maxX, y: sr.midY), to: NSPoint(x: ar.minX, y: ar.midY),
                     color: running ? a.tint : s.tint, active: running,
                     lit: isSelected(.agent(a.id)) || isSelected(.source(s.id)))
            }
            let outColor = st.status == .idle ? TH.fill(0.5) : st.status.color
            edge(from: NSPoint(x: ar.maxX, y: ar.midY), to: NSPoint(x: budRect.minX, y: budRect.midY),
                 color: running ? a.tint : outColor, active: running,
                 lit: isSelected(.agent(a.id)) || isSelected(.bud))
        }

        for (s, r) in sourceRects { drawSource(s, r) }
        for (a, r) in agentRects { drawAgent(a, r, m.state(a.id)) }
        drawBud(budRect)
    }

    private func isSelected(_ s: Selection) -> Bool { selection == s }

    /// La trame de points du plan de travail.
    private func drawGrid() {
        TH.fill(0.07).setFill()
        let step: CGFloat = 18
        var x = bounds.minX + 9
        while x < bounds.maxX {
            var y = bounds.minY + 9
            while y < bounds.maxY {
                NSRect(x: x, y: y, width: 1.4, height: 1.4).fill()
                y += step
            }
            x += step
        }
    }

    private func edge(from a: NSPoint, to b: NSPoint, color: NSColor, active: Bool, lit: Bool) {
        let dx = max(26, (b.x - a.x) * 0.5)
        let c1 = NSPoint(x: a.x + dx, y: a.y), c2 = NSPoint(x: b.x - dx, y: b.y)
        let p = NSBezierPath()
        p.move(to: a)
        p.curve(to: b, controlPoint1: c1, controlPoint2: c2)
        p.lineWidth = active || lit ? 2 : 1.4
        p.lineCapStyle = .round
        if active {
            // Des tirets qui avancent : le sens du flux se lit sans flèche.
            let pattern: [CGFloat] = [6, 5]
            p.setLineDash(pattern, count: 2, phase: -t * 26)
            color.withAlphaComponent(0.95).setStroke()
            p.stroke()
            // Et une perle qui circule, avec son halo.
            for k in 0..<2 {
                let u = (t * 0.7 + CGFloat(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let q = bezier(a, c1, c2, b, u)
                color.withAlphaComponent(0.25).setFill()
                NSBezierPath(ovalIn: NSRect(x: q.x - 6, y: q.y - 6, width: 12, height: 12)).fill()
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)).fill()
            }
        } else {
            color.withAlphaComponent(lit ? 0.85 : 0.38).setStroke()
            p.stroke()
        }
    }

    private func bezier(_ a: NSPoint, _ c1: NSPoint, _ c2: NSPoint, _ b: NSPoint, _ u: CGFloat) -> NSPoint {
        let v = 1 - u
        let x = v * v * v * a.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * b.x
        let y = v * v * v * a.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * b.y
        return NSPoint(x: x, y: y)
    }

    private func port(_ c: NSPoint, _ tint: NSColor, on: Bool) {
        let r: CGFloat = on ? 4.5 : 3.8
        (TH.dark ? NSColor(calibratedWhite: 0.10, alpha: 1) : NSColor.white).setFill()
        let o = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        o.fill()
        tint.withAlphaComponent(on ? 1 : 0.7).setStroke()
        o.lineWidth = 1.6
        o.stroke()
    }

    /// Le fond commun des nœuds : verre, liseré, et l'anneau de sélection.
    private func nodeShell(_ r: NSRect, radius: CGFloat, tint: NSColor, selected: Bool, hovered: Bool) {
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        if selected {
            NSGraphicsContext.current?.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = tint.withAlphaComponent(0.55)
            sh.shadowBlurRadius = 12
            sh.shadowOffset = .zero
            sh.set()
            (TH.dark ? NSColor(calibratedWhite: 0.13, alpha: 0.96) : NSColor(calibratedWhite: 0.99, alpha: 0.96)).setFill()
            p.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            (TH.dark ? NSColor(calibratedWhite: 0.11, alpha: 0.92) : NSColor(calibratedWhite: 0.98, alpha: 0.92)).setFill()
            p.fill()
        }
        TH.fill(hovered ? 0.10 : 0.04).setFill()
        p.fill()
        (selected ? tint : TH.fill(0.16)).setStroke()
        p.lineWidth = selected ? 1.6 : 0.8
        p.stroke()
    }

    private func drawSource(_ s: FlowSource, _ r: NSRect) {
        let m = BudAgentManager.shared
        let live = m.agents.contains { a in
            m.state(a.id).status == .running && a.sources.contains { $0.id == s.id }
        }
        nodeShell(r, radius: 9, tint: s.tint, selected: isSelected(.source(s.id)),
                  hovered: hover == .source(s.id))
        let disc = NSRect(x: r.minX + 6, y: r.midY - 10, width: 20, height: 20)
        s.tint.withAlphaComponent(live ? 1 : 0.85).setFill()
        NSBezierPath(roundedRect: disc, xRadius: 6, yRadius: 6).fill()
        drawSymbol(s.icon, center: NSPoint(x: disc.midX, y: disc.midY), size: 10, weight: .semibold, color: .white)
        drawString(s.title, in: NSRect(x: r.minX + 32, y: r.midY - 8, width: r.width - 40, height: 16),
                   size: 11, weight: .semibold, color: TH.text)
        port(NSPoint(x: r.maxX, y: r.midY), s.tint, on: live)
    }

    private func drawAgent(_ a: BudAgent, _ r: NSRect, _ st: AgentState) {
        let sel = isSelected(.agent(a.id))
        nodeShell(r, radius: 14, tint: a.tint, selected: sel, hovered: hover == .agent(a.id))

        // La bande de couleur à gauche, comme l'en-tête d'un nœud n8n.
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).addClip()
        a.tint.setFill()
        NSRect(x: r.minX, y: r.minY, width: 4, height: r.height).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let tile = NSRect(x: r.minX + 14, y: r.maxY - 40, width: 28, height: 28)
        NSGradient(colors: [a.tint, a.tint.blended(withFraction: 0.35, of: .black) ?? a.tint])?
            .draw(in: NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8), angle: -90)
        drawSymbol(a.icon, center: NSPoint(x: tile.midX, y: tile.midY), size: 13, weight: .semibold, color: .white)

        // Le badge d'état, en haut à droite.
        var label = st.status.label
        if st.status == .needsApproval, let n = st.result?.approval?.items.count { label += " · \(n)" }
        if st.simulated && st.status != .idle { label += " · démo" }
        let bw = textWidth(label, size: 9.5, weight: .bold) + 24
        let badge = NSRect(x: r.maxX - bw - 8, y: r.maxY - 22, width: bw, height: 16)
        st.status.color.withAlphaComponent(0.18).setFill()
        capsule(badge).fill()
        if st.status == .running {
            let c = NSPoint(x: badge.minX + 9, y: badge.midY)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 4, startAngle: t * 400, endAngle: t * 400 + 250)
            arc.lineWidth = 1.6
            st.status.color.setStroke()
            arc.stroke()
        } else {
            drawSymbol(st.status.icon, center: NSPoint(x: badge.minX + 9, y: badge.midY),
                       size: 7.5, weight: .bold, color: st.status.color)
        }
        drawString(label, in: NSRect(x: badge.minX + 16, y: badge.minY + 1.5, width: bw - 18, height: 13),
                   size: 9.5, weight: .bold, color: st.status.color)

        drawString(a.name, in: NSRect(x: tile.maxX + 9, y: r.maxY - 30, width: badge.minX - tile.maxX - 14, height: 17),
                   size: 12.5, weight: .bold, color: TH.text)
        let line = st.line.isEmpty ? a.summary : st.line
        drawString(line, in: NSRect(x: r.minX + 14, y: r.minY + 8, width: r.width - 26, height: 14),
                   size: 10.5, weight: .medium, color: TH.dim(0.6))

        // Pendant le travail, un trait qui parcourt le bas du nœud : la
        // durée est inconnue, on montre seulement que ça avance.
        if st.status == .running {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).addClip()
            let w = r.width * 0.3
            let x = r.minX - w + (t * 0.6).truncatingRemainder(dividingBy: 1) * (r.width + w)
            NSGradient(colors: [a.tint.withAlphaComponent(0), a.tint, a.tint.withAlphaComponent(0)])?
                .draw(in: NSRect(x: x, y: r.minY, width: w, height: 2.5), angle: 0)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        port(NSPoint(x: r.minX, y: r.midY), a.tint, on: st.status == .running)
        port(NSPoint(x: r.maxX, y: r.midY), a.tint, on: st.status == .running)
    }

    private func drawBud(_ r: NSRect) {
        let c = expression.color
        nodeShell(r, radius: 18, tint: c, selected: isSelected(.bud), hovered: hover == .bud)
        // Un halo de la couleur de l'expression, derrière le personnage.
        let halo = NSRect(x: r.midX - 52, y: r.maxY - 116, width: 104, height: 104)
        NSGradient(colors: [c.withAlphaComponent(0.28), c.withAlphaComponent(0)])?
            .draw(in: halo, relativeCenterPosition: .zero)
        let face = NSRect(x: r.midX - 46, y: r.maxY - 108, width: 92, height: 92)
        sprite.render(in: face, detail: true, glowColor: c)

        drawString("BUDs", in: NSRect(x: r.minX, y: r.minY + 28, width: r.width, height: 17),
                   size: 13, weight: .bold, color: TH.text, align: .center)
        let lw = textWidth(expression.label, size: 10, weight: .bold) + 18
        let pill = NSRect(x: r.midX - lw / 2, y: r.minY + 10, width: lw, height: 16)
        c.withAlphaComponent(0.2).setFill()
        capsule(pill).fill()
        drawString(expression.label, in: NSRect(x: pill.minX, y: pill.minY + 1.5, width: lw, height: 13),
                   size: 10, weight: .bold, color: c, align: .center)
        port(NSPoint(x: r.minX, y: r.midY), c, on: expression == .working)
    }
}

// ═══════════════════════════════════════════════════════════
//  Les cartes, à la manière des widgets iOS
// ═══════════════════════════════════════════════════════════

final class BudCardView: NSView {
    let card: BudCard
    private var hovering = false
    private var busy = false
    private var spin: CGFloat = 0
    private var note: (Bool, String)?
    private var timer: Timer?
    private var sky: WeatherSceneView?

    init(frame: NSRect, card: BudCard) {
        self.card = card
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        if card.style == .weather {
            // Le vrai ciel animé, en petit : le même que le panneau Météo.
            let s = WeatherSceneView(frame: bounds)
            s.condition = WeatherCondition(code: card.weatherCode, isDay: card.isDay)
            s.autoresizingMask = [.width, .height]
            addSubview(s)
            let o = WeatherCardText(frame: bounds, card: card)
            o.autoresizingMask = [.width, .height]
            addSubview(o)
            sky = s
        }
        toolTip = card.detail
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard card.style == .control else { return }
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseUp(with e: NSEvent) {
        guard card.style == .control, !busy, let act = card.action,
              bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        busy = true
        note = nil
        let tm = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.spin += 0.25; self?.needsDisplay = true
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
        BudAgentManager.shared.onExpression?(.working, 30)
        act { [weak self] ok, msg in
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.busy = false
                s.timer?.invalidate(); s.timer = nil
                s.note = (ok, msg)
                s.needsDisplay = true
                BudAgentManager.shared.onExpression?(ok ? .happy : .sad, 2.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak s] in
                    s?.note = nil; s?.needsDisplay = true
                }
            }
        }
    }

    override func draw(_ dirty: NSRect) {
        guard card.style != .weather else { return }
        let b = bounds
        let p = NSBezierPath(roundedRect: b, xRadius: 16, yRadius: 16)
        let on = busy || note?.0 == true
        if card.style == .control && on && TH.dark {
            // Comme un accessoire allumé dans Maison : la carte s'éclaire.
            NSColor(calibratedWhite: 0.95, alpha: 0.95).setFill()
        } else {
            TH.fill(hovering ? 0.12 : 0.07).setFill()
        }
        p.fill()
        TH.fill(0.10).setStroke()
        p.lineWidth = 0.8
        p.stroke()

        let ink: NSColor = (card.style == .control && on && TH.dark) ? NSColor(calibratedWhite: 0.1, alpha: 1) : TH.text
        let disc = NSRect(x: 12, y: b.maxY - 34, width: 22, height: 22)
        card.tint.setFill()
        NSBezierPath(ovalIn: disc).fill()
        let dc = NSPoint(x: disc.midX, y: disc.midY)
        if busy {
            let a = NSBezierPath()
            a.appendArc(withCenter: dc, radius: 6, startAngle: spin * 57.3, endAngle: spin * 57.3 + 260)
            a.lineWidth = 1.8
            NSColor.white.setStroke()
            a.stroke()
        } else if let n = note {
            drawSymbol(n.0 ? "checkmark" : "exclamationmark", center: dc, size: 10, weight: .bold, color: .white)
        } else {
            drawSymbol(card.icon, center: dc, size: 10.5, weight: .semibold, color: .white)
        }
        drawString(card.title, in: NSRect(x: 40, y: b.maxY - 29, width: b.width - 48, height: 13),
                   size: 9, weight: .bold, color: ink.withAlphaComponent(0.55))

        let big: CGFloat = card.style == .control ? 14 : 20
        drawString(card.value, in: NSRect(x: 12, y: b.minY + 28, width: b.width - 22, height: big + 6),
                   size: big, weight: .bold, color: ink)
        let detail = note?.1 ?? card.detail
        drawString(detail, in: NSRect(x: 12, y: b.minY + 10, width: b.width - 22, height: 14),
                   size: 10, weight: .medium,
                   color: note?.0 == false ? dangerColor : ink.withAlphaComponent(0.6))
    }
}

/// Le texte de la carte météo, posé sur son ciel animé.
private final class WeatherCardText: NSView {
    let card: BudCard
    init(frame: NSRect, card: BudCard) { self.card = card; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        let b = bounds
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
        sh.shadowBlurRadius = 4
        sh.set()
        drawString(card.title, in: NSRect(x: 12, y: b.maxY - 24, width: b.width - 40, height: 13),
                   size: 9.5, weight: .bold, color: NSColor.white.withAlphaComponent(0.9))
        drawString(card.value, in: NSRect(x: 12, y: b.minY + 26, width: b.width - 20, height: 34),
                   size: 28, weight: .light, color: .white)
        drawString(card.detail, in: NSRect(x: 12, y: b.minY + 9, width: b.width - 20, height: 14),
                   size: 10, weight: .semibold, color: NSColor.white.withAlphaComponent(0.85))
        NSGraphicsContext.current?.restoreGraphicsState()
        drawWeatherSymbol(card.icon, center: NSPoint(x: b.maxX - 22, y: b.maxY - 20), size: 15)
    }
}

/// La tuile d'icône d'un agent ou d'une source, dans l'inspecteur.
private final class FlowIconView: NSView {
    let icon: String, tint: NSColor
    init(frame: NSRect, icon: String, tint: NSColor) {
        self.icon = icon; self.tint = tint
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSGradient(colors: [tint, tint.blended(withFraction: 0.35, of: .black) ?? tint])?
            .draw(in: NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10), angle: -90)
        drawSymbol(icon, center: NSPoint(x: r.midX, y: r.midY), size: 16, weight: .semibold, color: .white)
    }
}

/// Le badge d'état, réutilisé hors du graphe.
private final class StatusPillView: NSView {
    var status: NodeStatus = .idle { didSet { needsDisplay = true } }
    var extra = ""
    override func draw(_ dirty: NSRect) {
        let label = status.label + extra
        let w = min(bounds.width, textWidth(label, size: 10, weight: .bold) + 26)
        let r = NSRect(x: 0, y: bounds.midY - 9, width: w, height: 18)
        status.color.withAlphaComponent(0.18).setFill()
        capsule(r).fill()
        drawSymbol(status.icon, center: NSPoint(x: r.minX + 10, y: r.midY), size: 8, weight: .bold, color: status.color)
        drawString(label, in: NSRect(x: r.minX + 18, y: r.minY + 2, width: w - 20, height: 14),
                   size: 10, weight: .bold, color: status.color)
    }
}

// ═══════════════════════════════════════════════════════════
//  La fiche d'approbation
//
//  Elle couvre le panneau : tant qu'elle est ouverte, rien
//  d'autre ne se clique. Chaque élément a sa case, son
//  icône, sa raison et sa taille ; le total suit les coches ;
//  le bouton d'action dit ce qu'il va faire et sur combien
//  d'éléments, et il est éteint quand rien n'est coché.
// ═══════════════════════════════════════════════════════════

final class ApprovalSheetView: NSView {
    private var items: [ApprovalItem]
    private let request: ApprovalRequest
    private let agentID: String
    private var total: NSTextField!
    private var confirm: GlassButton!
    private var boxes: [NSButton] = []
    var onClose: (() -> Void)?

    init(frame: NSRect, agentID: String, request: ApprovalRequest) {
        self.items = request.items
        self.request = request
        self.agentID = agentID
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Le voile avale les clics : rien ne passe à travers la fiche.
    override func mouseDown(with e: NSEvent) {}
    override func scrollWheel(with e: NSEvent) {}

    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(TH.dark ? 0.55 : 0.30).setFill()
        bounds.fill()
    }

    private func build() {
        let W: CGFloat = min(500, bounds.width - 40), H: CGFloat = min(430, bounds.height - 40)
        let sheet = NSView(frame: NSRect(x: (bounds.width - W) / 2, y: (bounds.height - H) / 2, width: W, height: H))
        sheet.wantsLayer = true
        sheet.layer?.cornerRadius = 20
        sheet.layer?.backgroundColor = (TH.dark ? NSColor(calibratedWhite: 0.10, alpha: 0.98)
                                                : NSColor(calibratedWhite: 0.98, alpha: 0.98)).cgColor
        sheet.layer?.borderWidth = 0.8
        sheet.layer?.borderColor = TH.fill(0.18).cgColor
        sheet.shadow = NSShadow()
        sheet.layer?.shadowOpacity = 0.4
        sheet.layer?.shadowRadius = 24
        addSubview(sheet)

        let purple = NodeStatus.needsApproval.color
        sheet.addSubview(FlowIconView(frame: NSRect(x: 20, y: H - 56, width: 36, height: 36),
                                      icon: "hand.raised.fill", tint: purple))
        sheet.addSubview(mkLabel(request.title, NSRect(x: 66, y: H - 40, width: W - 86, height: 22), 16, .bold))
        let msg = mkLabel(request.message, NSRect(x: 66, y: H - 84, width: W - 86, height: 44), 11.5, .medium, alpha: 0.65)
        msg.cell?.usesSingleLineMode = false
        msg.cell?.wraps = true
        msg.lineBreakMode = .byWordWrapping
        msg.maximumNumberOfLines = 3
        sheet.addSubview(msg)

        let all = GlassButton(frame: NSRect(x: 20, y: H - 120, width: 110, height: 26),
                              title: "Tout cocher", icon: "checkmark.circle", compact: true)
        all.onClick = { [weak self] _ in self?.setAll(true) }
        sheet.addSubview(all)
        let none = GlassButton(frame: NSRect(x: 138, y: H - 120, width: 120, height: 26),
                               title: "Tout décocher", icon: "circle", compact: true)
        none.onClick = { [weak self] _ in self?.setAll(false) }
        sheet.addSubview(none)

        // La liste.
        let listH = H - 128 - 70
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 66, width: W - 24, height: listH))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let rowH: CGFloat = 46
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: W - 38, height: max(listH, CGFloat(items.count) * rowH)))
        for (i, it) in items.enumerated() {
            let y = CGFloat(i) * rowH
            if i > 0 {
                let sep = NSView(frame: NSRect(x: 44, y: y, width: doc.frame.width - 52, height: 0.5))
                sep.wantsLayer = true
                sep.layer?.backgroundColor = TH.fill(0.10).cgColor
                doc.addSubview(sep)
            }
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.frame = NSRect(x: 10, y: y + 13, width: 22, height: 20)
            box.state = it.selected ? .on : .off
            box.tag = i
            box.setAccessibilityLabel(it.label)
            doc.addSubview(box)
            boxes.append(box)
            let iv = NSImageView(frame: NSRect(x: 36, y: y + 13, width: 20, height: 20))
            iv.image = NSImage(systemSymbolName: it.icon, accessibilityDescription: nil)
            iv.contentTintColor = it.icon.contains("shield") ? dangerColor : TH.dim(0.7)
            doc.addSubview(iv)
            let sizeText = it.bytes > 0 ? formatBytes(it.bytes) : ""
            doc.addSubview(mkLabel(it.label, NSRect(x: 64, y: y + 6, width: doc.frame.width - 160, height: 17), 12.5, .semibold))
            doc.addSubview(mkLabel(it.detail, NSRect(x: 64, y: y + 24, width: doc.frame.width - 160, height: 15), 10.5, .medium, alpha: 0.55))
            doc.addSubview(mkLabel(sizeText, NSRect(x: doc.frame.width - 92, y: y + 14, width: 84, height: 16),
                                   11.5, .semibold, alpha: 0.75, .right, mono: true))
        }
        scroll.documentView = doc
        sheet.addSubview(scroll)

        total = mkLabel("", NSRect(x: 22, y: 24, width: W - 300, height: 18), 12, .semibold, alpha: 0.75)
        sheet.addSubview(total)
        let cancel = GlassButton(frame: NSRect(x: W - 276, y: 18, width: 96, height: 30), title: "Annuler")
        cancel.onClick = { [weak self] _ in
            guard let s = self else { return }
            BudAgentManager.shared.decline(s.agentID)
            s.close()
        }
        sheet.addSubview(cancel)
        confirm = GlassButton(frame: NSRect(x: W - 172, y: 18, width: 152, height: 30),
                              title: request.confirmLabel, icon: request.destructive ? "trash.fill" : "checkmark",
                              prominent: true)
        confirm.destructive = request.destructive
        confirm.onClick = { [weak self] _ in
            guard let s = self else { return }
            BudAgentManager.shared.approve(s.agentID, items: s.items)
            s.close()
        }
        sheet.addSubview(confirm)
        refreshTotal()
        ThemeRegistry.shared.prune()
    }

    @objc private func toggled(_ b: NSButton) {
        guard b.tag >= 0, b.tag < items.count else { return }
        items[b.tag].selected = b.state == .on
        refreshTotal()
    }

    private func setAll(_ on: Bool) {
        for i in items.indices { items[i].selected = on }
        for b in boxes { b.state = on ? .on : .off }
        refreshTotal()
    }

    private func refreshTotal() {
        let chosen = items.filter { $0.selected }
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.bytes }
        total.stringValue = chosen.isEmpty
            ? "Rien de coché."
            : "\(chosen.count) élément\(chosen.count > 1 ? "s" : "") · \(formatBytes(bytes))"
        confirm.enabledFlag = !chosen.isEmpty
    }

    private func close() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.onClose?()
        })
    }
}

// ═══════════════════════════════════════════════════════════
//  Le panneau
// ═══════════════════════════════════════════════════════════

final class FlowPanelView: NSView {
    private let canvasScroll: NSScrollView
    let canvas: FlowCanvasView
    private let inspector = NSView()
    private var selection: FlowCanvasView.Selection = .bud
    private var linkField: NSTextField?
    private var sheet: ApprovalSheetView?

    override init(frame: NSRect) {
        let W = frame.width, H = frame.height
        let canvasH: CGFloat = 262
        canvasScroll = NSScrollView(frame: NSRect(x: 0, y: H - 46 - canvasH, width: W, height: canvasH))
        canvas = FlowCanvasView(frame: NSRect(x: 0, y: 0, width: W, height: canvasH))
        super.init(frame: frame)

        addSubview(mkLabel("Flux", NSRect(x: 0, y: H - 34, width: 120, height: 28), 22, .bold))
        addSubview(mkLabel("Sources  →  Agents  →  BUDs", NSRect(x: 70, y: H - 30, width: 220, height: 18),
                           12, .medium, alpha: 0.5))

        let faces = GlassButton(frame: NSRect(x: W - 300, y: H - 36, width: 90, height: 28),
                                title: "Visages", icon: "face.smiling", compact: true)
        faces.onClick = { [weak self] _ in self?.expressionTour() }
        addSubview(faces)
        let demo = GlassButton(frame: NSRect(x: W - 204, y: H - 36, width: 84, height: 28),
                               title: "Démo", icon: "play.circle", compact: true)
        demo.onClick = { _ in BudAgentManager.shared.demo() }
        addSubview(demo)
        let all = GlassButton(frame: NSRect(x: W - 114, y: H - 36, width: 114, height: 28),
                              title: "Tout lancer", icon: "play.fill", prominent: true, compact: true)
        all.onClick = { _ in
            for a in BudAgentManager.shared.agents { BudAgentManager.shared.run(a.id) }
        }
        addSubview(all)

        // Le plan de travail, dans son cadre de verre.
        _ = mkCard(self, canvasScroll.frame, radius: Radius.l, alpha: 0.04)
        canvasScroll.drawsBackground = false
        canvasScroll.hasVerticalScroller = true
        canvasScroll.autohidesScrollers = true
        canvasScroll.documentView = canvas
        addSubview(canvasScroll)

        inspector.frame = NSRect(x: 0, y: 0, width: W, height: canvasScroll.frame.minY - 10)
        _ = mkCard(self, inspector.frame, radius: Radius.l, alpha: 0.06)
        addSubview(inspector)

        canvas.onSelect = { [weak self] s in
            self?.selection = s
            self?.rebuildInspector()
            if case .agent(let id) = s { BudAgentManager.shared.preview(id) }
        }
        canvas.onRun = { id in BudAgentManager.shared.run(id) }
        canvas.selection = .bud

        BudAgentManager.shared.observe { [weak self] id in
            guard let s = self else { return }
            s.resizeCanvas()
            s.canvas.needsDisplay = true
            if s.selection == .agent(id) { s.rebuildInspector() }
        }
        resizeCanvas()
        rebuildInspector()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        resizeCanvas()
        canvas.updateClock()
        rebuildInspector()
    }

    /// Appelée par l'application à chaque changement d'expression, pour
    /// que le BUDs du graphe suive celui du bureau.
    func show(_ e: BudExpression, hold: TimeInterval) {
        canvas.expression = e
        canvas.sprite.flash(e.mood, for: hold)
        // Revenir à « attentif » quand l'expression s'éteint.
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let s = self, s.canvas.expression == e, e != .working || !BudAgentManager.shared.anyRunning
            else { return }
            s.canvas.expression = .neutral
        }
        if selection == .bud { rebuildInspector() }
    }

    private func resizeCanvas() {
        let h = max(canvasScroll.contentSize.height, canvas.neededHeight())
        if abs(canvas.frame.height - h) > 0.5 {
            canvas.frame = NSRect(x: 0, y: 0, width: canvasScroll.contentSize.width, height: h)
        }
    }

    /// Les huit expressions à la suite, une seconde et demie chacune.
    private func expressionTour() {
        for (i, e) in BudFlowSamples.expressionTour.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.5) {
                BudAgentManager.shared.onExpression?(e, 1.6)
                BudAgentManager.shared.onStatus?("Expression : \(e.label)")
            }
        }
    }

    // ═════════════ L'inspecteur ═════════════

    private func rebuildInspector() {
        inspector.subviews.forEach { $0.removeFromSuperview() }
        linkField = nil
        switch selection {
        case .agent(let id):
            if let a = BudAgentManager.shared.agent(id) { inspectAgent(a) }
        case .source(let id):
            if let s = BudAgentManager.shared.sources.first(where: { $0.id == id }) { inspectSource(s) }
        case .bud:
            inspectBud()
        }
        ThemeRegistry.shared.prune()
    }

    private func header(icon: String, tint: NSColor, title: String, subtitle: String, rightInset: CGFloat) {
        let W = inspector.bounds.width, H = inspector.bounds.height
        inspector.addSubview(FlowIconView(frame: NSRect(x: 16, y: H - 54, width: 38, height: 38), icon: icon, tint: tint))
        inspector.addSubview(mkLabel(title, NSRect(x: 64, y: H - 35, width: W - 64 - rightInset, height: 20), 15, .bold))
        inspector.addSubview(mkLabel(subtitle, NSRect(x: 64, y: H - 54, width: W - 64 - rightInset, height: 16),
                                     11, .medium, alpha: 0.6))
    }

    private func inspectAgent(_ a: BudAgent) {
        let m = BudAgentManager.shared
        let st = m.state(a.id)
        let W = inspector.bounds.width, H = inspector.bounds.height
        header(icon: a.icon, tint: a.tint, title: a.name, subtitle: a.summary, rightInset: 216)

        let running = st.status == .running
        let sim = GlassButton(frame: NSRect(x: W - 206, y: H - 50, width: 92, height: 28),
                              title: "Simuler", icon: "wand.and.stars", compact: true)
        sim.enabledFlag = !running
        sim.onClick = { _ in m.run(a.id, simulated: true) }
        inspector.addSubview(sim)
        let go = GlassButton(frame: NSRect(x: W - 108, y: H - 50, width: 94, height: 28),
                             title: running ? "Arrêter" : "Exécuter",
                             icon: running ? "stop.fill" : "play.fill", prominent: !running, compact: true)
        go.onClick = { _ in
            if running { m.cancel(a.id) } else { m.run(a.id) }
        }
        inspector.addSubview(go)

        // L'état, et quand.
        let pill = StatusPillView(frame: NSRect(x: 16, y: H - 86, width: 130, height: 22))
        pill.status = st.status
        if st.simulated && st.status != .idle { pill.extra = " · démo" }
        inspector.addSubview(pill)
        var line = st.line.isEmpty ? "Jamais exécuté. Double-cliquez sur le nœud, ou « Exécuter »." : st.line
        if let d = st.lastRun {
            let f = RelativeDateTimeFormatter()
            f.locale = Locale(identifier: "fr_FR")
            line += "  ·  " + f.localizedString(for: d, relativeTo: Date())
        }
        let lw = textWidth(st.status.label + (pill.extra), size: 10, weight: .bold) + 34
        inspector.addSubview(mkLabel(line, NSRect(x: 16 + lw, y: H - 85, width: W - 32 - lw, height: 17), 11.5, .medium, alpha: 0.75))

        // La rangée d'action propre à l'agent.
        let rowY = H - 122
        if let req = st.result?.approval, st.status == .needsApproval {
            let n = req.items.count
            let review = GlassButton(frame: NSRect(x: 16, y: rowY, width: 270, height: 28),
                                     title: "Examiner et approuver · \(n) élément\(n > 1 ? "s" : "")",
                                     icon: "hand.raised.fill", prominent: true, compact: true)
            review.accentTint = NodeStatus.needsApproval.color
            review.onClick = { [weak self] _ in self?.openApproval(a.id, req) }
            inspector.addSubview(review)
            let skip = GlassButton(frame: NSRect(x: 294, y: rowY, width: 96, height: 28),
                                   title: "Ignorer", icon: "xmark", compact: true)
            skip.onClick = { _ in m.decline(a.id) }
            inspector.addSubview(skip)
        } else if let sec = a as? SecurityAgent {
            let f = NSTextField(frame: NSRect(x: 16, y: rowY + 2, width: W - 290, height: 24))
            f.placeholderString = "Coller un lien ou un domaine à vérifier…"
            f.bezelStyle = .roundedBezel
            f.font = NSFont.systemFont(ofSize: 12)
            f.target = self
            f.action = #selector(analyzeLink)
            inspector.addSubview(f)
            linkField = f
            let check = GlassButton(frame: NSRect(x: W - 266, y: rowY, width: 110, height: 28),
                                    title: "Analyser", icon: "magnifyingglass", compact: true)
            check.onClick = { [weak self] _ in self?.analyzeLink() }
            inspector.addSubview(check)
            let key = GlassButton(frame: NSRect(x: W - 148, y: rowY, width: 134, height: 28),
                                  title: SafeBrowsing.key == nil ? "Safe Browsing…" : "Safe Browsing ✓",
                                  icon: "key.fill", compact: true)
            key.onClick = { [weak self] _ in self?.askSafeBrowsingKey() }
            inspector.addSubview(key)
            _ = sec
        } else {
            let srcs = a.sources.map { $0.title }.joined(separator: " · ")
            inspector.addSubview(mkLabel("Lit : " + srcs, NSRect(x: 16, y: rowY + 6, width: W - 32, height: 16),
                                         11, .medium, alpha: 0.5))
        }

        addCards(st.result?.cards ?? [], placeholder: running ? "Au travail…" : "Les cartes du résultat s'afficheront ici.")
    }

    private func inspectSource(_ s: FlowSource) {
        let W = inspector.bounds.width, H = inspector.bounds.height
        let users = BudAgentManager.shared.agents.filter { a in a.sources.contains { $0.id == s.id } }
        header(icon: s.icon, tint: s.tint, title: s.title,
               subtitle: "Source · lue par " + users.map { $0.name }.joined(separator: ", "), rightInset: 20)
        let note = mkLabel(s.note, NSRect(x: 16, y: H - 100, width: W - 32, height: 34), 12, .medium, alpha: 0.75)
        note.cell?.usesSingleLineMode = false
        note.cell?.wraps = true
        note.maximumNumberOfLines = 2
        inspector.addSubview(note)
        var x: CGFloat = 16
        for a in users {
            let b = GlassButton(frame: NSRect(x: x, y: H - 140, width: 200, height: 28),
                                title: "Ouvrir « \(a.name) »", icon: a.icon, compact: true)
            b.frame.size.width = b.idealWidth()
            b.onClick = { [weak self] _ in self?.select(.agent(a.id)) }
            inspector.addSubview(b)
            x += b.frame.width + 8
        }
    }

    private func inspectBud() {
        let W = inspector.bounds.width, H = inspector.bounds.height
        let e = canvas.expression
        header(icon: "face.smiling", tint: e.color, title: "BUDs · \(e.label)",
               subtitle: "La sortie de tous les agents : l'expression dit le résultat, les cartes le détaillent.",
               rightInset: 20)
        inspector.addSubview(mkLabel("APERÇU DES EXPRESSIONS", NSRect(x: 16, y: H - 84, width: 300, height: 14),
                                     10, .bold, alpha: 0.5))
        var x: CGFloat = 16, y = H - 120
        for ex in BudExpression.allCases {
            let b = GlassButton(frame: NSRect(x: x, y: y, width: 100, height: 28), title: ex.label, compact: true)
            b.frame.size.width = b.idealWidth()
            if x + b.frame.width > W - 16 { x = 16; y -= 36; b.frame.origin = NSPoint(x: x, y: y) }
            b.accentTint = ex.color
            b.selected = ex == e
            b.onClick = { _ in BudAgentManager.shared.onExpression?(ex, 3) }
            inspector.addSubview(b)
            x += b.frame.width + 8
        }
        // Le dernier mot de chaque agent, en cartes.
        let cards = BudAgentManager.shared.agents.map { a -> BudCard in
            let st = BudAgentManager.shared.state(a.id)
            return BudCard(icon: a.icon, title: a.name.uppercased(), value: st.status.label,
                           detail: st.line.isEmpty ? "Pas encore lancé" : st.line, tint: a.tint)
        }
        addCards(cards, placeholder: "")
    }

    private func addCards(_ cards: [BudCard], placeholder: String) {
        let W = inspector.bounds.width
        let cw: CGFloat = 150, ch: CGFloat = 96, gapX: CGFloat = 10
        guard !cards.isEmpty else {
            if !placeholder.isEmpty {
                inspector.addSubview(mkLabel(placeholder, NSRect(x: 16, y: 52, width: W - 32, height: 18),
                                             12, .medium, alpha: 0.4, .center))
            }
            return
        }
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 10, width: W - 24, height: ch + 4))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let docW = max(W - 24, CGFloat(cards.count) * (cw + gapX) + 4)
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: docW, height: ch + 4))
        for (i, c) in cards.enumerated() {
            doc.addSubview(BudCardView(frame: NSRect(x: 4 + CGFloat(i) * (cw + gapX), y: 2, width: cw, height: ch), card: c))
        }
        scroll.documentView = doc
        inspector.addSubview(scroll)
    }

    private func select(_ s: FlowCanvasView.Selection) {
        selection = s
        canvas.selection = s
        rebuildInspector()
    }

    // ═════════════ Actions ═════════════

    @objc private func analyzeLink() {
        guard let f = linkField, let sec = BudAgentManager.shared.agent("security") as? SecurityAgent else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sec.input = text
        BudAgentManager.shared.run(sec.id)
    }

    /// La clé Safe Browsing se tape ici et file au trousseau. Elle n'est
    /// jamais affichée en clair, jamais écrite sur disque.
    private func askSafeBrowsingKey() {
        let alert = NSAlert()
        alert.messageText = "Clé Google Safe Browsing (facultative)"
        alert.informativeText = "Avec une clé, les adresses des liens — et seulement elles — sont aussi vérifiées auprès de Google. Sans clé, l'analyse reste entièrement locale. Laissez vide pour retirer la clé."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = SafeBrowsing.key == nil ? "Clé d'API" : "•••••••• (enregistrée)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            let k = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if k.isEmpty { BudKeychain.delete(SafeBrowsing.account) }
            else { BudKeychain.set(k, account: SafeBrowsing.account) }
            self?.rebuildInspector()
        }
    }

    private func openApproval(_ id: String, _ req: ApprovalRequest) {
        guard sheet == nil else { return }
        let s = ApprovalSheetView(frame: bounds, agentID: id, request: req)
        s.alphaValue = 0
        s.onClose = { [weak self] in self?.sheet = nil; self?.rebuildInspector() }
        addSubview(s)
        sheet = s
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            s.animator().alphaValue = 1
        }
        BudAgentManager.shared.onExpression?(.reflection, 6)
    }
}
