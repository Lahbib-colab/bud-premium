import Cocoa

// ═══════════════════════════════════════════════════════════
//  Sessions / alertes d'agents IA
//  Un agent dépose agents/<id>.json, BUD écrit <id>.reply.
// ═══════════════════════════════════════════════════════════

struct AgentRequest: Codable {
    var id: String
    var source: String
    var title: String
    var detail: String
    var path: String?
    var kind: String        // approval · question · info
    var created: TimeInterval

    var createdDate: Date { Date(timeIntervalSince1970: created) }
    var icon: String {
        switch kind {
        case "question": return "questionmark.bubble.fill"
        case "info": return "info.circle.fill"
        default: return "checkmark.seal.fill"
        }
    }
}

final class AgentCenter {
    static let shared = AgentCenter()

    let dir: URL = {
        let d = budSupportDir.appendingPathComponent("agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private(set) var requests: [AgentRequest] = []
    private var knownIDs = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?

    var onChange: (([AgentRequest], AgentRequest?) -> Void)?

    func start() {
        reload(announce: false)
        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: .main)
            s.setEventHandler { [weak self] in self?.reload(announce: true) }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
        }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.reload(announce: true) }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    func reload(announce: Bool) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return }
        var found: [AgentRequest] = []
        for f in files where f.pathExtension.lowercased() == "json" {
            guard let d = try? Data(contentsOf: f),
                  var r = try? JSONDecoder().decode(AgentRequest.self, from: d) else { continue }
            if r.id.isEmpty { r.id = f.deletingPathExtension().lastPathComponent }
            found.append(r)
        }
        found.sort { $0.created < $1.created }

        let newOnes = found.filter { !knownIDs.contains($0.id) }
        let changed = (found.map { $0.id } != requests.map { $0.id })
        requests = found
        knownIDs = Set(found.map { $0.id })
        if changed || !newOnes.isEmpty {
            onChange?(requests, announce ? newOnes.last : nil)
        }
    }

    func answer(_ r: AgentRequest, reply: String) {
        try? reply.write(to: dir.appendingPathComponent("\(r.id).reply"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(r.id).json"))
        knownIDs.remove(r.id)
        reload(announce: false)
    }

    func reveal(_ r: AgentRequest) {
        guard let p = r.path, !p.isEmpty else { return }
        let u = URL(fileURLWithPath: p)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
            if isDir.boolValue { NSWorkspace.shared.open(u) }
            else { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        }
    }

    func clearAll() { for r in requests { answer(r, reply: "dismissed") } }

    func createDemoRequest() {
        let r = AgentRequest(id: UUID().uuidString, source: "Démo",
                             title: "Lancer la commande ?",
                             detail: "L'agent veut exécuter une migration de base de données.",
                             path: FileManager.default.homeDirectoryForCurrentUser.path,
                             kind: "approval", created: Date().timeIntervalSince1970)
        if let d = try? JSONEncoder().encode(r) {
            try? d.write(to: dir.appendingPathComponent("\(r.id).json"))
        }
        reload(announce: true)
    }
}

final class AgentsPanelView: NSView {
    private let hero: HeroHeader
    private var cards: [NSView] = []
    private var emptyIcon: NSImageView!
    private var emptyLabel: NSTextField!
    private var emptyHint: NSTextField!
    private let listHost = NSView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)

    var onAnswered: ((String) -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Agents", subtitle: "Les validations que vos agents IA attendent de vous.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        addSubview(hero)

        mkSection(self, H - 116, W, "Demandes en attente")

        scroll.frame = NSRect(x: 0, y: 56, width: W, height: H - 180)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        let cy = scroll.frame.midY
        emptyIcon = mkIcon(self, "checkmark.circle.fill", x: W / 2 - 14, y: cy + 24, size: 26, alpha: 0.25)
        emptyLabel = mkLabel("Tout est calme", NSRect(x: 0, y: cy - 4, width: W, height: 22),
                             14, .semibold, alpha: 0.5, .center)
        addSubview(emptyLabel)
        emptyHint = mkLabel("Vos agents peuvent demander une validation avec bud-ask.",
                            NSRect(x: 0, y: cy - 26, width: W, height: 18), 11.5, .regular, alpha: 0.32, .center)
        addSubview(emptyHint)

        let bw = (W - 36) / 4
        let items: [(String, String, () -> Void)] = [
            ("Simuler", "wand.and.stars", { AgentCenter.shared.createDemoRequest() }),
            ("Tout ignorer", "xmark.circle", { [weak self] in
                AgentCenter.shared.clearAll()
                self?.onAnswered?("Demandes ignorées")
            }),
            ("Copier bud-ask", "doc.on.doc.fill", { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\"\(budSupportDir.path)/bud-ask\" \"Titre\" \"Détail\" \"$PWD\"",
                                               forType: .string)
                self?.onAnswered?("Commande copiée")
            }),
            ("Dossier", "folder.fill", { NSWorkspace.shared.open(AgentCenter.shared.dir) })
        ]
        for (i, it) in items.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (bw + 12), y: 0, width: bw, height: 40),
                                title: it.0, icon: it.1, compact: true)
            b.onClick = { _ in it.2() }
            addSubview(b)
        }
    }

    func refresh() {
        let reqs = AgentCenter.shared.requests
        cards.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        ThemeRegistry.shared.prune()

        let empty = reqs.isEmpty
        emptyIcon.isHidden = !empty
        emptyLabel.isHidden = !empty
        emptyHint.isHidden = !empty
        hero.set(subtitle: empty ? "Aucune validation en attente."
                                 : "\(reqs.count) demande(s) attendent votre réponse.",
                 trailing: empty ? "" : "\(reqs.count) en attente")

        let W = scroll.bounds.width - 6
        let cardH: CGFloat = 112
        let totalH = max(scroll.bounds.height, CGFloat(reqs.count) * (cardH + 12))
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: totalH)

        let hm = DateFormatter(); hm.dateFormat = "HH:mm"

        for (i, r) in reqs.enumerated() {
            let y = totalH - CGFloat(i + 1) * (cardH + 12) + 12
            let card = mkCard(listHost, NSRect(x: 0, y: y, width: W, height: cardH), radius: 16)
            card.layer?.borderWidth = 1
            card.layer?.borderColor = warnColor.withAlphaComponent(0.28).cgColor
            cards.append(card)

            mkIcon(card, r.icon, x: 16, y: cardH - 32, size: 15, alpha: 0.9).contentTintColor = warnColor

            card.addSubview(mkFitLabel(r.title, x: 40, y: cardH - 33, 13.5, .bold))

            let meta = "\(r.source) · \(hm.string(from: r.createdDate))"
            let mw = textWidth(meta, size: 10.5, weight: .medium) + 6
            card.addSubview(mkLabel(meta, NSRect(x: W - mw - 16, y: cardH - 31, width: mw, height: 16),
                                    10.5, .medium, alpha: 0.45, .right))

            let detail = mkLabel(r.detail, NSRect(x: 40, y: cardH - 62, width: W - 56, height: 24),
                                 11.5, .regular, alpha: 0.62)
            card.addSubview(detail)

            if let p = r.path, !p.isEmpty {
                let short = p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path,
                                                   with: "~")
                let l = mkLabel(short, NSRect(x: 40, y: cardH - 80, width: W - 56, height: 15),
                                10, .regular, alpha: 0.32)
                l.lineBreakMode = .byTruncatingMiddle
                card.addSubview(l)
            }

            let bw = (W - 44) / 3
            let ok = GlassButton(frame: NSRect(x: 16, y: 12, width: bw, height: 34),
                                 title: "Valider", icon: "checkmark", prominent: true, compact: true)
            ok.onClick = { [weak self] _ in
                AgentCenter.shared.answer(r, reply: "approved")
                self?.onAnswered?("Validé · \(r.title)")
            }
            let no = GlassButton(frame: NSRect(x: 22 + bw, y: 12, width: bw, height: 34),
                                 title: "Refuser", icon: "xmark", compact: true)
            no.destructive = true
            no.onClick = { [weak self] _ in
                AgentCenter.shared.answer(r, reply: "dismissed")
                self?.onAnswered?("Refusé · \(r.title)")
            }
            let open = GlassButton(frame: NSRect(x: 28 + bw * 2, y: 12, width: bw, height: 34),
                                   title: "Ouvrir", icon: "arrow.up.forward.square", compact: true)
            open.enabledFlag = !(r.path ?? "").isEmpty
            open.onClick = { _ in AgentCenter.shared.reveal(r) }
            [ok, no, open].forEach { card.addSubview($0) }
        }
        listHost.scroll(NSPoint(x: 0, y: totalH))
    }
}
