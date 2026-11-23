import Cocoa

// ═══════════════════════════════════════════════════════════
//  BUD — le personnage, dessiné en vectoriel et animé
//
//  Portage fidèle du compagnon « standard » : un squircle blanc,
//  deux joues rose pastel, deux yeux ronds et une bouche en « O »
//  avec la langue rose. Tout est tracé en Bézier, donc net du
//  16 px au 1024 px.
//
//  Attention à l'axe Y : le prototype était en Canvas HTML, où Y
//  descend. AppKit a Y qui monte. Tous les décalages verticaux sont
//  donc inversés, et les arcs sont redonnés en degrés dans le sens
//  antihoraire d'AppKit — un arc « bas » du Canvas (0,15π → 0,85π)
//  devient ici 200° → 340°.
// ═══════════════════════════════════════════════════════════

/// Les humeurs de BUD.
///
/// Chacune est attachée à un fait, jamais décorative : il écoute quand
/// la veille l'a entendu, parle quand il répond, est fier quand une
/// tâche a abouti, déçu quand elle a échoué, perplexe quand il n'a pas
/// compris. Une humeur qui ne correspond à rien finit par être ignorée,
/// et c'est alors toute l'expressivité qui ne veut plus rien dire.
enum BudMood {
    case calm, happy, alert, sleepy, wink, dizzy, angry, thinking
    case listening, speaking, proud, sad, confused
}

/// Trois habillages : à plat, nacré-or, et métal.
enum BudStyle { case flat, premium, metal, logo }

/// Palette du personnage, indépendante du thème de l'interface.
enum BudSkin {
    // Style à plat
    static let shell      = NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
    static let shellEdge  = NSColor(calibratedRed: 0.847, green: 0.886, blue: 0.910, alpha: 0.85)
    static let ink        = NSColor(calibratedRed: 0.137, green: 0.152, blue: 0.200, alpha: 1)
    static let blush      = NSColor(calibratedRed: 1.00, green: 0.710, blue: 0.710, alpha: 1)
    static let tongue     = NSColor(calibratedRed: 1.00, green: 0.557, blue: 0.620, alpha: 1)
    static let sweat      = NSColor(calibratedRed: 0.647, green: 0.847, blue: 1.00, alpha: 1)
    static let anger      = NSColor(calibratedRed: 0.910, green: 0.478, blue: 0.302, alpha: 1)

    // Style nacré-or
    static let goldHi     = NSColor(calibratedRed: 0.965, green: 0.906, blue: 0.824, alpha: 1)
    static let goldMid    = NSColor(calibratedRed: 0.875, green: 0.757, blue: 0.616, alpha: 1)
    static let goldLo     = NSColor(calibratedRed: 0.784, green: 0.635, blue: 0.478, alpha: 1)
    static let pearlHi    = NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
    static let pearlMid   = NSColor(calibratedRed: 0.961, green: 0.949, blue: 0.933, alpha: 1)
    static let pearlLo    = NSColor(calibratedRed: 0.890, green: 0.867, blue: 0.835, alpha: 1)
    static let inkWarm    = NSColor(calibratedRed: 0.141, green: 0.118, blue: 0.102, alpha: 1)
    static let blushWarm  = NSColor(calibratedRed: 0.894, green: 0.643, blue: 0.576, alpha: 1)
    static let tongueWarm = NSColor(calibratedRed: 0.851, green: 0.541, blue: 0.486, alpha: 1)
    static let smileGold  = NSColor(calibratedRed: 0.831, green: 0.643, blue: 0.349, alpha: 1)
    static let smileEdge  = NSColor(calibratedRed: 0.620, green: 0.443, blue: 0.196, alpha: 1)

    // Style métal : coque ardoise, cadre argenté, écran sombre
    static let shellSlate = NSColor(calibratedRed: 0.169, green: 0.188, blue: 0.251, alpha: 1)
    static let shellSlateHi = NSColor(calibratedRed: 0.235, green: 0.259, blue: 0.341, alpha: 1)
    static let shellSlateLo = NSColor(calibratedRed: 0.114, green: 0.129, blue: 0.180, alpha: 1)
    static let bezel      = NSColor(calibratedRed: 0.553, green: 0.600, blue: 0.682, alpha: 1)
    static let bezelHi    = NSColor(calibratedRed: 0.796, green: 0.835, blue: 0.882, alpha: 1)
    static let bezelLo    = NSColor(calibratedRed: 0.392, green: 0.455, blue: 0.545, alpha: 1)
    static let screen     = NSColor(calibratedRed: 0.051, green: 0.063, blue: 0.090, alpha: 1)
    static let screenHi   = NSColor(calibratedRed: 0.078, green: 0.098, blue: 0.137, alpha: 1)
    static let sensor     = NSColor(calibratedRed: 0.118, green: 0.161, blue: 0.231, alpha: 1)
    static let cyan       = NSColor(calibratedRed: 0.133, green: 0.890, blue: 0.961, alpha: 1)
    static let rose       = NSColor(calibratedRed: 0.984, green: 0.443, blue: 0.522, alpha: 1)
    static let indigo     = NSColor(calibratedRed: 0.506, green: 0.549, blue: 0.972, alpha: 1)
}

/// Les yeux du BUD métal suivent la couleur d'accent, mais un accent
/// sombre disparaîtrait sur l'écran noir : on retombe alors sur le cyan.
func metalEyeColor(_ accent: NSColor) -> NSColor {
    guard let c = accent.usingColorSpace(.deviceRGB) else { return BudSkin.cyan }
    let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    return lum < 0.42 ? BudSkin.cyan : accent
}

/// Le corps : un squircle centré sur l'origine, coins très arrondis.
/// `radiusRatio` vaut 0,30 pour le compagnon standard.
func squirclePath(size: CGFloat, radiusRatio: CGFloat = 0.30) -> NSBezierPath {
    let h = size / 2
    let r = size * radiusRatio
    // Le prototype trace des quadratiques dont le point de contrôle est
    // le coin. En cubique, cela place les deux contrôles à r/3 du coin.
    let k = r / 3
    let p = NSBezierPath()
    p.move(to: NSPoint(x: -h + r, y: -h))
    p.line(to: NSPoint(x: h - r, y: -h))
    p.curve(to: NSPoint(x: h, y: -h + r),
            controlPoint1: NSPoint(x: h - k, y: -h),
            controlPoint2: NSPoint(x: h, y: -h + k))
    p.line(to: NSPoint(x: h, y: h - r))
    p.curve(to: NSPoint(x: h - r, y: h),
            controlPoint1: NSPoint(x: h, y: h - k),
            controlPoint2: NSPoint(x: h - k, y: h))
    p.line(to: NSPoint(x: -h + r, y: h))
    p.curve(to: NSPoint(x: -h, y: h - r),
            controlPoint1: NSPoint(x: -h + k, y: h),
            controlPoint2: NSPoint(x: -h, y: h - k))
    p.line(to: NSPoint(x: -h, y: -h + r))
    p.curve(to: NSPoint(x: -h + r, y: -h),
            controlPoint1: NSPoint(x: -h, y: -h + k),
            controlPoint2: NSPoint(x: -h + k, y: -h))
    p.close()
    return p
}

/// État animé de BUD : ressorts, clignements, regard, humeur.
/// Une instance par vue ; les deux rendus (notch et panneau) partagent ce code.
final class BudSprite {

    /// Habillage commun à toutes les instances, piloté par les réglages.
    static var style: BudStyle = .flat

