import Cocoa

// ═══════════════════════════════════════════════════════════
//  Le Flux — des agents en nœuds, à la manière de n8n
//
//  Ce n'est pas un moteur n8n et cela ne parle à aucun
//  serveur : c'est une façon de montrer et d'organiser ce que
//  font les agents de BUD. Trois colonnes, lues de gauche à
//  droite :
//
//      Sources  ──▶  Agents  ──▶  BUDs
//
//  Une source est ce qu'un agent lit (les téléchargements, le
//  courrier, le ciel). Un agent est un traitement. BUDs est la
//  sortie : son expression dit le résultat, et ses cartes le
//  détaillent.
//
//  Tout passe par un registre. Un nouvel agent est une classe
//  conforme à `BudAgent`, inscrite d'une ligne dans
//  `BudAgentCatalog.registerDefaults()` : la vue le place,
//  trace ses liens, gère son état et ses cartes. Elle n'a pas
//  à être retouchée.
// ═══════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────
//  Les expressions de BUD, dans le vocabulaire des agents
//
//  Les agents parlent en expressions — sept visages et un
//  état de travail — et pas en humeurs internes : un agent
//  écrit dans une future mise à jour n'a pas à connaître les
//  treize humeurs du compagnon, ni leurs postures.
// ─────────────────────────────────────────────────────────

enum BudExpression: String, CaseIterable {
    case neutral, happy, reflection, annoyed, dizzy, cool, sad, working

    /// L'humeur du compagnon qui porte cette expression — visage et
    /// posture compris.
    var mood: BudMood {
        switch self {
        case .neutral:    return .listening
        case .happy:      return .happy
        case .reflection: return .thinking
        case .annoyed:    return .angry
        case .dizzy:      return .dizzy
        case .cool:       return .proud
        case .sad:        return .sad
        case .working:    return .working
        }
    }

    var label: String {
        switch self {
        case .neutral:    return "Attentif"
        case .happy:      return "Content"
        case .reflection: return "Réfléchi"
        case .annoyed:    return "Agacé"
        case .dizzy:      return "Étourdi"
        case .cool:       return "Cool"
        case .sad:        return "Déçu"
        case .working:    return "Au travail"
        }
    }
}

// ─────────────────────────────────────────────────────────
//  États et badges
// ─────────────────────────────────────────────────────────

enum NodeStatus: Equatable {
    case idle, running, success, warning, failure, needsApproval

    var label: String {
        switch self {
        case .idle:          return "Prêt"
        case .running:       return "En cours"
        case .success:       return "OK"
        case .warning:       return "Alerte"
        case .failure:       return "Échec"
        case .needsApproval: return "À valider"
        }
    }

    var color: NSColor {
        switch self {
        case .idle:          return NSColor(calibratedWhite: 0.62, alpha: 1)
        case .running:       return NSColor(calibratedRed: 0.38, green: 0.66, blue: 1.00, alpha: 1)
        case .success:       return NSColor(calibratedRed: 0.30, green: 0.82, blue: 0.55, alpha: 1)
        case .warning:       return NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.25, alpha: 1)
        case .failure:       return NSColor(calibratedRed: 1.00, green: 0.40, blue: 0.42, alpha: 1)
        case .needsApproval: return NSColor(calibratedRed: 0.72, green: 0.52, blue: 1.00, alpha: 1)
        }
    }

    var icon: String {
        switch self {
        case .idle:          return "circle"
        case .running:       return "arrow.triangle.2.circlepath"
        case .success:       return "checkmark"
        case .warning:       return "exclamationmark.triangle.fill"
        case .failure:       return "xmark"
        case .needsApproval: return "hand.raised.fill"
        }
    }
}

/// Une source : ce qu'un agent lit. Deux agents qui déclarent la même
/// source (même `id`) partagent son nœud dans la vue.
struct FlowSource {
    let id: String
    let title: String
    let icon: String
    var tint: NSColor = NSColor(calibratedWhite: 0.8, alpha: 1)
    /// Ce qu'on en lit, et si quelque chose sort du Mac.
    var note: String = ""
}

// ─────────────────────────────────────────────────────────
//  Les cartes — le détail d'un résultat
//
//  Des cartes compactes à la manière des widgets iOS : une
//  pastille, un intitulé en petites capitales, une valeur en
//  gros, une ligne de détail. Trois styles seulement : une
//  carte de statistique, une carte de contrôle (cliquable,
//  pour la maison) et une carte météo, qui dessine son ciel.
// ─────────────────────────────────────────────────────────

struct BudCard {
    enum Style { case stat, control, weather }

