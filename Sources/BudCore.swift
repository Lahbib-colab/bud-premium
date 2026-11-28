import Cocoa
import IOKit.ps
import Darwin

// ═══════════════════════════════════════════════════════════
//  État persistant — state.json
//  Schéma v8 : toutes les clés v7 sont conservées (y compris
//  celles devenues inutiles : batterie clavier, position de la
//  fenêtre) pour qu'aucune donnée existante ne soit perdue.
// ═══════════════════════════════════════════════════════════

struct BudState: Codable {
    // — Hérité v6/v7 : conservé tel quel, relu et réécrit —
    var lastChargeTs: TimeInterval = Date().timeIntervalSince1970
    var totalDays: Int = 30
    var extraHours: Int = 0
    var posX: Double? = nil
    var posY: Double? = nil

    // — Préférences —
    var moodIndex: Int = 0
    var notchEnabled: Bool = true
    var soundEnabled: Bool = true
    var autoCoucou: Bool = true
    var breakReminder: Bool = false
    var notifyEnabled: Bool = true
    var focusMinutes: Int = 25
    var breakMinutes: Int = 5
    var focusSessions: Int = 0
    var focusTotalMinutes: Int = 0
    var sessionsDay: String = ""
    var notes: String = ""
    var personality: Int = 0
    var accentIndex: Int = 0
    var themeMode: Int = 0        // 0 auto · 1 clair · 2 sombre
    var glassLevel: Int = 1       // 0 opaque · 1 verre dépoli · 2 cristal
    var followMouse: Bool = true
    var sortRoot: String = ""
    var sortByMonth: Bool = false
    var sortedCount: Int = 0

    // — Nouveau en v8 —
    var agentAlerts: Bool = true
    var agentSound: Bool = true
    var lowDiskThreshold: Int = 10      // % libre déclenchant l'alerte
    var pasteToFrontApp: Bool = false   // coller dans l'app active
    var hideInFullscreen: Bool = true   // s'effacer devant une app en plein écran
    var mailWatch: Bool = true          // surveiller les messages non lus
    var mailFrom: String = ""           // adresse d'expédition (vide = compte par défaut)
    var gmailAccount: String = ""       // adresse connectée par mot de passe d'application
    var oauthEmail: String = ""         // adresse connectée par OAuth Google
    var updateChannel: String = ""      // vide = canal par défaut
    var lastUpdateCheck: TimeInterval = 0
    var musicSource: Int = 0            // obsolète depuis la v23 : Apple Music seule
    var alarmSound: Bool = true       // sonnerie répétée des rappels
    /// Écoute permanente du mot d'activation. Faux par défaut, et ce
    /// défaut est un choix : garder le micro ouvert et la reconnaissance
    /// en marche se paie en batterie, et personne ne doit le découvrir
    /// après coup.
    var wakeWord: Bool = false
    /// La ville de la météo. Une ville plutôt que la position : la
    /// localisation demanderait une autorisation de plus, et la météo
    /// d'une ville suffit à savoir s'il faut un parapluie.
    var weatherCity: String = "Paris"
    /// Le dossier de Raccourcis où BUD cherche les commandes de la maison.
    var homeFolder: String = "BUD Maison"
    var budPremium: Bool = false      // v17 : conservé pour la migration
    /// 0 à plat · 1 nacré-or · 2 métal · 3 logo.
    ///
    /// Le logo par défaut depuis la 25.0 : c'est votre illustration, et
    /// l'application doit ressembler à sa marque sans qu'on ait à le
    /// demander. Les trois dessins vectoriels restent au choix.
    var budSkin: Int = 3
    /// Vrai une fois que l'habillage logo a été proposé à une
    /// installation qui existait avant lui. Sans ce témoin, on ne saurait
    /// pas distinguer « il a choisi À plat » de « il n'a jamais choisi ».
    var sawLogoSkin: Bool = false

