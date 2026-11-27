import Cocoa
import QuartzCore

// ═══════════════════════════════════════════════════════════
//  Registre de thème
// ═══════════════════════════════════════════════════════════

final class ThemeRegistry {
    static let shared = ThemeRegistry()
    private var labels: [(NSTextField, CGFloat)] = []
    private var boxes: [(NSView, CGFloat)] = []
    private var icons: [(NSImageView, CGFloat)] = []

    func register(_ l: NSTextField, alpha: CGFloat) { labels.append((l, alpha)) }
    func register(box: NSView, alpha: CGFloat = 0.06) { boxes.append((box, alpha)) }
    func register(icon: NSImageView, alpha: CGFloat) { icons.append((icon, alpha)) }

    func prune() {
        labels.removeAll { $0.0.superview == nil }
        boxes.removeAll { $0.0.superview == nil }
        icons.removeAll { $0.0.superview == nil }
    }

    func apply() {
        prune()
        for (l, a) in labels { l.textColor = TH.dim(a) }
        for (b, a) in boxes { b.layer?.backgroundColor = TH.fill(a).cgColor }
        for (iv, a) in icons { iv.contentTintColor = TH.dim(a) }
    }
}

// ═══════════════════════════════════════════════════════════
//  Helpers de construction
// ═══════════════════════════════════════════════════════════

/// Applique l'accent choisi en tenant compte du thème (le blanc devient graphite en clair).
func resolvedAccent(_ index: Int, dark: Bool) -> NSColor {
    let c = accentPalette[max(0, min(accentPalette.count - 1, index))].1
    if index == whiteAccentIndex && !dark { return NSColor(calibratedWhite: 0.20, alpha: 1) }
    return c
}

func mkLabel(_ s: String, _ f: NSRect, _ size: CGFloat, _ w: NSFont.Weight = .regular,
             alpha: CGFloat = 1, _ a: NSTextAlignment = .left, mono: Bool = false) -> NSTextField {
    let t = NSTextField(frame: f)
    t.stringValue = s
    t.isBezeled = false
    t.drawsBackground = false
    t.isEditable = false
    t.isSelectable = false
    t.font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: w)
                  : NSFont.systemFont(ofSize: size, weight: w)
    t.textColor = TH.dim(alpha)
    t.alignment = a
    t.lineBreakMode = .byTruncatingTail
    t.cell?.usesSingleLineMode = true
    ThemeRegistry.shared.register(t, alpha: alpha)
    return t
}

/// Étiquette dimensionnée sur mesure : jamais tronquée.
func mkFitLabel(_ s: String, x: CGFloat, y: CGFloat, _ size: CGFloat, _ w: NSFont.Weight = .regular,
                alpha: CGFloat = 1, mono: Bool = false) -> NSTextField {
    // Un NSTextField ajoute ~4 pt de marge interne de chaque côté : sans cette
    // réserve, le libellé se termine par une ellipse alors qu'il tiendrait.
    let width = textWidth(s, size: size, weight: w, mono: mono) + 10
    let l = mkLabel(s, NSRect(x: x, y: y, width: width, height: ceil(size * 1.6)), size, w,
                    alpha: alpha, .left, mono: mono)
    l.lineBreakMode = .byClipping
    return l
}

@discardableResult
/// Une carte de verre. `alpha` est conservé dans la signature pour les
/// quarante appels existants, mais il ne sert plus de couleur : il est
/// traduit en niveau d'élévation, afin que l'application entière passe
/// au même matériau sans toucher à chaque appel.
func mkCard(_ parent: NSView, _ f: NSRect, radius: CGFloat = Radius.m,
            alpha: CGFloat = 0.06) -> NSView {
    let level = alpha <= 0.05 ? 0 : (alpha <= 0.08 ? 1 : 2)
    let v = GlassCard(frame: f, radius: radius, level: level)
    parent.addSubview(v)
    return v
}

func mkIcon(_ parent: NSView, _ name: String, x: CGFloat, y: CGFloat,
            size: CGFloat = 13, weight: NSFont.Weight = .semibold, alpha: CGFloat = 0.55) -> NSImageView {
    let iv = NSImageView(frame: NSRect(x: x, y: y, width: size + 4, height: size + 4))
    iv.image = symbol(name, size, weight)
    iv.contentTintColor = TH.dim(alpha)
    iv.imageScaling = .scaleProportionallyUpOrDown
    parent.addSubview(iv)
    ThemeRegistry.shared.register(icon: iv, alpha: alpha)
    return iv
}

@discardableResult
func mkStatRow(_ parent: NSView, _ y: CGFloat, _ x: CGFloat, _ w: CGFloat,
               _ icon: String, _ key: String) -> NSTextField {
    mkCard(parent, NSRect(x: x, y: y, width: w, height: 32), radius: 10)
    mkIcon(parent, icon, x: x + 12, y: y + 8)
    let keyW = textWidth(key, size: 11.5, weight: .medium) + 4
    parent.addSubview(mkLabel(key, NSRect(x: x + 36, y: y + 8, width: keyW, height: 16), 11.5, .medium, alpha: 0.6))
    let valX = x + 40 + keyW
    let v = mkLabel("—", NSRect(x: valX, y: y + 8, width: max(60, x + w - 14 - valX), height: 16),
                    12, .semibold, alpha: 1, .right, mono: true)
    parent.addSubview(v)
    return v
}

func mkSection(_ parent: NSView, _ y: CGFloat, _ w: CGFloat, _ t: String) {
    parent.addSubview(mkLabel(t.uppercased(), NSRect(x: 2, y: y, width: w, height: 14),
                              Typo.micro.size, Typo.micro.weight, alpha: Typo.Ink.ghost))
}

/// Tuile de statistique : grande valeur, légende en dessous.
final class StatTile: NSView {
    private let valueLabel: NSTextField
    private let captionLabel: NSTextField
    private let hintLabel: NSTextField

    init(frame: NSRect, caption: String, hint: String = "") {
        valueLabel = mkLabel("—", NSRect(x: 14, y: frame.height - 52, width: frame.width - 28, height: 34),
                             26, .bold, alpha: 1, .left, mono: true)
        captionLabel = mkLabel(caption, NSRect(x: 14, y: frame.height - 24, width: frame.width - 28, height: 16),
                               10.5, .medium, alpha: 0.5)
        hintLabel = mkLabel(hint, NSRect(x: 14, y: 10, width: frame.width - 28, height: 14), 10, .regular, alpha: 0.35)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = TH.fill(0.06).cgColor
        ThemeRegistry.shared.register(box: self, alpha: 0.06)
        [captionLabel, valueLabel, hintLabel].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ value: String, hint: String? = nil) {
        valueLabel.stringValue = value
        // Réduit la taille jusqu'à ce que la valeur tienne : aucune troncature.
        let avail = bounds.width - 28
        var size: CGFloat = 26
        while size > 13 && textWidth(value, size: size, weight: .bold, mono: true) > avail {
            size -= 1
        }
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        if let h = hint { hintLabel.stringValue = h }
    }
}

/// Bandeau d'en-tête d'un panneau : titre, sous-titre, dégradé d'accent.
final class HeroHeader: NSView {
    private var titleText: String
    private var subtitleText: String
    var trailing: String = ""
    /// Teinte de la capsule de droite. Une alerte affichée dans le même
    /// gris que le reste n'alerte personne.
    var trailingTint: NSColor?