    var style: Style = .stat
    var icon: String
    var title: String
    var value: String
    var detail: String = ""
    var tint: NSColor
    /// Pour une carte de contrôle : l'action au clic. Elle reçoit un
    /// rappel à appeler avec le message de fin.
    var action: ((@escaping (Bool, String) -> Void) -> Void)? = nil
    /// Pour une carte météo : le code OMM et le jour ou la nuit.
    var weatherCode: Int = 0
    var isDay: Bool = true
}

// ─────────────────────────────────────────────────────────
//  La fiche d'approbation
//
//  Tout ce qui supprime, désinstalle ou modifie passe par là.
//  Un agent ne reçoit pas le droit d'agir : il propose une
//  liste, et c'est la fiche qui rend la sélection, cochée à la
//  main. Les éléments risqués arrivent décochés.
// ─────────────────────────────────────────────────────────

struct ApprovalItem {
    let id: String
    var label: String
    var detail: String
    var icon: String
    var bytes: Int64 = 0
    var selected: Bool
    var url: URL? = nil
}

struct ApprovalRequest {
    var title: String
    var message: String
    var items: [ApprovalItem]
    var confirmLabel: String
    var destructive: Bool = true
    /// Exécutée avec les seuls éléments cochés, hors du fil principal si
    /// besoin ; le rappel rend le résultat final.
    var perform: ([ApprovalItem], @escaping (AgentResult) -> Void) -> Void
}

// ─────────────────────────────────────────────────────────
//  Le résultat d'un agent
// ─────────────────────────────────────────────────────────

struct AgentResult {
    var status: NodeStatus
    var expression: BudExpression
    var headline: String
    var cards: [BudCard] = []
    var approval: ApprovalRequest? = nil
    /// Combien de temps BUDs garde l'expression.
    var hold: TimeInterval = 4
}

/// Ce qu'un agent reçoit pour travailler.
final class AgentContext {
    let simulated: Bool
    /// Une ligne d'avancement, affichée sous le nœud. Appelable de
    /// n'importe quel fil.
    let progress: (String) -> Void
    private(set) var cancelled = false
    init(simulated: Bool, progress: @escaping (String) -> Void) {
        self.simulated = simulated
        self.progress = progress
    }
    func cancel() { cancelled = true }
}

// ═══════════════════════════════════════════════════════════
//  Le contrat d'un agent
// ═══════════════════════════════════════════════════════════

protocol BudAgent: AnyObject {
    var id: String { get }
    var name: String { get }
    /// Une phrase : ce que fait l'agent.
    var summary: String { get }
    var icon: String { get }
    var tint: NSColor { get }
    var sources: [FlowSource] { get }
    /// Le vrai travail. `done` peut être appelé de n'importe quel fil ;
    /// le gestionnaire le ramène sur le fil principal.
    func run(_ ctx: AgentContext, done: @escaping (AgentResult) -> Void)
    /// Le même parcours sur des données d'exemple, sans rien lire ni
    /// toucher. Sert à la démonstration et aux essais d'interface.
    func simulate(_ ctx: AgentContext, done: @escaping (AgentResult) -> Void)
}

/// Ce que voit la vue d'un agent à un instant donné.
struct AgentState {
    var status: NodeStatus = .idle
    var line = ""
    var lastRun: Date?
    var result: AgentResult?
    var simulated = false
}

// ═══════════════════════════════════════════════════════════
//  Le registre
// ═══════════════════════════════════════════════════════════

final class BudAgentManager {
    static let shared = BudAgentManager()

    private(set) var agents: [BudAgent] = []
    private(set) var states: [String: AgentState] = [:]
    private var contexts: [String: AgentContext] = [:]

    /// Prévenu à chaque changement d'état, avec l'identifiant de l'agent.
    private var observers: [(String) -> Void] = []
    /// Branché par l'application : c'est ainsi que BUDs change de visage.
    var onExpression: ((BudExpression, TimeInterval) -> Void)?
    /// Une ligne pour la barre d'état de BUD.
    var onStatus: ((String) -> Void)?

    func observe(_ f: @escaping (String) -> Void) { observers.append(f) }
    private func changed(_ id: String) { observers.forEach { $0(id) } }

    func register(_ a: BudAgent) {
        guard !agents.contains(where: { $0.id == a.id }) else { return }
        agents.append(a)
        states[a.id] = AgentState()
        changed(a.id)
    }

    func agent(_ id: String) -> BudAgent? { agents.first { $0.id == id } }
    func state(_ id: String) -> AgentState { states[id] ?? AgentState() }

    /// Toutes les sources, dans l'ordre des agents, sans doublon.
    var sources: [FlowSource] {
        var seen = Set<String>(), out: [FlowSource] = []
        for a in agents { for s in a.sources where seen.insert(s.id).inserted { out.append(s) } }
        return out
    }