    // — Nouveau en v23.6 —
    //
    //  Les raccourcis, au choix de l'utilisateur. Clé = nom de l'action,
    //  valeur = le raccourci encodé « <masque>:<caractère> », par exemple
    //  « 1572864:b » pour ⌘⌥B. Un dictionnaire plutôt qu'un champ par
    //  action : ajouter une action ne demande alors aucune migration, et
    //  ce qui manque retombe sur le raccourci d'usine.
    var shortcuts: [String: String] = [:]
    var voiceEnabled: Bool = true     // dictée accessible depuis le chat
    /// Les quatre pastilles de l'aperçu, par clé. Vide = celles d'usine.
    var previewChips: [String] = []

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = BudState()
        lastChargeTs = try c.decodeIfPresent(TimeInterval.self, forKey: .lastChargeTs) ?? z.lastChargeTs
        totalDays = try c.decodeIfPresent(Int.self, forKey: .totalDays) ?? z.totalDays
        extraHours = try c.decodeIfPresent(Int.self, forKey: .extraHours) ?? z.extraHours
        posX = try c.decodeIfPresent(Double.self, forKey: .posX)
        posY = try c.decodeIfPresent(Double.self, forKey: .posY)
        moodIndex = try c.decodeIfPresent(Int.self, forKey: .moodIndex) ?? z.moodIndex
        notchEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchEnabled) ?? z.notchEnabled
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? z.soundEnabled
        autoCoucou = try c.decodeIfPresent(Bool.self, forKey: .autoCoucou) ?? z.autoCoucou
        breakReminder = try c.decodeIfPresent(Bool.self, forKey: .breakReminder) ?? z.breakReminder
        notifyEnabled = try c.decodeIfPresent(Bool.self, forKey: .notifyEnabled) ?? z.notifyEnabled
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? z.focusMinutes
        breakMinutes = try c.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? z.breakMinutes
        focusSessions = try c.decodeIfPresent(Int.self, forKey: .focusSessions) ?? z.focusSessions
        focusTotalMinutes = try c.decodeIfPresent(Int.self, forKey: .focusTotalMinutes) ?? z.focusTotalMinutes
        sessionsDay = try c.decodeIfPresent(String.self, forKey: .sessionsDay) ?? z.sessionsDay
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? z.notes
        personality = try c.decodeIfPresent(Int.self, forKey: .personality) ?? z.personality
        accentIndex = try c.decodeIfPresent(Int.self, forKey: .accentIndex) ?? z.accentIndex
        themeMode = try c.decodeIfPresent(Int.self, forKey: .themeMode) ?? z.themeMode
        glassLevel = try c.decodeIfPresent(Int.self, forKey: .glassLevel) ?? z.glassLevel
        followMouse = try c.decodeIfPresent(Bool.self, forKey: .followMouse) ?? z.followMouse
        sortRoot = try c.decodeIfPresent(String.self, forKey: .sortRoot) ?? z.sortRoot
        sortByMonth = try c.decodeIfPresent(Bool.self, forKey: .sortByMonth) ?? z.sortByMonth
        sortedCount = try c.decodeIfPresent(Int.self, forKey: .sortedCount) ?? z.sortedCount
        agentAlerts = try c.decodeIfPresent(Bool.self, forKey: .agentAlerts) ?? z.agentAlerts
        agentSound = try c.decodeIfPresent(Bool.self, forKey: .agentSound) ?? z.agentSound
        lowDiskThreshold = try c.decodeIfPresent(Int.self, forKey: .lowDiskThreshold) ?? z.lowDiskThreshold
        pasteToFrontApp = try c.decodeIfPresent(Bool.self, forKey: .pasteToFrontApp) ?? z.pasteToFrontApp
        hideInFullscreen = try c.decodeIfPresent(Bool.self, forKey: .hideInFullscreen) ?? z.hideInFullscreen
        mailWatch = try c.decodeIfPresent(Bool.self, forKey: .mailWatch) ?? z.mailWatch
        mailFrom = try c.decodeIfPresent(String.self, forKey: .mailFrom) ?? z.mailFrom
        gmailAccount = try c.decodeIfPresent(String.self, forKey: .gmailAccount) ?? z.gmailAccount
        oauthEmail = try c.decodeIfPresent(String.self, forKey: .oauthEmail) ?? z.oauthEmail
        updateChannel = try c.decodeIfPresent(String.self, forKey: .updateChannel) ?? z.updateChannel
        lastUpdateCheck = try c.decodeIfPresent(TimeInterval.self, forKey: .lastUpdateCheck) ?? z.lastUpdateCheck
        musicSource = try c.decodeIfPresent(Int.self, forKey: .musicSource) ?? z.musicSource
        alarmSound = try c.decodeIfPresent(Bool.self, forKey: .alarmSound) ?? z.alarmSound
        budPremium = try c.decodeIfPresent(Bool.self, forKey: .budPremium) ?? z.budPremium
        budSkin = try c.decodeIfPresent(Int.self, forKey: .budSkin) ?? z.budSkin
        shortcuts = try c.decodeIfPresent([String: String].self, forKey: .shortcuts) ?? z.shortcuts
        voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? z.voiceEnabled
        previewChips = try c.decodeIfPresent([String].self, forKey: .previewChips) ?? z.previewChips
        sawLogoSkin = try c.decodeIfPresent(Bool.self, forKey: .sawLogoSkin) ?? false
        // L'écoute « Hey Bud » n'était jamais relue depuis la 24.5 :
        // l'interrupteur se remettait à zéro à chaque lancement. Un champ
        // ajouté sans sa ligne ici est un réglage qui ne survit pas.
        wakeWord = try c.decodeIfPresent(Bool.self, forKey: .wakeWord) ?? z.wakeWord
        weatherCity = try c.decodeIfPresent(String.self, forKey: .weatherCity) ?? z.weatherCity
        homeFolder = try c.decodeIfPresent(String.self, forKey: .homeFolder) ?? z.homeFolder
        // Un état écrit par la v17 ne connaît que budPremium : on le reporte.
        if budSkin == 0 && budPremium { budSkin = 1 }
        // La borne était à 2, héritée d'avant le logo : elle ramenait
        // l'habillage 3 à 0 à chaque relecture, et le choix ne survivait
        // donc pas au redémarrage. Un défaut à corriger, pas seulement à
        // élargir — une borne qu'on oublie d'étendre est le genre de bug
        // qui ne se voit qu'au deuxième lancement.
        if budSkin < 0 || budSkin > 3 { budSkin = 0 }
        // Une installation d'avant le logo garde son habillage si elle en
        // avait choisi un ; celle qui n'avait jamais touché au réglage
        // reçoit le logo. On ne remplace pas un choix, on comble un vide.
        if !sawLogoSkin {
            if budSkin == 0 && !budPremium { budSkin = 3 }
            sawLogoSkin = true
        }
    }
}