    /// Pendant la lecture, BUD danse. Honnêteté : macOS n'expose aucun
    /// niveau audio en sortie sans capturer le flux, ce que BUD ne fait
    /// pas. Le rythme est donc régulier et synthétique — un signe de vie,
    /// pas une mesure du morceau.
    var equalizer = false { didSet { if !equalizer { beat = 0 } } }
    private var beat: CGFloat = 0

    // Humeur
    var mood: BudMood = .calm
    private var happyUntil = Date.distantPast
    private var winkUntil = Date.distantPast
    private var dizzyUntil = Date.distantPast

    /// Humeurs passagères, posées par `flash(_:for:)` : elles l'emportent
    /// le temps qu'elles durent, puis l'humeur de fond revient.
    private var flashMood: BudMood = .calm
    private var flashUntil = Date.distantPast

    /// Montre une humeur pendant quelques secondes. Rien à remettre en
    /// place ensuite : l'échéance s'en charge.
    func flash(_ m: BudMood, for seconds: TimeInterval) {
        flashMood = m
        flashUntil = Date().addingTimeInterval(seconds)
    }

    private var effectiveMood: BudMood {
        let now = Date()
        // Une alerte prime sur tout, sauf sur une humeur passagère plus
        // précise : « en colère » dit déjà qu'il y a un problème, et le
        // dit mieux.
        if now < flashUntil { return flashMood }
        if mood == .alert { return .alert }
        if now < dizzyUntil { return .dizzy }
        if now < winkUntil { return .wink }
        if now < happyUntil { return .happy }
        return mood
    }

    // Horloge continue, en secondes
    private var clock: CGFloat = 0
    private let dt: CGFloat = 1.0 / 30.0

    // Ressorts d'écrasement et de saut (portés du prototype)
    private var scaleX: CGFloat = 1, velScaleX: CGFloat = 0
    private var scaleY: CGFloat = 1, velScaleY: CGFloat = 0
    private var jump: CGFloat = 0, velJump: CGFloat = 0
    /// Danse : balancement latéral, et le côté vers lequel part le
    /// prochain temps. Alterner donne un pas à deux temps ; sans cela,
    /// BUD tremblerait sur place au lieu de danser.
    private var sway: CGFloat = 0, velSway: CGFloat = 0
    private var danceSide: CGFloat = 1
    private var tilt: CGFloat = 0, tiltVel: CGFloat = 0
    private var waveUntil = Date.distantPast

    // Regard et paupières
    private var lookX: CGFloat = 0, lookY: CGFloat = 0
    private var blink: CGFloat = 0
    private var blinkTimer: CGFloat = 2.2
    private var closing = false

    // Oscillateurs
    private var spiral: CGFloat = 0
    private var glow: CGFloat = 0
    private var drops: [CGFloat] = [0.0, 0.45, 0.75]
    private let dropSpeed: [CGFloat] = [0.24, 0.20, 0.22]
    private let dropSize: [CGFloat] = [1.0, 0.78, 0.68]

    /// Rebond élastique : clic, réaction, bonne nouvelle.
    /// Le prototype enchaînait standard → clin d'œil → souriant ;
    /// on garde cet enchaînement.
    func poke(strength: CGFloat = 1, joyful: Bool = true) {
        velScaleX += 0.14 * strength
        velScaleY -= 0.16 * strength
        velJump += 250 * strength
        closing = true
        blinkTimer = 0
        if joyful {
            winkUntil = Date().addingTimeInterval(0.55)
            happyUntil = Date().addingTimeInterval(1.9)
        }
    }

    /// Petit salut : le compagnon se balance deux fois.
    func wave() {
        waveUntil = Date().addingTimeInterval(1.6)
        tiltVel += 0.22
        happyUntil = Date().addingTimeInterval(1.8)
    }

    /// Tête qui tourne : utile pendant un nettoyage ou une longue tâche.
    func spin(for seconds: TimeInterval = 2.4) {
        dizzyUntil = Date().addingTimeInterval(seconds)
        velScaleX += 0.07
    }

    /// Avance d'une image. Renvoie true si la vue doit se redessiner.
    @discardableResult
    func step(follow: Bool, in view: NSView, anchor: NSPoint) -> Bool {
        let m = effectiveMood
        clock += dt

        glow += m == .alert ? 0.16 : 0.055
        if glow > .pi * 2 { glow -= .pi * 2 }
        spiral += dt * 4.5
        if spiral > .pi * 2 { spiral -= .pi * 2 }

        // Gouttes de sueur : chute cyclique
        for i in drops.indices {
            drops[i] = (drops[i] + dt * dropSpeed[i] * 3.2).truncatingRemainder(dividingBy: 1)
        }

        // Regard : suivi souple du curseur, curiosité au repos
        var targetX: CGFloat = 0, targetY: CGFloat = 0
        if follow, m != .sleepy, let w = view.window {
            let eye = w.convertPoint(toScreen: view.convert(anchor, to: nil))
            let p = NSEvent.mouseLocation
            let dx = (p.x - eye.x) / 460
            let dy = (p.y - eye.y) / 340
            let dist = sqrt(dx * dx + dy * dy)
            if dist > 1 {
                targetX = dx / dist
                targetY = dy / dist
            } else {
                targetX = dx
                targetY = dy
            }
        } else if m != .sleepy {
            targetX = sin(clock * 0.7) * 0.18
            targetY = cos(clock * 0.5) * 0.12
        }
        let lerp = 1 - exp(-8 * dt)
        lookX += (targetX - lookX) * lerp
        lookY += (targetY - lookY) * lerp

        // Clignement : fermeture rapide, ouverture plus douce
        blinkTimer -= dt
        let interval: CGFloat = m == .alert ? 1.4 : (m == .happy ? 2.4 : 3.6)
        if m == .sleepy {
            blink += (1 - blink) * 0.2
        } else if closing {
            blink += (1 - blink) * 0.45
            if blink > 0.96 { closing = false }
        } else {
            blink += (0 - blink) * 0.22
            if blinkTimer <= 0 { closing = true; blinkTimer = interval + CGFloat.random(in: 0...2.4) }
        }

        // Battement de lecture : une impulsion régulière dans les ressorts
        // suffit à faire danser le personnage, sans animation séparée.
        if equalizer {
            beat += dt * 2.1
            if beat >= 1 {
                beat -= 1
                danceSide = -danceSide
                velJump += 38
                velScaleX += 0.030
                velScaleY -= 0.034
                // Le pas de côté et l'inclinaison partent du même temps et
                // du même côté : c'est leur accord qui fait la danse. Les
                // dissocier donnerait deux mouvements qui se contrarient.
                velSway += 54 * danceSide
                tiltVel += 0.034 * danceSide
            }
        }

        // Balancement du salut, ou frisson d'alerte
        if Date() < waveUntil {
            tiltVel += sin(clock * 9) * 0.012
        } else if m == .alert {
            tiltVel += sin(clock * 7) * 0.004
        }
        tiltVel = (tiltVel - 0.22 * tilt) * 0.84
        tilt += tiltVel
        if abs(tilt) < 0.0005 && abs(tiltVel) < 0.0005 { tilt = 0; tiltVel = 0 }

        // Ressorts écrasement / étirement et saut, amortis en exponentielle
        let stiffness: CGFloat = 180, damping: CGFloat = 12
        velScaleX = (velScaleX + (1 - scaleX) * stiffness * dt) * exp(-damping * dt)
        scaleX += velScaleX * dt
        velScaleY = (velScaleY + (1 - scaleY) * stiffness * dt) * exp(-damping * dt)
        scaleY += velScaleY * dt
        velJump = (velJump + (0 - jump) * 160 * dt) * exp(-11 * dt)
        jump += velJump * dt
        // Ressort plus mou que celui du saut : le balancement doit traîner
        // un peu derrière le temps, comme un corps qui suit la musique.
        velSway = (velSway + (0 - sway) * 95 * dt) * exp(-8 * dt)
        sway += velSway * dt
        if !equalizer && abs(sway) < 0.05 && abs(velSway) < 0.05 { sway = 0; velSway = 0 }

        return true   // la respiration anime en continu, très légèrement
    }

