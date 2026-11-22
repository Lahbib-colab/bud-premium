import Cocoa

// ═══════════════════════════════════════════════════════════
//  La charte, en code
//
//  Un système de design n'est pas une liste de règles écrites
//  quelque part : c'est le fait qu'il n'existe qu'un seul
//  endroit d'où sortent les valeurs. Tant qu'un rayon de 12
//  peut être tapé à la main dans un panneau, il finira par
//  valoir 13 dans un autre, et aucune relecture ne rattrapera
//  cela durablement.
//
//  Ce fichier est donc cet endroit unique. Les primitives
//  partagées — GlassButton, les cartes, la barre segmentée,
//  l'entête, les tuiles, les interrupteurs — y puisent, et
//  comme elles servent dans les seize panneaux, Compagnon,
//  Chat, Agents et Courrier compris, la cohérence n'est pas
//  à maintenir : elle est structurelle.
//
//  BUD est une application AppKit : il n'y a pas de CSS ici,
//  et une feuille de style n'aurait rien à styler. Les jetons
//  en tiennent lieu, avec le même rôle — nommer les valeurs
//  une fois, les employer partout.
// ═══════════════════════════════════════════════════════════

// ───────────────────────────────────────────────────────────
//  Espacement
//
//  Une échelle géométrique de base 4. Les valeurs intermédiaires
//  n'existent pas : un espace de 10 points dans une interface
//  réglée sur 8 et 12 ne se remarque pas isolément, mais trois
//  d'entre eux suffisent à donner cette impression de à-peu-près
//  qu'on n'arrive plus à nommer.
// ───────────────────────────────────────────────────────────

enum Space {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let s:   CGFloat = 8
    static let m:   CGFloat = 12
    static let l:   CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32

    /// L'écart entre un intertitre et le groupe qu'il annonce,
    /// et celui entre deux groupes. Le second est plus grand que
    /// le premier : c'est cette différence qui dit au regard
    /// lesquels vont ensemble.
    static let withinGroup: CGFloat = s
    static let betweenGroups: CGFloat = m
}

// ───────────────────────────────────────────────────────────
//  Rayons
// ───────────────────────────────────────────────────────────

enum Radius {
    static let xs: CGFloat = 6     // étiquettes, puces
    static let s:  CGFloat = 10    // champs, petites cartes
    static let m:  CGFloat = 13    // cartes de contenu
    static let l:  CGFloat = 16    // panneaux
    static let xl: CGFloat = 20    // entêtes

    /// Entièrement arrondi. Les boutons de BUD sont des capsules :
    /// c'est le seul rayon qui ne change pas d'aspect avec la
    /// hauteur, donc le seul qui reste identique d'un bouton de
    /// 28 points à un bouton de 56.
    static func pill(_ height: CGFloat) -> CGFloat { height / 2 }
}

// ───────────────────────────────────────────────────────────
//  Typographie
//
//  Six rôles, et des graisses franchement contrastées : gras
//  pour les grandes tailles, demi-gras pour les moyennes,
//  normal pour les petites. Le contraste de graisse fait la
//  hiérarchie bien mieux que le contraste de taille, et il
//  survit aux écrans à faible densité, où deux points d'écart
//  ne se distinguent plus.
//
//  Les chiffres qui changent — heures, pourcentages, volumes —
//  passent en chasse fixe : sinon la valeur tremble à chaque
//  mise à jour, un « 1 » étant plus étroit qu'un « 8 ».
// ───────────────────────────────────────────────────────────

enum Typo {
    typealias Role = (size: CGFloat, weight: NSFont.Weight)

    static let display: Role = (22,   .bold)       // titre d'entête
    static let title:   Role = (17,   .bold)       // titre de carte
    static let heading: Role = (13.5, .semibold)   // sous-titre, expéditeur
    static let body:    Role = (12.5, .medium)     // texte courant
    static let caption: Role = (11,   .regular)    // légende, aide
    static let micro:   Role = (9.5,  .bold)       // intertitre, en capitales

    /// Opacités du texte, du plus affirmé au plus discret.
    enum Ink {
        static let strong:  CGFloat = 1.00
        static let normal:  CGFloat = 0.78
        static let muted:   CGFloat = 0.55
        static let faint:   CGFloat = 0.38
        static let ghost:   CGFloat = 0.26
    }
}

// ───────────────────────────────────────────────────────────
//  Mouvement
//
//  Trois durées, pas davantage. Une interface où chaque
//  transition a sa propre durée paraît hésitante, alors même
//  que chaque animation prise séparément semble correcte.
//
//  Les courbes ne sont pas symétriques : ce qui apparaît
//  démarre vite et ralentit, ce qui disparaît fait l'inverse.
//  Une sortie lente donne l'impression que l'application
//  réfléchit avant d'obéir.
// ───────────────────────────────────────────────────────────

enum Motion {
    static let quick: TimeInterval = 0.12   // survol, pression
    static let base:  TimeInterval = 0.22   // bascule, apparition
    static let slow:  TimeInterval = 0.38   // ouverture de panneau