    init(frame: NSRect, title: String, subtitle: String) {
        titleText = title
        subtitleText = subtitle
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title: String? = nil, subtitle: String? = nil, trailing: String? = nil) {
        if let t = title { titleText = t }
        if let s = subtitle { subtitleText = s }
        if let r = trailing { self.trailing = r }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let path = NSBezierPath(roundedRect: r, xRadius: Radius.xl, yRadius: Radius.xl)
        let a = TH.accent
        let c1 = a.withAlphaComponent(TH.dark ? 0.26 : 0.20)
        let c2 = a.withAlphaComponent(TH.dark ? 0.05 : 0.04)
        if let g = NSGradient(starting: c1, ending: c2) { g.draw(in: path, angle: -25) }
        TH.fill(0.05).setFill()
        path.fill()
        TH.fill(0.08).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Poussière lumineuse discrète
        for i in 0..<14 {
            let fx = CGFloat((i * 71) % 97) / 97.0
            let fy = CGFloat((i * 37) % 53) / 53.0
            let d: CGFloat = (i % 3 == 0) ? 2.4 : 1.5
            TH.fill(0.10 + 0.05 * CGFloat(i % 3)).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + 20 + fx * (r.width - 60),
                                        y: r.minY + 12 + fy * (r.height - 28),
                                        width: d, height: d)).fill()
        }

        drawString(titleText, in: NSRect(x: 22, y: r.height - 50, width: r.width - 160, height: 30),
                   size: Typo.display.size, weight: Typo.display.weight, color: TH.text)
        drawString(subtitleText, in: NSRect(x: 22, y: r.height - 74, width: r.width - 160, height: 20),
                   size: Typo.body.size, weight: Typo.body.weight, color: TH.dim(Typo.Ink.muted))
        if !trailing.isEmpty {
            // La capsule ne déborde jamais sur le titre : au besoin elle
            // rétrécit, et c'est le texte qui est coupé, pas la mise en page.
            let want = textWidth(trailing, size: 11.5, weight: .semibold) + 26
            let w = min(want, max(60, r.width - 200))
            let cap = NSRect(x: r.maxX - w - 18, y: r.height - 44, width: w, height: 26)
            let tint = trailingTint
            (tint?.withAlphaComponent(0.22) ?? TH.fill(0.12)).setFill()
            capsule(cap).fill()
            if let t = tint {
                t.withAlphaComponent(0.70).setStroke()
                let s = capsule(cap); s.lineWidth = 1; s.stroke()
            }
            drawString(trailing, in: NSRect(x: cap.minX, y: cap.midY - 8, width: cap.width, height: 16),
                       size: 11.5, weight: .semibold, color: tint ?? TH.text, align: .center)
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  Matière de verre
//
//  Deux primitives partagées par les boutons et les cartes,
//  pour que tout l'habillage réagisse à la lumière de la même
//  façon. Les écrire une fois plutôt qu'à chaque endroit est
//  ce qui rend l'ensemble harmonieux : vingt reflets réglés
//  séparément finissent par diverger.
// ═══════════════════════════════════════════════════════════

/// Le reflet spéculaire : une bande claire sur la moitié haute, bornée
/// à la forme, qui s'éteint vers le milieu.
func specular(_ shape: NSBezierPath, _ r: NSRect, strength: CGFloat) {
    guard strength > 0.01, r.height > 6 else { return }
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    let top = NSColor.white.withAlphaComponent(strength * (TH.dark ? 0.22 : 0.42))
    let fade = NSColor.white.withAlphaComponent(0)
    if let g = NSGradient(starting: top, ending: fade) {
        g.draw(in: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90)
    }
    NSGraphicsContext.current?.restoreGraphicsState()
}

/// Le liseré : vif en haut, éteint en bas. C'est ce dégradé qui donne
/// l'épaisseur ; un contour uniforme reste un trait.
func rim(_ shape: NSBezierPath, _ r: NSRect, color: NSColor, strength: CGFloat) {
    guard strength > 0.01, r.height > 4 else { return }
    // Un dégradé le long d'un contour n'existe pas en AppKit : on ne peut
    // pas clipper sur un trait. On trace donc le même contour par bandes
    // horizontales, d'opacité décroissante. Quatre suffisent — à cette
    // échelle, les marches ne se voient pas.
    let a = strength * (TH.dark ? 1.0 : 0.55)
    let bands = 4
    for i in 0..<bands {
        let f = CGFloat(i) / CGFloat(bands - 1)         // 0 en haut, 1 en bas
        let h = r.height / CGFloat(bands)
        let band = NSRect(x: r.minX - 2, y: r.maxY - h * CGFloat(i + 1),
                          width: r.width + 4, height: h)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: band).setClip()
        color.withAlphaComponent(a * (1 - f) * (1 - f)).setStroke()
        shape.lineWidth = 1.4
        shape.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

// ═══════════════════════════════════════════════════════════
//  Boutons
// ═══════════════════════════════════════════════════════════

/// Le capteur de raccourci : un clic, puis la combinaison qu'on tape.
///
/// Le moniteur est **local** et non global : il ne doit intercepter les
/// touches que pendant qu'on enregistre, et seulement dans la fenêtre de
/// BUD. Un moniteur global avalerait les frappes de toutes les
/// applications tant que l'enregistrement serait ouvert.
final class KeyRecorder: NSView {
    var combo: String { didSet { needsDisplay = true } }
    var onChange: ((String) -> Void)?
    /// Phrase à afficher quand une combinaison est refusée.
    var onRefuse: ((String) -> Void)?
    /// Rend le nom de l'action qui utilise déjà ce raccourci, ou `nil`.
    /// Deux actions sur la même combinaison, et l'une des deux ne part
    /// jamais : laquelle dépendrait de l'ordre du tableau, ce qui est
    /// indéfendable. On refuse donc le doublon à la saisie.
    var conflict: ((String) -> String?)?

    private var recording = false { didSet { needsDisplay = true } }
    private var monitor: Any?
    private var hover = false
    private var track: NSTrackingArea?

    init(frame: NSRect, combo: String) {
        self.combo = combo
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { stopRecording() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = track { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        track = a
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let s = self else { return ev }
            // Échap annule, sans rien changer.
            if ev.keyCode == 53 { s.stopRecording(); return nil }
            guard let ch = ev.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty,
                  let first = ch.first, first.isLetter || first.isNumber else {
                s.onRefuse?("Choisissez une lettre ou un chiffre.")
                return nil
            }
            let candidate = Shortcuts.encode(ev.modifierFlags, String(first))
            guard Shortcuts.isUsable(candidate) else {
                s.onRefuse?("Il faut au moins ⌘, ⌥ ou ⌃ — sans quoi le raccourci "
                    + "intercepterait votre frappe dans toutes les applications.")
                return nil
            }
            if let taken = s.conflict?(candidate) {
                s.onRefuse?("\(Shortcuts.display(candidate)) sert déjà à « \(taken) ». "
                    + "Changez d'abord celui-là, ou choisissez une autre touche.")
                return nil
            }
            s.combo = candidate
            s.onChange?(candidate)
            s.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = capsule(r)
        TH.fill(recording ? 0.18 : (hover ? 0.12 : 0.07)).setFill()
        p.fill()
        (recording ? TH.accent.withAlphaComponent(0.8) : TH.fill(0.12)).setStroke()
        p.lineWidth = recording ? 1.5 : 1
        p.stroke()
        drawString(recording ? "tapez…" : Shortcuts.display(combo),
                   in: NSRect(x: r.minX, y: r.midY - 7, width: r.width, height: 15),
                   size: 11.5, weight: .semibold,
                   color: recording ? TH.accent : TH.text, align: .center, mono: !recording)
    }
}

final class GlassButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    var iconName: String? { didSet { needsDisplay = true } }
    var prominent = false { didSet { needsDisplay = true } }
    var destructive = false { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var enabledFlag = true { didSet { needsDisplay = true } }
    var alignLeft = false
    var compact = false
    var idx = 0
    /// Teinte propre au bouton, pour colorer un groupe d'outils. `nil`
    /// laisse l'accent général choisi par l'utilisateur.
    var accentTint: NSColor? { didSet { needsDisplay = true } }
    var onClick: ((GlassButton) -> Void)?

    private var hoverT: CGFloat = 0
    private var pressT: CGFloat = 0
    private var hovering = false
    private var pressing = false
    private var anim: Timer?

    init(frame: NSRect, title: String, icon: String? = nil,
         prominent: Bool = false, alignLeft: Bool = false, compact: Bool = false) {
        self.title = title
        self.iconName = icon
        self.prominent = prominent
        self.alignLeft = alignLeft
        self.compact = compact
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Largeur minimale pour afficher le libellé en entier.
    func idealWidth() -> CGFloat {
        let t = textWidth(title, size: compact ? 11.5 : 12, weight: .semibold)
        return t + (iconName == nil ? 32 : 58)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func startAnim() {
        guard anim == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tm in
            guard let s = self else { tm.invalidate(); return }
            let hT: CGFloat = s.hovering ? 1 : 0
            let pT: CGFloat = s.pressing ? 1 : 0
            s.hoverT += (hT - s.hoverT) * 0.25
            s.pressT += (pT - s.pressT) * 0.35
            if abs(hT - s.hoverT) < 0.01 && abs(pT - s.pressT) < 0.01 {
                s.hoverT = hT; s.pressT = pT
                tm.invalidate(); s.anim = nil
            }
            s.needsDisplay = true
        }
        anim = t
        RunLoop.main.add(t, forMode: .common)
    }

    override func mouseEntered(with e: NSEvent) { hovering = true; startAnim() }
    override func mouseExited(with e: NSEvent) { hovering = false; pressing = false; startAnim() }
    override func mouseDown(with e: NSEvent) {
        guard enabledFlag else { return }
        pressing = true
        startAnim()
    }
    override func mouseUp(with e: NSEvent) {
        let was = pressing
        pressing = false
        startAnim()
        guard enabledFlag, was, bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        onClick?(self)
    }

    override func draw(_ dirty: NSRect) {
        let lift = pressT
        let r = bounds.insetBy(dx: 0.5 + lift, dy: 0.5 + lift)
        let path = capsule(r)
        // La teinte propre du bouton l'emporte sur l'accent général, sauf
        // pour un bouton destructeur, qui reste rouge quoi qu'on demande.
        let tint = destructive ? dangerColor : (accentTint ?? TH.accent)

        // ── Matière ──
        //
        //  Le verre d'iOS 26 n'existe pas en AppKit sur macOS 12 : il n'y a
        //  pas d'API à appeler, et BUD vise Monterey. On en reprend donc
        //  les trois principes à la main, sans prétendre à autre chose —
        //  une matière épaisse plutôt qu'un aplat, un reflet spéculaire en
        //  haut, un liseré qui s'éclaire sur le bord supérieur.
        //
        //  C'est le liseré qui fait le plus : un contour d'intensité
        //  constante lit comme un trait dessiné, un contour qui s'éteint
        //  vers le bas lit comme une épaisseur.
        if !enabledFlag {
            Surface.fill(0).setFill()
            path.fill()
        } else if prominent || selected {
            let top = tint.blended(withFraction: 0.22, of: NSColor.white) ?? tint
            let bottom = tint.blended(withFraction: 0.16, of: NSColor.black) ?? tint
            if let g = NSGradient(starting: top, ending: bottom) { g.draw(in: path, angle: -90) }
            else { tint.setFill(); path.fill() }
            if hoverT > 0.01 {
                NSColor.white.withAlphaComponent(0.10 * hoverT).setFill()
                path.fill()
            }
            specular(path, r, strength: 0.30 + 0.12 * hoverT)
            rim(path, r, color: NSColor.white, strength: 0.42)
        } else {
            // Un bouton au repos est une surface de niveau 1 qui monte au
            // niveau 2 sous le curseur : la même matière que les cartes,
            // le même reflet, le même liseré. C'est ce partage qui évite
            // qu'un bouton du Courrier ait l'air d'un autre matériau
            // qu'une carte du Chat.
            let hovering = hoverT > 0.5 || pressT > 0.01
            drawGlass(in: bounds.insetBy(dx: lift, dy: lift),
                      radius: Radius.pill(r.height), level: hovering ? 2 : 1,
                      hover: hoverT, tint: accentTint?.withAlphaComponent(0.5))
            // Pas de contour supplémentaire ici : `drawGlass` ferme déjà
            // la forme. En ajouter un doublerait le trait et épaissirait
            // le bord d'un bouton sur deux.
        }

        let fg: NSColor = !enabledFlag ? TH.dim(0.25)
                        : ((prominent || selected) ? TH.onAccent : (destructive ? dangerColor : TH.text))
        // L'icône peut porter la teinte du groupe pendant que le titre
        // reste lisible : colorer les deux rendrait le texte pâle.
        let ig: NSColor = !enabledFlag ? TH.dim(0.25)
                        : ((prominent || selected) ? TH.onAccent
                           : (destructive ? dangerColor : (accentTint ?? TH.text)))
        let fontSize: CGFloat = compact ? 11.5 : 12
        let tw = textWidth(title, size: fontSize, weight: .semibold)

        if title.isEmpty {
            if let icon = iconName {
                drawSymbol(icon, center: NSPoint(x: r.midX, y: r.midY), size: compact ? 12 : 13,
                           weight: .semibold, color: ig)
            }
            return
        }

        if alignLeft {
            var x = r.minX + 14
            if let icon = iconName {
                drawSymbol(icon, center: NSPoint(x: x + 7, y: r.midY), size: compact ? 12 : 13,
                           weight: .semibold, color: ig)
                x += 26
            }
            drawString(title, in: NSRect(x: x, y: r.midY - 8, width: max(10, r.maxX - 12 - x), height: 16),
                       size: fontSize, weight: .semibold, color: fg)
        } else {
            let iconW: CGFloat = iconName == nil ? 0 : 20
            let block = min(r.width - 16, tw + iconW)
            var x = r.midX - block / 2
            if let icon = iconName {
                drawSymbol(icon, center: NSPoint(x: x + 7, y: r.midY), size: compact ? 12 : 13,
                           weight: .semibold, color: ig)
                x += iconW
            }
            drawString(title, in: NSRect(x: x, y: r.midY - 8, width: max(10, r.maxX - 8 - x), height: 16),
                       size: fontSize, weight: .semibold, color: fg)
        }
    }
}

/// Rangée de la barre latérale : icône + libellé + pastille de notification.
final class SidebarItem: NSView {
    let iconName: String
    let title: String
    var selected = false { didSet { needsDisplay = true } }
    var badgeCount = 0 { didSet { needsDisplay = true } }
    var idx = 0
    var onClick: ((Int) -> Void)?
    private var hover = false

    init(frame: NSRect, icon: String, title: String, index: Int) {
        self.iconName = icon
        self.title = title
        self.idx = index
        super.init(frame: frame)
        wantsLayer = true
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
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?(idx) }
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 1)
        if hover && !selected {
            TH.fill(0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        }
        let fg = selected ? TH.text : TH.dim(hover ? 0.8 : 0.6)
        drawSymbol(iconName, center: NSPoint(x: r.minX + 20, y: r.midY), size: 14,
                   weight: selected ? .semibold : .regular, color: selected ? TH.accent : fg)
        drawString(title, in: NSRect(x: r.minX + 38, y: r.midY - 8, width: r.width - 72, height: 17),
                   size: 12.5, weight: selected ? .semibold : .regular, color: fg)
        if badgeCount > 0 {
            let txt = badgeCount > 9 ? "9+" : "\(badgeCount)"
            let w = max(18, textWidth(txt, size: 9.5, weight: .bold) + 12)
            let br = NSRect(x: r.maxX - w - 8, y: r.midY - 8, width: w, height: 16)
            dangerColor.setFill()
            capsule(br).fill()
            drawString(txt, in: NSRect(x: br.minX, y: br.minY + 2, width: br.width, height: 12),
                       size: 9.5, weight: .bold, color: .white, align: .center, mono: true)
        }
    }
}

final class SwatchButton: NSView {
    let color: NSColor
    var selected = false { didSet { needsDisplay = true } }
    var idx = 0
    var onClick: ((Int) -> Void)?
    private var hover = false

    init(frame: NSRect, color: NSColor, index: Int) {
        self.color = color
        self.idx = index
        super.init(frame: frame)
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
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?(idx) }
    }
    override func draw(_ dirty: NSRect) {
        let inset: CGFloat = selected ? 4 : (hover ? 4.5 : 6)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).fill()
        if selected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            color.withAlphaComponent(0.55).setStroke()
            ring.lineWidth = 2
            ring.stroke()
            drawSymbol("checkmark", center: NSPoint(x: bounds.midX, y: bounds.midY),
                       size: 10, weight: .bold, color: TH.onAccent)
        }
    }
}

final class ProgressBar: NSView {
    var value: CGFloat = 0 { didSet { needsDisplay = true } }
    var tint: NSColor? = nil
    override func draw(_ dirty: NSRect) {
        let r = bounds
        TH.fill(0.10).setFill()
        capsule(r).fill()
        guard value > 0.001 else { return }
        (tint ?? TH.accent).setFill()
        capsule(NSRect(x: r.minX, y: r.minY, width: max(r.height, r.width * min(1, value)), height: r.height)).fill()
    }
}

final class GaugeRing: NSView {
    var percent = 0
    var caption = ""
    var tint: NSColor? = nil
    private var progress: CGFloat = 1

    func set(_ v: Int, caption c: String, animated: Bool) {
        percent = max(0, min(100, v))
        caption = c
        progress = animated ? 0 : 1
        needsDisplay = true
    }
    func step() { if progress < 1 { progress = min(1, progress + 0.07); needsDisplay = true } }

    override func draw(_ dirty: NSRect) {
        let cx = bounds.midX, cy = bounds.midY, r = min(cx, cy) - 8
        let bg = NSBezierPath()
        bg.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: 360)
        bg.lineWidth = 8
        TH.fill(0.10).setStroke()
        bg.stroke()

        let col: NSColor = tint ?? (percent >= 90 ? dangerColor : (percent >= 75 ? warnColor : TH.accent))
        let ratio = CGFloat(percent) / 100 * progress
        if ratio > 0.001 {
            let fg = NSBezierPath()
            fg.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r,
                         startAngle: 90, endAngle: 90 - 360 * ratio, clockwise: true)
            fg.lineWidth = 8
            fg.lineCapStyle = .round
            col.setStroke()
            fg.stroke()
        }
        drawString("\(percent)%", in: NSRect(x: 0, y: cy - 1, width: bounds.width, height: 24),
                   size: 18, weight: .bold, color: TH.text, align: .center, mono: true)
        drawString(caption, in: NSRect(x: 0, y: cy - 19, width: bounds.width, height: 14),
                   size: 9.5, weight: .semibold, color: TH.dim(0.42), align: .center)
    }
}