/// Dossier racine partagé par tous les modules.
let budSupportDir: URL = {
    let fm = FileManager.default
    let d = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BUD-Assistant", isDirectory: true)
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

final class BudStore {
    static let shared = BudStore()
    private let url = budSupportDir.appendingPathComponent("state.json")

    func load() -> BudState {
        guard let d = try? Data(contentsOf: url),
              var s = try? JSONDecoder().decode(BudState.self, from: d) else { return BudState() }
        if s.lastChargeTs <= 0 { s.lastChargeTs = Date().timeIntervalSince1970 }
        s.focusMinutes = max(5, s.focusMinutes)
        s.breakMinutes = max(1, s.breakMinutes)
        s.personality = max(0, min(2, s.personality))
        s.accentIndex = max(0, min(accentPalette.count - 1, s.accentIndex))
        s.themeMode = max(0, min(2, s.themeMode))
        s.glassLevel = max(0, min(2, s.glassLevel))
        s.lowDiskThreshold = max(2, min(40, s.lowDiskThreshold))
        return s
    }

    func save(_ s: BudState) {
        let e = JSONEncoder()
        e.outputFormatting = .prettyPrinted
        if let d = try? e.encode(s) { try? d.write(to: url, options: .atomic) }
    }
}

// ═══════════════════════════════════════════════════════════
//  Thème global
// ═══════════════════════════════════════════════════════════

extension NSColor {
    /// Luminance perçue, 0 à 1. La conversion en sRGB est obligatoire :
    /// lire `redComponent` sur une couleur d'un autre espace lève une
    /// exception Objective-C, et un gris de catalogue n'est pas en RVB.
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

let accentPalette: [(String, NSColor)] = [
    ("Vert menthe",    NSColor(calibratedRed: 0.22, green: 0.85, blue: 0.62, alpha: 1)),
    ("Bleu océan",     NSColor(calibratedRed: 0.29, green: 0.62, blue: 0.99, alpha: 1)),
    ("Violet néon",    NSColor(calibratedRed: 0.68, green: 0.49, blue: 1.00, alpha: 1)),
    ("Orange solaire", NSColor(calibratedRed: 1.00, green: 0.64, blue: 0.24, alpha: 1)),
    ("Rose flash",     NSColor(calibratedRed: 0.99, green: 0.42, blue: 0.68, alpha: 1)),
    ("Blanc pur",      NSColor(calibratedWhite: 0.97, alpha: 1))
]
/// Le blanc doit devenir graphite en thème clair, sinon il disparaît.
let whiteAccentIndex = 5
let dangerColor = NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.42, alpha: 1)
let warnColor   = NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.20, alpha: 1)

struct Theme {
    var dark = true
    var glass = 1
    var accent = accentPalette[0].1

    var base: NSColor {
        dark ? NSColor(calibratedWhite: 0.045, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)
    }
    var baseAlpha: CGFloat { glass == 0 ? 1.0 : (glass == 1 ? 0.60 : 0.28) }
    var text: NSColor { dark ? .white : NSColor(calibratedWhite: 0.10, alpha: 1) }
    func fill(_ a: CGFloat) -> NSColor {
        dark ? NSColor(calibratedWhite: 1, alpha: a) : NSColor(calibratedWhite: 0.15, alpha: a * 0.85)
    }
    func dim(_ a: CGFloat) -> NSColor { text.withAlphaComponent(a) }