    // ═══════════ Rendu ═══════════

    /// `detail` active l'ombre portée, les reflets et les effets d'humeur
    /// (tailles moyennes et grandes).
    /// L'habillage « Logo » : votre Ü, animé par calques.
    ///
    /// La même horloge et le même battement que le dessin vectoriel, pour
    /// que les deux habillages respirent au même rythme et qu'un
    /// changement de réglage ne change que l'apparence.
    ///
    /// Les billes montent et penchent, le corps se tasse. Pendant la
    /// lecture, le rebond est franc et la tête penche en mesure — c'est
    /// là que la séparation en deux calques paie.
    /// La seule entrée de dessin du compagnon.
    ///
    /// Avant, chaque vue choisissait : le panneau savait traiter
    /// l'habillage Logo, le notch non — il appelait `draw` directement et
    /// montrait donc toujours le personnage vectoriel, quel que soit le
    /// réglage. Un aiguillage dupliqué est un aiguillage qu'on oublie
    /// quelque part ; il n'y en a plus qu'un.
    func render(in rect: NSRect, detail: Bool, glowColor: NSColor) {
        if BudSprite.style == .logo && BudArt.hasCompanion {
            drawLogo(in: rect)
        } else {
            draw(in: rect, detail: detail, glowColor: glowColor)
        }
    }

