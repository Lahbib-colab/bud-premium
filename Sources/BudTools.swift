import Cocoa
import ImageIO

// ═══════════════════════════════════════════════════════════
//  Les outils du chat
//
//  L'onglet Outils a disparu : ses boutons vivent maintenant
//  dans le chat, derrière une pilule. Un outil est une action
//  en un clic — capture, veille, verrouillage, un agent du
//  Flux — que BUD exécute et dont il rend compte dans le fil.
//
//  Le partage des rôles :
//    • `BudTool` décrit un outil et sait l'exécuter ;
//    • `BudToolManager` les range, les retrouve à partir d'une
//      phrase du chat, et pilote l'expression de BUDs ;
//    • le chat, lui, présente : la confirmation, la bulle qui
//      tourne, la bulle du résultat.
//
//  Ajouter un outil, c'est écrire un `BudTool` et l'inscrire
//  dans `BudToolCatalog.registerDefaults` : la pilule, le menu,
//  la reconnaissance dans le chat et les expressions suivent.
// ═══════════════════════════════════════════════════════════

/// Le niveau de prudence avant d'exécuter.
enum ToolRisk: Equatable {
    /// Exécuté au clic.
    case none
    /// Une question, un bouton : pour l'irréversible.
    case confirm(String)
    /// Un compte à rebours annulable : pour ce qui interrompt le travail
    /// mais ne détruit rien, comme la veille.
    case countdown(Int)
}

enum ToolCategory: Int, CaseIterable {
    case capture, system, agents, more
    var title: String {
        switch self {
        case .capture: return "CAPTURE"
        case .system:  return "SYSTÈME"
        case .agents:  return "AGENTS"
        case .more:    return "PLUS"
        }
    }
}

/// Ce qu'un outil rend. Le chat en fait une bulle.
struct ToolOutcome {
    var ok: Bool
    var text: String
    /// Une miniature à montrer dans la bulle.
    var image: NSImage? = nil
    /// Un geste au clic sur la bulle : révéler la capture, ouvrir les
    /// réglages d'autorisation, ouvrir le Flux…
    var tapLabel: String? = nil
    var tap: (() -> Void)? = nil
    /// L'expression de BUDs. `nil` : celle par défaut (content ou déçu).
    var expression: BudExpression? = nil
    /// Vrai quand l'outil a déjà réglé l'expression lui-même — un agent
    /// du Flux le fait, et le doubler ferait sauter le visage.
    var expressionHandled = false

    static func cancelled(_ why: String = "Annulé.") -> ToolOutcome {
        ToolOutcome(ok: true, text: why, expression: .neutral)
    }
}

/// Ce que l'application prête aux outils. Les outils n'ont pas accès à
/// `BudApp` : ils reçoivent ces quelques gestes, et rien d'autre.
struct ToolHost {
    /// Replie le panneau et l'encoche, pour que BUD ne figure pas sur la
    /// capture.
    var hidePanel: () -> Void = {}
    /// Les ramène, sur l'onglet Chat.
    var showChat: () -> Void = {}
    var openTab: (String) -> Void = { _ in }
    var lockScreen: () -> String = { "" }
    var setAppearance: (String) -> String = { _ in "" }
    var emptyTrash: (@escaping (String) -> Void) -> Void = { _ in }
    var openKeyboardShortcuts: () -> Void = {}
    var battery: () -> String = { "" }
    var network: () -> String = { "" }
}

final class BudTool {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: NSColor
    let category: ToolCategory
    let risk: ToolRisk
    /// Les tournures du chat qui le déclenchent, sans accents ni
    /// ponctuation. La plus longue qui correspond l'emporte : « capture la
    /// fenêtre » bat « capture ».
    let phrases: [String]
    /// Libellé de la bulle pendant le travail.
    let working: String
    private let body: (@escaping (String) -> Void, @escaping (ToolOutcome) -> Void) -> Void

    /// `body` reçoit une fonction d'avancement et la fonction de fin ; il
    /// peut appeler la fin de n'importe quel fil.
    init(id: String, title: String, subtitle: String, icon: String, tint: NSColor,
         category: ToolCategory, risk: ToolRisk = .none, phrases: [String] = [],
         working: String = "Un instant…",
         body: @escaping (@escaping (String) -> Void, @escaping (ToolOutcome) -> Void) -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.icon = icon
        self.tint = tint; self.category = category; self.risk = risk
        self.phrases = phrases; self.working = working; self.body = body
    }

    fileprivate func execute(progress: @escaping (String) -> Void, done: @escaping (ToolOutcome) -> Void) {
        body(progress, done)
    }
}

// ═══════════════════════════════════════════════════════════
//  Le gestionnaire
// ═══════════════════════════════════════════════════════════