    /// Ce qu'on écrit **sur** la couleur d'accent.
    ///
    /// C'était du quasi-noir, quelle que soit la teinte. Les six accents
    /// d'usine sont clairs, donc cela passait — mais « Blanc pur » devient
    /// graphite en thème clair, et le noir sur graphite ne se lit plus.
    /// On choisit maintenant d'après la luminance réelle de la couleur,
    /// ce qui tient aussi pour toute teinte ajoutée plus tard.
    var onAccent: NSColor {
        accent.luminance > 0.55
            ? NSColor(calibratedWhite: 0.06, alpha: 0.95)
            : NSColor(calibratedWhite: 1.00, alpha: 0.97)
    }
}

var TH = Theme()

// ═══════════════════════════════════════════════════════════
//  Contenus
// ═══════════════════════════════════════════════════════════

let personalityNames = ["Zen", "Coach", "Rigolo"]
let personalityIcons = ["leaf.fill", "target", "theatermasks.fill"]

let tipsZen = [
    "Respire : 4 secondes d'inspiration, 6 d'expiration. Trois fois.",
    "Règle 20-20-20 : toutes les 20 min, regarde à 6 m pendant 20 s.",
    "Un verre d'eau maintenant ? Ton cerveau te dira merci.",
    "Détends la mâchoire et laisse retomber les épaules.",
    "Range une seule chose sur ton bureau, ça allège la tête.",
    "Étire tes poignets dix secondes, ton clavier te remerciera."
]
let tipsCoach = [
    "Choisis UNE tâche et lance un focus de 25 minutes.",
    "Commence par ce que tu repousses depuis ce matin.",
    "Découpe : quelle est la plus petite étape suivante ?",
    "Note ton objectif du jour dans l'onglet Notes.",
    "Deux sessions de focus avant midi, c'est une bonne journée.",
    "Ferme les onglets inutiles : chaque distraction coûte 20 minutes."
]
let tipsFun = [
    "Glisse des fichiers sur moi, je les range tout seul.",
    "⌘⌥D ouvre la capture rapide, où que tu sois.",
    "⌘⌥B pour m'ouvrir, ⌘⌥C pour un coucou, ⌘⌥F pour un focus.",
    "Je te suis du regard, c'est normal, c'est de l'affection.",
    "Tes agents peuvent me réveiller avec bud-ask.",
    "Clique-moi dessus, j'adore qu'on me chatouille."
]
func tipsFor(_ p: Int) -> [String] { p == 1 ? tipsCoach : (p == 2 ? tipsFun : tipsZen) }

let budJokes = [
    "Pourquoi les plongeurs plongent en arrière ? Sinon ils tombent dans le bateau.",
    "Que fait un geek quand il a froid ? Il ferme Windows.",
    "Je ne suis pas en retard, c'est mon fuseau horaire qui est en avance.",
    "Un octet entre dans un bar : « je prendrai juste un bit ».",
    "Le Wi-Fi, c'est comme l'amour : on le remarque surtout quand il manque.",
    "Pourquoi les robots ne stressent jamais ? Ils ont des nerfs d'acier.",
    "Mon disque dur et moi, c'est une histoire de place."
]

func timeGreeting() -> (String, String) {
    switch Calendar.current.component(.hour, from: Date()) {
    case 0..<5:   return ("Coucou, noctambule", "Il est tard… pense à te reposer un peu.")
    case 5..<12:  return ("Coucou, bonjour", "Belle matinée pour avancer sur tes projets.")
    case 12..<14: return ("C'est l'heure de manger", "Bon appétit, les pixels attendront.")
    case 14..<18: return ("Bon après-midi", "Encore une belle marge avant la fin de journée.")
    case 18..<22: return ("Bonsoir", "Tu as bien travaillé aujourd'hui.")
    default:      return ("Coucou", "Il se fait tard, bientôt l'heure de dormir.")
    }
}

func clockString() -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "HH:mm"
    return f.string(from: Date())
}
/// Le sens du balayage, pour qu'un geste du doigt vers la gauche soit
/// toujours un geste vers la gauche.
///
/// AppKit applique déjà le réglage « défilement naturel » à
/// `scrollingDeltaX` : le même mouvement de doigt produit donc un
/// signe opposé selon ce réglage. Pour un geste de balayage, c'est le
/// doigt qui compte, pas le défilement — on défait donc l'inversion.
/// Lu une seule fois, à la première utilisation.
let swipeSign: CGFloat = {
    let out = runShell("/usr/bin/defaults", ["read", "-g", "com.apple.swipescrolldirection"])
    return out.trimmingCharacters(in: .whitespacesAndNewlines) == "0" ? -1 : 1
}()