// ═══════════════════════════════════════════════════════════
//  Compagnon
// ═══════════════════════════════════════════════════════════

final class CompanionView: NSView {
    let sprite = BudSprite()
    var sleepy = false {
        didSet { if alertCount == 0 { sprite.mood = sleepy ? .sleepy : .calm } }
    }
    var alertCount = 0 {
        didSet {
            sprite.mood = alertCount > 0 ? .alert : (sleepy ? .sleepy : .calm)
            needsDisplay = true
        }
    }
    var onTap: (() -> Void)?

    func react() { sprite.poke() }
    func wave() { sprite.wave() }
    var musicPlaying: Bool {
        get { sprite.equalizer }
        set { sprite.equalizer = newValue }
    }

    func step(follow: Bool) {
        if sprite.step(follow: follow, in: self, anchor: NSPoint(x: bounds.midX, y: bounds.midY)) {
            needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        sprite.poke()
        onTap?()
    }

    override func draw(_ dirty: NSRect) {
        sprite.render(in: bounds.insetBy(dx: 1, dy: 1), detail: bounds.width >= 40,
                      glowColor: alertCount > 0 ? warnColor : TH.accent)
        if alertCount > 0 {
            let txt = alertCount > 9 ? "9+" : "\(alertCount)"
            let d: CGFloat = 18
            let br = NSRect(x: bounds.maxX - d, y: bounds.maxY - d - 2, width: d, height: d)
            dangerColor.setFill()
            NSBezierPath(ovalIn: br).fill()
            drawString(txt, in: NSRect(x: br.minX, y: br.minY + 3, width: d, height: 12),
                       size: 9.5, weight: .bold, color: .white, align: .center, mono: true)
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  Notch
// ═══════════════════════════════════════════════════════════

enum NotchState { case collapsed, glance, approval, open }

final class Backdrop: NSVisualEffectView {
    var radius: CGFloat = 15 { didSet { if radius != oldValue { needsLayout = true } } }
    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        let rad = radius
        maskImage = NSImage(size: bounds.size, flipped: false) { r in
            NSColor.black.setFill()
            notchShape(r, radius: rad).fill()
            return true
        }
    }
}

final class NotchChrome: NSView {
    var state: NotchState = .collapsed
    var greeting = "Coucou"
    var subtitle = ""
    var mono = ""                      // ligne de commande d'une demande d'agent
    /// Icône, valeur, teinte. La teinte à `nil` garde l'ancien gris.
    var chips: [(String, String, NSColor?)] = []
    /// Les rectangles des pastilles, mémorisés au dessin pour savoir
    /// laquelle est sous le curseur. Calculer la mise en page deux fois —
    /// une pour dessiner, une pour viser — serait deux occasions de
    /// diverger.
    private var chipRects: [NSRect] = []
    private var chipHover = -1
    /// Appelé avec l'indice de la pastille cliquée.
    var onChipClick: ((Int) -> Void)?
    var progress: CGFloat = 0
    var badge: NSColor?
    var alertCount = 0
    var dropActive = false { didSet { needsDisplay = true } }
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    /// Lecture en cours : le replié montre le titre au lieu de l'heure,
    /// et BUD prend le rythme.
    var nowPlaying = "" { didSet { if nowPlaying != oldValue { marquee = 0 } } }
    /// La pochette du morceau, vignette dans le replié.
    var nowPlayingArt: NSImage? { didSet { needsDisplay = true } }
    var musicPlaying = false {
        didSet {
            sprite.equalizer = musicPlaying
            if !musicPlaying { marquee = 0 }
            needsDisplay = true
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  Le lecteur réduit
    //
    //  Un clic sur la pastille Musique ne quitte plus l'aperçu
    //  pour ouvrir le grand panneau : la pastille se déplie sur
    //  place en un petit lecteur — pochette, titre, artiste,
    //  avancement, précédent, lecture, suivant. On change de
    //  morceau sans perdre ce qu'on faisait.
    //
    //  Il naît de la pastille, littéralement : son rectangle
    //  part de celui de la pastille cliquée et s'étire jusqu'à
    //  la largeur de l'aperçu, avec un léger dépassement. Un
    //  lecteur qui apparaîtrait ailleurs, en fondu, ne dirait
    //  pas d'où il vient.
    // ═══════════════════════════════════════════════════════════

    enum PlayerAction { case previous, toggle, next, open, close }
    var onPlayer: ((PlayerAction) -> Void)?

    /// Ce que le lecteur affiche, en lecture comme en pause.
    var playerTitle = "" { didSet { if playerTitle != oldValue { marquee = 0 } } }
    var playerArtist = ""
    /// Teinte de la pastille Musique, reprise par le lecteur : il en est
    /// le prolongement, il en garde la couleur.
    var playerTint: NSColor = .systemPink

    /// Position et durée connues, et l'instant où on les a apprises :
    /// la barre avance entre deux relevés au lieu de sauter de quatre
    /// secondes en quatre secondes.
    private var playerPos: Double = 0
    private var playerDur: Double = 0
    private var playerStamp = Date()

    func setPlayback(position: Double, duration: Double, known: Bool) {
        playerPos = known ? position : 0
        playerDur = known ? duration : 0
        playerStamp = Date()
    }

    private(set) var playerShown = false
    private var playerMorph: CGFloat = 0          // 0 pastilles · 1 lecteur
    private var playerOrigin = NSRect.zero
    private var playerRects: [(PlayerAction, NSRect)] = []
    private var playerHover: PlayerAction?

    /// Déplie le lecteur depuis la pastille `i`.
    func showPlayer(fromChip i: Int) {
        playerOrigin = chipRects.indices.contains(i) ? chipRects[i] : playerFrame()
        if chips.indices.contains(i), let tint = chips[i].2 { playerTint = tint }
        playerShown = true
        chipHover = -1
        needsDisplay = true
    }

    /// Replie le lecteur dans sa pastille ; `instant` saute l'animation,
    /// pour un aperçu qui se ferme de toute façon.
    func hidePlayer(instant: Bool = false) {
        playerShown = false
        playerHover = nil
        if instant { playerMorph = 0 }
        needsDisplay = true
    }

    /// La place du lecteur déplié : la bande des pastilles et de la ligne
    /// d'aide, qu'il remplace le temps qu'il est ouvert.
    private func playerFrame() -> NSRect {
        NSRect(x: 22, y: 10, width: bounds.width - 44, height: 52)
    }

    let sprite = BudSprite()
    private var phase: CGFloat = 0, dash: CGFloat = 0
    private var frames = 0
    private var marquee: CGFloat = 0
    private var eqLevels: [CGFloat] = [0.35, 0.65, 0.45, 0.80]
    private var eqClock: CGFloat = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) {
        onHover?(false)
        if chipHover != -1 { chipHover = -1; needsDisplay = true }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let a = playerAction(at: p)
        if a != playerHover { playerHover = a; needsDisplay = true }
        let i = chipIndex(at: p)
        if i != chipHover { chipHover = i; needsDisplay = true }
    }

    override func mouseUp(with e: NSEvent) {
        guard state != .open else { return }
        let p = convert(e.locationInWindow, from: nil)
        // Le lecteur d'abord : ses boutons sont posés là où étaient les
        // pastilles. Un clic dans le lecteur mais hors d'un bouton ne fait
        // rien — ouvrir le grand panneau parce qu'on a visé à côté de
        // « suivant » serait une punition.
        if playerShown && playerMorph > 0.8 {
            if let a = playerAction(at: p) { onPlayer?(a); return }
            if playerFrame().contains(p) { return }
        }
        // Une pastille cliquée mène à son panneau ; partout ailleurs, le
        // clic ouvre BUD comme avant.
        let i = chipIndex(at: p)
        if i >= 0 { onChipClick?(i); return }
        onClick?()
    }

    private func playerAction(at p: NSPoint) -> PlayerAction? {
        guard state == .glance, playerShown, playerMorph > 0.8 else { return nil }
        for (a, r) in playerRects where r.contains(p) { return a }
        return nil
    }

    /// L'indice de la pastille sous le point, ou -1.
    private func chipIndex(at p: NSPoint) -> Int {
        guard state == .glance, !playerShown, playerMorph < 0.05 else { return -1 }
        for (i, r) in chipRects.enumerated() where r.contains(p) { return i }
        return -1
    }

    private func budRect() -> NSRect {
        switch state {
        case .collapsed: return NSRect(x: 9, y: bounds.midY - 16, width: 34, height: 32)
        default:         return NSRect(x: 14, y: bounds.maxY - 94, width: 74, height: 74)
        }
    }

    func step(follow: Bool) {
        frames += 1
        phase += alertCount > 0 ? 0.20 : 0.12
        dash += 0.6
        sprite.mood = alertCount > 0 ? .alert : .calm

        if musicPlaying {
            eqClock += 1.0 / 30.0
            let f: [CGFloat] = [5.3, 7.1, 4.3, 8.7]
            let ph: [CGFloat] = [0, 1.7, 0.9, 2.4]
            for i in eqLevels.indices {
                var v = 0.5 + 0.34 * sin(eqClock * f[i] + ph[i])
                        + 0.16 * sin(eqClock * f[(i + 2) % 4] * 0.37)
                v += CGFloat.random(in: -0.06...0.06)
                eqLevels[i] = max(0.12, min(1, eqLevels[i] * 0.45 + v * 0.55))
            }
            marquee += 0.9
        }

        // Le dépli prend trois dixièmes, le repli un peu moins : on
        // referme plus vite qu'on n'ouvre, l'attention est déjà ailleurs.
        let target: CGFloat = playerShown ? 1 : 0
        if playerMorph != target {
            let speed: CGFloat = playerShown ? 1.0 / (30 * 0.30) : 1.0 / (30 * 0.22)
            playerMorph = playerShown ? min(1, playerMorph + speed) : max(0, playerMorph - speed)
            needsDisplay = true
        }
        if playerShown && musicPlaying && state == .glance { needsDisplay = true }

        let r = budRect()
        var dirty = sprite.step(follow: follow, in: self, anchor: NSPoint(x: r.midX, y: r.midY))
        if dropActive || state != .collapsed { dirty = true }
        if state == .collapsed && frames % 2 == 0 { dirty = true }
        if musicPlaying { dirty = true }
        if dirty && state != .open { needsDisplay = true }
    }

    func wave() { sprite.wave() }
    func poke() { sprite.poke() }

    /// Quatre barres, dessinées directement : imbriquer une vue dans le
    /// notch replié pour 20 pt de large serait disproportionné.
    private func drawEqBars(in r: NSRect) {
        let n = eqLevels.count
        let gap: CGFloat = 2.5
        let w = (r.width - gap * CGFloat(n - 1)) / CGFloat(n)
        guard w > 0 else { return }
        for i in 0..<n {
            let h = max(2.5, r.height * eqLevels[i])
            let bar = NSRect(x: r.minX + CGFloat(i) * (w + gap), y: r.minY, width: w, height: h)
            TH.accent.withAlphaComponent(0.55 + 0.40 * eqLevels[i]).setFill()
            NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }

    /// Titre défilant. Un texte plus large que la place disponible est
    /// dessiné deux fois, à une longueur d'écart, pour que la boucle ne
    /// montre jamais de trou. En dessous, il reste simplement centré.
    private func drawMarquee(_ s: String, in r: NSRect, size: CGFloat, color: NSColor) {
        let tw = textWidth(s, size: size, weight: .semibold)
        guard tw > r.width else {
            drawString(s, in: r, size: size, weight: .semibold, color: color)
            return
        }
        let gapWidth: CGFloat = 36
        let span = tw + gapWidth
        let off = marquee.truncatingRemainder(dividingBy: span)

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        for k in 0..<2 {
            let x = r.minX - off + CGFloat(k) * span
            drawString(s, in: NSRect(x: x, y: r.minY, width: tw + 4, height: r.height),
                       size: size, weight: .semibold, color: color)
        }
        // Dégradés aux deux bords : le texte s'efface au lieu d'être coupé.
        if let g = NSGradient(colors: [TH.base.withAlphaComponent(TH.baseAlpha),
                                       TH.base.withAlphaComponent(0)],
                              atLocations: [0, 1], colorSpace: .deviceRGB) {
            g.draw(in: NSRect(x: r.minX, y: r.minY, width: 10, height: r.height), angle: 0)
            g.draw(in: NSRect(x: r.maxX - 10, y: r.minY, width: 10, height: r.height), angle: 180)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func draw(_ dirty: NSRect) {
        let b = bounds
        let radius: CGFloat = state == .collapsed ? 15 : (state == .open ? 30 : 26)
        let shape = notchShape(b, radius: radius)
        TH.base.withAlphaComponent(TH.baseAlpha).setFill()
        shape.fill()
        if alertCount > 0 && state != .open {
            warnColor.withAlphaComponent(0.22 + 0.18 * CGFloat(abs(sin(phase)))).setStroke()
            shape.lineWidth = 2
        } else {
            TH.fill(0.07).setStroke()
            shape.lineWidth = 1
        }
        shape.stroke()

        if dropActive {
            let zone = b.insetBy(dx: 16, dy: 16)
            let p = NSBezierPath(roundedRect: zone, xRadius: 18, yRadius: 18)
            TH.accent.withAlphaComponent(0.08).setFill()
            p.fill()
            p.lineWidth = 2
            p.setLineDash([7, 5], count: 2, phase: dash)
            TH.accent.withAlphaComponent(0.85).setStroke()
            p.stroke()
            drawSymbol("tray.and.arrow.down.fill", center: NSPoint(x: b.midX, y: b.midY + 18),
                       size: 26, weight: .semibold, color: TH.accent)
            drawString("Déposez vos fichiers, je les range",
                       in: NSRect(x: 0, y: b.midY - 24, width: b.width, height: 20),
                       size: 13, weight: .semibold, color: TH.text, align: .center)
            return
        }

        if state == .open { return }

        if state == .collapsed {
            sprite.render(in: budRect(), detail: false,
                          glowColor: alertCount > 0 ? warnColor : TH.accent)
            // Pendant la lecture, le titre prend la place de l'heure :
            // 214 pt ne suffisent pas pour les deux, et savoir ce qui joue
            // vaut mieux qu'une horloge présente partout ailleurs.
            if musicPlaying && !nowPlaying.isEmpty && alertCount == 0 {
                let reserved: CGFloat = badge != nil ? 34 : 14
                var x: CGFloat = 48
                if let art = nowPlayingArt {
                    let ar = NSRect(x: x, y: b.midY - 9, width: 18, height: 18)
                    let cp = NSBezierPath(roundedRect: ar, xRadius: 5, yRadius: 5)
                    NSGraphicsContext.current?.saveGraphicsState()
                    cp.addClip()
                    let s = art.size
                    if s.width > 0 && s.height > 0 {
                        let k = max(ar.width / s.width, ar.height / s.height)
                        let w = s.width * k, h = s.height * k
                        art.draw(in: NSRect(x: ar.midX - w / 2, y: ar.midY - h / 2,
                                            width: w, height: h))
                    }
                    NSGraphicsContext.current?.restoreGraphicsState()
                    TH.fill(0.10).setStroke()
                    cp.lineWidth = 1
                    cp.stroke()
                    x = ar.maxX + 7
                }
                drawEqBars(in: NSRect(x: x, y: b.midY - 7, width: 20, height: 14))
                let mx = x + 26
                drawMarquee(nowPlaying,
                            in: NSRect(x: mx, y: b.midY - 8,
                                       width: max(40, b.maxX - mx - reserved), height: 16),
                            size: 11.5, color: TH.text)
            } else {
                // L'heure comme sur un iPhone : collée à gauche, en gras,
                // avec la date du jour à sa droite en plus discret. Les
                // chiffres sont à largeur fixe, sinon l'heure tremblerait
                // à chaque minute — un « 1 » est plus étroit qu'un « 8 ».
                let t = clockString()
                let tw = textWidth(t, size: 14, weight: .bold, mono: true)
                drawString(t, in: NSRect(x: 50, y: b.midY - 9, width: tw + 3, height: 19),
                           size: 14, weight: .bold, color: TH.text, mono: true)

                let reserved: CGFloat = alertCount > 0 || badge != nil ? 34 : 14
                let dx = 50 + tw + 9
                let dw = b.maxX - dx - reserved
                if dw > 40 {
                    drawString(shortDateString(),
                               in: NSRect(x: dx, y: b.midY - 7, width: dw, height: 15),
                               size: 10.5, weight: .medium, color: TH.dim(0.42))
                }
            }
            if alertCount > 0 {
                let txt = alertCount > 9 ? "9+" : "\(alertCount)"
                let w = max(17, textWidth(txt, size: 9.5, weight: .bold) + 11)
                let br = NSRect(x: b.maxX - w - 12, y: b.midY - 8, width: w, height: 16)
                dangerColor.setFill()
                capsule(br).fill()
                drawString(txt, in: NSRect(x: br.minX, y: br.minY + 2, width: br.width, height: 12),
                           size: 9.5, weight: .bold, color: .white, align: .center, mono: true)
            } else if let badge = badge {
                let p = 5 + sin(phase) * 1.0
                badge.setFill()
                NSBezierPath(ovalIn: NSRect(x: b.maxX - 24 - p / 2, y: b.midY - p / 2,
                                            width: p, height: p)).fill()
            }
            return
        }

        // ── Aperçu et carte d'approbation ──
        sprite.render(in: budRect(), detail: true,
                    glowColor: alertCount > 0 ? warnColor : TH.accent)

        let top = b.maxY
        let left: CGFloat = 98
        let right = b.width - 22

        drawString(greeting, in: NSRect(x: left, y: top - 50, width: right - left, height: 24),
                   size: 16.5, weight: .bold, color: TH.text)
        drawString(subtitle, in: NSRect(x: left, y: top - 74, width: right - left, height: 20),
                   size: 12, weight: .medium, color: TH.dim(0.58))

        if state == .approval {
            if !mono.isEmpty {
                let boxRect = NSRect(x: left, y: top - 116, width: right - left, height: 34)
                TH.fill(0.09).setFill()
                NSBezierPath(roundedRect: boxRect, xRadius: 10, yRadius: 10).fill()
                TH.fill(0.07).setStroke()
                let bp = NSBezierPath(roundedRect: boxRect, xRadius: 10, yRadius: 10)
                bp.lineWidth = 1
                bp.stroke()
                drawString(mono, in: NSRect(x: boxRect.minX + 12, y: boxRect.midY - 8,
                                            width: boxRect.width - 24, height: 17),
                           size: 12, weight: .medium, color: TH.text, mono: true)
            }
            return   // les boutons sont de vraies vues, posées par le délégué
        }

        if progress > 0.001 {
            let t = NSRect(x: 22, y: top - 92, width: b.width - 44, height: 4)
            TH.fill(0.12).setFill()
            NSBezierPath(roundedRect: t, xRadius: 2, yRadius: 2).fill()
            TH.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: t.minX, y: t.minY, width: t.width * min(1, progress), height: 4),
                         xRadius: 2, yRadius: 2).fill()
        }

        // Les pastilles et la ligne d'aide s'effacent pendant que le
        // lecteur se déplie : on les dessine dans un calque dont
        // l'opacité suit le dépli, plutôt que de les retirer d'un coup.
        let chipAlpha = 1 - min(1, playerMorph * 1.6)
        let ctx = NSGraphicsContext.current?.cgContext
        if chipAlpha < 1 {
            ctx?.saveGState()
            ctx?.setAlpha(chipAlpha)
            ctx?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if !chips.isEmpty && chipAlpha > 0 {
            let gap: CGFloat = 8
            let cw = (b.width - 44 - gap * CGFloat(chips.count - 1)) / CGFloat(chips.count)
            chipRects.removeAll()
            for (i, chip) in chips.enumerated() {
                let r = NSRect(x: 22 + CGFloat(i) * (cw + gap), y: top - 128, width: cw, height: 28)
                chipRects.append(r)
                let tint = chip.2 ?? TH.dim(0.68)
                let live = (i == chipHover)
                // La pastille survolée s'éclaire de sa propre teinte : c'est
                // ce qui dit qu'elle se clique, sans ajouter un libellé.
                (live ? tint.withAlphaComponent(0.20) : TH.fill(0.09)).setFill()
                capsule(r).fill()
                let sp = capsule(r)
                (live ? tint.withAlphaComponent(0.50) : TH.fill(0.07)).setStroke()
                sp.lineWidth = 1
                sp.stroke()
                drawSymbol(chip.0, center: NSPoint(x: r.minX + 17, y: r.midY), size: 11.5,
                           weight: .semibold, color: tint)
                let maxW = r.width - 32
                drawString(chip.1, in: NSRect(x: r.minX + 28, y: r.midY - 8, width: maxW, height: 16),
                           size: 11.5, weight: .semibold, color: TH.text, mono: true)
            }
        }

        if chipAlpha > 0 {
            drawString("Cliquer pour ouvrir · déposer des fichiers ici",
                       in: NSRect(x: 0, y: 8, width: b.width, height: 14),
                       size: 9.5, weight: .medium, color: TH.dim(0.26), align: .center)
        }
        if chipAlpha < 1 {
            ctx?.endTransparencyLayer()
            ctx?.restoreGState()
        }

        if playerMorph > 0.001 { drawPlayer() } else { playerRects.removeAll() }
    }

    // ─────────────────────────────────────────────────────────
    //  Le lecteur réduit, dessiné
    // ─────────────────────────────────────────────────────────

    /// Dépli élastique : le lecteur dépasse un peu sa largeur puis s'y
    /// pose. Au repli, une courbe douce — un ressort qui se referme en
    /// rebondissant aurait l'air de résister.
    private func playerEase(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        if !playerShown { return c * c * (3 - 2 * c) }
        if c >= 1 { return 1 }
        return 1 - exp(-6.0 * c) * cos(8.0 * c)
    }

    private func lerp(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    private func drawPlayer() {
        let full = playerFrame()
        let origin = playerOrigin == .zero ? full : playerOrigin
        let e = playerEase(playerMorph)
        let r = lerp(origin, full, e)
        let radius = min(r.height / 2, 14 + (1 - e) * 6)

        // La coque garde la teinte de la pastille : c'est elle qui grandit.
        let shell = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        playerTint.withAlphaComponent(0.10 + 0.06 * (1 - e)).setFill()
        shell.fill()
        TH.fill(0.06).setFill()
        shell.fill()
        playerTint.withAlphaComponent(0.42).setStroke()
        shell.lineWidth = 1
        shell.stroke()

        // Le contenu n'apparaît qu'une fois la coque presque dépliée :
        // un titre qui s'étire avec elle serait illisible le temps du
        // mouvement.
        let ca = max(0, min(1, (playerMorph - 0.45) / 0.55))
        playerRects.removeAll()
        guard ca > 0.01 else { return }

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setAlpha(ca)
        ctx?.beginTransparencyLayer(auxiliaryInfo: nil)

        // ── La pochette, ou une note quand il n'y en a pas ──
        let art = NSRect(x: full.minX + 6, y: full.minY + 6, width: 40, height: 40)
        let ap = NSBezierPath(roundedRect: art, xRadius: 9, yRadius: 9)
        if let img = nowPlayingArt, img.size.width > 0, img.size.height > 0 {
            NSGraphicsContext.current?.saveGraphicsState()
            ap.addClip()
            let k = max(art.width / img.size.width, art.height / img.size.height)
            let w = img.size.width * k, h = img.size.height * k
            img.draw(in: NSRect(x: art.midX - w / 2, y: art.midY - h / 2, width: w, height: h))
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            playerTint.withAlphaComponent(0.22).setFill()
            ap.fill()
            drawSymbol("music.note", center: NSPoint(x: art.midX, y: art.midY), size: 16,
                       weight: .semibold, color: playerTint)
        }
        TH.fill(0.10).setStroke()
        ap.lineWidth = 1
        ap.stroke()
        // Pendant la lecture, l'égaliseur se pose sur un coin de la
        // pochette : on voit d'un coup d'œil que ça joue.
        if musicPlaying {
            let eq = NSRect(x: art.maxX - 15, y: art.minY + 4, width: 11, height: 9)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: eq.insetBy(dx: -2.5, dy: -2), xRadius: 3, yRadius: 3).fill()
            drawEqBars(in: eq)
        }

        // ── Les commandes, à droite ──
        let cy = full.midY
        let close = NSRect(x: full.maxX - 26, y: cy - 10, width: 20, height: 20)
        let next = NSRect(x: close.minX - 34, y: cy - 14, width: 28, height: 28)
        let play = NSRect(x: next.minX - 38, y: cy - 16, width: 32, height: 32)
        let prev = NSRect(x: play.minX - 34, y: cy - 14, width: 28, height: 28)
        let textX = art.maxX + 10
        let textW = max(40, prev.minX - 10 - textX)
        playerRects = [(.previous, prev), (.toggle, play), (.next, next), (.close, close),
                       (.open, NSRect(x: art.minX, y: full.minY, width: textX + textW - art.minX,
                                      height: full.height))]

        func button(_ a: PlayerAction, _ rect: NSRect, _ symbol: String, _ size: CGFloat,
                    filled: Bool = false) {
            let hot = playerHover == a
            if filled {
                (hot ? playerTint : playerTint.withAlphaComponent(0.88)).setFill()
                NSBezierPath(ovalIn: rect).fill()
                drawSymbol(symbol, center: NSPoint(x: rect.midX + (symbol == "play.fill" ? 1 : 0),
                                                   y: rect.midY),
                           size: size, weight: .bold, color: .white)
            } else {
                if hot {
                    TH.fill(0.12).setFill()
                    NSBezierPath(ovalIn: rect).fill()
                }
                drawSymbol(symbol, center: NSPoint(x: rect.midX, y: rect.midY), size: size,
                           weight: .semibold, color: hot ? TH.text : TH.dim(0.78))
            }
        }
        button(.previous, prev, "backward.fill", 12)
        button(.toggle, play, musicPlaying ? "pause.fill" : "play.fill", 13, filled: true)
        button(.next, next, "forward.fill", 12)
        button(.close, close, "chevron.down", 10)

        // ── Titre, artiste, avancement ──
        let hasTrack = !playerTitle.isEmpty
        let title = hasTrack ? playerTitle : "Rien en lecture"
        let sub = hasTrack ? (playerArtist.isEmpty ? "Musique" : playerArtist)
                           : "Touchez lecture pour lancer Musique"
        drawMarquee(title, in: NSRect(x: textX, y: cy + 3, width: textW, height: 16),
                    size: 12.5, color: TH.text)
        drawString(sub, in: NSRect(x: textX, y: cy - 12, width: textW, height: 14),
                   size: 10.5, weight: .medium, color: TH.dim(0.55))

        if playerDur > 0 {
            let elapsed = musicPlaying ? Date().timeIntervalSince(playerStamp) : 0
            let f = CGFloat(max(0, min(1, (playerPos + elapsed) / playerDur)))
            let track = NSRect(x: textX, y: full.minY + 7, width: textW, height: 3)
            TH.fill(0.14).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            playerTint.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                             width: max(3, track.width * f), height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        ctx?.endTransparencyLayer()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

final class DropHost: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { onEnter?(); return .copy }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { onExit?() }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        guard !urls.isEmpty else { onExit?(); return false }
        onDrop?(urls)
        return true
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// ═══════════════════════════════════════════════════════════
//  Contrôles sobres : segments et interrupteurs
// ═══════════════════════════════════════════════════════════

/// Groupe de segments dans un seul cadre, à la manière des réglages macOS.
final class SegmentedBar: NSView {
    struct Item { let title: String; let icon: String? }
    private let items: [Item]
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    private var hoverIndex = -1

    init(frame: NSRect, items: [Item], selected: Int = 0) {
        self.items = items
        self.selected = selected
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func indexAt(_ p: NSPoint) -> Int {
        guard !items.isEmpty, bounds.contains(p) else { return -1 }
        let w = bounds.width / CGFloat(items.count)
        return min(items.count - 1, max(0, Int(p.x / w)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with e: NSEvent) {
        let i = indexAt(convert(e.locationInWindow, from: nil))
        if i != hoverIndex { hoverIndex = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hoverIndex = -1; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        let i = indexAt(convert(e.locationInWindow, from: nil))
        guard i >= 0 else { return }
        selected = i
        onSelect?(i)
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        // Le conteneur est creux — niveau 0 — et la cellule choisie
        // ressort au niveau 2 : c'est le même langage d'élévation que
        // les cartes et les boutons, et non un style propre à la barre.
        drawGlass(in: bounds, radius: Radius.m, level: 0)

        let w = r.width / CGFloat(items.count)
        for (i, it) in items.enumerated() {
            let cell = NSRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: w, height: r.height).insetBy(dx: 3, dy: 3)
            if i == selected {
                drawGlass(in: cell, radius: Radius.s, level: 2,
                          tint: TH.accent.withAlphaComponent(0.42))
            } else if i == hoverIndex {
                drawGlass(in: cell, radius: Radius.s, level: 1, hover: 0.6)
            }

            let fg = i == selected ? TH.text : TH.dim(i == hoverIndex ? 0.75 : 0.5)
            let tw = textWidth(it.title, size: 12, weight: i == selected ? .semibold : .medium)
            let iconW: CGFloat = it.icon == nil ? 0 : 20
            var x = cell.midX - (tw + iconW) / 2
            if let ic = it.icon {
                drawSymbol(ic, center: NSPoint(x: x + 7, y: cell.midY), size: 12.5,
                           weight: .semibold, color: i == selected ? TH.accent : fg)
                x += iconW
            }
            drawString(it.title, in: NSRect(x: x, y: cell.midY - 8, width: tw + 4, height: 16),
                       size: 12, weight: i == selected ? .semibold : .medium, color: fg)
        }
    }
}

/// Rangée d'option : icône, libellé, interrupteur à droite.
final class ToggleRow: NSView {
    let title: String
    let iconName: String
    var isOn = false {
        didSet { if isOn != oldValue { animateKnob() } }
    }
    var onToggle: (() -> Void)?

    private var knobT: CGFloat = 0
    private var hover = false
    private var anim: Timer?

    init(frame: NSRect, title: String, icon: String) {
        self.title = title
        self.iconName = icon
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setOn(_ v: Bool, animated: Bool = true) {
        if !animated { knobT = v ? 1 : 0 }
        isOn = v
        needsDisplay = true
    }

    private func animateKnob() {
        guard anim == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tm in
            guard let s = self else { tm.invalidate(); return }
            let target: CGFloat = s.isOn ? 1 : 0
            s.knobT += (target - s.knobT) * 0.3
            if abs(target - s.knobT) < 0.01 { s.knobT = target; tm.invalidate(); s.anim = nil }
            s.needsDisplay = true
        }
        anim = t
        RunLoop.main.add(t, forMode: .common)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        guard bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        onToggle?()
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let card = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        TH.fill(hover ? 0.09 : 0.05).setFill()
        card.fill()
        TH.fill(isOn ? 0.10 : 0.07).setStroke()
        card.lineWidth = 1
        card.stroke()

        drawSymbol(iconName, center: NSPoint(x: r.minX + (r.width < 230 ? 18 : 20), y: r.midY),
                   size: r.width < 230 ? 12.5 : 13, weight: .semibold,
                   color: isOn ? TH.accent : TH.dim(0.45))

        // Interrupteur, réduit quand la rangée est étroite
        let narrow = r.width < 230
        let tw: CGFloat = narrow ? 34 : 40
        let th: CGFloat = narrow ? 19 : 22
        let track = NSRect(x: r.maxX - tw - 12, y: r.midY - th / 2, width: tw, height: th)
        if isOn || knobT > 0.01 {
            TH.fill(0.12).setFill()
            capsule(track).fill()
            TH.accent.withAlphaComponent(knobT).setFill()
            capsule(track).fill()
        } else {
            TH.fill(0.12).setFill()
            capsule(track).fill()
        }
        let kd: CGFloat = th - 6
        let kx = track.minX + 3 + knobT * (tw - kd - 6)
        let knob = NSRect(x: kx, y: track.midY - kd / 2, width: kd, height: kd)
        NSColor.white.withAlphaComponent(TH.dark ? 0.95 : 1).setFill()
        NSBezierPath(ovalIn: knob).fill()

        let labelX = r.minX + (narrow ? 34 : 38)
        let labelMax = max(10, track.minX - labelX - 8)
        drawString(title, in: NSRect(x: labelX, y: r.midY - 8, width: labelMax, height: 16),
                   size: narrow ? 11 : 11.5, weight: .medium, color: isOn ? TH.text : TH.dim(0.65))
    }
}

// ═══════════════════════════════════════════════════════════
//  La fenêtre des raccourcis
//
//  Une fenêtre à part, et non une section des Réglages : les
//  cinq rangées d'interrupteurs occupent déjà le panneau jusqu'à
//  six points du bord. Dix raccourcis n'y entraient pas sans
//  tout recomposer, et une liste qu'on modifie mérite de la
//  place.
// ═══════════════════════════════════════════════════════════

final class ShortcutsWindow: NSWindowController {

    /// Appelé à chaque changement : l'action et son nouveau raccourci.
    var onSet: ((String, String) -> Void)?
    /// Appelé quand l'utilisateur rend tout à l'usine.
    var onReset: (() -> Void)?

    private var recorders: [String: KeyRecorder] = [:]
    private var note: NSTextField!
    private var current: (String) -> String

    /// Les quatre pastilles de l'aperçu en vigueur.
    var chipsNow: () -> [String] = { PreviewChips.fallback }
    /// Appelé quand une pastille change : l'emplacement et la nouvelle clé.
    var onChipSet: ((Int, String) -> Void)?
    private var chipPops: [NSPopUpButton] = []

    /// Largeur et hauteur fixes : la fenêtre n'est pas redimensionnable, et
    /// toute la mise en page part de ces deux nombres.
    private static let W: CGFloat = 560
    private static var H: CGFloat { CGFloat(Shortcuts.actions.count) * 42 + 322 }

    init(current: @escaping (String) -> String) {
        self.current = current
        let H = ShortcutsWindow.H

        // Un NSPanel, et non une fenêtre ordinaire.
        //
        //  Le panneau de BUD vit au niveau `.statusBar`, au-dessus de tout.
        //  Une fenêtre de niveau normal passait donc derrière lui dès qu'on
        //  le rouvrait, et devenait inatteignable sans replier BUD. Le
        //  panneau se place juste au-dessus, et `isFloatingPanel` le garde
        //  devant les autres fenêtres de l'application.
        //
        //  Il doit pouvoir devenir fenêtre clé : le capteur de raccourci
        //  écoute par un moniteur local, qui ne reçoit les touches que si
        //  la fenêtre a le focus.
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ShortcutsWindow.W, height: H),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = "Raccourcis et aperçu"
        w.isReleasedWhenClosed = false
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        w.center()
        super.init(window: w)
        build(H)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(_ H: CGFloat) {
        guard let content = window?.contentView else { return }
        let W = ShortcutsWindow.W

        let title = mkLabel("Choisissez vos raccourcis",
                            NSRect(x: 22, y: H - 42, width: W - 44, height: 22), 15, .bold)
        content.addSubview(title)
        let sub = mkLabel("Cliquez un raccourci, puis tapez la combinaison. Échap annule.",
                          NSRect(x: 22, y: H - 66, width: W - 44, height: 16), 11.5, .regular, alpha: 0.5)
        content.addSubview(sub)

        for (i, a) in Shortcuts.actions.enumerated() {
            let y = H - 98 - CGFloat(i) * 42
            let lab = mkLabel(a.label, NSRect(x: 22, y: y, width: W - 190, height: 20), 12.5, .medium)
            content.addSubview(lab)

            let rec = KeyRecorder(frame: NSRect(x: W - 152, y: y - 5, width: 130, height: 30),
                                  combo: current(a.key))
            let key = a.key
            rec.conflict = { [weak self] candidate in
                guard let s = self else { return nil }
                for other in Shortcuts.actions where other.key != key {
                    if s.current(other.key) == candidate { return other.label }
                }
                return nil
            }
            rec.onChange = { [weak self] combo in
                self?.onSet?(key, combo)
                self?.note.stringValue = "\(a.label) : \(Shortcuts.display(combo))"
                self?.note.textColor = TH.dim(0.55)
            }
            rec.onRefuse = { [weak self] why in
                self?.note.stringValue = why
                self?.note.textColor = dangerColor
            }
            content.addSubview(rec)
            recorders[a.key] = rec
        }

        // ── Les quatre pastilles de l'aperçu ──
        //
        //  Deux rangées de deux, et non quatre de front. À quatre, chaque
        //  menu recevait 113 points et tronquait ses intitulés — « Disques
        //  ex… », « Focus en c… ». Deux par rangée en donnent 252, où
        //  « Disques externes » tient en entier.
        let sec = mkLabel("Pastilles de l'aperçu",
                          NSRect(x: 22, y: 194, width: W - 44, height: 18), 12.5, .bold)
        content.addSubview(sec)
        let hint2 = mkLabel("Ce que montrent les quatre capsules sous la salutation. Un clic dessus ouvre le panneau correspondant.",
                            NSRect(x: 22, y: 170, width: W - 44, height: 16), 10.5, .regular, alpha: 0.45)
        content.addSubview(hint2)

        let keys = chipsNow()
        let pw = (W - 44 - 12) / 2
        for slot in 0..<4 {
            let col = CGFloat(slot % 2), row = CGFloat(slot / 2)
            let pop = NSPopUpButton(frame: NSRect(x: 22 + col * (pw + 12),
                                                  y: 134 - row * 34, width: pw, height: 28))
            for c in PreviewChips.catalogue { pop.addItem(withTitle: c.label) }
            if slot < keys.count,
               let i = PreviewChips.catalogue.firstIndex(where: { $0.key == keys[slot] }) {
                pop.selectItem(at: i)
            }
            pop.tag = slot
            pop.target = self
            pop.action = #selector(chipPicked(_:))
            content.addSubview(pop)
            chipPops.append(pop)
        }

        // La note de statut vivait à 50..80 et les menus à 60..86 : elle les
        // recouvrait de vingt points. Posée après eux, elle était au-dessus,
        // et comme un NSTextField reste une cible de clic même non
        // modifiable, elle avalait les clics destinés aux menus. C'est
        // pourquoi ils paraissaient inertes : ils ne recevaient rien.
        note = mkLabel("", NSRect(x: 22, y: 58, width: W - 44, height: 32), 11, .regular, alpha: 0.55)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        note.cell?.usesSingleLineMode = false
        note.cell?.wraps = true
        // Et par précaution, elle ne prend plus aucun clic : une étiquette
        // de statut n'a rien à intercepter, quelle que soit sa position.
        note.isSelectable = false
        note.refusesFirstResponder = true
        content.addSubview(note)

        let reset = GlassButton(frame: NSRect(x: 22, y: 14, width: 210, height: 34),
                                title: "Rendre les raccourcis d'usine", icon: "arrow.counterclockwise")
        reset.onClick = { [weak self] _ in
            guard let s = self else { return }
            s.onReset?()
            for a in Shortcuts.actions { s.recorders[a.key]?.combo = a.fallback }
            s.note.stringValue = "Raccourcis d'usine rétablis."
            s.note.textColor = TH.dim(0.55)
        }
        content.addSubview(reset)

        let done = GlassButton(frame: NSRect(x: W - 122, y: 14, width: 100, height: 34),
                               title: "Terminé", icon: "checkmark", prominent: true)
        done.onClick = { [weak self] _ in self?.window?.close() }
        content.addSubview(done)
    }

    @objc private func chipPicked(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < PreviewChips.catalogue.count else { return }
        let c = PreviewChips.catalogue[i]
        onChipSet?(sender.tag, c.key)
        note.stringValue = "Pastille \(sender.tag + 1) : \(c.label)."
        note.textColor = TH.dim(0.55)
    }

    /// Relit les raccourcis en vigueur — utile si l'état a changé ailleurs.
    func refresh() {
        for a in Shortcuts.actions { recorders[a.key]?.combo = current(a.key) }
        let keys = chipsNow()
        for (slot, pop) in chipPops.enumerated() where slot < keys.count {
            if let i = PreviewChips.catalogue.firstIndex(where: { $0.key == keys[slot] }) {
                pop.selectItem(at: i)
            }
        }
    }
}