final class BudToolManager {
    static let shared = BudToolManager()

    private(set) var tools: [BudTool] = []
    private var running = Set<String>()
    var host = ToolHost()
    /// Le même chemin que les agents : bureau, encoche et Flux ensemble.
    var onExpression: ((BudExpression, TimeInterval) -> Void)?

    func register(_ t: BudTool) {
        tools.removeAll { $0.id == t.id }
        tools.append(t)
    }

    func tool(_ id: String) -> BudTool? { tools.first { $0.id == id } }

    func tools(in c: ToolCategory) -> [BudTool] { tools.filter { $0.category == c } }

    func isRunning(_ id: String) -> Bool { running.contains(id) }

    /// Minuscules, sans accents, ponctuation remplacée par des espaces :
    /// « Mets le Mac en veille ! » → « mets le mac en veille ».
    static func normalize(_ s: String) -> String {
        let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        let cleaned = f.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// L'outil qu'une phrase demande, s'il y en a un.
    func intent(for phrase: String) -> BudTool? {
        let t = " " + BudToolManager.normalize(phrase) + " "
        var best: (BudTool, Int)?
        for tool in tools {
            for p in tool.phrases where t.contains(" " + p + " ") || (p.count >= 9 && t.contains(p)) {
                if best == nil || p.count > best!.1 { best = (tool, p.count) }
            }
        }
        return best?.0
    }

    /// Exécute, en pilotant BUDs : au travail pendant, puis le résultat.
    /// La confirmation a déjà eu lieu — c'est le rôle de la vue.
    func execute(_ t: BudTool, progress: @escaping (String) -> Void,
                 done: @escaping (ToolOutcome) -> Void) {
        guard !running.contains(t.id) else { return }
        running.insert(t.id)
        onExpression?(.working, 60)
        t.execute(progress: { p in DispatchQueue.main.async { progress(p) } }) { [weak self] out in
            DispatchQueue.main.async {
                guard let s = self else { return }
                s.running.remove(t.id)
                if !out.expressionHandled {
                    let e = out.expression ?? (out.ok ? .happy : .sad)
                    s.onExpression?(e, out.ok ? 2.6 : 3.5)
                }
                done(out)
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  Les outils d'origine
// ═══════════════════════════════════════════════════════════

enum BudToolCatalog {

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static func registerDefaults() {
        let m = BudToolManager.shared
        let indigo = c(124, 122, 255), amber = c(240, 176, 70), teal = c(70, 205, 195)
        let blue = c(90, 165, 255), violet = c(190, 120, 255), green = c(100, 210, 140)
        let red = c(255, 110, 100), cyan = c(90, 205, 245), orange = c(245, 140, 80)

        // ── Capture ──
        m.register(captureTool(id: "capture-screen", title: "Capture d'écran",
                               subtitle: "Tout l'écran, sur le Bureau", mode: .screen, target: .desktop,
                               tint: teal, phrases: ["capture", "capture d ecran", "copie d ecran",
                                                     "screenshot", "photo de l ecran", "capture l ecran"]))
        m.register(captureTool(id: "capture-window", title: "Capturer une fenêtre",
                               subtitle: "Cliquez la fenêtre voulue", mode: .window, target: .desktop,
                               tint: teal, phrases: ["capture la fenetre", "capture une fenetre",
                                                     "capture de la fenetre", "capture fenetre"]))
        m.register(captureTool(id: "capture-zone", title: "Capturer une zone",
                               subtitle: "Tracez le rectangle", mode: .selection, target: .desktop,
                               tint: teal, phrases: ["capture une zone", "capture la zone", "capture une selection",
                                                     "capture la selection", "capture un morceau"]))
        m.register(captureTool(id: "capture-clip", title: "Capture vers le presse-papiers",
                               subtitle: "Une zone, prête à coller", mode: .selection, target: .clipboard,
                               tint: cyan, phrases: ["capture dans le presse papiers",
                                                     "capture vers le presse papiers"]))

        // ── Système ──
        m.register(BudTool(id: "sleep-mac", title: "Mettre le Mac en veille",
                           subtitle: "Après un compte à rebours de 5 s", icon: "moon.zzz.fill", tint: indigo,
                           category: .system, risk: .countdown(5),
                           phrases: ["mets le mac en veille", "mac en veille", "endors le mac", "mets en veille",
                                     "mise en veille", "suspends le mac", "veille le mac"],
                           working: "Mise en veille…") { _, done in
            done(ToolOutcome(ok: true, text: "Bonne nuit. Le Mac s'endort.", expression: .happy))
            // Le message d'abord, la veille ensuite : on veut le lire au
            // réveil, pas le perdre dans la mise en veille.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.9) {
                let r = runShellDetailed("/usr/bin/pmset", ["sleepnow"])
                if r.status != 0 {
                    _ = runShellDetailed("/usr/bin/osascript",
                                         ["-e", "tell application \"System Events\" to sleep"])
                }
            }
        })
        m.register(BudTool(id: "sleep-display", title: "Veille de l'écran",
                           subtitle: "Le Mac continue de tourner", icon: "display", tint: blue,
                           category: .system,
                           phrases: ["eteins l ecran", "veille ecran", "veille de l ecran", "coupe l ecran",
                                     "endors l ecran", "ecran en veille"],
                           working: "Extinction de l'écran…") { _, done in
            done(ToolOutcome(ok: true, text: "Écran éteint. Touchez une touche pour le rallumer."))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                _ = runShellDetailed("/usr/bin/pmset", ["displaysleepnow"])
            }
        })
        m.register(BudTool(id: "lock", title: "Verrouiller l'écran",
                           subtitle: "Après 3 s, annulable", icon: "lock.fill", tint: violet,
                           category: .system, risk: .countdown(3),
                           phrases: ["verrouille", "verrouiller", "bloque l ecran", "bloque la session",
                                     "verrouille l ecran"],
                           working: "Verrouillage…") { _, done in
            let r = m.host.lockScreen()
            done(ToolOutcome(ok: true, text: r))
        })
        m.register(BudTool(id: "appearance", title: "Basculer clair / sombre",
                           subtitle: "L'apparence de tout macOS", icon: "circle.lefthalf.fill", tint: amber,
                           category: .system, phrases: ["bascule le theme", "clair sombre", "apparence"]) { _, done in
            let r = m.host.setAppearance("toggle")
            done(ToolOutcome(ok: true, text: r, expression: .cool))
        })
        m.register(BudTool(id: "trash", title: "Vider la corbeille",
                           subtitle: "Définitif, avec confirmation", icon: "trash.fill", tint: orange,
                           category: .system,
                           risk: .confirm("Vider la corbeille ? Ce qu'elle contient sera supprimé définitivement."),
                           phrases: ["vide la corbeille", "vider la corbeille", "purge la corbeille"],
                           working: "Vidage de la corbeille…") { _, done in
            m.host.emptyTrash { msg in done(ToolOutcome(ok: true, text: "Corbeille vidée : \(msg)")) }
        })
        m.register(BudTool(id: "network", title: "Infos réseau", subtitle: "Wi-Fi, adresse locale",
                           icon: "wifi", tint: teal, category: .system) { _, done in
            done(ToolOutcome(ok: true, text: m.host.network(), expression: .neutral))
        })
        m.register(BudTool(id: "battery", title: "Batterie", subtitle: "Charge et autonomie",
                           icon: "battery.75", tint: green, category: .system) { _, done in
            done(ToolOutcome(ok: true, text: m.host.battery(), expression: .neutral))
        })

        // ── Agents du Flux ──
        m.register(agentTool(id: "agent-cleanup", agent: "cleanup", title: "Rangement & nettoyage",
                             subtitle: "Téléchargements, apps dormantes", icon: "sparkles", tint: green,
                             phrases: ["agent de rangement", "lance le rangement", "range mon mac",
                                       "apps inutiles", "applications inutiles"]))
        m.register(agentTool(id: "agent-security", agent: "security", title: "Cybersécurité",
                             subtitle: "Liens du presse-papiers et courrier", icon: "lock.shield.fill", tint: red,
                             phrases: ["cybersecurite", "verifie ce lien", "analyse ce lien",
                                       "ce lien est il sur", "phishing", "hameconnage"]))
        m.register(agentTool(id: "agent-weather", agent: "weatherhome", title: "Météo & Maison",
                             subtitle: "Le ciel et vos commandes", icon: "cloud.sun.fill", tint: blue,
                             phrases: []))

        // ── Plus ──
        m.register(BudTool(id: "keys", title: "Raccourcis clavier…",
                           subtitle: "Et les pastilles de l'aperçu", icon: "keyboard", tint: violet,
                           category: .more) { _, done in
            m.host.openKeyboardShortcuts()
            done(ToolOutcome(ok: true, text: "Fenêtre des raccourcis ouverte.", expression: .neutral))
        })
        for (name, icon, tint) in [("Finder", "folder.fill", blue), ("Terminal", "terminal.fill", green)] {
            m.register(BudTool(id: "open-\(name.lowercased())", title: "Ouvrir \(name)", subtitle: "Application",
                               icon: icon, tint: tint, category: .more,
                               phrases: ["ouvre \(name.lowercased())", "lance \(name.lowercased())"]) { _, done in
                let r = runShellDetailed("/usr/bin/open", ["-a", name])
                done(r.status == 0 ? ToolOutcome(ok: true, text: "\(name) ouvert.", expression: .neutral)
                                   : ToolOutcome(ok: false, text: "\(name) n'a pas pu s'ouvrir."))
            })
        }
    }

    // ─────────────────────────────────────────────────────────
    //  La capture
    //
    //  L'autorisation d'abord. Sans « Enregistrement de l'écran »,
    //  macOS ne refuse pas : il rend une image vide ou le seul fond
    //  d'écran. On le demande donc avant, et on dit où l'accorder
    //  plutôt que de laisser une capture inutile sur le Bureau.
    // ─────────────────────────────────────────────────────────

    static let screenSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func captureTool(id: String, title: String, subtitle: String, mode: CaptureMode,
                            target: CaptureTarget, tint: NSColor, phrases: [String]) -> BudTool {
        let m = BudToolManager.shared
        return BudTool(id: id, title: title, subtitle: subtitle, icon: mode.icon, tint: tint,
                       category: .capture, phrases: phrases,
                       working: mode.interactive ? "Cliquez la fenêtre ou tracez la zone…" : "Capture dans un instant…") { _, done in
            if !CGPreflightScreenCaptureAccess() {
                // Montre la demande du système la première fois ; ensuite
                // macOS ne la remontre plus, d'où le lien vers les réglages.
                _ = CGRequestScreenCaptureAccess()
                done(ToolOutcome(ok: false,
                                 text: "BUD n'a pas encore le droit d'enregistrer l'écran. Autorisez-le dans "
                                     + "Confidentialité et sécurité → Enregistrement de l'écran, puis relancez BUD.",
                                 tapLabel: "Ouvrir les réglages",
                                 tap: { BudToolCatalog.screenSettingsOpen() }))
                return
            }
            m.host.hidePanel()
            ScreenCapture.run(mode, to: target) { r in
                m.host.showChat()
                guard r.ok else {
                    let cancelled = r.message.hasPrefix("Capture annulée")
                    var out = ToolOutcome(ok: cancelled, text: r.message,
                                          expression: cancelled ? .neutral : .sad)
                    if r.message.contains("Enregistrement de l'écran") {
                        out.tapLabel = "Ouvrir les réglages"
                        out.tap = { BudToolCatalog.screenSettingsOpen() }
                    }
                    done(out)
                    return
                }
                guard let u = r.url else {
                    done(ToolOutcome(ok: true, text: r.message))
                    return
                }
                done(ToolOutcome(ok: true, text: "Capture enregistrée sur le Bureau.\n\(u.lastPathComponent)",
                                 image: BudToolCatalog.thumbnail(u, max: 520),
                                 tapLabel: "Afficher dans le Finder",
                                 tap: { ScreenCapture.reveal(u) }))
            }
        }
    }

    static func screenSettingsOpen() { NSWorkspace.shared.open(screenSettings) }

    /// Une miniature légère : une capture 5K pèse des dizaines de
    /// mégaoctets en mémoire, la bulle n'en montre que quelques centaines
    /// de points.
    static func thumbnail(_ u: URL, max: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // ─────────────────────────────────────────────────────────
    //  Un agent du Flux, en outil
    //
    //  L'agent pilote lui-même l'expression de BUDs ; l'outil se
    //  contente d'attendre qu'il ait fini et d'en rapporter la
    //  ligne, avec un accès direct au Flux pour les cartes et la
    //  fiche d'approbation.
    // ─────────────────────────────────────────────────────────

    static func agentTool(id: String, agent: String, title: String, subtitle: String,
                          icon: String, tint: NSColor, phrases: [String]) -> BudTool {
        let m = BudToolManager.shared
        return BudTool(id: id, title: title, subtitle: subtitle, icon: icon, tint: tint,
                       category: .agents, phrases: phrases, working: "\(title) au travail…") { progress, done in
            let am = BudAgentManager.shared
            guard am.agent(agent) != nil else {
                done(ToolOutcome(ok: false, text: "Cet agent n'est pas disponible."))
                return
            }
            am.run(agent)
            var ticks = 0
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { tm in
                ticks += 1
                let st = am.state(agent)
                if st.status == .running {
                    if !st.line.isEmpty { progress(st.line) }
                    if ticks < 400 { return }
                }
                tm.invalidate()
                let ok = st.status != .failure
                let open: () -> Void = { m.host.openTab("flow") }
                var text = st.line.isEmpty ? "Terminé." : st.line
                if st.status == .needsApproval { text += "\nRien n'a été touché : la fiche attend votre accord dans le Flux." }
                done(ToolOutcome(ok: ok, text: text,
                                 tapLabel: st.status == .needsApproval ? "Examiner dans le Flux" : "Voir les cartes",
                                 tap: open, expressionHandled: true))
            }
        }
    }
}