// ═══════════════════════════════════════════════════════════
//  Raccourcis clavier
//
//  Chaque action porte un identifiant stable, un libellé, et un
//  raccourci d'usine. Ce que l'utilisateur choisit vit dans
//  `BudState.shortcuts` sous cet identifiant ; ce qui manque
//  retombe sur l'usine. Renommer un libellé ne casse donc rien,
//  et ajouter une action ne demande aucune migration.
// ═══════════════════════════════════════════════════════════

struct ShortcutAction {
    let key: String
    let label: String
    let fallback: String
}

// ═══════════════════════════════════════════════════════════
//  Les pastilles de l'aperçu
//
//  Les quatre capsules sous la salutation. Elles étaient
//  figées — disque, disques externes, focus, heure — et
//  purement décoratives. Elles deviennent au choix, teintées,
//  et cliquables : chacune mène au panneau qui la concerne.
// ═══════════════════════════════════════════════════════════

struct PreviewChip {
    let key: String
    let label: String        // dans la fenêtre de réglage
    let icon: String
    let color: NSColor
    /// L'onglet à ouvrir au clic, ou "" pour une pastille qui n'ouvre rien.
    let target: String
}

enum PreviewChips {
    static let catalogue: [PreviewChip] = [
        PreviewChip(key: "disk", label: "Espace libre", icon: "internaldrive.fill",
                    color: NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.00, alpha: 1),
                    target: "storage"),
        PreviewChip(key: "external", label: "Disques externes", icon: "externaldrive.fill",
                    color: NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.76, alpha: 1),
                    target: "storage"),
        PreviewChip(key: "agents", label: "Demandes des agents", icon: "bell.badge.fill",
                    color: NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.35, alpha: 1),
                    target: "agents"),
        PreviewChip(key: "focus", label: "Focus en cours", icon: "timer",
                    color: NSColor(calibratedRed: 0.74, green: 0.47, blue: 1.00, alpha: 1),
                    target: "focus"),
        PreviewChip(key: "clock", label: "Heure", icon: "clock",
                    color: NSColor(calibratedWhite: 0.80, alpha: 1), target: ""),
        PreviewChip(key: "battery", label: "Batterie", icon: "battery.100",
                    color: NSColor(calibratedRed: 0.40, green: 0.82, blue: 0.56, alpha: 1),
                    target: ""),
        PreviewChip(key: "mail", label: "Courrier non lu", icon: "envelope.fill",
                    color: NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.00, alpha: 1),
                    target: "mail"),
        PreviewChip(key: "reminders", label: "Prochain rappel", icon: "checklist",
                    color: NSColor(calibratedRed: 0.96, green: 0.69, blue: 0.27, alpha: 1),
                    target: "reminders"),
        PreviewChip(key: "music", label: "Lecture en cours", icon: "music.note",
                    color: NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.62, alpha: 1),
                    target: "music"),
        PreviewChip(key: "memory", label: "Mémoire libre", icon: "memorychip",
                    color: NSColor(calibratedRed: 0.74, green: 0.47, blue: 1.00, alpha: 1),
                    target: ""),
        // L'icône réelle suit le ciel du moment ; celle-ci sert au menu.
        PreviewChip(key: "weather", label: "Météo", icon: "cloud.sun.fill",
                    color: NSColor(calibratedRed: 0.45, green: 0.72, blue: 1.00, alpha: 1),
                    target: "weather")
    ]

    static let fallback = ["disk", "external", "focus", "clock"]

    static func chip(_ key: String) -> PreviewChip? {
        catalogue.first { $0.key == key }
    }

    /// Les quatre clés en vigueur. On revient à l'usine si l'état est vide
    /// ou abîmé — une liste de longueur inattendue casserait la rangée.
    static func current(_ state: BudState) -> [String] {
        let s = state.previewChips
        guard s.count == 4, s.allSatisfy({ chip($0) != nil }) else { return fallback }
        return s
    }
}

enum Shortcuts {

    /// Encode un raccourci. On ne retient que les quatre modificateurs
    /// qui comptent : le masque brut d'un événement porte aussi l'état
    /// du pavé numérique et des touches de fonction, qui varient d'un
    /// clavier à l'autre et rendraient la comparaison instable.
    static func encode(_ mods: NSEvent.ModifierFlags, _ ch: String) -> String {
        let m = mods.intersection([.command, .option, .control, .shift])
        return "\(m.rawValue):\(ch.lowercased())"
    }