    func drawLogo(in rect: NSRect) {
        let t = clock
        // Respiration au repos : un sixième du rebond de la danse, assez
        // pour qu'on voie que BUD est vivant sans qu'il s'agite.
        let breath = (sin(t * 2.3) + 1) / 2
        var bounce = breath * 0.18
        var tilt = sin(t * 0.9) * 1.2
        var squash = breath * 0.018

        if equalizer {
            // `beat` est avancé par `step()`, comme pour l'égaliseur du
            // dessin vectoriel : la danse ne dépend pas de la cadence de
            // rafraîchissement de la vue.
            let b = (sin(beat * 6.2) + 1) / 2
            bounce = 0.25 + b * 0.75
            tilt = sin(beat * 3.1) * 7
            squash = 0.02 + b * 0.085
        }
        if effectiveMood == .alert {
            // L'alerte secoue, sans monter : une alerte qui saute de joie
            // dit le contraire de ce qu'elle doit dire.
            tilt = sin(t * 18) * 5
            bounce = 0.1
        }
        if effectiveMood == .sleepy {
            bounce = breath * 0.06
            tilt = -3 + sin(t * 0.6) * 1.0
            squash = 0.03 + breath * 0.01
        }

        // Chaque humeur a son corps, et pas seulement son visage. Une
        // expression posée sur une posture qui la contredit ne se lit
        // pas : on croit au dessin le moins ambigu des deux.
        switch effectiveMood {
        case .angry:
            // Tassé, bas sur ses appuis, et il tremble. La colère
            // n'allonge pas, elle ramasse.
            bounce = 0
            tilt = sin(t * 23) * 2.6
            squash = 0.075 + breath * 0.012
        case .dizzy:
            // La tête part d'un côté puis de l'autre, en retard sur
            // elle-même : deux sinus de périodes différentes ne
            // repassent pas par le même point, et c'est ce décalage qui
            // fait le tangage.
            bounce = 0.12 + (sin(t * 3.1) + 1) / 2 * 0.22
            tilt = sin(t * 2.2) * 9 + sin(t * 3.7) * 4
            squash = 0.02 + breath * 0.02
        case .thinking:
            // Penché d'un seul côté, immobile, très légèrement relevé.
            // L'inclinaison est lente et asymétrique : on ne réfléchit
            // pas en balançant la tête en cadence.
            bounce = 0.05 + breath * 0.05
            tilt = -6.5 + sin(t * 0.45) * 1.6
            squash = breath * 0.01
        case .listening:
            // Dressé et droit. Les billes montent au rythme du visage,
            // comme deux antennes qui captent : c'est le seul mouvement,
            // et il suffit parce qu'il est régulier.
            bounce = 0.30 + (sin(t * 5.2) + 1) / 2 * 0.30
            tilt = 0
            squash = 0
        case .speaking:
            // Un léger balancement, de l'amplitude d'une conversation.
            // Le corps accompagne la bouche sans la concurrencer.
            bounce = 0.10 + (sin(t * 7.4) + 1) / 2 * 0.14
            tilt = sin(t * 2.6) * 2.2
            squash = 0.01 + breath * 0.012
        case .proud:
            // Haut sur ses appuis, et un rebond lent. La fierté se tient
            // droite ; elle ne saute pas, elle se redresse.
            bounce = 0.55 + (sin(t * 2.4) + 1) / 2 * 0.45
            tilt = sin(t * 1.1) * 1.4
            squash = 0
        case .sad:
            // Tassé, penché, immobile. C'est la posture qui porte la
            // tristesse — le visage seul, sur un corps qui respire
            // normalement, se lirait comme une grimace passagère.
            bounce = 0
            tilt = -4.0 + sin(t * 0.5) * 0.8
            squash = 0.09 + breath * 0.008
        case .confused:
            // La tête penche d'un côté puis de l'autre, lentement, sans
            // jamais s'arrêter au milieu : c'est l'hésitation.
            bounce = 0.08 + breath * 0.06
            tilt = sin(t * 1.3) * 7.5
            squash = breath * 0.012
        default:
            break
        }

        let side = min(rect.width, rect.height)
        // L'illustration est plus haute que large : on l'inscrit sur la
        // hauteur, centrée, pour qu'elle ne se déforme jamais.
        let h = side * 0.96
        let w = h * 0.878          // 253 / 288, le rapport des calques
        let box = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2,
                         width: w, height: h)
        BudArt.drawCompanion(in: box, beat: bounce, tilt: tilt, squash: squash,
                             mood: effectiveMood, clock: t)
    }

    func draw(in rect: NSRect, detail: Bool, glowColor: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let m = effectiveMood
        let premium = BudSprite.style == .premium
        let s = min(rect.width, rect.height) * 0.80
        let t = clock

        // Respiration : flottement vertical et dilatation croisée
        let floatY = sin(t * 2.3) * (s * 0.032)
        let breathX = 1 + sin(t * 2.3 - 0.6) * 0.014
        let breathY = 1 - sin(t * 2.3 - 0.6) * 0.014

        // Tremblement de colère
        let shakeX: CGFloat = m == .alert ? sin(t * 42) * (s * 0.0075) : 0
        let shakeY: CGFloat = m == .alert ? cos(t * 37) * (s * 0.0048) : 0

        let cx = rect.midX
        let cy = rect.midY

        // ── Ombre au sol, qui se resserre quand le compagnon monte ──
        if detail {
            let lift = floatY + jump
            let hf = max(0.7, min(1.2, 1 - lift / (s * 0.25)))
            let sy = cy - s * 0.60
            let sw = s * 0.42 * hf
            let sh = s * 0.055 * hf
            ctx.saveGState()
            if let g = NSGradient(colors: [NSColor.black.withAlphaComponent(0.42),
                                           NSColor.black.withAlphaComponent(0)],
                                  atLocations: [0, 1], colorSpace: .deviceRGB) {
                NSBezierPath(ovalIn: NSRect(x: cx - sw, y: sy - sh,
                                            width: sw * 2, height: sh * 2)).addClip()
                g.draw(fromCenter: NSPoint(x: cx, y: sy), radius: 1,
                       toCenter: NSPoint(x: cx, y: sy), radius: sw,
                       options: [])
            }
            ctx.restoreGState()
        }

        ctx.saveGState()
        // Le balancement est en proportion de la taille : un sprite de
        // 34 pt dans le notch et un de 200 pt dans le panneau doivent
        // danser de la même façon, pas du même nombre de points.
        ctx.translateBy(x: cx + shakeX + sway * (s / 160), y: cy + floatY + jump + shakeY)
        ctx.rotate(by: tilt)
        ctx.scaleBy(x: scaleX * breathX, y: scaleY * breathY)

        // ── Halo d'ambiance : un dégradé radial, jamais un disque plein,
        //    sinon le bord net se voit sur fond sombre. ──
        // Rayon contenu dans le rectangle du sprite (s vaut 0,80 × rect) :
        // au-delà, la vue couperait le dégradé net.
        let haloR = s * (0.58 + 0.025 * sin(glow))
        let inner = s * 0.40
        let a: CGFloat = m == .alert ? 0.34 : (premium ? 0.22 : 0.16)
        if let halo = NSGradient(colors: [glowColor.withAlphaComponent(a),
                                          glowColor.withAlphaComponent(a * 0.55),
                                          glowColor.withAlphaComponent(0)],
                                 atLocations: [0, 0.45, 1], colorSpace: .deviceRGB) {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(ovalIn: NSRect(x: -haloR, y: -haloR,
                                        width: haloR * 2, height: haloR * 2)).addClip()
            halo.draw(fromCenter: .zero, radius: inner,
                      toCenter: .zero, radius: haloR, options: [])
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        if BudSprite.style == .metal {
            let eye = metalEyeColor(m == .alert ? BudSkin.rose : glowColor)
            drawMetalBody(ctx, size: s, detail: detail, t: t)
            drawMetalFace(ctx, size: s, mood: m, detail: detail, t: t, eye: eye)
        } else {
            drawBody(ctx, size: s, premium: premium, detail: detail)
            drawFace(ctx, size: s, mood: m, premium: premium, detail: detail, t: t)
        }

        ctx.restoreGState()
    }

    // ═══════════ Habillage métal ═══════════
    //
    //  Une tête autonome : coque ardoise, cadre argenté, écran facial
    //  sombre et yeux carrés lumineux. Le prototype raisonne en « radius » ;
    //  on pose r = s/1,92 pour que la coque ait exactement la largeur du
    //  squircle blanc, et les trois habillages gardent la même empreinte.

    private func metalR(_ s: CGFloat) -> CGFloat { s / 1.92 }

    private func drawMetalBody(_ ctx: CGContext, size s: CGFloat, detail: Bool, t: CGFloat) {
        let r = metalR(s)
        let shellW = r * 1.92, shellH = r * 1.72
        // Canvas : le haut de la coque est à -0,46·h, elle est donc
        // décalée vers le bas. En AppKit, le centre descend de 0,04·h.
        let shellRect = NSRect(x: -shellW / 2, y: -shellH / 2 - shellH * 0.04,
                               width: shellW, height: shellH)
        let shellR = r * 0.52

        let shell = NSBezierPath(roundedRect: shellRect, xRadius: shellR, yRadius: shellR)
        if let g = NSGradient(colors: [BudSkin.shellSlateHi, BudSkin.shellSlate,
                                       BudSkin.shellSlateLo],
                              atLocations: [0, 0.5, 1], colorSpace: .deviceRGB) {
            g.draw(in: shell, angle: -55)
        } else {
            BudSkin.shellSlate.setFill()
            shell.fill()
        }

        // Cadre argenté
        let bezelRect = NSRect(x: shellRect.minX + r * 0.13,
                               y: shellRect.minY + r * 0.14,
                               width: shellRect.width - r * 0.26,
                               height: shellRect.height - r * 0.27)
        let bezelR = shellR * 0.84
        let bezel = NSBezierPath(roundedRect: bezelRect, xRadius: bezelR, yRadius: bezelR)
        if let g = NSGradient(colors: [BudSkin.bezelHi, BudSkin.bezel, BudSkin.bezelLo],
                              atLocations: [0, 0.5, 1], colorSpace: .deviceRGB) {
            g.draw(in: bezel, angle: -55)
        } else {
            BudSkin.bezel.setFill()
            bezel.fill()
        }

        // Écran facial
        let th = r * 0.055
        let screenRect = bezelRect.insetBy(dx: th, dy: th)
        let screenR = max(3, bezelR - th)
        let screen = NSBezierPath(roundedRect: screenRect, xRadius: screenR, yRadius: screenR)
        ctx.saveGState()
        screen.addClip()
        if let g = NSGradient(colors: [BudSkin.screenHi, BudSkin.screen],
                              atLocations: [0, 1], colorSpace: .deviceRGB) {
            g.draw(fromCenter: NSPoint(x: 0, y: r * 0.05), radius: r * 0.08,
                   toCenter: .zero, radius: r * 0.95, options: [])
        } else {
            BudSkin.screen.setFill()
            screen.fill()
        }

        // Balayage lumineux lent, uniquement en grand format
        if detail {
            let phase = (t * 0.2).truncatingRemainder(dividingBy: 1)
            let x = -shellW * 0.85 + (shellW * 1.70) * phase
            if let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0),
                                               NSColor.white.withAlphaComponent(0.10),
                                               NSColor.white.withAlphaComponent(0)],
                                      atLocations: [0, 0.5, 1], colorSpace: .deviceRGB) {
                sheen.draw(in: NSRect(x: x - shellW * 0.12, y: -shellH,
                                      width: shellW * 0.24, height: shellH * 2), angle: 0)
            }
        }
        ctx.restoreGState()

        // Capteur discret en haut de l'écran
        let sd = r * 0.072
        BudSkin.sensor.setFill()
        NSBezierPath(ovalIn: NSRect(x: -sd / 2, y: screenRect.maxY - r * 0.085 - sd / 2,
                                    width: sd, height: sd)).fill()
    }

    private func drawMetalFace(_ ctx: CGContext, size s: CGFloat, mood m: BudMood,
                               detail: Bool, t: CGFloat, eye: NSColor) {
        let r = metalR(s)
        let gx = lookX * r * 0.13
        let gy = lookY * r * 0.10

        ctx.saveGState()
        ctx.translateBy(x: gx, y: gy)

        let eyeX = r * 0.31
        let eyeY = r * 0.01            // Canvas : -0,01 → AppKit +0,01
        let eyeS = r * 0.32
        let corner = r * 0.078
        let open = max(0.08, 1 - blink * 0.92)

        switch m {
        case .calm, .sleepy, .thinking, .speaking, .confused, .sad:
            let h = m == .sleepy ? eyeS * 0.18 : eyeS * open
            metalEye(NSPoint(x: -eyeX, y: eyeY), w: eyeS, h: h, r: corner, c: eye, detail: detail)
            metalEye(NSPoint(x: eyeX * 1.04, y: eyeY + r * 0.01),
                     w: eyeS * 1.12, h: eyeS * 1.08 * (m == .sleepy ? 0.17 : open),
                     r: corner * 1.06, c: eye, detail: detail)

        case .happy, .proud:
            // Les yeux deviennent deux arcs relevés
            for (x, w) in [(-eyeX, eyeS), (eyeX * 1.04, eyeS * 1.12)] {
                let a = NSBezierPath()
                a.appendArc(withCenter: NSPoint(x: x, y: eyeY - eyeS * 0.32),
                            radius: w * 0.46, startAngle: 22, endAngle: 158)
                a.lineWidth = max(2, eyeS * 0.24)
                a.lineCapStyle = .round
                eye.setStroke()
                a.stroke()
            }
            metalMouth(arcAt: NSPoint(x: 0, y: -r * 0.34 + r * 0.02 + r * 0.04),
                       radius: r * 0.18, from: 205, to: 335,
                       width: max(2.5, r * 0.058), c: eye)

        case .wink:
            metalEye(NSPoint(x: -eyeX, y: eyeY), w: eyeS, h: eyeS * open,
                     r: corner, c: eye, detail: detail)
            let a = NSBezierPath()
            a.appendArc(withCenter: NSPoint(x: eyeX * 1.04, y: eyeY - r * 0.02 - r * 0.04),
                        radius: eyeS * 0.46, startAngle: 22, endAngle: 158)
            a.lineWidth = max(3.2, r * 0.072)
            a.lineCapStyle = .round
            eye.setStroke()
            a.stroke()
            metalMouth(arcAt: NSPoint(x: r * 0.03, y: -r * 0.34 + r * 0.015 + r * 0.03),
                       radius: r * 0.14, from: 207, to: 328,
                       width: max(2.5, r * 0.052), c: eye)

        case .alert, .angry, .listening:
            // Yeux écrasés et inclinés, sourcils rouges
            for side in [CGFloat(-1), CGFloat(1)] {
                let w = side < 0 ? eyeS : eyeS * 1.12
                let h = (side < 0 ? eyeS : eyeS * 1.08) * 0.74 * open
                let cx = side < 0 ? -eyeX : eyeX * 1.04
                let cy = side < 0 ? eyeY : eyeY + r * 0.01

                // Le Canvas tourne dans le sens horaire, AppKit l'inverse :
                // l'œil gauche (side = −1) doit donc pencher de −0,20.
                ctx.saveGState()
                ctx.translateBy(x: cx, y: cy)
                ctx.rotate(by: side * 0.20)
                metalEye(.zero, w: w, h: h, r: min(corner, h * 0.45), c: eye, detail: detail)
                ctx.restoreGState()

                ctx.saveGState()
                ctx.translateBy(x: cx, y: cy + h * 0.62 + r * 0.03)
                ctx.rotate(by: side * 0.34)
                let b = NSBezierPath()
                b.move(to: NSPoint(x: -w * 0.5, y: 0))
                b.line(to: NSPoint(x: w * 0.5, y: 0))
                b.lineWidth = max(2.5, r * 0.044)
                b.lineCapStyle = .round
                BudSkin.rose.setStroke()
                b.stroke()
                ctx.restoreGState()
            }
            metalMouth(arcAt: NSPoint(x: 0, y: -r * 0.34 - r * 0.03 - r * 0.06),
                       radius: r * 0.15, from: 36, to: 144,
                       width: max(2.5, r * 0.054), c: BudSkin.rose)
            if detail { metalAngerMark(ctx, r: r, t: t) }

        case .dizzy:
            drawSpiralEye(at: NSPoint(x: -eyeX, y: eyeY + sin(t * 7.2) * r * 0.035),
                          r: eyeS * 0.48, angle: spiral, premium: false, size: s, tint: eye)
            drawSpiralEye(at: NSPoint(x: eyeX * 1.04, y: eyeY - cos(t * 6.8) * r * 0.035),
                          r: eyeS * 0.48, angle: -spiral, premium: false, size: s, tint: eye)
            // Bouche ondulée
            let w = r * 0.26, hh = r * 0.055
            let p = NSBezierPath()
            let my = -r * 0.34 - r * 0.01
            p.move(to: NSPoint(x: -w * 0.5, y: my))
            p.curve(to: NSPoint(x: 0, y: my),
                    controlPoint1: NSPoint(x: -w * 0.333, y: my + hh * 0.667),
                    controlPoint2: NSPoint(x: -w * 0.167, y: my + hh * 0.667))
            p.curve(to: NSPoint(x: w * 0.5, y: my),
                    controlPoint1: NSPoint(x: w * 0.167, y: my - hh * 0.667),
                    controlPoint2: NSPoint(x: w * 0.333, y: my - hh * 0.667))
            p.lineWidth = max(2.2, r * 0.048)
            p.lineCapStyle = .round
            BudSkin.indigo.setStroke()
            p.stroke()
            if detail {
                metalQuestionMark(ctx, r: r, t: t)
                metalSweat(r: r)
            }
        }

        ctx.restoreGState()
    }

    private func metalEye(_ c: NSPoint, w: CGFloat, h: CGFloat, r: CGFloat,
                          c col: NSColor, detail: Bool) {
        let hh = max(1.5, h)
        let box = NSRect(x: c.x - w / 2, y: c.y - hh / 2, width: w, height: hh)
        let rad = min(r, hh * 0.45)
        let path = NSBezierPath(roundedRect: box, xRadius: rad, yRadius: rad)

        // Lueur : deux passes élargies plutôt qu'une ombre, moins coûteux
        if detail {
            for (grow, alpha) in [(w * 0.26, CGFloat(0.12)), (w * 0.13, CGFloat(0.18))] {
                let g = NSBezierPath(roundedRect: box.insetBy(dx: -grow, dy: -grow),
                                     xRadius: rad + grow, yRadius: rad + grow)
                col.withAlphaComponent(alpha).setFill()
                g.fill()
            }
        }
        col.setFill()
        path.fill()

        if detail && hh > w * 0.35 {
            NSColor.white.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: box.minX + w * 0.18,
                                             y: box.maxY - hh * 0.32 - hh * 0.20,
                                             width: w * 0.24, height: hh * 0.20),
                         xRadius: rad * 0.4, yRadius: rad * 0.4).fill()
        }
    }

    private func metalMouth(arcAt c: NSPoint, radius: CGFloat, from a0: CGFloat,
                            to a1: CGFloat, width: CGFloat, c col: NSColor) {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: radius, startAngle: a0, endAngle: a1)
        p.lineWidth = width
        p.lineCapStyle = .round
        col.setStroke()
        p.stroke()
    }

    private func metalAngerMark(_ ctx: CGContext, r: CGFloat, t: CGFloat) {
        let tx = sin(t * 38) * r * 0.018
        let ty = cos(t * 44) * r * 0.018
        let pop = 1.08 + sin(t * 12) * 0.06

        ctx.saveGState()
        ctx.translateBy(x: r * 0.56 + tx, y: r * 0.34 + ty)
        ctx.scaleBy(x: pop, y: pop)

        let rIn = r * 0.032, rOut = r * 0.095
        BudSkin.rose.setStroke()
        for i in 0..<4 {
            ctx.saveGState()
            ctx.rotate(by: CGFloat(i) * .pi / 2 + .pi / 4)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: -rOut * 0.55, y: rIn))
            p.curve(to: NSPoint(x: rOut * 0.55, y: rIn),
                    controlPoint1: NSPoint(x: -rOut * 0.1833, y: rIn * 0.667),
                    controlPoint2: NSPoint(x: rOut * 0.1833, y: rIn * 0.667))
            p.lineWidth = max(2, r * 0.035)
            p.lineCapStyle = .round
            p.stroke()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func metalQuestionMark(_ ctx: CGContext, r: CGFloat, t: CGFloat) {
        let bob = sin(t * 5.2) * r * 0.035
        ctx.saveGState()
        ctx.translateBy(x: r * 0.54, y: r * 0.33 + bob)
        ctx.rotate(by: -sin(t * 3.8) * 0.14)

        let q = r * 0.068
        BudSkin.indigo.setStroke()
        BudSkin.indigo.setFill()
        let p = NSBezierPath()
        // Canvas : arc 0,95π → 0,28π en y descendant ; ici 0,05π → 0,72π
        p.appendArc(withCenter: NSPoint(x: 0, y: q * 0.4), radius: q,
                    startAngle: 189, endAngle: 50, clockwise: true)
        p.curve(to: NSPoint(x: 0, y: -q * 0.72),
                controlPoint1: NSPoint(x: q * 0.9, y: -q * 0.45),
                controlPoint2: NSPoint(x: q * 0.6, y: -q * 0.60))
        p.line(to: NSPoint(x: 0, y: -q * 1.12))
        p.lineWidth = max(2.2, r * 0.038)
        p.lineCapStyle = .round
        p.stroke()

        let d = max(1.8, r * 0.024)
        NSBezierPath(ovalIn: NSRect(x: -d, y: -q * 1.56 - d, width: d * 2, height: d * 2)).fill()
        ctx.restoreGState()
    }

    private func metalSweat(r: CGFloat) {
        let xs: [CGFloat] = [0.26, 0.34, 0.21]
        let ys: [CGFloat] = [0.25, 0.17, 0.17]
        for i in 0..<3 {
            let p0 = drops[i]
            let fade: CGFloat = p0 < 0.2 ? p0 / 0.2 : (p0 > 0.78 ? (1 - p0) / 0.22 : 1)
            let x = xs[i] * r * 1.25
            let y = ys[i] * r * 0.75 - p0 * r * 0.16
            let rr = r * 0.04 * dropSize[i]

            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: y + rr * 1.4))
            p.curve(to: NSPoint(x: x, y: y - rr),
                    controlPoint1: NSPoint(x: x + rr, y: y + rr * 0.1),
                    controlPoint2: NSPoint(x: x + rr * 0.9, y: y - rr))
            p.curve(to: NSPoint(x: x, y: y + rr * 1.4),
                    controlPoint1: NSPoint(x: x - rr * 0.9, y: y - rr),
                    controlPoint2: NSPoint(x: x - rr, y: y + rr * 0.1))
            p.close()
            NSColor(calibratedRed: 0.220, green: 0.741, blue: 0.972,
                    alpha: max(0, min(1, fade))).setFill()
            p.fill()
        }
    }

    // ── Le corps ──

    private func drawBody(_ ctx: CGContext, size s: CGFloat, premium: Bool, detail: Bool) {
        let half = s / 2

        if !premium {
            // Style à plat : coque blanche et liseré interne.
            // Le prototype appelle ctx.translate() APRÈS avoir construit le
            // chemin ; en Canvas cela ne déplace rien, le tracé est déjà figé
            // en espace écran. Le liseré est donc centré, pas décalé.
            let body = squirclePath(size: s, radiusRatio: 0.30)
            BudSkin.shell.setFill()
            body.fill()

            ctx.saveGState()
            body.addClip()
            let ring = squirclePath(size: s, radiusRatio: 0.30)
            ring.lineWidth = s * 0.065
            BudSkin.shellEdge.setStroke()
            ring.stroke()
            ctx.restoreGState()

            // Liseré discret : sans lui, le blanc disparaît en thème clair.
            if !TH.dark {
                body.lineWidth = max(0.8, s * 0.010)
                NSColor(calibratedWhite: 0.62, alpha: 0.30).setStroke()
                body.stroke()
            }
            return
        }

        // Style nacré-or : cadre champagne, coque nacrée, reflet, signature.
        let outer = squirclePath(size: s * 1.045, radiusRatio: 0.31)
        if let g = NSGradient(colors: [BudSkin.goldHi, BudSkin.goldMid,
                                       BudSkin.pearlHi, BudSkin.goldLo, BudSkin.goldHi],
                              atLocations: [0, 0.32, 0.55, 0.82, 1], colorSpace: .deviceRGB) {
            g.draw(in: outer, angle: -45)
        } else {
            BudSkin.goldMid.setFill()
            outer.fill()
        }
        outer.lineWidth = 1.5
        NSColor(calibratedRed: 1, green: 0.973, blue: 0.922, alpha: 0.65).setStroke()
        outer.stroke()

        let inner = squirclePath(size: s * 0.94, radiusRatio: 0.295)
        ctx.saveGState()
        inner.addClip()
        if let g = NSGradient(colors: [BudSkin.pearlHi, BudSkin.pearlMid, BudSkin.pearlLo],
                              atLocations: [0, 0.65, 1], colorSpace: .deviceRGB) {
            g.draw(fromCenter: NSPoint(x: -s * 0.14, y: s * 0.18), radius: s * 0.05,
                   toCenter: NSPoint(x: 0, y: 0), radius: s * 0.72, options: [])
        } else {
            BudSkin.pearlMid.setFill()
            inner.fill()
        }

        // Reflet spéculaire en haut de la coque
        if let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.70),
                                           NSColor.white.withAlphaComponent(0)],
                                  atLocations: [0, 1], colorSpace: .deviceRGB) {
            sheen.draw(in: NSRect(x: -half, y: half - half * 0.85,
                                  width: s, height: half * 0.85), angle: -90)
        }
        ctx.restoreGState()

        // Signature discrète, comme sur le modèle
        if detail {
            let f = NSFont(name: "Georgia-Bold", size: s * 0.068)
                ?? NSFont.boldSystemFont(ofSize: s * 0.068)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: f,
                .foregroundColor: NSColor(calibratedRed: 0.749, green: 0.596,
                                          blue: 0.416, alpha: 0.75)
            ]
            let str = NSAttributedString(string: "BUD", attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: -sz.width / 2, y: -s * 0.355 - sz.height / 2))
        }
    }

    // ── Le visage ──

    private func drawFace(_ ctx: CGContext, size s: CGFloat, mood m: BudMood,
                          premium: Bool, detail: Bool, t: CGFloat) {
        let ink = premium ? BudSkin.inkWarm : BudSkin.ink
        // Le regard déplace les traits de quelques points seulement.
        let gx = lookX * s * 0.042
        let gy = lookY * s * 0.036

        // Joues, légèrement en retrait du regard
        drawCheeks(size: s, gx: gx, gy: gy, premium: premium, t: t)

        ctx.saveGState()
        ctx.translateBy(x: gx, y: gy)

        let eyeX = s * 0.145
        let eyeY = -s * 0.012          // Canvas : +0,012 vers le bas
        let eyeR = s * 0.044

        switch m {
        case .calm, .thinking, .speaking, .confused, .sad:
            drawRoundEye(at: NSPoint(x: -eyeX, y: eyeY), r: eyeR, premium: premium, detail: detail)
            drawRoundEye(at: NSPoint(x: eyeX, y: eyeY), r: eyeR, premium: premium, detail: detail)
            drawOMouth(size: s, y: -s * 0.125, w: s * 0.042, h: s * 0.056,
                       ink: ink, premium: premium)

        case .happy, .proud:
            drawRoundEye(at: NSPoint(x: -eyeX, y: eyeY), r: eyeR, premium: premium, detail: detail)
            drawRoundEye(at: NSPoint(x: eyeX, y: eyeY), r: eyeR, premium: premium, detail: detail)
            drawBigSmile(size: s, premium: premium, ink: ink)

        case .wink:
            drawRoundEye(at: NSPoint(x: -eyeX, y: eyeY), r: eyeR, premium: premium, detail: detail)
            // Œil droit fermé : arc qui bombe vers le haut
            let lid = NSBezierPath()
            lid.appendArc(withCenter: NSPoint(x: eyeX, y: eyeY - s * 0.008),
                          radius: eyeR * 1.15, startAngle: 20, endAngle: 160)
            lid.lineWidth = s * 0.021
            lid.lineCapStyle = .round
            (premium ? BudSkin.smileGold : ink).setStroke()
            lid.stroke()
            // Petit sourire courbe
            let sm = NSBezierPath()
            sm.appendArc(withCenter: NSPoint(x: 0, y: -s * 0.098),
                         radius: s * 0.055, startAngle: 200, endAngle: 340)
            sm.lineWidth = s * 0.021
            sm.lineCapStyle = .round
            (premium ? BudSkin.smileGold : ink).setStroke()
            sm.stroke()

        case .alert, .angry, .listening:
            drawAngryEyes(size: s, eyeX: eyeX, eyeY: eyeY, r: eyeR,
                          ink: ink, premium: premium)
            // Bouche en moue : arc qui bombe vers le haut
            let mo = NSBezierPath()
            mo.appendArc(withCenter: NSPoint(x: 0, y: -s * 0.138 - s * 0.028),
                         radius: s * 0.052, startAngle: 20, endAngle: 160)
            mo.lineWidth = s * 0.021
            mo.lineCapStyle = .round
            ink.setStroke()
            mo.stroke()
            if detail { drawAngerSymbol(size: s, t: t) }

        case .dizzy:
            drawSpiralEye(at: NSPoint(x: -eyeX, y: eyeY), r: eyeR * 1.25,
                          angle: spiral, premium: premium, size: s)
            drawSpiralEye(at: NSPoint(x: eyeX, y: eyeY), r: eyeR * 1.25,
                          angle: -spiral, premium: premium, size: s)
            drawOMouth(size: s, y: -s * 0.132, w: s * 0.044, h: s * 0.054,
                       ink: ink, premium: premium)
            if detail { drawSweat(size: s, premium: premium) }

        case .sleepy:
            // Paupières tombantes : deux arcs qui bombent vers le bas
            for dx in [-eyeX, eyeX] {
                let p = NSBezierPath()
                p.appendArc(withCenter: NSPoint(x: dx, y: eyeY + s * 0.004),
                            radius: eyeR * 1.05, startAngle: 200, endAngle: 340)
                p.lineWidth = s * 0.020
                p.lineCapStyle = .round
                ink.withAlphaComponent(0.85).setStroke()
                p.stroke()
            }
            let p = NSBezierPath()
            p.move(to: NSPoint(x: -s * 0.030, y: -s * 0.125))
            p.line(to: NSPoint(x: s * 0.030, y: -s * 0.125))
            p.lineWidth = s * 0.020
            p.lineCapStyle = .round
            ink.withAlphaComponent(0.85).setStroke()
            p.stroke()
        }

        ctx.restoreGState()
    }

    // ── Pièces du visage ──

    private func drawCheeks(size s: CGFloat, gx: CGFloat, gy: CGFloat,
                            premium: Bool, t: CGFloat) {
        let pulse = 1 + sin(t * 3.2) * 0.045
        let ox = s * 0.235 + gx * 0.45
        let oy = -s * 0.095 + gy * 0.45
        let rx = s * 0.072 * pulse
        let ry = s * 0.041 * pulse

        for side in [CGFloat(-1), CGFloat(1)] {
            let box = NSRect(x: side * ox - rx, y: oy - ry, width: rx * 2, height: ry * 2)
            if premium {
                let path = NSBezierPath(ovalIn: box.insetBy(dx: -rx * 0.05, dy: -ry * 0.10))
                NSGraphicsContext.current?.saveGraphicsState()
                path.addClip()
                if let g = NSGradient(colors: [NSColor(calibratedRed: 0.973, green: 0.812,
                                                       blue: 0.761, alpha: 1),
                                               BudSkin.blushWarm,
                                               NSColor(calibratedRed: 0.773, green: 0.510,
                                                       blue: 0.447, alpha: 1)],
                                      atLocations: [0, 0.65, 1], colorSpace: .deviceRGB) {
                    g.draw(fromCenter: NSPoint(x: side * ox - rx * 0.25, y: oy + ry * 0.3),
                           radius: rx * 0.1,
                           toCenter: NSPoint(x: side * ox, y: oy), radius: rx * 1.1,
                           options: [])
                }
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                BudSkin.blush.setFill()
                NSBezierPath(ovalIn: box).fill()
            }
        }
    }

    private func drawRoundEye(at c: NSPoint, r: CGFloat, premium: Bool, detail: Bool) {
        if blink > 0.85 {
            // Œil fermé : arc doux qui bombe vers le bas
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r * 0.9, startAngle: 200, endAngle: 340)
            p.lineWidth = r * 0.42
            p.lineCapStyle = .round
            (premium ? BudSkin.inkWarm : BudSkin.ink).setStroke()
            p.stroke()
            return
        }

        let open = max(0.12, 1 - blink * 0.9)
        let rr = premium ? r * 1.05 : r
        let box = NSRect(x: c.x - rr, y: c.y - rr * open, width: rr * 2, height: rr * 2 * open)

        if premium {
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(ovalIn: box).addClip()
            if let g = NSGradient(colors: [NSColor(calibratedRed: 0.349, green: 0.306,
                                                   blue: 0.275, alpha: 1),
                                           NSColor(calibratedRed: 0.141, green: 0.118,
                                                   blue: 0.102, alpha: 1),
                                           NSColor(calibratedRed: 0.071, green: 0.059,
                                                   blue: 0.051, alpha: 1)],
                                  atLocations: [0, 0.45, 1], colorSpace: .deviceRGB) {
                g.draw(fromCenter: NSPoint(x: c.x - rr * 0.3, y: c.y + rr * 0.3 * open),
                       radius: rr * 0.1,
                       toCenter: NSPoint(x: c.x, y: c.y), radius: rr, options: [])
            }
            NSGraphicsContext.current?.restoreGraphicsState()
            if open > 0.5 {
                NSColor(calibratedRed: 1, green: 0.980, blue: 0.941, alpha: 0.85).setFill()
                let g = rr * 0.24
                NSBezierPath(ovalIn: NSRect(x: c.x - rr * 0.32 - g,
                                            y: c.y + (rr * 0.32 - g) * open,
                                            width: g * 2, height: g * 2 * open)).fill()
            }
        } else {
            BudSkin.ink.setFill()
            NSBezierPath(ovalIn: box).fill()
            if open > 0.6 && detail {
                NSColor.white.withAlphaComponent(0.72).setFill()
                let g = rr * 0.26
                NSBezierPath(ovalIn: NSRect(x: c.x - rr * 0.30 - g,
                                            y: c.y + (rr * 0.30 - g) * open,
                                            width: g * 2, height: g * 1.5 * open)).fill()
            }
        }
    }

    /// Bouche en « O » avec la langue rose, le trait du compagnon standard.
    private func drawOMouth(size s: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                            ink: NSColor, premium: Bool) {
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: -w, y: y - h, width: w * 2, height: h * 2)).fill()

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: -w * 0.78, y: y - h * 0.80,
                                    width: w * 1.56, height: h * 1.60)).addClip()
        (premium ? BudSkin.tongueWarm : BudSkin.tongue).setFill()
        NSBezierPath(ovalIn: NSRect(x: -w * 0.72, y: y - h * 0.38 - h * 0.52,
                                    width: w * 1.44, height: h * 1.04)).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// Grand sourire ouvert en demi-lune.
    private func drawBigSmile(size s: CGFloat, premium: Bool, ink: NSColor) {
        let r = s * 0.072
        let c = NSPoint(x: 0, y: -s * 0.095)
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: 191, endAngle: 349)
        p.close()

        if premium {
            NSGraphicsContext.current?.saveGraphicsState()
            p.addClip()
            if let g = NSGradient(colors: [NSColor(calibratedRed: 0.961, green: 0.839,
                                                   blue: 0.576, alpha: 1),
                                           BudSkin.smileGold,
                                           NSColor(calibratedRed: 0.953, green: 0.808,
                                                   blue: 0.518, alpha: 1)],
                                  atLocations: [0, 0.5, 1], colorSpace: .deviceRGB) {
                g.draw(in: p, angle: -45)
            }
            NSGraphicsContext.current?.restoreGraphicsState()
            p.lineWidth = s * 0.014
            BudSkin.smileEdge.setStroke()
            p.stroke()
        } else {
            NSColor.white.setFill()
            p.fill()
            p.lineWidth = s * 0.018
            p.lineJoinStyle = .round
            ink.setStroke()
            p.stroke()
        }
    }

    private func drawAngryEyes(size s: CGFloat, eyeX: CGFloat, eyeY: CGFloat, r: CGFloat,
                              ink: NSColor, premium: Bool) {
        let lidColor = premium ? BudSkin.pearlMid : NSColor.white
        for side in [CGFloat(-1), CGFloat(1)] {
            let c = NSPoint(x: side * eyeX, y: eyeY - s * 0.008)

            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - r * 0.95, y: c.y - r * 0.95,
                                        width: r * 1.9, height: r * 1.9)).fill()

            // Paupière supérieure inclinée, de la couleur de la coque
            let ctxg = NSGraphicsContext.current
            ctxg?.saveGraphicsState()
            let tr = NSAffineTransform()
            tr.translateX(by: c.x, yBy: c.y)
            tr.rotate(byRadians: side * 0.35)
            tr.concat()
            lidColor.setFill()
            NSBezierPath(rect: NSRect(x: -r * 1.3, y: r * 0.50,
                                      width: r * 2.6, height: r * 0.95)).fill()
            ctxg?.restoreGraphicsState()

            // Sourcil froncé
            ctxg?.saveGraphicsState()
            let tb = NSAffineTransform()
            tb.translateX(by: c.x, yBy: eyeY + r * 1.15)
            tb.rotate(byRadians: side * 0.38)
            tb.concat()
            let br = NSBezierPath()
            br.move(to: NSPoint(x: -r * 1.05, y: 0))
            br.line(to: NSPoint(x: r * 1.05, y: 0))
            br.lineWidth = s * 0.021
            br.lineCapStyle = .round
            ink.setStroke()
            br.stroke()
            ctxg?.restoreGraphicsState()
        }
    }

    private func drawAngerSymbol(size s: CGFloat, t: CGFloat) {
        let pulse = 1 + sin(t * 10) * 0.12
        let ctxg = NSGraphicsContext.current
        ctxg?.saveGraphicsState()
        let tr = NSAffineTransform()
        tr.translateX(by: s * 0.25, yBy: s * 0.24)
        tr.scale(by: pulse)
        tr.concat()

        let rIn = s * 0.022, rOut = s * 0.058
        BudSkin.anger.setStroke()
        for i in 0..<4 {
            let inner = NSGraphicsContext.current
            inner?.saveGraphicsState()
            let rot = NSAffineTransform()
            rot.rotate(byRadians: CGFloat(i) * .pi / 2 + .pi / 4)
            rot.concat()
            // Quadratique du prototype convertie en cubique :
            // C1 = P0 + ⅔(Q−P0), C2 = P2 + ⅔(Q−P2).
            let p = NSBezierPath()
            p.move(to: NSPoint(x: -rOut * 0.55, y: rIn))
            p.curve(to: NSPoint(x: rOut * 0.55, y: rIn),
                    controlPoint1: NSPoint(x: -rOut * 0.1833, y: rIn * 0.70),
                    controlPoint2: NSPoint(x: rOut * 0.1833, y: rIn * 0.70))
            p.lineWidth = s * 0.022
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
            inner?.restoreGraphicsState()
        }
        ctxg?.restoreGraphicsState()
    }

    private func drawSpiralEye(at c: NSPoint, r: CGFloat, angle: CGFloat,
                               premium: Bool, size s: CGFloat, tint: NSColor? = nil) {
        let ctxg = NSGraphicsContext.current
        ctxg?.saveGraphicsState()
        let tr = NSAffineTransform()
        tr.translateX(by: c.x, yBy: c.y)
        tr.rotate(byRadians: angle)
        tr.concat()

        let p = NSBezierPath()
        let turns: CGFloat = 2.4
        let steps = 48
        for i in 0...steps {
            let prog = CGFloat(i) / CGFloat(steps)
            let theta = prog * turns * .pi * 2
            let rad = prog * r * 1.35
            let pt = NSPoint(x: cos(theta) * rad, y: sin(theta) * rad)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.lineWidth = r * 0.22
        p.lineCapStyle = .round
        (tint ?? (premium ? NSColor(calibratedRed: 0.227, green: 0.196, blue: 0.176, alpha: 1)
                          : BudSkin.ink)).setStroke()
        p.stroke()
        ctxg?.restoreGraphicsState()
    }

    private func drawSweat(size s: CGFloat, premium: Bool) {
        let xs: [CGFloat] = [0.27, 0.34, 0.22]
        let ys: [CGFloat] = [0.28, 0.21, 0.22]
        for i in 0..<3 {
            let cycle = drops[i]
            let alpha: CGFloat = cycle < 0.2 ? cycle / 0.2
                               : (cycle > 0.75 ? (1 - cycle) / 0.25 : 1)
            let dy = cycle * s * 0.09
            let r = s * 0.022 * dropSize[i]
            let px = xs[i] * s
            let py = ys[i] * s - dy        // Canvas : la goutte descend

            let ctxg = NSGraphicsContext.current
            ctxg?.saveGraphicsState()
            let tr = NSAffineTransform()
            tr.translateX(by: px, yBy: py)
            tr.concat()

            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: r * 1.45))
            p.curve(to: NSPoint(x: 0, y: -r * 1.1),
                    controlPoint1: NSPoint(x: r * 1.1, y: r * 0.1),
                    controlPoint2: NSPoint(x: r * 1.0, y: -r * 1.1))
            p.curve(to: NSPoint(x: 0, y: r * 1.45),
                    controlPoint1: NSPoint(x: -r * 1.0, y: -r * 1.1),
                    controlPoint2: NSPoint(x: -r * 1.1, y: r * 0.1))
            p.close()

            let a = max(0, min(1, alpha))
            if premium {
                NSGraphicsContext.current?.saveGraphicsState()
                p.addClip()
                if let g = NSGradient(colors: [NSColor.white.withAlphaComponent(a),
                                               NSColor(calibratedRed: 0.596, green: 0.667,
                                                       blue: 0.722, alpha: a)],
                                      atLocations: [0, 1], colorSpace: .deviceRGB) {
                    g.draw(in: NSRect(x: -r * 1.2, y: -r * 1.5,
                                      width: r * 2.4, height: r * 3), angle: -45)
                }
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                BudSkin.sweat.withAlphaComponent(a).setFill()
                p.fill()
                p.lineWidth = s * 0.011
                BudSkin.ink.withAlphaComponent(a).setStroke()
                p.stroke()
            }
            ctxg?.restoreGraphicsState()
        }
    }
}