    /// 60 images par seconde, le pas des animations dessinées à la main.
    static let frame: TimeInterval = 1.0 / 60

    static var enter: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 0.90, 0.28, 1.0)
    }
    static var exit: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.40, 0.0, 0.70, 0.30)
    }

    /// Approche exponentielle d'une cible, indépendante de la cadence.
    /// `rate` est la fraction de l'écart rattrapée en une seconde.
    static func ease(_ value: CGFloat, to target: CGFloat,
                     rate: CGFloat, dt: CGFloat) -> CGFloat {
        value + (target - value) * (1 - exp(-rate * dt))
    }
}

// ───────────────────────────────────────────────────────────
//  Matières
//
//  Le verre dépoli de BUD tient en quatre couches, toujours
//  dans cet ordre : le fond translucide, le reflet spéculaire
//  en haut, le liseré qui s'éteint vers le bas, et l'ombre
//  portée. Les intervertir donne du plastique.
//
//  La valeur la plus importante est la plus discrète : les
//  fonds portent une pointe de bleu. Un gris parfaitement
//  neutre sur fond sombre paraît sale ; deux pour cent de
//  bleu suffisent à le rendre calme, sans qu'on puisse dire
//  pourquoi.
// ───────────────────────────────────────────────────────────

enum Surface {
    /// Niveaux d'élévation. 0 est le panneau lui-même, 3 un
    /// élément survolé qui se détache.
    static func fill(_ level: Int) -> NSColor {
        let a: CGFloat
        switch level {
        case 0:  a = 0.040
        case 1:  a = 0.065
        case 2:  a = 0.095
        default: a = 0.130
        }
        return tinted(a)
    }

    /// Le liseré d'une surface au repos.
    static func stroke(_ level: Int) -> NSColor {
        tinted(level >= 2 ? 0.14 : 0.085)
    }

    /// Le gris bleuté commun à toutes les surfaces.
    private static func tinted(_ a: CGFloat) -> NSColor {
        TH.dark
            ? NSColor(calibratedRed: 0.76, green: 0.82, blue: 0.95, alpha: a)
            : NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.20, alpha: a * 0.88)
    }

    /// Force du reflet selon l'élévation.
    static func specularStrength(_ level: Int, hover: CGFloat = 0) -> CGFloat {
        (level >= 2 ? 0.22 : 0.14) + 0.10 * hover
    }
    static func rimStrength(_ level: Int) -> CGFloat {
        level >= 2 ? 0.34 : 0.22
    }
}

// ───────────────────────────────────────────────────────────
//  Le dessin d'une surface de verre
//
//  Une seule fonction pour toutes les cartes et tous les
//  boutons. C'est elle qui garantit qu'un bouton du Courrier
//  et une carte du Chat réagissent à la lumière de la même
//  façon — non par discipline, mais parce qu'il n'y a qu'un
//  seul code qui les dessine.
// ───────────────────────────────────────────────────────────

func drawGlass(in rect: NSRect, radius: CGFloat, level: Int,
               hover: CGFloat = 0, tint: NSColor? = nil) {
    let r = rect.insetBy(dx: 0.5, dy: 0.5)
    guard r.width > 1, r.height > 1 else { return }
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

    // 1. Le fond, légèrement dégradé : deux pour cent d'écart entre le
    //    haut et le bas suffisent à ce qu'une surface ait du corps.
    let base = Surface.fill(level)
    let lift = base.withAlphaComponent(min(1, base.alphaComponent + 0.025 + 0.03 * hover))
    if let g = NSGradient(starting: lift, ending: base) {
        g.draw(in: path, angle: -90)
    } else {
        base.setFill(); path.fill()
    }

    // 2. La teinte, s'il y en a une, posée par-dessus sans masquer le fond.
    if let t = tint {
        t.withAlphaComponent(0.16 + 0.08 * hover).setFill()
        path.fill()
    }

    // 3. Reflet puis liseré, dans cet ordre.
    specular(path, r, strength: Surface.specularStrength(level, hover: hover))
    rim(path, r, color: tint ?? NSColor.white, strength: Surface.rimStrength(level))

    // 4. Le contour de base, qui ferme la forme là où le liseré s'est éteint.
    Surface.stroke(level).setStroke()
    path.lineWidth = 1
    path.stroke()
}

// ───────────────────────────────────────────────────────────
//  La carte
//
//  `mkCard` rendait une NSView dont on colorait le calque.
//  Elle rend maintenant une carte qui se dessine, donc qui
//  relit le thème à chaque affichage : le changement de thème
//  ne peut plus la laisser avec une couleur périmée, et toutes
//  les cartes de l'application héritent du verre d'un coup.
// ───────────────────────────────────────────────────────────

final class GlassCard: NSView {
    var radius: CGFloat = Radius.m { didSet { needsDisplay = true } }
    var level: Int = 1 { didSet { needsDisplay = true } }
    var tint: NSColor? { didSet { needsDisplay = true } }

    init(frame: NSRect, radius: CGFloat, level: Int) {
        self.radius = radius
        self.level = level
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        drawGlass(in: bounds, radius: radius, level: level, tint: tint)
    }
}