    static func decode(_ s: String) -> (mods: NSEvent.ModifierFlags, ch: String)? {
        let p = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard p.count == 2, let raw = UInt(p[0]), !p[1].isEmpty else { return nil }
        return (NSEvent.ModifierFlags(rawValue: raw), String(p[1]))
    }

    /// « ⌘⌥B », dans l'ordre où macOS les écrit.
    static func display(_ s: String) -> String {
        guard let (m, ch) = decode(s) else { return "—" }
        var out = ""
        if m.contains(.control) { out += "⌃" }
        if m.contains(.option)  { out += "⌥" }
        if m.contains(.shift)   { out += "⇧" }
        if m.contains(.command) { out += "⌘" }
        return out + ch.uppercased()
    }

    /// Un raccourci sans ⌘, ⌃ ni ⌥ intercepterait la frappe ordinaire
    /// dans toutes les applications : on refuse de l'enregistrer.
    static func isUsable(_ s: String) -> Bool {
        guard let (m, _) = decode(s) else { return false }
        return !m.intersection([.command, .control, .option]).isEmpty
    }

    static let actions: [ShortcutAction] = [
        ShortcutAction(key: "panel",     label: "Ouvrir ou fermer le panneau",
                       fallback: encode([.command, .option], "b")),
        ShortcutAction(key: "hello",     label: "Dire coucou",
                       fallback: encode([.command, .option], "c")),
        ShortcutAction(key: "focus",     label: "Lancer ou arrêter un focus",
                       fallback: encode([.command, .option], "f")),
        ShortcutAction(key: "capture",   label: "Capture d'écran",
                       fallback: encode([.command, .option], "d")),
        ShortcutAction(key: "voice",     label: "Parler à BUD (dictée)",
                       fallback: encode([.command, .option], "v")),
        ShortcutAction(key: "chat",      label: "Onglet Chat",
                       fallback: encode([.command, .option], "k")),
        ShortcutAction(key: "mail",      label: "Onglet Courrier",
                       fallback: encode([.command, .option], "m")),
        ShortcutAction(key: "reminders", label: "Onglet Rappels",
                       fallback: encode([.command, .option], "r")),
        ShortcutAction(key: "agents",    label: "Onglet Agents",
                       fallback: encode([.command, .option], "a")),
        ShortcutAction(key: "phone",     label: "Onglet Téléphone",
                       fallback: encode([.command, .option], "p"))
    ]

    /// Le raccourci en vigueur pour une action : celui de l'utilisateur,
    /// sinon celui d'usine.
    static func current(_ key: String, in state: BudState) -> String {
        if let s = state.shortcuts[key], isUsable(s) { return s }
        return actions.first { $0.key == key }?.fallback ?? ""
    }
}

/// L'état de la batterie en une phrase. Beaucoup de Mac n'en ont pas —
/// un Mac mini, un iMac — et `pmset` ne renvoie alors aucune ligne de
/// batterie : il faut le dire plutôt que d'afficher « 0 % ».
func batteryLine() -> String {
    let out = runShell("/usr/bin/pmset", ["-g", "batt"])
    guard out.contains("InternalBattery") else {
        return "Ce Mac n'a pas de batterie — il est sur le secteur."
    }
    let pct = out.range(of: "[0-9]{1,3}%", options: .regularExpression)
        .map { String(out[$0]) } ?? "?"
    let onAC = out.contains("'AC Power'")
    var state = ""
    for (key, word) in [("charged", "pleine"), ("charging", "en charge"),
                        ("discharging", "sur batterie"), ("finishing charge", "fin de charge")] {
        if out.contains(key) { state = word; break }
    }
    // « 2:13 remaining » : le temps restant n'est pas toujours calculé,
    // et pmset écrit alors « (no estimate) ».
    var left = ""
    if let r = out.range(of: "[0-9]{1,2}:[0-9]{2} remaining", options: .regularExpression) {
        let t = String(out[r]).replacingOccurrences(of: " remaining", with: "")
        left = " · \(t) restantes"
    }
    let src = onAC ? "secteur" : "batterie"
    return "Batterie \(pct)\(state.isEmpty ? "" : " · \(state)") · alimentation \(src)\(left)."
}