    var anyRunning: Bool { states.values.contains { $0.status == .running } }

    // ── Exécution ──

    func run(_ id: String, simulated: Bool = false) {
        guard let a = agent(id), state(id).status != .running else { return }
        var st = state(id)
        st.status = .running
        st.line = simulated ? "Simulation…" : "Démarrage…"
        st.simulated = simulated
        states[id] = st
        changed(id)
        // « Au travail » tient tant que l'agent tourne ; on le renouvelle
        // à la fin, par l'expression du résultat.
        onExpression?(.working, 120)
        onStatus?("\(a.name) : au travail…")

        let ctx = AgentContext(simulated: simulated) { [weak self] line in
            DispatchQueue.main.async {
                guard let s = self, var st = s.states[id], st.status == .running else { return }
                st.line = line
                s.states[id] = st
                s.changed(id)
            }
        }
        contexts[id] = ctx
        let finish: (AgentResult) -> Void = { [weak self] r in
            DispatchQueue.main.async { self?.finish(id, r, ctx: ctx) }
        }
        if simulated { a.simulate(ctx, done: finish) } else { a.run(ctx, done: finish) }
    }

    func cancel(_ id: String) {
        contexts[id]?.cancel()
    }

    private func finish(_ id: String, _ r: AgentResult, ctx: AgentContext) {
        guard contexts[id] === ctx else { return }
        contexts[id] = nil
        var st = state(id)
        st.status = ctx.cancelled ? .idle : (r.approval != nil ? .needsApproval : r.status)
        st.line = ctx.cancelled ? "Interrompu." : r.headline
        st.lastRun = Date()
        st.result = r
        states[id] = st
        changed(id)
        let expr: BudExpression = ctx.cancelled ? .neutral : r.expression
        // Si un autre agent tourne encore, BUDs reste au travail.
        onExpression?(anyRunning ? .working : expr, anyRunning ? 120 : r.hold)
        onStatus?(st.line)
    }

    /// Exécute la fiche d'approbation avec les éléments cochés. Une liste
    /// vide revient à refuser.
    func approve(_ id: String, items: [ApprovalItem]) {
        guard var st = states[id], let req = st.result?.approval else { return }
        let chosen = items.filter { $0.selected }
        guard !chosen.isEmpty else { decline(id); return }
        st.status = .running
        st.line = "Application de votre choix…"
        states[id] = st
        changed(id)
        onExpression?(.working, 120)
        req.perform(chosen) { [weak self] r in
            DispatchQueue.main.async {
                guard let s = self else { return }
                var st = s.state(id)
                st.status = r.status
                st.line = r.headline
                st.lastRun = Date()
                // On garde les cartes du relevé si l'exécution n'en rend pas.
                var merged = r
                if merged.cards.isEmpty { merged.cards = st.result?.cards ?? [] }
                merged.approval = nil
                st.result = merged
                s.states[id] = st
                s.changed(id)
                s.onExpression?(s.anyRunning ? .working : r.expression, r.hold)
                s.onStatus?(r.headline)
            }
        }
    }

    func decline(_ id: String) {
        guard var st = states[id] else { return }
        st.result?.approval = nil
        st.status = .success
        st.line = "Rien n'a été touché."
        states[id] = st
        changed(id)
        onExpression?(.neutral, 2.5)
    }

    /// Sélectionner un nœud montre son dernier état sur le visage de BUDs :
    /// le dernier résultat s'il y en a un, l'attention sinon.
    func preview(_ id: String) {
        let st = state(id)
        if st.status == .running { onExpression?(.working, 120); return }
        onExpression?(st.result?.expression ?? .neutral, 2.5)
    }

    /// Les agents un par un, sur les données d'exemple : la démonstration
    /// complète des nœuds et des expressions.
    func demo() {
        for (i, a) in agents.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 4.5) { [weak self] in
                self?.run(a.id, simulated: true)
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  Le catalogue
//
//  La seule liste à toucher pour ajouter un agent.
// ═══════════════════════════════════════════════════════════

enum BudAgentCatalog {
    static func registerDefaults(mail: @escaping () -> [MailMessage],
                                 city: @escaping () -> String,
                                 runHome: @escaping (String, @escaping (Bool, String) -> Void) -> Void) {
        let m = BudAgentManager.shared
        m.register(CleanupAgent())
        m.register(SecurityAgent(mail: mail))
        m.register(WeatherHomeAgent(city: city, runHome: runHome))
        // Prochains agents : m.register(MonNouvelAgent())
    }
}