/// IP locale et nom du réseau sans fil, en une phrase.
func networkLine() -> String {
    let ip = runShell("/usr/sbin/ipconfig", ["getifaddr", "en0"])
    let wifi = runShell("/usr/sbin/networksetup", ["-getairportnetwork", "en0"])
        .replacingOccurrences(of: "Current Wi-Fi Network: ", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let ipPart = ip.isEmpty ? "pas d'adresse sur en0" : "IP locale \(ip)"
    let netPart = wifi.isEmpty || wifi.contains("not associated")
        ? "pas de Wi-Fi associé" : "réseau « \(wifi) »"
    return "\(ipPart) · \(netPart)."
}

/// « dim. 22 nov. » — ce qui tient à côté de l'heure dans la barre repliée.
func shortDateString() -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
    f.setLocalizedDateFormatFromTemplate("EEEdMMM")
    return f.string(from: Date())
}
func longDateString() -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEEE d MMMM"
    return f.string(from: Date()).capitalized
}

// ═══════════════════════════════════════════════════════════
//  Dessin
// ═══════════════════════════════════════════════════════════

// ── Pipeline d'icônes : SF Symbols vectoriels, mis en cache, rendus nets ──

private final class SymbolCache {
    static let shared = SymbolCache()
    private var store: [String: NSImage] = [:]

    func image(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)"
        if let c = store[key] { return c }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true
        store[key] = img
        return img
    }
}

/// Image vectorielle d'un symbole, teintée par la vue hôte (contentTintColor).
func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSImage? {
    SymbolCache.shared.image(name, size, weight)
}

/// Dessine un symbole net dans le contexte courant : l'image reste vectorielle et
/// la teinte est appliquée dans un calque de transparence, sans rastérisation à 1x.
func drawSymbol(_ name: String, center: NSPoint, size: CGFloat,
                weight: NSFont.Weight = .medium, color: NSColor = .white, alpha: CGFloat = 1) {
    guard let img = symbol(name, size, weight),
          let ctx = NSGraphicsContext.current?.cgContext else { return }
    let w = ceil(img.size.width), h = ceil(img.size.height)
    let r = NSRect(x: (center.x - w / 2).rounded(), y: (center.y - h / 2).rounded(), width: w, height: h)
    ctx.beginTransparencyLayer(in: r, auxiliaryInfo: nil)
    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: alpha)
    color.setFill()
    r.fill(using: .sourceAtop)
    ctx.endTransparencyLayer()
}

/// Largeur exacte d'un texte : sert à dimensionner sans jamais tronquer.
func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> CGFloat {
    let f = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                 : NSFont.systemFont(ofSize: size, weight: weight)
    return ceil((s as NSString).size(withAttributes: [.font: f]).width) + 1
}

func drawString(_ s: String, in r: NSRect, size: CGFloat, weight: NSFont.Weight,
                color: NSColor, align: NSTextAlignment = .left, mono: Bool = false) {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    p.lineBreakMode = .byTruncatingTail
    let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
    (s as NSString).draw(in: r, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
}

func notchShape(_ r: NSRect, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX, y: r.maxY))
    p.line(to: NSPoint(x: r.maxX, y: r.maxY))
    p.line(to: NSPoint(x: r.maxX, y: r.minY + radius))
    p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius),
                radius: radius, startAngle: 0, endAngle: 270, clockwise: true)
    p.line(to: NSPoint(x: r.minX + radius, y: r.minY))
    p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius),
                radius: radius, startAngle: 270, endAngle: 180, clockwise: true)
    p.close()
    return p
}

func capsule(_ r: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
}

// ═══════════════════════════════════════════════════════════
//  Système
// ═══════════════════════════════════════════════════════════

func macBattery() -> (percent: Int, charging: Bool, has: Bool) {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
        return (0, false, false)
    }
    for ps in list {
        if let i = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
           let cap = i[kIOPSCurrentCapacityKey] as? Int,
           let mx = i[kIOPSMaxCapacityKey] as? Int, mx > 0 {
            return (min(100, cap * 100 / mx), (i[kIOPSIsChargingKey] as? Bool) ?? false, true)
        }
    }
    return (0, false, false)
}

func memoryStats() -> (used: Double, total: Double) {
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    var st = vm_statistics64_data_t()
    var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &st) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, total) }
    let page = Double(vm_kernel_page_size)
    let free = (Double(st.free_count) + Double(st.inactive_count)) * page
    return (max(0, total - free), total)
}

func formatUptime(_ s: TimeInterval) -> String {
    let t = Int(s), d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
    if d > 0 { return "\(d) j \(h) h" }
    if h > 0 { return "\(h) h \(m) min" }
    return "\(m) min"
}

/// Format court et francisé : « 312 Go », « 1,05 To », « 870 Mo ».
func formatBytes(_ b: Int64) -> String {
    let gb = Double(b) / 1_000_000_000
    func fr(_ s: String) -> String { s.replacingOccurrences(of: ".", with: ",") }
    if gb >= 1000 { return fr(String(format: "%.2f To", gb / 1000)) }
    if gb >= 100  { return String(format: "%.0f Go", gb) }
    if gb >= 10   { return fr(String(format: "%.1f Go", gb)) }
    if gb >= 1    { return fr(String(format: "%.2f Go", gb)) }
    return String(format: "%.0f Mo", Double(b) / 1_000_000)
}

/// Version de l'application, affichée dans la barre latérale.
let budVersion = "25.8"
let budSignature = "by Lahbib.AI"

@discardableResult
func runShell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Comme `runShell`, mais rend aussi la sortie d'erreur et le code de
/// sortie.
///
/// `runShell` jette stderr. Pour `osascript`, c'est un angle mort grave :
/// un refus d'autorisation — « Not authorized to send Apple events to
/// Music. (-1743) » — s'écrit entièrement sur stderr, et l'appelant ne
/// recevait qu'une chaîne vide, impossible à distinguer d'une réponse
/// légitimement vide. BUD affichait alors « rien en lecture » au lieu de
/// dire que l'autorisation manquait.
func runShellDetailed(_ path: String, _ args: [String]) -> (out: String, err: String, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let op = Pipe(), ep = Pipe()
    p.standardOutput = op
    p.standardError = ep
    do { try p.run() } catch {
        return ("", "lancement impossible : \(error.localizedDescription)", -1)
    }

    // Les deux tuyaux se lisent en parallèle. Vider l'un jusqu'au bout
    // pendant que l'autre se remplit bloque le processus dès que son
    // tampon de 64 Ko est plein, et plus rien n'avance.
    var outData = Data(), errData = Data()
    let g = DispatchGroup()
    let q = DispatchQueue(label: "fr.lahbib.bud.shell", attributes: .concurrent)
    g.enter(); q.async { outData = op.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    g.enter(); q.async { errData = ep.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    g.wait()
    p.waitUntilExit()

    let trim = { (d: Data) in
        String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return (trim(outData), trim(errData), p.terminationStatus)
}

func notify(_ t: String, _ b: String) {
    let n = NSUserNotification()
    n.title = t
    n.informativeText = b
    NSUserNotificationCenter.default.deliver(n)
}

// ═══════════════════════════════════════════════════════════
//  Rangement de fichiers (inchangé depuis la v7)
// ═══════════════════════════════════════════════════════════

struct FileCategory {
    let name: String
    let icon: String
    let exts: Set<String>
}

let fileCategories: [FileCategory] = [
    FileCategory(name: "Images", icon: "photo.fill",
                 exts: ["png","jpg","jpeg","gif","heic","heif","webp","tiff","tif","bmp","svg","raw","cr2","nef"]),
    FileCategory(name: "Vidéos", icon: "film.fill",
                 exts: ["mp4","mov","avi","mkv","m4v","webm","mpg","mpeg","wmv"]),
    FileCategory(name: "Audio", icon: "music.note",
                 exts: ["mp3","wav","aiff","aif","m4a","flac","aac","ogg","caf"]),
    FileCategory(name: "Documents", icon: "doc.text.fill",
                 exts: ["pdf","doc","docx","pages","txt","rtf","md","odt","epub","tex"]),
    FileCategory(name: "Tableurs", icon: "tablecells.fill",
                 exts: ["xls","xlsx","xlsm","numbers","csv","tsv","ods"]),
    FileCategory(name: "Présentations", icon: "rectangle.on.rectangle",
                 exts: ["ppt","pptx","key","odp"]),
    FileCategory(name: "Archives", icon: "archivebox.fill",
                 exts: ["zip","rar","7z","tar","gz","bz2","xz","tgz"]),
    FileCategory(name: "Installeurs", icon: "shippingbox.fill",
                 exts: ["dmg","pkg","mpkg","app","command","iso"]),
    FileCategory(name: "Code", icon: "chevron.left.forwardslash.chevron.right",
                 exts: ["swift","py","js","mjs","ts","tsx","jsx","html","htm","css","json","xml","yml","yaml",
                        "sh","bash","zsh","c","cpp","cc","h","hpp","java","rb","go","php","rs","kt","plist","sql"]),
    FileCategory(name: "Polices", icon: "textformat",
                 exts: ["ttf","otf","woff","woff2","ttc"])
]

func categoryFor(_ url: URL) -> FileCategory {
    let ext = url.pathExtension.lowercased()
    for c in fileCategories where c.exts.contains(ext) { return c }
    return FileCategory(name: "Divers", icon: "questionmark.folder.fill", exts: [])
}

struct SortMove { let from: URL; let to: URL }
