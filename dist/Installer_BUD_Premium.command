#!/bin/bash
set -e

SUPPORT_DIR="$HOME/Library/Application Support/BUD-Assistant"
SRC_DIR="$SUPPORT_DIR/src"
TOOLS_DIR="$SUPPORT_DIR/tools"

echo "============================================================"
echo "   BUD Premium 22.0 — macOS 12 Monterey à Sequoia"
echo "============================================================"

mkdir -p "$SRC_DIR" "$TOOLS_DIR" "$SUPPORT_DIR/agents"

# Sauvegarde de l'état avant toute écriture : une mise à jour ne doit
# jamais coûter les réglages ni les notes.
if [ -f "$SUPPORT_DIR/state.json" ]; then
  cp "$SUPPORT_DIR/state.json" "$SUPPORT_DIR/state.backup-$(date +%Y%m%d-%H%M%S).json"
  echo "Sauvegarde de state.json effectuée."
fi

cat << 'EOF_BUDAGENTS_SWIFT' > "$SRC_DIR/BudAgents.swift"
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
EOF_BUDAGENTS_SWIFT

cat << 'EOF_BUDAPP_SWIFT' > "$SRC_DIR/BudApp.swift"
import Cocoa
import QuartzCore

enum FocusPhase { case idle, focus, rest }

final class BudDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSMenuDelegate {

    private var panel: NotchPanel!
    private var host: DropHost!
    private var backdrop: Backdrop!
    private var chrome: NotchChrome!
    private var content: NSView!
    private var approvalBar: NSView!
    private var approveBtn: GlassButton!
    private var rejectBtn: GlassButton!
    private var detailBtn: GlassButton!
    private var notchState: NotchState = .collapsed

    private let sizeCollapsed = NSSize(width: 214, height: 36)
    private let sizeGlance    = NSSize(width: 470, height: 160)
    private let sizeApproval  = NSSize(width: 600, height: 210)
    private let sizeOpen      = NSSize(width: 880, height: 610)
    private let sidebarW: CGFloat = 196

    // Barre latérale
    private var avatar: CompanionView!
    private var sidebarItems: [SidebarItem] = []
    private var navIndicator: NSView!
    private var panelFrame: NSRect = .zero
    private var statusPill: NSTextField!
    private var panels: [NSView] = []

    private struct NavEntry { let icon: String; let title: String }
    private let nav: [(String, [NavEntry])] = [
        ("Essentiel",     [NavEntry(icon: "face.smiling", title: "Compagnon"),
                           NavEntry(icon: "bubble.left.and.bubble.right.fill", title: "Chat"),
                           NavEntry(icon: "bell.badge.fill", title: "Agents")]),
        ("Communication", [NavEntry(icon: "envelope.fill", title: "Courrier"),
                           NavEntry(icon: "iphone", title: "Téléphone"),
                           NavEntry(icon: "alarm.fill", title: "Rappels"),
                           NavEntry(icon: "music.note", title: "Musique")]),
        ("Travail",       [NavEntry(icon: "internaldrive.fill", title: "Stockage"),
                           NavEntry(icon: "sparkles", title: "Nettoyage"),
                           NavEntry(icon: "timer", title: "Focus"),
                           NavEntry(icon: "note.text", title: "Notes"),
                           NavEntry(icon: "text.badge.plus", title: "Snippets"),
                           NavEntry(icon: "doc.on.clipboard", title: "Presse-papiers"),
                           NavEntry(icon: "tray.full.fill", title: "Rangement")]),
        ("Système",       [NavEntry(icon: "wrench.and.screwdriver", title: "Outils"),
                           NavEntry(icon: "slider.horizontal.3", title: "Réglages")])
    ]
    private let tabCompanion = 0, tabChat = 1, tabAgents = 2, tabMail = 3,
                tabPhone = 4, tabReminders = 5, tabMusic = 6, tabStorage = 7,
                tabClean = 8, tabFocus = 9, tabNotes = 10, tabSnippets = 11,
                tabClipboard = 12, tabSorting = 13, tabTools = 14, tabSettings = 15

    // Modules
    private var storagePanel: StoragePanelView!
    private var agentsPanel: AgentsPanelView!
    private var snippetsPanel: SnippetsPanelView!
    private var cleanPanel: CleanupPanelView!
    private var chatPanel: ChatPanelView!
    private var mailPanel: MailPanelView!
    private var phonePanel: PhonePanelView!
    private var remindersPanel: RemindersPanelView!
    private var musicPanel: MusicPanelView!
    private var capture: CaptureWindow!

    // Panneaux maison
    private var companionHero: HeroHeader!, focusHero: HeroHeader!, notesHero: HeroHeader!
    private var clipHero: HeroHeader!, sortHero: HeroHeader!, toolsHero: HeroHeader!, settingsHero: HeroHeader!
    private var bubbleLabel: NSTextField!
    private var updateCard: UpdateCardView!
    private var focusTime: NSTextField!, focusPhaseLabel: NSTextField!, focusStats: NSTextField!
    private var focusBar: ProgressBar!, focusBtn: GlassButton!
    fileprivate var notesView: NSTextView!
    private var notesCount: NSTextField!
    private var clipButtons: [GlassButton] = []
    private var clipHistory: [String] = []
    private var lastClipChange = NSPasteboard.general.changeCount
    private var searchField: NSSearchField!, toolsInfo: NSTextField!
    private var sortPathLabel: NSTextField!, sortStatsLabel: NSTextField!
    private var sortLogLabels: [NSTextField] = []
    private var undoBtn: GlassButton!
    private var lastMoves: [SortMove] = []
    private var sortLog: [String] = []
    private var themeSeg: SegmentedBar!
    private var glassSeg: SegmentedBar!
    private var personalitySeg: SegmentedBar!
    private var skinSeg: SegmentedBar!
    private var swatches: [SwatchButton] = []
    private var toggleRows: [String: ToggleRow] = [:]
    private var monthRow: ToggleRow!

    private var statusItem: NSStatusItem!
    private var menuItems: [String: NSMenuItem] = [:]

    fileprivate var state = BudStore.shared.load()
    private var animTimer: Timer?, tickTimer: Timer?
    private var currentTab = 0, ticks = 0
    fileprivate var phase: FocusPhase = .idle
    fileprivate var phaseEnd: Date?
    private var lastBreak = Date()
    private var lastCoucouHour = Calendar.current.component(.hour, from: Date())
    private var holdUntil = Date.distantPast
    private var dragging = false
    private var lowDiskAlerted = false
    fileprivate var pendingAgents = 0
    private var frontRequest: AgentRequest?
    private var firingReminder: Reminder?
    private var alarmBeats = 0
    private var lastUnread = -1
    private var hiddenByFullscreen = false

    private let agentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.lahbib.bud.assistant.plist")

    fileprivate var sortRootURL: URL {
        if !state.sortRoot.isEmpty { return URL(fileURLWithPath: state.sortRoot) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/BUD Rangement")
    }

    // ═══════════ Lancement ═══════════

    func applicationDidFinishLaunching(_ n: Notification) {
        refreshTheme()
        normalizeSessions()
        buildWindow()
        buildStatusItem()
        installMonitors()

        MailRouter.account = state.gmailAccount
        GmailAuth.shared.email = state.oauthEmail
        phonePanel.refresh()        // le compte est restauré après buildWindow()
        applyBudStyle()
        capture = CaptureWindow()
        capture.onSubmit = { [weak self] text, target in self?.handleCapture(text, target) }

        AgentCenter.shared.onChange = { [weak self] list, newOne in self?.agentsChanged(list, newOne) }
        AgentCenter.shared.start()

        updateFocusUI()
        storagePanel.refresh(animated: true)
        agentsPanel.refresh()
        snippetsPanel.refresh()
        refreshClipboardUI()
        refreshSortUI()
        refreshSettingsUI()
        remindersPanel.refresh()
        refreshReminderBadge()
        selectTab(0)
        refreshChips()
        applyTheme()

        panel.orderFrontRegardless()

        animTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.animate() }
        RunLoop.main.add(animTimer!, forMode: .common)
        tickTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tickTimer!, forMode: .common)

        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged),
                                                          name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumesChanged),
                                                          name: NSWorkspace.didUnmountNotification, object: nil)
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(systemThemeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let g = timeGreeting()
            self?.coucou(g.0, g.1, hold: 4.5)
        }
        if Date().timeIntervalSince1970 - state.lastUpdateCheck > 86400 {
            state.lastUpdateCheck = Date().timeIntervalSince1970
            BudStore.shared.save(state)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.updateCard.check(silent: true)
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) { BudStore.shared.save(state) }

    // ═══════════ Thème ═══════════

    private func systemIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func refreshTheme() {
        TH.dark = state.themeMode == 0 ? systemIsDark() : (state.themeMode == 2)
        TH.glass = state.glassLevel
        TH.accent = resolvedAccent(state.accentIndex, dark: TH.dark)
    }

    @objc private func systemThemeChanged() {
        guard state.themeMode == 0 else { return }
        applyTheme()
    }

    private func applyTheme() {
        refreshTheme()
        panel.appearance = NSAppearance(named: TH.dark ? .vibrantDark : .vibrantLight)
        backdrop.isHidden = (TH.glass == 0)
        backdrop.material = TH.glass == 2 ? .underWindowBackground : .hudWindow
        backdrop.radius = radiusFor(notchState)
        backdrop.needsLayout = true

        ThemeRegistry.shared.apply()

        notesView?.backgroundColor = TH.fill(0.06)
        notesView?.textColor = TH.text
        notesView?.insertionPointColor = TH.text

        content.subviews.forEach { $0.needsDisplay = true }
        panels.forEach { p in p.subviews.forEach { $0.needsDisplay = true } }
        sidebarItems.forEach { $0.needsDisplay = true }
        navIndicator?.layer?.backgroundColor = TH.accent.withAlphaComponent(0.16).cgColor
        navIndicator?.layer?.borderColor = TH.accent.withAlphaComponent(0.30).cgColor
        avatar?.needsDisplay = true
        chrome.needsDisplay = true
        storagePanel?.refresh()
        snippetsPanel?.refresh()
        agentsPanel?.refresh()
    }

    private func radiusFor(_ s: NotchState) -> CGFloat {
        switch s {
        case .collapsed: return 15
        case .open: return 30
        default: return 26
        }
    }

    // ═══════════ Fenêtre ═══════════

    private func sizeFor(_ s: NotchState) -> NSSize {
        switch s {
        case .collapsed: return sizeCollapsed
        case .glance: return sizeGlance
        case .approval: return sizeApproval
        case .open: return sizeOpen
        }
    }

    private func frameFor(_ s: NotchState) -> NSRect {
        let sf = (NSScreen.main ?? NSScreen.screens[0]).frame
        let size = sizeFor(s)
        return NSRect(x: (sf.midX - size.width / 2).rounded(),
                      y: sf.maxY - size.height, width: size.width, height: size.height)
    }

    private func buildWindow() {
        panel = NotchPanel(contentRect: frameFor(.collapsed),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Sans .fullScreenAuxiliary, le notch ne s'invite pas dans l'espace
        // plein écran d'une autre application.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        host = DropHost(frame: NSRect(origin: .zero, size: sizeCollapsed))
        host.autoresizingMask = [.width, .height]
        host.onEnter = { [weak self] in self?.dragEnter() }
        host.onExit = { [weak self] in self?.dragExit() }
        host.onDrop = { [weak self] urls in self?.handleDrop(urls) }
        panel.contentView = host

        backdrop = Backdrop(frame: NSRect(origin: .zero, size: sizeCollapsed))
        backdrop.autoresizingMask = [.width, .height]
        backdrop.blendingMode = .behindWindow
        backdrop.material = .hudWindow
        backdrop.state = .active
        host.addSubview(backdrop)

        chrome = NotchChrome(frame: NSRect(origin: .zero, size: sizeCollapsed))
        chrome.autoresizingMask = [.width, .height]
        chrome.onHover = { [weak self] inside in self?.hover(inside) }
        chrome.onClick = { [weak self] in self?.notchClicked() }
        host.addSubview(chrome)

        buildApprovalBar()
        host.addSubview(approvalBar)

        content = NSView(frame: NSRect(origin: .zero, size: sizeOpen))
        content.isHidden = true
        host.addSubview(content)
        buildContent()
    }

    /// Boutons réels de la carte d'approbation affichée dans le notch.
    private func buildApprovalBar() {
        let W = sizeApproval.width, H = sizeApproval.height
        approvalBar = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        approvalBar.isHidden = true

        let left: CGFloat = 98
        let avail = W - left - 22
        let bw = (avail - 24) / 3
        let y: CGFloat = H - 170

        approveBtn = GlassButton(frame: NSRect(x: left, y: y, width: bw, height: 36),
                                 title: "Autoriser", icon: "checkmark", prominent: true)
        approveBtn.onClick = { [weak self] _ in self?.answerFront("approved") }
        rejectBtn = GlassButton(frame: NSRect(x: left + bw + 12, y: y, width: bw, height: 36),
                                title: "Refuser", icon: "xmark")
        rejectBtn.destructive = true
        rejectBtn.onClick = { [weak self] _ in self?.answerFront("dismissed") }
        detailBtn = GlassButton(frame: NSRect(x: left + (bw + 12) * 2, y: y, width: bw, height: 36),
                                title: "Détails", icon: "arrow.up.forward.square")
        detailBtn.onClick = { [weak self] _ in
            guard let s = self else { return }
            s.openPanel()
            s.selectTab(s.firingReminder != nil ? s.tabReminders : s.tabAgents)
        }
        [approveBtn, rejectBtn, detailBtn].forEach { approvalBar.addSubview($0) }
    }

    private func answerFront(_ reply: String) {
        if let rem = firingReminder {
            if reply == "approved" { ReminderStore.shared.complete(id: rem.id) }
            else { ReminderStore.shared.snooze(id: rem.id, minutes: 10) }
            firingReminder = nil
            alarmBeats = 0
            remindersPanel?.refresh()
            refreshReminderBadge()
            approvalBar.isHidden = true
            setState(.collapsed)
            setStatus(reply == "approved" ? "Rappel terminé" : "Reporté de 10 minutes")
            return
        }
        guard let r = frontRequest else { return }
        AgentCenter.shared.answer(r, reply: reply)
        frontRequest = nil
        approvalBar.isHidden = true
        setState(.collapsed)
    }

    // ═══════════ Rappels et courrier ═══════════

    private func refreshReminderBadge() {
        let due = ReminderStore.shared.items.filter { $0.fireAt <= Date().timeIntervalSince1970 }.count
        if sidebarItems.indices.contains(tabReminders) { sidebarItems[tabReminders].badgeCount = due }
    }

    private func fireReminder(_ r: Reminder) {
        firingReminder = r
        alarmBeats = 0
        avatar?.alertCount = max(1, pendingAgents)
        if state.notifyEnabled { notify("Rappel · \(r.title)", r.whenLabel) }
        guard state.notchEnabled else { return }
        chrome.alertCount = max(1, pendingAgents)
        chrome.greeting = r.title
        chrome.subtitle = "Rappel · \(r.repeatLabel)"
        chrome.mono = r.whenLabel
        approveBtn.title = "Terminé"
        approveBtn.iconName = "checkmark"
        rejectBtn.title = "+10 min"
        rejectBtn.iconName = "clock.arrow.circlepath"
        detailBtn.title = "Rappels"
        holdUntil = Date().addingTimeInterval(300)
        setState(.approval)
        if state.alarmSound { NSSound(named: NSSound.Name("Glass"))?.play() }
    }

    private func checkReminders() {
        guard firingReminder == nil else {
            // Alarme en cours : on relance le son toutes les 5 secondes, une minute durant
            alarmBeats += 1
            if state.alarmSound && alarmBeats % 5 == 0 && alarmBeats < 60 {
                NSSound(named: NSSound.Name("Glass"))?.play()
            }
            return
        }
        if let due = ReminderStore.shared.due() { fireReminder(due) }
    }

    private func checkMail() {
        guard state.mailWatch, MailRouter.gmailReady || MailBridge.mailRunning() else { return }
        DispatchQueue.global(qos: .utility).async {
            let snap = MailRouter.snapshot(1)
            let n = snap.unread
            guard n >= 0, snap.error == nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                let previous = s.lastUnread
                s.lastUnread = n
                if s.sidebarItems.indices.contains(s.tabMail) {
                    s.sidebarItems[s.tabMail].badgeCount = n
                }
                guard previous >= 0, n > previous else { return }
                let newOnes = n - previous
                let latest = snap.msgs.first
                let who = latest?.shortSender ?? "votre boîte"
                let what = latest?.subject ?? ""
                var title = newOnes == 1 ? "Nouveau message" : "\(newOnes) nouveaux messages"
                // Un message dangereux doit se signaler avant d'être ouvert.
                if let lvl = latest?.threat.level, lvl != .clean {
                    title = lvl == .dangerous ? "Message dangereux" : "Message suspect"
                    s.chrome.alertCount = max(s.chrome.alertCount, 1)
                }
                s.coucou(title, what.isEmpty ? who : "\(who) · \(what)", hold: 7, push: true)
            }
        }
    }

    private func buildContent() {
        let W = sizeOpen.width, H = sizeOpen.height

        // ── Barre latérale ──
        let sep = NSView(frame: NSRect(x: sidebarW, y: 0, width: 1, height: H))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = TH.fill(0.08).cgColor
        ThemeRegistry.shared.register(box: sep, alpha: 0.08)
        content.addSubview(sep)

        avatar = CompanionView(frame: NSRect(x: 14, y: H - 70, width: 46, height: 46))
        avatar.onTap = { [weak self] in self?.cycleTip() }
        content.addSubview(avatar)
        content.addSubview(mkFitLabel("BUD Premium", x: 66, y: H - 50, 14.5, .bold))
        content.addSubview(mkFitLabel("\(budVersion) · \(budSignature)", x: 66, y: H - 66, 10.5, .medium, alpha: 0.42))

        let navScroll = NSScrollView(frame: NSRect(x: 0, y: 58, width: sidebarW, height: H - 150))
        navScroll.hasVerticalScroller = true
        navScroll.scrollerStyle = .overlay
        navScroll.drawsBackground = false
        navScroll.borderType = .noBorder
        navScroll.autohidesScrollers = true
        content.addSubview(navScroll)

        var contentH: CGFloat = 8
        for (_, entries) in nav { contentH += 20 + CGFloat(entries.count) * 30 + 6 }
        let navDoc = NSView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: max(contentH, navScroll.bounds.height)))
        navScroll.documentView = navDoc

        navIndicator = NSView(frame: .zero)
        navIndicator.wantsLayer = true
        navIndicator.layer?.cornerRadius = 9
        navIndicator.layer?.backgroundColor = TH.accent.withAlphaComponent(0.16).cgColor
        navIndicator.layer?.borderWidth = 1
        navIndicator.layer?.borderColor = TH.accent.withAlphaComponent(0.30).cgColor
        navDoc.addSubview(navIndicator)

        var y = navDoc.bounds.height - 4
        var index = 0
        for (section, entries) in nav {
            navDoc.addSubview(mkLabel(section.uppercased(), NSRect(x: 20, y: y - 14, width: sidebarW - 32, height: 14),
                                      9.5, .bold, alpha: 0.3))
            y -= 20
            for e in entries {
                let item = SidebarItem(frame: NSRect(x: 10, y: y - 28, width: sidebarW - 24, height: 30),
                                       icon: e.icon, title: e.title, index: index)
                item.onClick = { [weak self] i in self?.selectTab(i) }
                navDoc.addSubview(item)
                sidebarItems.append(item)
                y -= 30
                index += 1
            }
            y -= 6
        }
        navScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, navDoc.bounds.height - navScroll.bounds.height)))

        let pill = mkCard(content, NSRect(x: 10, y: 14, width: sidebarW - 20, height: 36), radius: 12, alpha: 0.07)
        let dot = NSView(frame: NSRect(x: 14, y: 16, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = TH.accent.cgColor
        pill.addSubview(dot)
        statusPill = mkLabel("Prêt · ⌘⌥D pour dicter", NSRect(x: 28, y: 10, width: sidebarW - 48, height: 16),
                             11, .medium, alpha: 0.6)
        pill.addSubview(statusPill)

        let closeBtn = GlassButton(frame: NSRect(x: W - 46, y: H - 44, width: 32, height: 28),
                                   title: "", icon: "chevron.up")
        closeBtn.onClick = { [weak self] _ in self?.collapse() }
        content.addSubview(closeBtn)

        // ── Panneaux ──
        let pf = NSRect(x: sidebarW + 22, y: 20, width: W - sidebarW - 46, height: H - 40)
        panelFrame = pf

        let companion = NSView(frame: pf)
        chatPanel = ChatPanelView(frame: pf)
        agentsPanel = AgentsPanelView(frame: pf)
        mailPanel = MailPanelView(frame: pf)
        phonePanel = PhonePanelView(frame: pf)
        remindersPanel = RemindersPanelView(frame: pf)
        musicPanel = MusicPanelView(frame: pf, source: state.musicSource)
        storagePanel = StoragePanelView(frame: pf)
        cleanPanel = CleanupPanelView(frame: pf)
        let focus = NSView(frame: pf)
        let notes = NSView(frame: pf)
        snippetsPanel = SnippetsPanelView(frame: pf)
        let clip = NSView(frame: pf)
        let sorting = NSView(frame: pf)
        let tools = NSView(frame: pf)
        let settings = NSView(frame: pf)

        panels = [companion, chatPanel, agentsPanel, mailPanel, phonePanel, remindersPanel,
                  musicPanel, storagePanel, cleanPanel, focus, notes, snippetsPanel,
                  clip, sorting, tools, settings]
        panels.forEach { p in
            p.isHidden = true
            content.addSubview(p)
        }

        storagePanel.onEject = { [weak self] msg in self?.setStatus(msg) }
        agentsPanel.onAnswered = { [weak self] msg in
            self?.refreshAgentBadges()
            self?.setStatus(msg)
        }
        snippetsPanel.onStatus = { [weak self] msg in
            self?.snippetsPanel.setStatus(msg)
            self?.setStatus(msg)
        }
        snippetsPanel.onCapture = { [weak self] in self?.showCapture() }
        cleanPanel.onStatus = { [weak self] msg in self?.setStatus(msg) }
        cleanPanel.onCleaned = { [weak self] in self?.storagePanel.refresh(animated: true) }
        chatPanel.onStatus = { [weak self] msg in self?.setStatus(msg) }
        mailPanel.onStatus = { [weak self] msg in self?.setStatus(msg) }
        mailPanel.fromAddress = { [weak self] in self?.state.mailFrom ?? "" }
        mailPanel.onAccountChange = { [weak self] addr in
            guard let s = self else { return }
            if GmailAuth.shared.isConnected {
                s.state.oauthEmail = GmailAuth.shared.email
                s.state.gmailAccount = ""
            } else {
                s.state.oauthEmail = ""
                s.state.gmailAccount = addr
            }
            BudStore.shared.save(s.state)
            s.lastUnread = -1
            s.checkMail()
            s.phonePanel.refresh()
        }
        phonePanel.onStatus = { [weak self] msg in self?.setStatus(msg) }
        phonePanel.prefillAddress = { [weak self] in self?.state.mailFrom ?? "" }
        phonePanel.onAccountChange = { [weak self] addr in
            guard let s = self else { return }
            if GmailAuth.shared.isConnected {
                s.state.oauthEmail = GmailAuth.shared.email
                s.state.gmailAccount = ""
            } else {
                s.state.oauthEmail = ""
                s.state.gmailAccount = addr
            }
            BudStore.shared.save(s.state)
            s.lastUnread = -1
            s.checkMail()
            s.mailPanel.refresh()
        }
        remindersPanel.onStatus = { [weak self] msg in self?.setStatus(msg) }
        remindersPanel.onChanged = { [weak self] in self?.refreshReminderBadge() }
        musicPanel.onStatus = { [weak self] msg in self?.setStatus(msg) }
        musicPanel.onSourceChange = { [weak self] i in
            self?.state.musicSource = i
            if let st = self?.state { BudStore.shared.save(st) }
        }
        wireChat()

        buildCompanion(companion)
        buildFocus(focus)
        buildNotes(notes)
        buildClipboard(clip)
        buildSorting(sorting)
        buildTools(tools)
        buildSettings(settings)
    }

    private func addHero(_ p: NSView, _ title: String, _ subtitle: String) -> HeroHeader {
        let h = HeroHeader(frame: NSRect(x: 0, y: p.bounds.height - 92, width: p.bounds.width, height: 92),
                           title: title, subtitle: subtitle)
        p.addSubview(h)
        return h
    }

    private func editUpdateChannel() {
        let al = NSAlert()
        al.messageText = "Canal de mise à jour"
        al.informativeText = "Adresse d'un fichier JSON : { \"version\", \"notes\", \"url\" }."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        f.stringValue = state.updateChannel.isEmpty ? BudUpdater.defaultChannel : state.updateChannel
        al.accessoryView = f
        al.addButton(withTitle: "Enregistrer")
        al.addButton(withTitle: "Valeur par défaut")
        al.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        switch al.runModal() {
        case .alertFirstButtonReturn:
            state.updateChannel = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .alertSecondButtonReturn:
            state.updateChannel = ""
        default:
            return
        }
        BudStore.shared.save(state)
        updateCard.check()
    }

    private func setStatus(_ s: String) {
        statusPill?.stringValue = s.count > 30 ? String(s.prefix(29)) + "…" : s
    }

    // ═══════════ Panneaux maison ═══════════

    private func buildCompanion(_ p: NSView) {
        let W = p.bounds.width, H = p.bounds.height
        companionHero = addHero(p, "Compagnon", "Votre assistant de bureau, toujours dans le notch.")

        mkCard(p, NSRect(x: 0, y: H - 234, width: W, height: 126), radius: 16)
        bubbleLabel = mkLabel(tipsFor(state.personality)[0],
                              NSRect(x: 20, y: H - 222, width: W - 40, height: 100), 14.5, .medium)
        bubbleLabel.lineBreakMode = .byWordWrapping
        bubbleLabel.maximumNumberOfLines = 4
        bubbleLabel.cell?.usesSingleLineMode = false
        p.addSubview(bubbleLabel)

        let bw = (W - 24) / 3
        let r1 = H - 288
        let specs: [(String, String, Bool, () -> Void)] = [
            ("Conseil", "sparkles", true, { [weak self] in self?.avatarTip() }),
            ("Coucou", "hand.wave.fill", false, { [weak self] in self?.sayHello() }),
            ("Blague", "bubble.left.fill", false, { [weak self] in self?.tellJoke() })
        ]
        for (i, s) in specs.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (bw + 12), y: r1, width: bw, height: 44),
                                title: s.0, icon: s.1, prominent: s.2)
            b.onClick = { _ in s.3() }
            p.addSubview(b)
        }

        mkSection(p, r1 - 32, W, "Personnalité")
        personalitySeg = SegmentedBar(frame: NSRect(x: 0, y: r1 - 82, width: W, height: 44),
                                      items: personalityNames.enumerated().map {
                                          SegmentedBar.Item(title: $0.element, icon: personalityIcons[$0.offset])
                                      },
                                      selected: state.personality)
        personalitySeg.onSelect = { [weak self] i in self?.setPersonality(i) }
        p.addSubview(personalitySeg)

        // Sous la personnalité (200·244) viennent l'habillage puis « À propos ».
        // Les hauteurs sont calées à la main pour que tout tienne sans
        // défilement : habillage 126·166, carte de version 32·100, astuce 10·26.
        mkSection(p, 172, W, "Habillage")
        skinSeg = SegmentedBar(frame: NSRect(x: 0, y: 126, width: W, height: 40),
                               items: [SegmentedBar.Item(title: "À plat", icon: "square.fill"),
                                       SegmentedBar.Item(title: "Nacré", icon: "sparkle"),
                                       SegmentedBar.Item(title: "Métal", icon: "cpu")],
                               selected: state.budSkin)
        skinSeg.onSelect = { [weak self] i in self?.setBudSkin(i) }
        p.addSubview(skinSeg)

        mkSection(p, 106, W, "À propos")
        updateCard = UpdateCardView(frame: NSRect(x: 0, y: 32, width: W, height: 68))
        updateCard.channel = { [weak self] in
            let c = self?.state.updateChannel ?? ""
            return c.isEmpty ? BudUpdater.defaultChannel : c
        }
        updateCard.onStatus = { [weak self] m in self?.setStatus(m) }
        updateCard.onChannelEdit = { [weak self] in self?.editUpdateChannel() }
        p.addSubview(updateCard)

        p.addSubview(mkLabel("Glissez des fichiers sur le notch pour les classer · ⌘⌥D pour la capture rapide.",
                             NSRect(x: 0, y: 10, width: W, height: 16), 11, .regular, alpha: 0.33, .center))
    }

    /// Change l'habillage du personnage et le fait réagir, pour qu'on voie
    /// aussitôt le nouveau rendu bouger.
    private func setBudSkin(_ i: Int) {
        state.budSkin = max(0, min(2, i))
        // L'ancien drapeau v17 reste dans le fichier pour les retours en
        // arrière : on le garde cohérent, sinon la migration au prochain
        // lancement réimposerait le nacré.
        state.budPremium = (state.budSkin == 1)
        BudStore.shared.save(state)
        applyBudStyle()
        avatar?.react()
        setStatus(["Compagnon à plat", "Compagnon nacré", "Compagnon métal"][state.budSkin])
    }

    private func buildFocus(_ p: NSView) {
        let W = p.bounds.width, H = p.bounds.height
        focusHero = addHero(p, "Focus", "Des sessions courtes, une tâche à la fois.")

        focusTime = mkLabel("25:00", NSRect(x: 0, y: H - 206, width: W, height: 86), 66, .semibold, alpha: 1, .center, mono: true)
        p.addSubview(focusTime)
        focusPhaseLabel = mkLabel("", NSRect(x: 0, y: H - 232, width: W, height: 18), 12.5, .medium, alpha: 0.7, .center)
        p.addSubview(focusPhaseLabel)
        focusBar = ProgressBar(frame: NSRect(x: 60, y: H - 256, width: W - 120, height: 6))
        p.addSubview(focusBar)
        focusStats = mkLabel("", NSRect(x: 0, y: H - 286, width: W, height: 18), 11, .regular, alpha: 0.45, .center)
        p.addSubview(focusStats)

        let r = H - 352
        focusBtn = GlassButton(frame: NSRect(x: 0, y: r, width: W * 0.44, height: 48),
                               title: "Démarrer", icon: "play.fill", prominent: true)
        focusBtn.onClick = { [weak self] _ in self?.toggleFocus() }
        p.addSubview(focusBtn)
        let sw = (W * 0.56 - 24) / 2
        let b1 = GlassButton(frame: NSRect(x: W * 0.44 + 12, y: r, width: sw, height: 48), title: "−5 min", icon: "minus")
        b1.onClick = { [weak self] _ in self?.changeFocus(-5) }
        let b2 = GlassButton(frame: NSRect(x: W * 0.44 + 24 + sw, y: r, width: sw, height: 48), title: "+5 min", icon: "plus")
        b2.onClick = { [weak self] _ in self?.changeFocus(5) }
        [b1, b2].forEach { p.addSubview($0) }

        p.addSubview(mkLabel("Le compte à rebours reste visible dans le notch replié.",
                             NSRect(x: 0, y: 14, width: W, height: 16), 11, .regular, alpha: 0.33, .center))
    }

    private func buildNotes(_ p: NSView) {
        let W = p.bounds.width, H = p.bounds.height
        notesHero = addHero(p, "Notes", "Un bloc qui se sauvegarde à chaque frappe.")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 60, width: W, height: H - 164))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 14
        scroll.layer?.masksToBounds = true

        let big: CGFloat = 1_000_000
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: W, height: H - 164))
        tv.minSize = NSSize(width: 0, height: H - 164)
        tv.maxSize = NSSize(width: big, height: big)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: W, height: big)
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = true
        tv.backgroundColor = TH.fill(0.06)
        tv.textColor = TH.text
        tv.insertionPointColor = TH.text
        tv.font = NSFont.systemFont(ofSize: 13.5)
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 14, height: 14)
        tv.string = state.notes
        tv.delegate = self
        scroll.documentView = tv
        notesView = tv
        p.addSubview(scroll)

        let bw = (W - 140 - 24) / 3
        let specs: [(String, String, Bool, () -> Void)] = [
            ("Copier", "doc.on.doc.fill", false, { [weak self] in self?.copyNotes() }),
            ("Markdown", "square.and.arrow.down.fill", false, { [weak self] in self?.exportNotes() }),
            ("Effacer", "trash.fill", true, { [weak self] in self?.clearNotes() })
        ]
        for (i, s) in specs.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (bw + 12), y: 6, width: bw, height: 42),
                                title: s.0, icon: s.1)
            b.destructive = s.2
            b.onClick = { _ in s.3() }
            p.addSubview(b)
        }
        notesCount = mkLabel("", NSRect(x: W - 136, y: 20, width: 136, height: 16), 11, .medium, alpha: 0.4, .right)
        p.addSubview(notesCount)
        updateNotesCount()
    }

    private func buildClipboard(_ p: NSView) {
        let W = p.bounds.width, H = p.bounds.height
        clipHero = addHero(p, "Presse-papiers", "Les derniers textes copiés, prêts à resservir.")

        mkSection(p, H - 116, W - 130, "Historique")
        let clear = GlassButton(frame: NSRect(x: W - 120, y: H - 128, width: 120, height: 32),
                                title: "Vider", icon: "trash", compact: true)
        clear.onClick = { [weak self] _ in self?.clearClipboard() }
        p.addSubview(clear)

        for i in 0..<6 {
            let b = GlassButton(frame: NSRect(x: 0, y: H - 174 - CGFloat(i) * 48, width: W, height: 42),
                                title: "—", icon: "doc.on.clipboard", alignLeft: true)
            b.idx = i
            b.enabledFlag = false
            b.onClick = { [weak self] btn in self?.pasteBack(btn.idx) }
            p.addSubview(b)
            clipButtons.append(b)
        }
        p.addSubview(mkLabel("Un clic replace l'élément dans le presse-papiers.",
                             NSRect(x: 0, y: 14, width: W, height: 16), 11, .regular, alpha: 0.33, .center))
    }

    private func buildSorting(_ p: NSView) {
        let W = p.bounds.width, H = p.bounds.height
        sortHero = addHero(p, "Rangement", "Déposez des fichiers sur le notch, je les classe.")

        mkSection(p, H - 116, W, "Dossier de destination")
        sortPathLabel = mkLabel("", NSRect(x: 2, y: H - 142, width: W - 250, height: 18), 12.5, .semibold)
        sortPathLabel.lineBreakMode = .byTruncatingHead
        p.addSubview(sortPathLabel)

        let bChange = GlassButton(frame: NSRect(x: W - 242, y: H - 148, width: 116, height: 32),
                                  title: "Changer", icon: "folder.badge.gearshape", compact: true)
        bChange.onClick = { [weak self] _ in self?.chooseSortRoot() }
        let bOpen = GlassButton(frame: NSRect(x: W - 118, y: H - 148, width: 118, height: 32),
                                title: "Ouvrir", icon: "folder.fill", compact: true)
        bOpen.onClick = { [weak self] _ in self?.openSortRoot() }
        [bChange, bOpen].forEach { p.addSubview($0) }

        monthRow = ToggleRow(frame: NSRect(x: 0, y: H - 202, width: (W - 12) / 2, height: 46),
                             title: "Sous-dossier par mois", icon: "calendar")
        monthRow.onToggle = { [weak self] in self?.toggleMonth() }
        p.addSubview(monthRow)

        undoBtn = GlassButton(frame: NSRect(x: (W - 12) / 2 + 12, y: H - 202, width: (W - 12) / 2, height: 46),
                              title: "Annuler le rangement", icon: "arrow.uturn.backward")
        undoBtn.enabledFlag = false
        undoBtn.onClick = { [weak self] _ in self?.undoSort() }
        p.addSubview(undoBtn)

        sortStatsLabel = mkLabel("", NSRect(x: 2, y: H - 228, width: W, height: 16), 11, .medium, alpha: 0.5)
        p.addSubview(sortStatsLabel)

        mkSection(p, H - 256, W, "Journal")
        for i in 0..<6 {
            let l = mkLabel("", NSRect(x: 2, y: H - 282 - CGFloat(i) * 23, width: W - 4, height: 18),
                            11.5, .regular, alpha: 0.6)
            l.lineBreakMode = .byTruncatingMiddle
            p.addSubview(l)
            sortLogLabels.append(l)
        }
        p.addSubview(mkLabel("Un dossier entier fonctionne aussi : il est parcouru en profondeur.",
                             NSRect(x: 0, y: 14, width: W, height: 16), 11, .regular, alpha: 0.33, .center))
    }

    private func buildTools(_ p: NSView) {
        let W = p.bounds.width, H = p.bounds.height
        toolsHero = addHero(p, "Outils", "Les raccourcis système dont vous vous servez tous les jours.")

        searchField = NSSearchField(frame: NSRect(x: 0, y: H - 134, width: W, height: 32))
        searchField.placeholderString = "Rechercher sur le web…"
        searchField.font = NSFont.systemFont(ofSize: 12.5)
        searchField.target = self
        searchField.action = #selector(webSearch(_:))
        p.addSubview(searchField)

        let bw = (W - 12) / 2
        func tool(_ x: CGFloat, _ y: CGFloat, _ t: String, _ i: String, _ run: @escaping () -> Void) {
            let b = GlassButton(frame: NSRect(x: x, y: y, width: bw, height: 44), title: t, icon: i)
            b.onClick = { _ in run() }
            p.addSubview(b)
        }
        let r1 = H - 192, r2 = r1 - 56, r3 = r2 - 56
        tool(0, r1, "Veille écran", "moon.fill") { runShell("/usr/bin/pmset", ["displaysleepnow"]) }
        tool(bw + 12, r1, "Clair / sombre système", "circle.lefthalf.fill") { [weak self] in self?.toggleSystemDark() }
        tool(0, r2, "Corbeille", "trash.fill") {
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        }
        tool(bw + 12, r2, "Infos réseau", "wifi") { [weak self] in self?.networkInfo() }

        let apps: [(String, String)] = [("Finder", "folder.fill"), ("Safari", "safari.fill"),
                                        ("Mail", "envelope.fill"), ("Terminal", "terminal.fill")]
        let aw = (W - 36) / 4
        for (i, a) in apps.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (aw + 12), y: r3, width: aw, height: 42),
                                title: a.0, icon: a.1, compact: true)
            b.idx = i
            b.onClick = { [weak self] btn in self?.launchApp(btn.idx) }
            p.addSubview(b)
        }

        toolsInfo = mkLabel("Finder · Safari · Mail · Terminal", NSRect(x: 0, y: 10, width: W, height: 40),
                            11.5, .regular, alpha: 0.5, .center)
        toolsInfo.lineBreakMode = .byWordWrapping
        toolsInfo.maximumNumberOfLines = 2
        toolsInfo.cell?.usesSingleLineMode = false
        p.addSubview(toolsInfo)
    }

    private func buildSettings(_ p: NSView) {
        let W = p.bounds.width, H = p.bounds.height
        settingsHero = addHero(p, "Réglages", "Apparence, matière et comportement de BUD.")

        // Tout tient dans la hauteur du panneau : aucune barre de défilement.
        mkSection(p, H - 122, W, "Apparence")
        themeSeg = SegmentedBar(frame: NSRect(x: 0, y: H - 170, width: W, height: 42),
                                items: [SegmentedBar.Item(title: "Auto", icon: "circle.righthalf.fill"),
                                        SegmentedBar.Item(title: "Clair", icon: "sun.max.fill"),
                                        SegmentedBar.Item(title: "Sombre", icon: "moon.fill")],
                                selected: state.themeMode)
        themeSeg.onSelect = { [weak self] i in self?.setTheme(i) }
        p.addSubview(themeSeg)

        mkSection(p, H - 194, W, "Matière du panneau")
        glassSeg = SegmentedBar(frame: NSRect(x: 0, y: H - 242, width: W, height: 42),
                                items: [SegmentedBar.Item(title: "Opaque", icon: "square.fill"),
                                        SegmentedBar.Item(title: "Verre dépoli", icon: "square.on.square"),
                                        SegmentedBar.Item(title: "Cristal", icon: "sparkles")],
                                selected: state.glassLevel)
        glassSeg.onSelect = { [weak self] i in self?.setGlass(i) }
        p.addSubview(glassSeg)

        mkSection(p, H - 266, W, "Couleur d'accent")
        let sGap = (W - CGFloat(accentPalette.count) * 42) / CGFloat(accentPalette.count)
        for (i, pair) in accentPalette.enumerated() {
            let sw = SwatchButton(frame: NSRect(x: CGFloat(i) * (42 + min(14, sGap)), y: H - 312,
                                                width: 42, height: 42),
                                  color: pair.1, index: i)
            sw.onClick = { [weak self] idx in self?.setAccent(idx) }
            p.addSubview(sw)
            swatches.append(sw)
        }

        mkSection(p, H - 336, W, "Comportement")
        let opts: [(String, String, String)] = [
            ("notch", "Notch actif", "macwindow"),
            ("follow", "Regard souris", "eye.fill"),
            ("agents", "Alertes agents", "bell.badge.fill"),
            ("agentSound", "Son alertes", "speaker.wave.2.fill"),
            ("auto", "Coucou horaire", "clock.badge.checkmark"),
            ("break", "Rappel pause", "figure.walk"),
            ("fullscreen", "Plein écran", "arrow.up.left.and.arrow.down.right"),
            ("paste", "Coller auto", "arrow.right.doc.on.clipboard"),
            ("notify", "Notifications", "bell.fill"),
            ("sound", "Sons", "speaker.wave.2.fill"),
            ("login", "Démarrage", "power"),
            ("mailWatch", "Veille courrier", "envelope.badge.fill"),
            ("alarmSound", "Son des alarmes", "alarm.fill")
        ]
        let cols: CGFloat = 3
        let ow = (W - 24) / cols
        for (i, o) in opts.enumerated() {
            let col = CGFloat(i % Int(cols)), row = CGFloat(i / Int(cols))
            let t = ToggleRow(frame: NSRect(x: col * (ow + 12), y: H - 380 - row * 46, width: ow, height: 42),
                              title: o.1, icon: o.2)
            t.onToggle = { [weak self] in self?.toggleOption(o.0) }
            p.addSubview(t)
            toggleRows[o.0] = t
        }
    }

    // ═══════════ Chat ═══════════

    private func wireChat() {
        var a = ChatActions()
        a.storageReport = { [weak self] in
            guard let s = self else { return "" }
            let vols = scanVolumes()
            guard let b = vols.first(where: { $0.isBoot }) ?? vols.first else { return "Aucun volume lisible." }
            var txt = "\(b.name) : \(formatBytes(b.free)) libres sur \(formatBytes(b.total)), soit \(b.freePercent) %."
            let ext = vols.filter { !$0.isBoot }
            if !ext.isEmpty {
                txt += "\nAussi monté : " + ext.map { "\($0.name) (\(formatBytes($0.free)) libres)" }
                    .joined(separator: ", ") + "."
            }
            if b.freePercent <= s.state.lowDiskThreshold {
                txt += "\nC'est serré — dis-moi « nettoie les résidus » si tu veux que je regarde."
            }
            return txt
        }
        a.agentsReport = { [weak self] in
            guard let s = self else { return "" }
            if s.pendingAgents == 0 { return "Aucune demande d'agent en attente, tout est calme." }
            let list = AgentCenter.shared.requests.suffix(3)
                .map { "• \($0.title) (\($0.source))" }.joined(separator: "\n")
            return "\(s.pendingAgents) demande(s) attendent :\n\(list)"
        }
        a.vitalsReport = {
            var l = [Double](repeating: 0, count: 3)
            getloadavg(&l, 3)
            let m = memoryStats()
            return String(format: "Charge CPU %.2f, mémoire %.1f Go sur %.0f Go, allumé depuis %@.",
                          l[0], m.used / 1_073_741_824, m.total / 1_073_741_824,
                          formatUptime(ProcessInfo.processInfo.systemUptime))
        }
        a.focusReport = { [weak self] in
            guard let s = self else { return "" }
            if s.phase == .idle {
                return "Aucun focus en cours. Sessions du jour : \(s.state.focusSessions), \(s.state.focusTotalMinutes) minutes."
            }
            let r = max(0, Int((s.phaseEnd ?? Date()).timeIntervalSinceNow))
            return "\(s.phase == .focus ? "Focus" : "Pause") en cours, il reste \(r / 60) min \(r % 60) s."
        }
        a.startFocus = { [weak self] minutes in
            guard let s = self else { return "" }
            if minutes >= 5 && minutes <= 120 {
                s.state.focusMinutes = minutes
                BudStore.shared.save(s.state)
            }
            if s.phase != .idle { return "Un focus tourne déjà. Dis « arrête le focus » si tu veux changer." }
            s.toggleFocus()
            return "C'est parti pour \(s.state.focusMinutes) minutes. Je garde le compte à rebours dans le notch."
        }
        a.stopFocus = { [weak self] in
            guard let s = self else { return "" }
            guard s.phase != .idle else { return "Il n'y avait pas de focus en cours." }
            s.toggleFocus()
            return "Focus arrêté."
        }
        a.emptyTrash = { [weak self] done in
            self?.cleanPanel.emptyTrashOnly { msg in
                done(msg)
                self?.storagePanel.refresh(animated: true)
            }
        }
        a.runCleanup = { [weak self] in
            guard let s = self else { return "" }
            s.selectTab(s.tabClean)
            s.cleanPanel.scan()
            return "J'analyse les résidus, l'onglet Nettoyage s'ouvre. Coche ce que tu veux libérer puis clique sur Nettoyer."
        }
        a.ejectAll = { [weak self] in self?.storagePanel.ejectAll() ?? "" }
        a.addNote = { [weak self] body in
            guard let s = self else { return "" }
            QuickNotesStore.shared.append(body)
            s.state.notes = s.state.notes.isEmpty ? body : body + "\n\n" + s.state.notes
            BudStore.shared.save(s.state)
            s.notesView?.string = s.state.notes
            s.updateNotesCount()
            return "C'est noté : « \(body) »."
        }
        a.listSnippets = {
            let items = SnippetStore.shared.items
            guard !items.isEmpty else { return "Aucun snippet enregistré pour l'instant." }
            return "Tes snippets : " + items.map { $0.title }.joined(separator: ", ")
                + ".\nDis « copie le snippet <titre> » pour en placer un dans le presse-papiers."
        }
        a.copySnippet = { key in
            let k = key.lowercased()
            let hit = SnippetStore.shared.items.first { $0.title.lowercased().contains(k) }
                   ?? SnippetStore.shared.items.first
            guard let s = hit else { return "Je n'ai aucun snippet à copier." }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.body, forType: .string)
            return "« \(s.title) » est dans le presse-papiers."
        }
        a.openCapture = { [weak self] in
            self?.showCapture()
            return "La capture rapide est ouverte — ⌘⌥D la rappelle de n'importe où."
        }
        a.openFolder = { [weak self] name in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let url: URL
            switch name {
            case "Applications": url = URL(fileURLWithPath: "/Applications")
            case "SORT": url = self?.sortRootURL ?? home
            default: url = home.appendingPathComponent(name)
            }
            NSWorkspace.shared.open(url)
            return "J'ouvre \(url.lastPathComponent)."
        }
        a.mailReport = { [weak self] in
            guard let s = self else { return "" }
            guard MailRouter.gmailReady || MailBridge.mailRunning() else {
                MailBridge.openInbox()
                return "Aucune source : j'ouvre Mail. Tu peux aussi connecter ton compte Gmail dans l'onglet Courrier."
            }
            let snap = MailRouter.snapshot(3)
            if let e = snap.error { return "Lecture impossible : \(e)" }
            if snap.unread <= 0 { return "Aucun message non lu, ta boîte est à jour." }
            let list = snap.msgs.map { "• \($0.sender) — \($0.subject)" }.joined(separator: "\n")
            s.lastUnread = snap.unread
            return "\(snap.unread) message(s) non lus via \(snap.source) :\n\(list)"
        }
        a.composeMail = { [weak self] to, subject, body in
            guard let s = self else { return "" }
            s.selectTab(s.tabMail)
            s.mailPanel.prefill(to: to, subject: subject, body: body)
            if to.isEmpty { return "J'ouvre la fenêtre d'écriture, indique le destinataire." }
            return MailRouter.gmailReady
                ? "Brouillon prêt pour \(to) via Gmail — vérifie puis clique sur Envoyer."
                : "Brouillon prêt pour \(to) — vérifie puis clique sur Envoyer."
        }
        a.addReminder = { [weak self] phrase in
            guard let s = self else { return "" }
            guard let p = ReminderParser.parse(phrase) else {
                return "Je n'ai pas compris l'heure. Dis par exemple « rappelle-moi d'appeler Paul à 17h30 »."
            }
            let r = ReminderStore.shared.add(title: p.title, at: p.date)
            s.remindersPanel.refresh()
            s.refreshReminderBadge()
            return "C'est noté : « \(r.title) », \(r.whenLabel)."
        }
        a.remindersReport = { [weak self] in
            guard let s = self else { return "" }
            let items = ReminderStore.shared.items
            guard !items.isEmpty else { return "Aucun rappel programmé." }
            let list = items.prefix(4).map { "• \($0.title) — \($0.whenLabel)" }.joined(separator: "\n")
            _ = s
            return "\(items.count) rappel(s) :\n\(list)"
        }
        a.music = { [weak self] cmd in
            guard let s = self else { return "" }
            return s.musicPanel.command(cmd)
        }
        a.tellJoke = { budJokes.randomElement() ?? "" }
        a.giveTip = { [weak self] in
            let pool = tipsFor(self?.state.personality ?? 0)
            return pool.randomElement() ?? ""
        }
        chatPanel.actions = a
    }

    // ═══════════ Agents ═══════════

    private func agentsChanged(_ list: [AgentRequest], _ newOne: AgentRequest?) {
        pendingAgents = list.count
        refreshAgentBadges()
        agentsPanel.refresh()
        if pendingAgents == 0 {
            frontRequest = nil
            approvalBar.isHidden = true
            if notchState == .approval { setState(.collapsed) }
        }
        guard state.agentAlerts, let r = newOne else { return }
        showApproval(r)
    }

    private func showApproval(_ r: AgentRequest) {
        frontRequest = r
        approveBtn.title = "Autoriser"
        approveBtn.iconName = "checkmark"
        rejectBtn.title = "Refuser"
        rejectBtn.iconName = "xmark"
        detailBtn.title = "Détails"
        avatar?.react()
        if state.notifyEnabled { notify(r.title, "\(r.source) · \(r.detail)") }
        guard state.notchEnabled, notchState != .open else { return }
        chrome.greeting = r.title
        chrome.subtitle = r.detail.isEmpty ? r.source : "\(r.source) · \(r.detail)"
        chrome.mono = (r.path ?? "").isEmpty ? r.source
                    : URL(fileURLWithPath: r.path!).lastPathComponent
        holdUntil = Date().addingTimeInterval(120)
        setState(.approval)
        if state.soundEnabled && state.agentSound { NSSound(named: NSSound.Name("Glass"))?.play() }
    }

    private func refreshAgentBadges() {
        pendingAgents = AgentCenter.shared.requests.count
        avatar?.alertCount = pendingAgents
        chrome.alertCount = pendingAgents
        if sidebarItems.indices.contains(tabAgents) { sidebarItems[tabAgents].badgeCount = pendingAgents }
        chrome.needsDisplay = true
    }

    // ═══════════ Capture ═══════════

    @objc private func showCapture() { capture.present() }

    private func handleCapture(_ text: String, _ target: CaptureWindow.CaptureTarget) {
        switch target {
        case .clipboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if state.pasteToFrontApp {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if !pasteIntoFrontApp() {
                        self.coucou("Collage impossible", "Autorisez BUD dans Confidentialité → Accessibilité.", hold: 5)
                    }
                }
            }
            coucou("Capturé", "Texte copié dans le presse-papiers.", hold: 2.5, sound: false)
        case .note:
            QuickNotesStore.shared.append(text)
            state.notes = state.notes.isEmpty ? text : text + "\n\n" + state.notes
            BudStore.shared.save(state)
            notesView?.string = state.notes
            updateNotesCount()
            coucou("Note ajoutée", String(text.prefix(60)), hold: 3, sound: false)
        case .snippet:
            let title = String(text.split(separator: "\n").first ?? "Snippet").trimmingCharacters(in: .whitespaces)
            SnippetStore.shared.add(Snippet(title: String(title.prefix(32)), body: text))
            snippetsPanel.refresh()
            coucou("Snippet enregistré", String(title.prefix(60)), hold: 3, sound: false)
        }
    }

    // ═══════════ Glisser-déposer ═══════════

    private func dragEnter() {
        guard !dragging else { return }
        dragging = true
        chrome.dropActive = true
        approvalBar.isHidden = true
        holdUntil = Date().addingTimeInterval(60)
        if notchState == .collapsed { setState(.glance) }
    }

    private func dragExit() {
        dragging = false
        chrome.dropActive = false
        holdUntil = Date().addingTimeInterval(0.4)
    }

    private func handleDrop(_ urls: [URL]) {
        dragging = false
        chrome.dropActive = false

        var files: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue && u.pathExtension.lowercased() != "app" {
                if let e = fm.enumerator(at: u, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in e {
                        var d: ObjCBool = false
                        if fm.fileExists(atPath: f.path, isDirectory: &d), !d.boolValue { files.append(f) }
                    }
                }
            } else {
                files.append(u)
            }
        }
        guard !files.isEmpty else {
            coucou("Rien à ranger", "Aucun fichier trouvé dans ce dépôt.", hold: 3)
            return
        }

        let monthFmt = DateFormatter()
        monthFmt.locale = Locale(identifier: "fr_FR")
        monthFmt.dateFormat = "yyyy-MM"

        var moves: [SortMove] = []
        var counts: [String: Int] = [:]
        var failed = 0

        for f in files {
            let cat = categoryFor(f)
            var dest = sortRootURL.appendingPathComponent(cat.name, isDirectory: true)
            if state.sortByMonth {
                dest = dest.appendingPathComponent(monthFmt.string(from: Date()), isDirectory: true)
            }
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                var target = dest.appendingPathComponent(f.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    let base = f.deletingPathExtension().lastPathComponent
                    let ext = f.pathExtension
                    var n = 2
                    repeat {
                        let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                        target = dest.appendingPathComponent(name)
                        n += 1
                    } while fm.fileExists(atPath: target.path) && n < 500
                }
                try fm.moveItem(at: f, to: target)
                moves.append(SortMove(from: f, to: target))
                counts[cat.name, default: 0] += 1
            } catch {
                failed += 1
            }
        }

        guard !moves.isEmpty else {
            coucou("Rangement impossible", "Déplacement refusé (permissions ?).", hold: 5)
            return
        }

        lastMoves = moves
        state.sortedCount += moves.count
        BudStore.shared.save(state)

        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        for m in moves.prefix(6) {
            let cat = m.to.deletingLastPathComponent().lastPathComponent
            sortLog.insert("\(hm.string(from: Date())) · \(m.to.lastPathComponent) → \(cat)", at: 0)
        }
        if sortLog.count > 30 { sortLog.removeLast(sortLog.count - 30) }

        let summary = counts.sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key.lowercased())" }
            .joined(separator: ", ")
        refreshSortUI()
        storagePanel.refresh()
        coucou(moves.count == 1 ? "1 fichier rangé" : "\(moves.count) fichiers rangés",
               summary + (failed > 0 ? " · \(failed) ignoré(s)" : ""), hold: 6, push: true)
    }

    private func undoSort() {
        guard !lastMoves.isEmpty else { return }
        let fm = FileManager.default
        var restored = 0
        for m in lastMoves.reversed() {
            do {
                try fm.createDirectory(at: m.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: m.from.path) {
                    try fm.moveItem(at: m.to, to: m.from)
                    restored += 1
                }
            } catch { }
        }
        lastMoves.removeAll()
        sortLog.insert("Rangement annulé · \(restored) fichier(s) remis en place", at: 0)
        refreshSortUI()
        setStatus("\(restored) fichier(s) restaurés")
    }

    private func refreshSortUI() {
        let short = sortRootURL.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        sortPathLabel?.stringValue = short
        sortStatsLabel?.stringValue = "\(state.sortedCount) fichier(s) rangés depuis l'installation"
        sortHero?.set(trailing: state.sortedCount > 0 ? "\(state.sortedCount) rangés" : "")
        monthRow?.setOn(state.sortByMonth, animated: false)
        undoBtn?.enabledFlag = !lastMoves.isEmpty
        for (i, l) in sortLogLabels.enumerated() { l.stringValue = i < sortLog.count ? sortLog[i] : "" }
    }

    private func chooseSortRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choisir"
        p.message = "Dossier où BUD rangera les fichiers déposés"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url {
            state.sortRoot = u.path
            BudStore.shared.save(state)
            refreshSortUI()
        }
    }

    private func openSortRoot() {
        try? FileManager.default.createDirectory(at: sortRootURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(sortRootURL)
    }

    private func toggleMonth() {
        state.sortByMonth.toggle()
        BudStore.shared.save(state)
        refreshSortUI()
    }

    // ═══════════ États du notch ═══════════

    private func setState(_ s: NotchState, animated: Bool = true) {
        guard notchState != s else { return }
        let opening = (s == .open)
        notchState = s
        chrome.state = s
        backdrop.radius = radiusFor(s)

        if !opening { content.isHidden = true }
        approvalBar.isHidden = (s != .approval)
        chrome.needsDisplay = true

        let target = frameFor(s)
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = opening ? 0.32 : 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.9, 0.3, 1.0)
                self.panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                guard let self = self else { return }
                if self.notchState == .open {
                    self.content.frame = NSRect(origin: .zero, size: self.sizeOpen)
                    self.content.isHidden = false
                    self.panel.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    self.avatar.wave()
                }
                self.backdrop.needsLayout = true
                self.chrome.needsDisplay = true
            })
        } else {
            panel.setFrame(target, display: true)
            content.frame = NSRect(origin: .zero, size: sizeOpen)
            content.isHidden = !opening
            backdrop.needsLayout = true
        }
    }

    private func hover(_ inside: Bool) {
        guard state.notchEnabled else { return }
        if inside {
            if notchState == .collapsed {
                if let r = AgentCenter.shared.requests.last, pendingAgents > 0 {
                    showApproval(r)
                } else {
                    let g = timeGreeting()
                    chrome.greeting = g.0
                    chrome.subtitle = longDateString() + " · " + clockString()
                    refreshChips()
                    setState(.glance)
                }
            }
        } else if (notchState == .glance || notchState == .approval) && Date() > holdUntil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self, self.notchState != .open, self.notchState != .collapsed,
                      !self.dragging else { return }
                if !self.mouseInside() && Date() > self.holdUntil { self.setState(.collapsed) }
            }
        }
    }

    private func mouseInside() -> Bool { panel.frame.contains(NSEvent.mouseLocation) }

    private func notchClicked() {
        if notchState == .approval { return }   // les boutons de la carte gèrent le clic
        openPanel()
    }

    private func openPanel() {
        holdUntil = .distantPast
        setState(.open)
        if pendingAgents > 0 { selectTab(tabAgents) }
    }

    @objc private func collapse() { setState(.collapsed) }
    @objc private func togglePanel() { notchState == .open ? collapse() : openPanel() }

    private func coucou(_ title: String, _ sub: String, hold: TimeInterval = 4.0,
                        sound: Bool = true, push: Bool = false) {
        avatar?.react()
        setStatus(title)
        if state.notifyEnabled && push { notify(title, sub) }
        guard state.notchEnabled, notchState != .open, notchState != .approval else { return }
        chrome.greeting = title
        chrome.subtitle = sub
        refreshChips()
        holdUntil = Date().addingTimeInterval(hold)
        setState(.glance)
        chrome.wave()
        if state.soundEnabled && sound { NSSound(named: NSSound.Name("Glass"))?.play() }
    }

    private func refreshChips() {
        var focusTxt = "—"
        var ratio: CGFloat = 0
        if phase != .idle, let end = phaseEnd {
            let s = max(0, Int(end.timeIntervalSinceNow))
            focusTxt = String(format: "%02d:%02d", s / 60, s % 60)
            let total = Double((phase == .focus ? state.focusMinutes : state.breakMinutes) * 60)
            ratio = CGFloat(max(0, min(1, 1 - Double(s) / max(1, total))))
        }
        let vols = scanVolumes()
        let boot = vols.first { $0.isBoot } ?? vols.first
        let ext = vols.filter { !$0.isBoot }.count
        chrome.chips = [
            ("internaldrive.fill", boot.map { formatBytes($0.free) } ?? "—"),
            (ext > 0 ? "externaldrive.fill" : "bell.badge.fill", ext > 0 ? "\(ext)" : "\(pendingAgents)"),
            ("timer", focusTxt),
            ("clock", clockString())
        ]
        chrome.progress = ratio
        if pendingAgents > 0 { chrome.badge = dangerColor }
        else if let b = boot, b.freePercent <= state.lowDiskThreshold { chrome.badge = warnColor }
        else if phase == .focus { chrome.badge = TH.accent }
        else { chrome.badge = nil }
    }

    @objc private func screenChanged() {
        panel.setFrame(frameFor(notchState), display: true)
        backdrop.needsLayout = true
    }

    @objc private func volumesChanged(_ n: Notification) {
        storagePanel?.refresh(animated: true)
        refreshChips()
        if let p = (n.userInfo?["NSDevicePath"] as? String) {
            let mounted = (n.name == NSWorkspace.didMountNotification)
            coucou(mounted ? "Volume monté" : "Volume éjecté",
                   URL(fileURLWithPath: p).lastPathComponent, hold: 3, sound: false)
        }
    }

    // ═══════════ Moniteurs ═══════════

    private func installMonitors() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            if e.keyCode == 53 && self.notchState == .open { self.collapse(); return nil }
            return self.handleHotkey(e) ? nil : e
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            _ = self?.handleHotkey(e)
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.notchState == .open else { return }
            self.collapse()
        }
    }

    private func handleHotkey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command), e.modifierFlags.contains(.option) else { return false }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "b": togglePanel(); return true
        case "c": sayHello(); return true
        case "f": toggleFocus(); return true
        case "d": showCapture(); return true
        case "a": openPanel(); selectTab(tabAgents); return true
        case "k": openPanel(); selectTab(tabChat); return true
        case "m": openPanel(); selectTab(tabMail); return true
        case "r": openPanel(); selectTab(tabReminders); return true
        case "p": openPanel(); selectTab(tabPhone); return true
        default: return false
        }
    }

    // ═══════════ Menu ═══════════

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "BUD") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "BUD"
        }
        let menu = NSMenu()
        menu.delegate = self
        func add(_ key: String, _ title: String, _ sel: Selector?) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            menu.addItem(it)
            menuItems[key] = it
        }
        add("toggle", "Ouvrir le tableau de bord", #selector(togglePanel))
        add("capture", "Capture rapide…", #selector(showCapture))
        add("agents", "Demandes des agents", #selector(openAgentsTab))
        add("focus", "Démarrer / arrêter un focus", #selector(toggleFocus))
        menu.addItem(.separator())
        add("chat", "Parler à BUD…", #selector(openChatTab))
        add("storage", "Stockage", #selector(openStorageTab))
        add("clean", "Nettoyer le Mac…", #selector(openCleanTab))
        add("mail", "Courrier", #selector(openMailTab))
        add("reminders", "Rappels", #selector(openRemindersTab))
        add("music", "Musique", #selector(openMusicTab))
        add("settings", "Réglages…", #selector(openSettings))
        menu.addItem(.separator())
        add("keys", "⌘⌥B · ⌘⌥K · ⌘⌥M · ⌘⌥R · ⌘⌥D · ⌘⌥F", nil)
        add("quit", "Quitter BUD", #selector(quitApp))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuItems["toggle"]?.title = notchState == .open ? "Replier le tableau de bord" : "Ouvrir le tableau de bord"
        menuItems["agents"]?.title = pendingAgents > 0 ? "Demandes des agents (\(pendingAgents))" : "Demandes des agents"
        menuItems["keys"]?.isEnabled = false
        if let img = NSImage(systemSymbolName: pendingAgents > 0 ? "bell.badge.fill" : "face.smiling",
                             accessibilityDescription: "BUD") {
            img.isTemplate = true
            statusItem.button?.image = img
        }
    }

    @objc private func openSettings() { openPanel(); selectTab(tabSettings) }
    @objc private func openAgentsTab() { openPanel(); selectTab(tabAgents) }
    @objc private func openStorageTab() { openPanel(); selectTab(tabStorage) }
    @objc private func openChatTab() { openPanel(); selectTab(tabChat) }
    @objc private func openCleanTab() { openPanel(); selectTab(tabClean) }
    @objc private func openMailTab() { openPanel(); selectTab(tabMail) }
    @objc private func openRemindersTab() { openPanel(); selectTab(tabReminders) }
    @objc private func openMusicTab() { openPanel(); selectTab(tabMusic) }

    // ═══════════ Réglages ═══════════

    private func setTheme(_ i: Int) { state.themeMode = i; BudStore.shared.save(state); applyTheme(); refreshSettingsUI() }
    private func setGlass(_ i: Int) { state.glassLevel = i; BudStore.shared.save(state); applyTheme(); refreshSettingsUI() }
    private func setAccent(_ i: Int) { state.accentIndex = i; BudStore.shared.save(state); applyTheme(); refreshSettingsUI() }

    private func toggleOption(_ key: String) {
        switch key {
        case "notch":
            state.notchEnabled.toggle()
            if !state.notchEnabled { setState(.collapsed); panel.orderOut(nil) }
            else { panel.orderFrontRegardless() }
        case "follow": state.followMouse.toggle()
        case "agents": state.agentAlerts.toggle()
        case "agentSound": state.agentSound.toggle()
        case "auto": state.autoCoucou.toggle()
        case "break": state.breakReminder.toggle(); lastBreak = Date()
        case "fullscreen":
            state.hideInFullscreen.toggle()
            hiddenByFullscreen = false
            if state.notchEnabled { panel.orderFrontRegardless() }
            updateFullscreenVisibility()
        case "paste":
            state.pasteToFrontApp.toggle()
            if state.pasteToFrontApp { _ = accessibilityGranted(prompt: true) }
        case "sound": state.soundEnabled.toggle()
        case "notify": state.notifyEnabled.toggle()
        case "mailWatch":
            state.mailWatch.toggle()
            if !state.mailWatch, sidebarItems.indices.contains(tabMail) {
                sidebarItems[tabMail].badgeCount = 0
            }
        case "alarmSound": state.alarmSound.toggle()
        case "login": toggleLogin(); return
        default: break
        }
        BudStore.shared.save(state)
        refreshSettingsUI()
    }

    private func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: agentURL.path) {
            try? fm.removeItem(at: agentURL)
        } else {
            try? fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let d: [String: Any] = ["Label": "local.lahbib.bud.assistant",
                                    "ProgramArguments": [Bundle.main.executablePath ?? ""],
                                    "RunAtLoad": true, "ProcessType": "Interactive"]
            if let data = try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0) {
                try? data.write(to: agentURL)
            }
        }
        refreshSettingsUI()
    }

    /// L'habillage du personnage est global : on le pose, puis on force
    /// le redessin des deux vues qui montrent BUD.
    private func applyBudStyle() {
        BudSprite.style = state.budSkin == 2 ? .metal : (state.budSkin == 1 ? .premium : .flat)
        skinSeg?.selected = state.budSkin
        avatar?.needsDisplay = true
        chrome?.needsDisplay = true
    }

    private func refreshSettingsUI() {
        themeSeg?.selected = state.themeMode
        glassSeg?.selected = state.glassLevel
        for (i, sw) in swatches.enumerated() { sw.selected = (i == state.accentIndex) }
        let map: [String: Bool] = [
            "notch": state.notchEnabled, "follow": state.followMouse,
            "agents": state.agentAlerts, "agentSound": state.agentSound,
            "auto": state.autoCoucou, "break": state.breakReminder,
            "fullscreen": state.hideInFullscreen, "paste": state.pasteToFrontApp,
            "notify": state.notifyEnabled, "sound": state.soundEnabled,
            "login": FileManager.default.fileExists(atPath: agentURL.path),
            "mailWatch": state.mailWatch, "alarmSound": state.alarmSound
        ]
        for (k, v) in map { toggleRows[k]?.setOn(v) }
        settingsHero?.set(trailing: accentPalette[state.accentIndex].0)
    }

    // ═══════════ Boucles ═══════════

    @objc private func animate() {
        chrome.step(follow: state.followMouse)
        if notchState == .open {
            avatar.step(follow: state.followMouse)
            storagePanel.stepRing()
        }
    }

    private func normalizeSessions() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        if state.sessionsDay != today {
            state.sessionsDay = today
            state.focusSessions = 0
            state.focusTotalMinutes = 0
            BudStore.shared.save(state)
        }
    }

    private func tick() {
        ticks += 1
        let now = Date()

        if phase != .idle, let end = phaseEnd {
            if now >= end { phaseFinished() }
            if notchState == .open { updateFocusUI() }
        }

        if notchState != .open && notchState != .collapsed && now > holdUntil
            && !mouseInside() && !dragging { setState(.collapsed) }

        if state.breakReminder && now.timeIntervalSince(lastBreak) > 3000 && phase != .focus {
            lastBreak = now
            coucou("Petite pause", "Levez-vous, étirez-vous, buvez un verre d'eau.", hold: 6, push: true)
        }

        if state.autoCoucou {
            let c = Calendar.current.dateComponents([.hour, .minute], from: now)
            if let h = c.hour, let m = c.minute, m == 0, h != lastCoucouHour {
                lastCoucouHour = h
                coucou("Il est \(h) h", timeGreeting().1, hold: 4)
            }
        }

        watchClipboard()
        checkReminders()
        if ticks % 60 == 0 { checkMail() }
        if ticks % 10 == 0 { refreshReminderBadge() }
        updateFullscreenVisibility()
        let hr = Calendar.current.component(.hour, from: now)
        avatar?.sleepy = (hr >= 23 || hr < 5) && pendingAgents == 0

        if notchState != .collapsed || ticks % 5 == 0 { refreshChips() }
        if ticks % 60 == 0 { checkLowDisk(); normalizeSessions() }
        guard notchState == .open else { return }
        if currentTab == tabStorage && ticks % 5 == 0 { storagePanel.refresh() }
    }

    /// Vrai quand une application occupe l'écran entier : la barre des menus
    /// disparaît, donc la zone visible touche le haut de l'écran.
    private func screenIsFullscreen() -> Bool {
        guard let s = NSScreen.main else { return false }
        return s.visibleFrame.maxY >= s.frame.maxY - 1
    }

    private func updateFullscreenVisibility() {
        guard state.notchEnabled else { return }
        let full = state.hideInFullscreen && screenIsFullscreen()
        if full && !hiddenByFullscreen {
            hiddenByFullscreen = true
            if notchState != .collapsed { setState(.collapsed, animated: false) }
            panel.orderOut(nil)
        } else if !full && hiddenByFullscreen {
            hiddenByFullscreen = false
            panel.orderFrontRegardless()
        }
    }

    private func checkLowDisk() {
        guard let b = bootVolume() else { return }
        if b.freePercent <= state.lowDiskThreshold && !lowDiskAlerted {
            lowDiskAlerted = true
            coucou("Disque presque plein",
                   "\(formatBytes(b.free)) libres sur \(b.name) · \(b.freePercent) %", hold: 8, push: true)
        } else if b.freePercent > state.lowDiskThreshold + 2 {
            lowDiskAlerted = false
        }
    }

    // ═══════════ Navigation ═══════════

    private func selectTab(_ i: Int) {
        let changed = (currentTab != i)
        currentTab = i

        // L'indicateur de sélection glisse d'une entrée à l'autre
        if sidebarItems.indices.contains(i) {
            let target = sidebarItems[i].frame.insetBy(dx: 0, dy: 1)
            if navIndicator.frame == .zero {
                navIndicator.frame = target
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.26
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.2, 0.4, 1)
                    navIndicator.animator().frame = target
                }
            }
        }
        for (j, t) in sidebarItems.enumerated() { t.selected = (j == i) }

        // Le panneau entrant monte en fondu, les sortants s'effacent
        for (j, p) in panels.enumerated() where j != i {
            if !p.isHidden {
                if changed {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.12
                        p.animator().alphaValue = 0
                    }, completionHandler: { p.isHidden = true; p.alphaValue = 1 })
                } else {
                    p.isHidden = true
                }
            }
        }

        let panel = panels[i]
        panel.wantsLayer = true
        if changed {
            panel.alphaValue = 0
            panel.frame = NSRect(x: panelFrame.minX, y: panelFrame.minY - 16,
                                 width: panelFrame.width, height: panelFrame.height)
            panel.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.30
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.25, 1)
                panel.animator().alphaValue = 1
                panel.animator().frame = panelFrame
            }
        } else {
            panel.frame = panelFrame
            panel.alphaValue = 1
            panel.isHidden = false
        }

        switch i {
        case tabCompanion: avatar.react()
        case tabChat: chatPanel.rebuild(); chatPanel.focusInput()
        case tabMail: mailPanel.refresh()
        case tabPhone: phonePanel.refresh()
        case tabReminders: remindersPanel.refresh()
        case tabMusic: musicPanel.refresh()
        case tabStorage: storagePanel.refresh(animated: true)
        case tabAgents: agentsPanel.refresh()
        case tabClean: cleanPanel.scan()
        case tabFocus: updateFocusUI()
        case tabNotes: self.panel.makeFirstResponder(notesView)
        case tabSnippets: snippetsPanel.refresh()
        case tabClipboard: refreshClipboardUI()
        case tabSorting: refreshSortUI()
        case tabSettings: refreshSettingsUI()
        default: break
        }
    }

    // ═══════════ Compagnon ═══════════

    private func cycleTip() {
        let pool = tipsFor(state.personality)
        state.moodIndex = (state.moodIndex + 1) % pool.count
        BudStore.shared.save(state)
        showBubble(pool[state.moodIndex])
    }

    private func showBubble(_ t: String) {
        bubbleLabel.alphaValue = 0.25
        bubbleLabel.stringValue = t
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            self.bubbleLabel.animator().alphaValue = 1
        }
    }

    private func avatarTip() { avatar.react(); cycleTip() }

    private func setPersonality(_ i: Int) {
        state.personality = i
        state.moodIndex = 0
        BudStore.shared.save(state)
        personalitySeg?.selected = i
        companionHero?.set(trailing: personalityNames[i])
        avatar.react()
        showBubble(tipsFor(i)[0])
    }

    @objc private func sayHello() {
        let g = timeGreeting()
        if notchState == .open {
            showBubble("\(g.0) — \(g.1)")
            avatar.wave()
        } else {
            coucou(g.0, g.1, hold: 4.5)
        }
    }

    private func tellJoke() {
        avatar.react()
        showBubble(budJokes.randomElement() ?? "")
    }

    // ═══════════ Focus ═══════════

    private func updateFocusUI() {
        var remaining = Double(state.focusMinutes * 60)
        var ratio: CGFloat = 0
        if phase != .idle {
            remaining = max(0, (phaseEnd ?? Date()).timeIntervalSinceNow)
            let total = Double((phase == .focus ? state.focusMinutes : state.breakMinutes) * 60)
            ratio = CGFloat(max(0, min(1, 1 - remaining / max(1, total))))
        }
        let s = Int(ceil(remaining))
        focusTime?.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
        focusBar?.value = ratio
        switch phase {
        case .idle:
            focusPhaseLabel?.stringValue = "Prêt · \(state.focusMinutes) min de focus, \(state.breakMinutes) min de pause"
            focusBtn?.title = "Démarrer"
            focusBtn?.iconName = "play.fill"
            focusHero?.set(trailing: "")
        case .focus:
            focusPhaseLabel?.stringValue = "Focus en cours"
            focusBtn?.title = "Arrêter"
            focusBtn?.iconName = "stop.fill"
            focusHero?.set(trailing: "En cours")
        case .rest:
            focusPhaseLabel?.stringValue = "Pause en cours"
            focusBtn?.title = "Arrêter"
            focusBtn?.iconName = "stop.fill"
            focusHero?.set(trailing: "Pause")
        }
        focusStats?.stringValue = "Aujourd'hui : \(state.focusSessions) session(s) · \(state.focusTotalMinutes) min concentrées"
    }

    @objc fileprivate func toggleFocus() {
        if phase == .idle {
            phase = .focus
            phaseEnd = Date().addingTimeInterval(Double(state.focusMinutes) * 60)
            if notchState != .open { coucou("Focus lancé", "\(state.focusMinutes) minutes, je veille.", hold: 3) }
        } else {
            phase = .idle
            phaseEnd = nil
        }
        updateFocusUI()
        refreshChips()
    }

    private func changeFocus(_ d: Int) {
        guard phase == .idle else { return }
        state.focusMinutes = max(5, min(120, state.focusMinutes + d))
        BudStore.shared.save(state)
        updateFocusUI()
    }

    private func phaseFinished() {
        if phase == .focus {
            normalizeSessions()
            state.focusSessions += 1
            state.focusTotalMinutes += state.focusMinutes
            BudStore.shared.save(state)
            phase = .rest
            phaseEnd = Date().addingTimeInterval(Double(state.breakMinutes) * 60)
            coucou("Session terminée", "Bravo. Pause de \(state.breakMinutes) min bien méritée.", hold: 6, push: true)
        } else {
            phase = .idle
            phaseEnd = nil
            coucou("Pause terminée", "On repart quand vous voulez.", hold: 5, push: true)
        }
        updateFocusUI()
        refreshChips()
    }

    // ═══════════ Notes ═══════════

    func textDidChange(_ n: Notification) {
        state.notes = notesView.string
        BudStore.shared.save(state)
        updateNotesCount()
    }

    fileprivate func updateNotesCount() {
        let c = notesView?.string.count ?? 0
        notesCount?.stringValue = "\(c) caractères"
        notesHero?.set(trailing: c > 0 ? "\(c) car." : "")
    }

    private func copyNotes() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notesView.string, forType: .string)
        avatar.react()
        setStatus("Notes copiées")
    }

    private func exportNotes() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/BUD-Notes-\(f.string(from: Date())).md")
        let md = "# Notes BUD\n\n" + notesView.string + "\n"
        if (try? md.write(to: url, atomically: true, encoding: .utf8)) != nil {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            setStatus("Exporté sur le Bureau")
        }
    }

    private func clearNotes() {
        let a = NSAlert()
        a.messageText = "Effacer toutes les notes ?"
        a.informativeText = "Le journal quicknotes.md est conservé."
        a.addButton(withTitle: "Effacer")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            notesView.string = ""
            state.notes = ""
            BudStore.shared.save(state)
            updateNotesCount()
        }
    }

    // ═══════════ Presse-papiers ═══════════

    private func watchClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastClipChange else { return }
        lastClipChange = pb.changeCount
        guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return }
        clipHistory.removeAll { $0 == s }
        clipHistory.insert(s, at: 0)
        if clipHistory.count > 20 { clipHistory.removeLast(clipHistory.count - 20) }
        if currentTab == tabClipboard { refreshClipboardUI() }
    }

    private func refreshClipboardUI() {
        clipHero?.set(trailing: clipHistory.isEmpty ? "" : "\(clipHistory.count) éléments")
        for (i, b) in clipButtons.enumerated() {
            if i < clipHistory.count {
                var l = clipHistory[i].replacingOccurrences(of: "\n", with: " ")
                let maxChars = Int((b.bounds.width - 70) / 6.4)
                if l.count > maxChars { l = String(l.prefix(max(10, maxChars))) + "…" }
                b.title = l
                b.enabledFlag = true
            } else {
                b.title = "—"
                b.enabledFlag = false
            }
        }
    }

    private func pasteBack(_ i: Int) {
        guard i < clipHistory.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipHistory[i], forType: .string)
        lastClipChange = NSPasteboard.general.changeCount
        avatar.react()
        setStatus("Replacé dans le presse-papiers")
    }

    private func clearClipboard() { clipHistory.removeAll(); refreshClipboardUI() }

    // ═══════════ Outils ═══════════

    @objc private func webSearch(_ s: NSSearchField) {
        let q = s.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty,
              let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(enc)") else { return }
        NSWorkspace.shared.open(url)
        s.stringValue = ""
    }

    private func toggleSystemDark() {
        runShell("/usr/bin/osascript",
                 ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
        toolsInfo.stringValue = "Apparence système basculée. Sans effet ? Autorisez BUD dans Confidentialité → Automatisation."
    }

    private func networkInfo() {
        let ip = runShell("/usr/sbin/ipconfig", ["getifaddr", "en0"])
        let wifi = runShell("/usr/sbin/networksetup", ["-getairportnetwork", "en0"])
        toolsInfo.stringValue = "IP locale : \(ip.isEmpty ? "non connectée (en0)" : ip)\n\(wifi.isEmpty ? "Wi-Fi inconnu" : wifi)"
    }

    private func launchApp(_ i: Int) {
        let names = ["Finder", "Safari", "Mail", "Terminal"]
        guard i < names.count else { return }
        runShell("/usr/bin/open", ["-a", names[i]])
        toolsInfo.stringValue = "Ouverture de \(names[i])…"
    }

    @objc private func quitApp() {
        BudStore.shared.save(state)
        NSApp.terminate(nil)
    }
}
EOF_BUDAPP_SWIFT

cat << 'EOF_BUDCHAT_SWIFT' > "$SRC_DIR/BudChat.swift"
import Cocoa

// ═══════════════════════════════════════════════════════════
//  Conversation avec BUD
//  Assistant local : aucune requête réseau, aucune clé d'API.
//  BUD comprend des intentions et agit sur la machine.
// ═══════════════════════════════════════════════════════════

struct ChatMsg {
    let fromBud: Bool
    let text: String
    let date: Date
}

/// Actions que le délégué expose au cerveau de BUD.
struct ChatActions {
    var storageReport: () -> String = { "" }
    var agentsReport: () -> String = { "" }
    var vitalsReport: () -> String = { "" }
    var focusReport: () -> String = { "" }
    var startFocus: (Int) -> String = { _ in "" }
    var stopFocus: () -> String = { "" }
    var emptyTrash: (@escaping (String) -> Void) -> Void = { _ in }
    var runCleanup: () -> String = { "" }
    var ejectAll: () -> String = { "" }
    var addNote: (String) -> String = { _ in "" }
    var listSnippets: () -> String = { "" }
    var copySnippet: (String) -> String = { _ in "" }
    var openCapture: () -> String = { "" }
    var openFolder: (String) -> String = { _ in "" }
    var tellJoke: () -> String = { "" }
    var mailReport: () -> String = { "" }
    var composeMail: (String, String, String) -> String = { _, _, _ in "" }
    var addReminder: (String) -> String = { _ in "" }
    var remindersReport: () -> String = { "" }
    var music: (String) -> String = { _ in "" }
    var giveTip: () -> String = { "" }
}

enum BudBrain {

    private static func norm(_ s: String) -> String {
        let lowered = s.lowercased()
        let folded = lowered.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        return folded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func has(_ t: String, _ words: [String]) -> Bool {
        words.contains { t.contains($0) }
    }

    private static func firstNumber(in t: String) -> Int? {
        let parts = t.split(whereSeparator: { !$0.isNumber })
        return parts.first.flatMap { Int($0) }
    }

    static let suggestions = ["Mes mails",
                              "Rappelle-moi de partir à 18h",
                              "Musique suivante",
                              "Que sais-tu faire ?"]

    /// Renvoie la réponse de BUD. `async` : certaines actions répondent plus tard.
    static func reply(to raw: String, actions: ChatActions,
                      late: @escaping (String) -> Void) -> String {
        let t = norm(raw)
        guard !t.isEmpty else { return "Je t'écoute." }

        if has(t, ["bonjour", "salut", "coucou", "hello", "bonsoir", "hey"]) {
            let g = timeGreeting()
            return "\(g.0) ! \(g.1)"
        }
        if has(t, ["merci", "super", "parfait", "genial", "bravo"]) {
            return "Avec plaisir. Autre chose ?"
        }
        if has(t, ["aide", "help", "que sais tu", "que sais-tu", "capacites", "tu peux faire", "commandes"]) {
            return """
            Voilà ce que je sais faire, en langage courant :
            • « combien d'espace reste-t-il ? » — état des disques
            • « vide la corbeille » ou « nettoie les résidus »
            • « éjecte les disques externes »
            • « lance un focus de 30 minutes » / « arrête le focus »
            • « note : rappeler le dentiste » — ajoute une note
            • « mes snippets » / « copie le snippet signature »
            • « ouvre les téléchargements » (bureau, documents, rangement…)
            • « mes mails », « envoie un mail à paul@exemple.fr pour dire bonjour »
            • « rappelle-moi d'appeler Paul à 17h30 », « mes rappels »
            • « musique », « morceau suivant », « monte le volume », « alexa »
            • « où en sont mes agents ? », « cpu », « l'heure », « une blague »
            """
        }
        if has(t, ["heure", "quelle heure"]) {
            return "Il est \(clockString()), nous sommes \(longDateString().lowercased())."
        }
        if has(t, ["blague", "rigole", "drole", "fais moi rire"]) {
            return actions.tellJoke()
        }
        if has(t, ["conseil", "astuce", "motive"]) {
            return actions.giveTip()
        }

        // ── Stockage et nettoyage ──
        if has(t, ["ejecte", "ejecter", "demonte", "debranche"]) {
            return actions.ejectAll()
        }
        if has(t, ["corbeille"]) && has(t, ["vide", "vider", "purge", "efface"]) {
            actions.emptyTrash { msg in late("Corbeille vidée : \(msg)") }
            return "Je vide la corbeille, un instant…"
        }
        if has(t, ["nettoie", "nettoyage", "residus", "fais du menage", "menage", "cache"]) {
            return actions.runCleanup()
        }
        if has(t, ["espace", "place", "disque", "stockage", "plein", "libre", "go ", "ssd"]) {
            return actions.storageReport()
        }
        if has(t, ["cpu", "memoire", "ram", "processeur", "charge", "uptime", "veille"]) {
            return actions.vitalsReport()
        }

        // ── Focus ──
        if has(t, ["focus", "concentration", "pomodoro", "minuteur"]) {
            if has(t, ["arrete", "stop", "annule", "fini"]) { return actions.stopFocus() }
            if has(t, ["lance", "demarre", "commence", "start", "mets"]) {
                return actions.startFocus(firstNumber(in: t) ?? 0)
            }
            return actions.focusReport()
        }

        // ── Notes et snippets ──
        if t.hasPrefix("note") || has(t, ["note :", "note:", "retiens", "souviens", "rappelle moi", "ajoute une note"]) {
            var body = raw
            for marker in ["note :", "note:", "Note :", "Note:", "retiens", "souviens-toi", "rappelle-moi"] {
                if let r = body.range(of: marker) { body = String(body[r.upperBound...]); break }
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return "Dis-moi quoi noter, par exemple « note : appeler le garage »." }
            return actions.addNote(body)
        }
        if has(t, ["snippet", "extrait", "modele"]) {
            if has(t, ["copie", "colle", "donne", "mets"]) {
                let words = raw.split(separator: " ").map(String.init)
                let key = words.last ?? ""
                return actions.copySnippet(key)
            }
            return actions.listSnippets()
        }
        if has(t, ["dictee", "dicte", "capture", "ecrire vite"]) {
            return actions.openCapture()
        }

        // ── Courrier ──
        if has(t, ["mail", "mail", "courrier", "message", "boite", "gmail", "inbox"]) {
            if has(t, ["envoie", "envoyer", "ecris", "ecrire", "redige", "rediger"]) {
                // « envoie un mail à paul@x.fr pour dire que je serai en retard »
                var to = ""
                for w in raw.split(whereSeparator: { " \n\t,;:".contains($0) }) where w.contains("@") {
                    to = String(w).trimmingCharacters(in: CharacterSet(charactersIn: "<>«»\""))
                    break
                }
                var body = ""
                for marker in [" pour dire ", " pour lui dire ", " disant ", " avec ", " : "] {
                    if let r = raw.range(of: marker) { body = String(raw[r.upperBound...]); break }
                }
                return actions.composeMail(to, body.isEmpty ? "" : String(body.prefix(60)), body)
            }
            return actions.mailReport()
        }

        // ── Rappels ──
        if has(t, ["rappelle", "rappel", "alarme", "n'oublie pas", "pense a", "reveille"]) {
            if has(t, ["mes rappels", "liste", "quels rappels", "prevu"]) { return actions.remindersReport() }
            return actions.addReminder(raw)
        }

        // ── Musique ──
        if has(t, ["musique", "chanson", "morceau", "spotify", "alexa", "joue", "pause", "volume",
                   "suivant", "precedent", "lecture"]) {
            if has(t, ["alexa"]) { return actions.music("alexa") }
            if has(t, ["suivant", "next", "passe"]) { return actions.music("next") }
            if has(t, ["precedent", "retour", "avant"]) { return actions.music("prev") }
            if has(t, ["monte", "plus fort", "augmente"]) { return actions.music("up") }
            if has(t, ["baisse", "moins fort", "diminue"]) { return actions.music("down") }
            if has(t, ["joue", "pause", "lance", "arrete", "stop", "reprend"]) { return actions.music("play") }
            return actions.music("status")
        }

        // ── Agents ──
        if has(t, ["agent", "validation", "demande", "approbation", "claude code"]) {
            return actions.agentsReport()
        }

        // ── Dossiers ──
        if has(t, ["ouvre", "montre", "affiche"]) {
            for (keys, name) in [(["telechargement", "download"], "Downloads"),
                                 (["bureau", "desktop"], "Desktop"),
                                 (["document"], "Documents"),
                                 (["image", "photo"], "Pictures"),
                                 (["rangement", "classe"], "SORT"),
                                 (["application"], "Applications")] {
                if has(t, keys) { return actions.openFolder(name) }
            }
        }

        if has(t, ["comment vas tu", "ca va", "tu vas bien"]) {
            return "Je tourne à \(clockString()) sans un accroc. " + actions.vitalsReport()
        }

        return """
        Je n'ai pas saisi. Essaie par exemple « combien d'espace me reste-t-il ? », \
        « vide la corbeille », « lance un focus de 25 minutes » ou « que sais-tu faire ? ».
        """
    }
}

/// Bulle de conversation, hauteur calculée sur le texte réel.
final class ChatBubble: NSView {
    private let msg: ChatMsg
    private let textRect: NSRect

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        let r = (text as NSString).boundingRect(
            with: NSSize(width: width - 32, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: p])
        return ceil(r.height) + 26
    }

    init(frame: NSRect, msg: ChatMsg) {
        self.msg = msg
        self.textRect = NSRect(x: 16, y: 13, width: frame.width - 32, height: frame.height - 26)
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        if msg.fromBud {
            TH.fill(0.07).setFill()
            path.fill()
            TH.fill(0.07).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            TH.accent.withAlphaComponent(0.22).setFill()
            path.fill()
            TH.accent.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        (msg.text as NSString).draw(
            with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                         .foregroundColor: TH.text.withAlphaComponent(msg.fromBud ? 0.92 : 1),
                         .paragraphStyle: p])
    }
}

final class ChatPanelView: NSView, NSTextFieldDelegate {
    private let hero: HeroHeader
    private let scroll = NSScrollView(frame: .zero)
    private let listHost = NSView(frame: .zero)
    private var input: NSTextField!
    private var bubbles: [NSView] = []
    private var messages: [ChatMsg] = []
    private var chips: [GlassButton] = []

    var actions = ChatActions()
    var onStatus: ((String) -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Chat", subtitle: "Parlez-moi normalement, j'agis sur votre Mac.")
        super.init(frame: frame)
        build()
        let g = timeGreeting()
        append(ChatMsg(fromBud: true,
                       text: "\(g.0) ! Demandez-moi de l'espace disque, un focus, un nettoyage… ou tapez « que sais-tu faire ? ».",
                       date: Date()))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height

        scroll.frame = NSRect(x: 0, y: 104, width: W, height: H - 196)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        // Suggestions rapides
        var x: CGFloat = 0
        for s in BudBrain.suggestions {
            let w = min(W - x, textWidth(s, size: 11.5, weight: .semibold) + 28)
            if x + w > W { break }
            let b = GlassButton(frame: NSRect(x: x, y: 62, width: w, height: 32), title: s, compact: true)
            b.onClick = { [weak self] _ in self?.send(s) }
            addSubview(b)
            chips.append(b)
            x += w + 8
        }

        input = NSTextField(frame: NSRect(x: 0, y: 6, width: W - 112, height: 44))
        input.placeholderString = "Écrivez à BUD…"
        input.font = NSFont.systemFont(ofSize: 13)
        input.bezelStyle = .roundedBezel
        input.focusRingType = .none
        input.delegate = self
        input.target = self
        input.action = #selector(sendFromField)
        addSubview(input)

        let sendBtn = GlassButton(frame: NSRect(x: W - 102, y: 6, width: 102, height: 44),
                                  title: "Envoyer", icon: "paperplane.fill", prominent: true)
        sendBtn.onClick = { [weak self] _ in self?.sendFromField() }
        addSubview(sendBtn)
    }

    func focusInput() { window?.makeFirstResponder(input) }

    @objc private func sendFromField() {
        let t = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input.stringValue = ""
        send(t)
    }

    func send(_ text: String) {
        append(ChatMsg(fromBud: false, text: text, date: Date()))
        let answer = BudBrain.reply(to: text, actions: actions) { [weak self] late in
            self?.append(ChatMsg(fromBud: true, text: late, date: Date()))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.append(ChatMsg(fromBud: true, text: answer, date: Date()))
        }
        onStatus?("BUD réfléchit…")
    }

    private func append(_ m: ChatMsg) {
        messages.append(m)
        if messages.count > 60 { messages.removeFirst(messages.count - 60) }
        rebuild()
    }

    func rebuild() {
        bubbles.forEach { $0.removeFromSuperview() }
        bubbles.removeAll()

        let W = scroll.bounds.width - 6
        let maxW = W * 0.82
        var heights: [CGFloat] = []
        for m in messages { heights.append(ChatBubble.height(for: m.text, width: maxW)) }
        let gap: CGFloat = 10
        let total = max(scroll.bounds.height, heights.reduce(0, +) + gap * CGFloat(max(0, messages.count)))
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: total)

        var y = total
        for (i, m) in messages.enumerated() {
            let h = heights[i]
            y -= h + gap
            let x = m.fromBud ? 0 : (W - maxW)
            let b = ChatBubble(frame: NSRect(x: x, y: y, width: maxW, height: h), msg: m)
            listHost.addSubview(b)
            bubbles.append(b)
        }
        listHost.scroll(NSPoint(x: 0, y: 0))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
EOF_BUDCHAT_SWIFT

cat << 'EOF_BUDCLEAN_SWIFT' > "$SRC_DIR/BudClean.swift"
import Cocoa

// ═══════════════════════════════════════════════════════════
//  Corbeille et résidus
//  Rien n'est supprimé sans analyse préalable ni confirmation.
// ═══════════════════════════════════════════════════════════

struct CleanTarget {
    let id: String
    let title: String
    let detail: String
    let icon: String
    /// true : le contenu part à la corbeille ; false : suppression directe
    let toTrash: Bool
    let urls: () -> [URL]
}

struct CleanResult {
    var bytes: Int64 = 0
    var files: Int = 0
}

enum Cleaner {

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Taille réelle occupée par un dossier, bornée pour rester rapide.
    static func sizeOf(_ url: URL, limit: Int = 60_000) -> CleanResult {
        var r = CleanResult()
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey],
                                    options: []) else { return r }
        var seen = 0
        for case let f as URL in e {
            seen += 1
            if seen > limit { break }
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey])
            if v?.isDirectory == true { continue }
            r.bytes += Int64(v?.totalFileAllocatedSize ?? 0)
            r.files += 1
        }
        return r
    }

    /// Les éléments de premier niveau d'un dossier (ce que l'on videra).
    static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                      options: [])) ?? []
    }

    static func targets() -> [CleanTarget] {
        let fm = FileManager.default
        let uid = getuid()
        return [
            CleanTarget(id: "trash", title: "Corbeille", detail: "Votre corbeille personnelle",
                        icon: "trash.fill", toTrash: false) {
                children(home.appendingPathComponent(".Trash"))
            },
            CleanTarget(id: "trashVol", title: "Corbeilles des volumes",
                        detail: "Fichiers supprimés restés sur les disques externes",
                        icon: "externaldrive.badge.xmark", toTrash: false) {
                var out: [URL] = []
                for v in scanVolumes() where !v.isBoot {
                    let t = v.url.appendingPathComponent(".Trashes/\(uid)")
                    if fm.fileExists(atPath: t.path) { out += children(t) }
                }
                return out
            },
            CleanTarget(id: "caches", title: "Caches applicatifs",
                        detail: "~/Bibliothèque/Caches, reconstruits automatiquement",
                        icon: "shippingbox.fill", toTrash: false) {
                children(home.appendingPathComponent("Library/Caches"))
            },
            CleanTarget(id: "logs", title: "Journaux",
                        detail: "~/Bibliothèque/Logs", icon: "doc.text.magnifyingglass", toTrash: false) {
                children(home.appendingPathComponent("Library/Logs"))
            },
            CleanTarget(id: "derived", title: "Données Xcode",
                        detail: "DerivedData et archives de compilation",
                        icon: "hammer.fill", toTrash: false) {
                children(home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
            },
            CleanTarget(id: "dsstore", title: "Fichiers .DS_Store",
                        detail: "Bureau, Documents et Téléchargements",
                        icon: "doc.badge.gearshape", toTrash: false) {
                var out: [URL] = []
                for d in ["Desktop", "Documents", "Downloads"] {
                    let root = home.appendingPathComponent(d)
                    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                                options: [.skipsPackageDescendants]) else { continue }
                    var n = 0
                    for case let f as URL in e {
                        n += 1
                        if n > 40_000 { break }
                        if f.lastPathComponent == ".DS_Store" { out.append(f) }
                    }
                }
                return out
            },
            CleanTarget(id: "oldDownloads", title: "Vieux téléchargements",
                        detail: "Fichiers de plus de 60 jours, envoyés à la corbeille",
                        icon: "clock.arrow.circlepath", toTrash: true) {
                let limit = Date().addingTimeInterval(-60 * 86400)
                return children(home.appendingPathComponent("Downloads")).filter { u in
                    let v = try? u.resourceValues(forKeys: [.contentModificationDateKey])
                    return (v?.contentModificationDate ?? Date()) < limit
                }
            }
        ]
    }

    /// Analyse en arrière-plan ; le résultat revient sur le fil principal.
    static func scan(progress: @escaping (Double, String) -> Void = { _, _ in },
                     done: @escaping ([String: CleanResult]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var out: [String: CleanResult] = [:]
            let fm = FileManager.default
            let all = targets()
            for (idx, t) in all.enumerated() {
                DispatchQueue.main.async { progress(Double(idx) / Double(all.count), t.title) }
                var r = CleanResult()
                for u in t.urls() {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                    if isDir.boolValue {
                        let s = sizeOf(u)
                        r.bytes += s.bytes
                        r.files += s.files
                    } else {
                        let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                        r.bytes += Int64(v?.totalFileAllocatedSize ?? 0)
                        r.files += 1
                    }
                }
                out[t.id] = r
            }
            DispatchQueue.main.async { progress(1, ""); done(out) }
        }
    }

    /// Exécute le nettoyage des cibles demandées.
    static func clean(ids: Set<String>,
                      progress: @escaping (Double, String, Int64) -> Void = { _, _, _ in },
                      done: @escaping (Int64, Int, Int) -> Void) {
        let selected = targets().filter { ids.contains($0.id) }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var freed: Int64 = 0
            var removed = 0
            var failed = 0
            for (idx, t) in selected.enumerated() {
                DispatchQueue.main.async { progress(Double(idx) / Double(max(1, selected.count)), t.title, freed) }
                for u in t.urls() {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                    let size: Int64
                    if isDir.boolValue { size = sizeOf(u).bytes }
                    else { size = Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                                            .totalFileAllocatedSize ?? 0) }
                    do {
                        if t.toTrash {
                            try fm.trashItem(at: u, resultingItemURL: nil)
                        } else {
                            try fm.removeItem(at: u)
                        }
                        freed += size
                        removed += 1
                    } catch {
                        failed += 1
                    }
                    if removed % 12 == 0 {
                        let snapshot = freed
                        DispatchQueue.main.async { progress(-1, t.title, snapshot) }
                    }
                }
            }
            DispatchQueue.main.async { progress(1, "", freed); done(freed, removed, failed) }
        }
    }
}

/// Ligne de nettoyage : case à cocher, intitulé, volume récupérable.
final class CleanRow: NSView {
    let targetID: String
    private let title: String
    private let detail: String
    private let iconName: String
    var checked = true { didSet { needsDisplay = true } }
    var sizeText = "—" { didSet { needsDisplay = true } }
    var empty = false { didSet { needsDisplay = true } }
    var onToggle: ((String) -> Void)?
    private var hover = false

    init(frame: NSRect, target: CleanTarget) {
        targetID = target.id
        title = target.title
        detail = target.detail
        iconName = target.icon
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
        guard !empty, bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        onToggle?(targetID)
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let card = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        TH.fill(empty ? 0.03 : (hover ? 0.09 : 0.05)).setFill()
        card.fill()
        TH.fill(0.07).setStroke()
        card.lineWidth = 1
        card.stroke()

        // Case à cocher
        let box = NSRect(x: r.minX + 14, y: r.midY - 9, width: 18, height: 18)
        let bp = NSBezierPath(roundedRect: box, xRadius: 5.5, yRadius: 5.5)
        if checked && !empty {
            TH.accent.setFill()
            bp.fill()
            drawSymbol("checkmark", center: NSPoint(x: box.midX, y: box.midY), size: 10,
                       weight: .bold, color: TH.onAccent)
        } else {
            TH.fill(0.10).setFill()
            bp.fill()
            TH.fill(0.14).setStroke()
            bp.lineWidth = 1
            bp.stroke()
        }

        drawSymbol(iconName, center: NSPoint(x: r.minX + 52, y: r.midY), size: 13.5, weight: .semibold,
                   color: empty ? TH.dim(0.25) : (checked ? TH.accent : TH.dim(0.45)))

        let sizeW = textWidth(sizeText, size: 13, weight: .bold, mono: true) + 10
        let textMax = r.width - 72 - sizeW - 16
        drawString(title, in: NSRect(x: r.minX + 72, y: r.midY + 1, width: textMax, height: 17),
                   size: 12.5, weight: .semibold, color: empty ? TH.dim(0.35) : TH.text)
        drawString(detail, in: NSRect(x: r.minX + 72, y: r.midY - 15, width: textMax, height: 15),
                   size: 10.5, weight: .regular, color: TH.dim(0.42))

        drawString(empty ? "rien" : sizeText,
                   in: NSRect(x: r.maxX - sizeW - 14, y: r.midY - 9, width: sizeW, height: 19),
                   size: 13, weight: .bold, color: empty ? TH.dim(0.3) : TH.text, align: .right, mono: true)
    }
}

final class CleanupPanelView: NSView {
    private let hero: HeroHeader
    private var rows: [CleanRow] = []
    private var totalTile: StatTile!
    private var statusLabel: NSTextField!
    private var cleanBtn: GlassButton!
    private var sizes: [String: CleanResult] = [:]
    private var sweep: SweepView!
    private var sweepTimer: Timer?
    private var selection = Set<String>(["trash", "trashVol", "caches", "logs"])
    private var busy = false

    var onStatus: ((String) -> Void)?
    var onCleaned: (() -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Nettoyage", subtitle: "Corbeille, caches et résidus récupérables.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height

        totalTile = StatTile(frame: NSRect(x: W - 190, y: H - 86, width: 180, height: 78),
                             caption: "Récupérable", hint: "lancez une analyse")
        addSubview(totalTile)

        sweep = SweepView(frame: NSRect(x: 0, y: H - 182, width: W, height: 62))
        sweep.isHidden = true
        addSubview(sweep)

        mkSection(self, H - 116, W, "Éléments")

        let targets = Cleaner.targets()
        for (i, t) in targets.enumerated() {
            let row = CleanRow(frame: NSRect(x: 0, y: H - 164 - CGFloat(i) * 50, width: W, height: 46), target: t)
            row.checked = selection.contains(t.id)
            row.onToggle = { [weak self] id in self?.toggle(id) }
            addSubview(row)
            rows.append(row)
        }

        statusLabel = mkLabel("Analysez pour connaître l'espace récupérable.",
                              NSRect(x: 0, y: 56, width: W, height: 18), 11, .regular, alpha: 0.45, .center)
        addSubview(statusLabel)

        let bw = (W - 12) / 2
        let scanBtn = GlassButton(frame: NSRect(x: 0, y: 0, width: bw, height: 46),
                                  title: "Analyser", icon: "magnifyingglass")
        scanBtn.onClick = { [weak self] _ in self?.scan() }
        cleanBtn = GlassButton(frame: NSRect(x: bw + 12, y: 0, width: bw, height: 46),
                               title: "Nettoyer", icon: "sparkles", prominent: true)
        cleanBtn.enabledFlag = false
        cleanBtn.onClick = { [weak self] _ in self?.confirmClean() }
        [scanBtn, cleanBtn].forEach { addSubview($0) }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        for r in rows where r.targetID == id { r.checked = selection.contains(id) }
        updateTotal()
    }

    private func updateTotal() {
        var total: Int64 = 0
        for id in selection { total += sizes[id]?.bytes ?? 0 }
        totalTile.set(sizes.isEmpty ? "—" : formatBytes(total),
                      hint: sizes.isEmpty ? "lancez une analyse" : "sur les éléments cochés")
        cleanBtn.enabledFlag = !busy && total > 0
        hero.set(trailing: total > 0 ? formatBytes(total) : "")
    }

    private func startSweep(_ caption: String) {
        sweep.reset()
        sweep.caption = caption
        sweep.freedText = ""
        sweep.progress = 0
        sweep.isHidden = false
        rows.forEach { $0.alphaValue = 0.35 }
        sweepTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.sweep.step() }
        RunLoop.main.add(t, forMode: .common)
        sweepTimer = t
    }

    private func endSweep(_ freed: String, celebrate: Bool) {
        sweep.freedText = freed
        if celebrate {
            sweep.celebrate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.hideSweep() }
        } else {
            hideSweep()
        }
    }

    private func hideSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        rows.forEach { $0.alphaValue = 1 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            sweep.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.sweep.isHidden = true
            self?.sweep.alphaValue = 1
        })
    }

    func scan() {
        guard !busy else { return }
        busy = true
        statusLabel.stringValue = "Analyse en cours…"
        cleanBtn.enabledFlag = false
        startSweep("Analyse…")
        Cleaner.scan(progress: { [weak self] p, name in
            self?.sweep.progress = CGFloat(p)
            self?.sweep.caption = name.isEmpty ? "Analyse…" : "Analyse · \(name)"
        }) { [weak self] res in
            guard let s = self else { return }
            s.sizes = res
            for r in s.rows {
                let v = res[r.targetID] ?? CleanResult()
                r.sizeText = formatBytes(v.bytes)
                r.empty = (v.bytes == 0)
                if v.bytes == 0 { s.selection.remove(r.targetID) }
                r.checked = s.selection.contains(r.targetID)
            }
            s.busy = false
            s.statusLabel.stringValue = "Analyse terminée. Décochez ce que vous voulez garder."
            s.updateTotal()
            var total: Int64 = 0
            for id in s.selection { total += res[id]?.bytes ?? 0 }
            s.endSweep(total > 0 ? "\(formatBytes(total)) récupérables" : "rien à libérer", celebrate: false)
        }
    }

    private func confirmClean() {
        var total: Int64 = 0
        var lines: [String] = []
        for t in Cleaner.targets() where selection.contains(t.id) {
            let b = sizes[t.id]?.bytes ?? 0
            guard b > 0 else { continue }
            total += b
            lines.append("• \(t.title) — \(formatBytes(b))")
        }
        guard total > 0 else { return }

        let a = NSAlert()
        a.messageText = "Libérer \(formatBytes(total)) ?"
        a.informativeText = lines.joined(separator: "\n")
            + "\n\nLa corbeille et les caches sont supprimés définitivement ; les vieux téléchargements partent à la corbeille."
        a.addButton(withTitle: "Nettoyer")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        busy = true
        cleanBtn.enabledFlag = false
        statusLabel.stringValue = "Nettoyage en cours…"
        startSweep("Nettoyage…")
        Cleaner.clean(ids: selection, progress: { [weak self] p, name, freed in
            guard let s = self else { return }
            if p >= 0 { s.sweep.progress = CGFloat(p) }
            if !name.isEmpty { s.sweep.caption = "Nettoyage · \(name)" }
            s.sweep.freedText = "\(formatBytes(freed)) libérés"
        }) { [weak self] freed, removed, failed in
            guard let s = self else { return }
            s.busy = false
            let msg = "\(formatBytes(freed)) libérés · \(removed) éléments"
                + (failed > 0 ? " · \(failed) protégés par le système" : "")
            s.statusLabel.stringValue = msg
            s.onStatus?(msg)
            s.onCleaned?()
            s.endSweep("\(formatBytes(freed)) libérés", celebrate: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.scan() }
        }
    }

    /// Vidage immédiat de la seule corbeille, utilisable depuis le chat.
    func emptyTrashOnly(_ done: @escaping (String) -> Void) {
        Cleaner.clean(ids: ["trash", "trashVol"]) { freed, removed, failed in
            done("\(formatBytes(freed)) libérés · \(removed) éléments"
                 + (failed > 0 ? " · \(failed) ignorés" : ""))
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  Animation de nettoyage
//  Des poussières sont aspirées vers la corbeille pendant que
//  BUD balaie ; le compteur d'octets libérés grimpe en direct.
// ═══════════════════════════════════════════════════════════

private struct Mote {
    var x: CGFloat, y: CGFloat
    var vx: CGFloat, vy: CGFloat
    var size: CGFloat
    var life: CGFloat
    var spin: CGFloat
}

final class SweepView: NSView {
    private var motes: [Mote] = []
    private var t: CGFloat = 0
    private var shimmer: CGFloat = 0
    private var burst: CGFloat = 0

    var progress: CGFloat = 0          // < 0 : indéterminé
    var caption = ""
    var freedText = ""
    var finished = false

    func reset() {
        motes.removeAll()
        t = 0
        burst = 0
        finished = false
    }

    func celebrate() {
        finished = true
        burst = 1
        for _ in 0..<26 {
            let a = CGFloat.random(in: 0...(.pi * 2))
            let sp = CGFloat.random(in: 1.4...4.2)
            motes.append(Mote(x: bounds.width * 0.5, y: bounds.height * 0.5,
                              vx: cos(a) * sp, vy: sin(a) * sp,
                              size: CGFloat.random(in: 1.6...3.4),
                              life: CGFloat.random(in: 0.7...1.0),
                              spin: CGFloat.random(in: -0.2...0.2)))
        }
    }

    func step() {
        t += 0.05
        shimmer += 0.028
        if shimmer > 1.6 { shimmer = -0.4 }
        if burst > 0 { burst = max(0, burst - 0.015) }

        let sink = NSPoint(x: bounds.width - 54, y: bounds.height / 2)

        if !finished && motes.count < 34 && Int(t * 20) % 2 == 0 {
            motes.append(Mote(x: CGFloat.random(in: 40...(bounds.width * 0.55)),
                              y: CGFloat.random(in: 12...(bounds.height - 12)),
                              vx: 0, vy: 0,
                              size: CGFloat.random(in: 1.4...3.2),
                              life: 1,
                              spin: CGFloat.random(in: -0.3...0.3)))
        }

        for i in motes.indices.reversed() {
            if finished {
                motes[i].x += motes[i].vx
                motes[i].y += motes[i].vy
                motes[i].vy -= 0.06
                motes[i].life -= 0.022
            } else {
                let dx = sink.x - motes[i].x, dy = sink.y - motes[i].y
                let d = max(6, sqrt(dx * dx + dy * dy))
                motes[i].vx += dx / d * 0.42
                motes[i].vy += dy / d * 0.42 + sin(t * 2 + motes[i].spin * 10) * 0.08
                motes[i].vx *= 0.90
                motes[i].vy *= 0.90
                motes[i].x += motes[i].vx
                motes[i].y += motes[i].vy
                if d < 14 { motes[i].life -= 0.14 }
            }
            if motes[i].life <= 0 { motes.remove(at: i) }
        }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let card = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        TH.fill(0.06).setFill()
        card.fill()
        TH.accent.withAlphaComponent(0.22).setStroke()
        card.lineWidth = 1
        card.stroke()

        // Reflet qui balaie la carte pendant le travail
        if !finished {
            NSGraphicsContext.current?.saveGraphicsState()
            card.addClip()
            let gx = r.minX + shimmer * r.width
            if let g = NSGradient(colors: [TH.accent.withAlphaComponent(0),
                                           TH.accent.withAlphaComponent(0.10),
                                           TH.accent.withAlphaComponent(0)]) {
                g.draw(in: NSRect(x: gx - 90, y: r.minY, width: 180, height: r.height), angle: 0)
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Poussières
        for m in motes {
            let a = max(0, min(1, m.life))
            (finished ? TH.accent : TH.dim(0.8)).withAlphaComponent(a * (finished ? 0.9 : 0.5)).setFill()
            NSBezierPath(ovalIn: NSRect(x: m.x - m.size, y: m.y - m.size,
                                        width: m.size * 2, height: m.size * 2)).fill()
        }

        // Balai de BUD, à gauche
        let bx = r.minX + 34 + sin(t * 3) * 5
        let by = r.midY + cos(t * 6) * 2
        drawSymbol(finished ? "sparkles" : "wind", center: NSPoint(x: bx, y: by),
                   size: 22, weight: .semibold, color: TH.accent)

        // Corbeille cible, à droite
        let sink = NSPoint(x: r.width - 54, y: r.midY)
        let pulse = finished ? 0 : CGFloat(abs(sin(t * 4))) * 2
        TH.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(ovalIn: NSRect(x: sink.x - 20 - pulse, y: sink.y - 20 - pulse,
                                    width: 40 + pulse * 2, height: 40 + pulse * 2)).fill()
        drawSymbol(finished ? "checkmark.circle.fill" : "trash.fill",
                   center: sink, size: 20, weight: .semibold,
                   color: finished ? TH.accent : TH.dim(0.75))

        // Texte et progression
        let textX = r.minX + 66
        let textW = r.width - 66 - 90
        drawString(finished ? "Nettoyage terminé" : (caption.isEmpty ? "Analyse…" : caption),
                   in: NSRect(x: textX, y: r.midY + 4, width: textW, height: 20),
                   size: 13, weight: .bold, color: TH.text)
        drawString(freedText, in: NSRect(x: textX, y: r.midY - 16, width: textW, height: 18),
                   size: 11.5, weight: .medium, color: TH.dim(0.55), mono: true)

        if !finished {
            let track = NSRect(x: textX, y: r.minY + 10, width: textW, height: 4)
            TH.fill(0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            TH.accent.setFill()
            if progress >= 0 {
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                                 width: max(4, track.width * progress), height: 4),
                             xRadius: 2, yRadius: 2).fill()
            } else {
                // Indéterminé : une navette va et vient
                let w = track.width * 0.3
                let x = track.minX + (track.width - w) * (0.5 + 0.5 * sin(t * 1.6))
                NSBezierPath(roundedRect: NSRect(x: x, y: track.minY, width: w, height: 4),
                             xRadius: 2, yRadius: 2).fill()
            }
        }
    }
}
EOF_BUDCLEAN_SWIFT

cat << 'EOF_BUDCORE_SWIFT' > "$SRC_DIR/BudCore.swift"
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
    var musicSource: Int = 0            // 0 Musique · 1 Spotify · 2 Alexa
    var alarmSound: Bool = true       // sonnerie répétée des rappels
    var budPremium: Bool = false      // v17 : conservé pour la migration
    var budSkin: Int = 0              // 0 à plat · 1 nacré-or · 2 métal

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
        // Un état écrit par la v17 ne connaît que budPremium : on le reporte.
        if budSkin == 0 && budPremium { budSkin = 1 }
        if budSkin < 0 || budSkin > 2 { budSkin = 0 }
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
    var onAccent: NSColor { NSColor(calibratedWhite: 0.06, alpha: 0.92) }
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
let budVersion = "22.0"
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
EOF_BUDCORE_SWIFT

cat << 'EOF_BUDFACE_SWIFT' > "$SRC_DIR/BudFace.swift"
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

enum BudMood { case calm, happy, alert, sleepy, wink, dizzy }

/// Trois habillages : à plat, nacré-or, et métal.
enum BudStyle { case flat, premium, metal }

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

    // Humeur
    var mood: BudMood = .calm
    private var happyUntil = Date.distantPast
    private var winkUntil = Date.distantPast
    private var dizzyUntil = Date.distantPast

    private var effectiveMood: BudMood {
        let now = Date()
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

        return true   // la respiration anime en continu, très légèrement
    }

    // ═══════════ Rendu ═══════════

    /// `detail` active l'ombre portée, les reflets et les effets d'humeur
    /// (tailles moyennes et grandes).
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
        ctx.translateBy(x: cx + shakeX, y: cy + floatY + jump + shakeY)
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
        case .calm, .sleepy:
            let h = m == .sleepy ? eyeS * 0.18 : eyeS * open
            metalEye(NSPoint(x: -eyeX, y: eyeY), w: eyeS, h: h, r: corner, c: eye, detail: detail)
            metalEye(NSPoint(x: eyeX * 1.04, y: eyeY + r * 0.01),
                     w: eyeS * 1.12, h: eyeS * 1.08 * (m == .sleepy ? 0.17 : open),
                     r: corner * 1.06, c: eye, detail: detail)

        case .happy:
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

        case .alert:
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
        case .calm:
            drawRoundEye(at: NSPoint(x: -eyeX, y: eyeY), r: eyeR, premium: premium, detail: detail)
            drawRoundEye(at: NSPoint(x: eyeX, y: eyeY), r: eyeR, premium: premium, detail: detail)
            drawOMouth(size: s, y: -s * 0.125, w: s * 0.042, h: s * 0.056,
                       ink: ink, premium: premium)

        case .happy:
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

        case .alert:
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
EOF_BUDFACE_SWIFT

cat << 'EOF_BUDGMAIL_SWIFT' > "$SRC_DIR/BudGmail.swift"
import Foundation
import Network
import Security

private typealias NWPort = NWEndpoint.Port

// ═══════════════════════════════════════════════════════════
//  Connexion directe à Gmail — IMAP pour lire, SMTP pour écrire
//
//  Google n'autorise plus le mot de passe du compte : il faut un
//  « mot de passe d'application » (compte protégé par validation en
//  deux étapes, puis myaccount.google.com/apppasswords).
//  Ce mot de passe est rangé dans le trousseau macOS, jamais sur disque.
// ═══════════════════════════════════════════════════════════

enum BudKeychain {
    static let service = "fr.lahbib.bud.gmail"

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// Connexion TLS ligne à ligne, synchrone, pensée pour IMAP et SMTP.
final class TLSLineSocket {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "fr.lahbib.bud.net")
    private var buffer = Data()
    private(set) var failure: String?

    init?(host: String, port: UInt16, timeout: TimeInterval = 15) {
        guard let p = NWPort(rawValue: port) else { return nil }
        let params = NWParameters(tls: NWProtocolTLS.Options())
        conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)

        let sem = DispatchSemaphore(value: 0)
        var ready = false
        var err: String?
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready: ready = true; sem.signal()
            case .failed(let e): err = e.localizedDescription; sem.signal()
            case .waiting(let e): err = e.localizedDescription
            case .cancelled: sem.signal()
            default: break
            }
        }
        conn.start(queue: queue)
        _ = sem.wait(timeout: .now() + timeout)
        guard ready else {
            conn.cancel()
            failure = err ?? "connexion impossible à \(host)"
            return nil
        }
    }

    private func fill(timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var chunk: Data?
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { d, _, _, _ in
            chunk = d
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success,
              let d = chunk, !d.isEmpty else { return false }
        buffer.append(d)
        return true
    }

    func readLine(timeout: TimeInterval = 20) -> String? {
        while true {
            if let r = buffer.range(of: Data([13, 10])) {
                let raw = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
            }
            if !fill(timeout: timeout) { return nil }
        }
    }

    @discardableResult
    func write(_ s: String, newline: Bool = true) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = true
        conn.send(content: Data((s + (newline ? "\r\n" : "")).utf8),
                  completion: .contentProcessed { e in
                      if e != nil { ok = false }
                      sem.signal()
                  })
        _ = sem.wait(timeout: .now() + 20)
        return ok
    }

    func close() { conn.cancel() }
}


// ── Décodage des en-têtes encodés (=?UTF-8?B?…?=) ──

func decodeMimeHeader(_ s: String) -> String {
    var out = s
    let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?="
    guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
    let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
    for m in matches {
        guard let whole = Range(m.range, in: s),
              let encR = Range(m.range(at: 2), in: s),
              let txtR = Range(m.range(at: 3), in: s) else { continue }
        let enc = s[encR].uppercased()
        let txt = String(s[txtR])
        var decoded = txt
        if enc == "B" {
            if let d = Data(base64Encoded: txt), let t = String(data: d, encoding: .utf8) { decoded = t }
        } else {
            var t = txt.replacingOccurrences(of: "_", with: " ")
            while let r = t.range(of: "=[0-9A-Fa-f]{2}", options: .regularExpression) {
                let hex = String(t[r]).dropFirst()
                if let v = UInt8(hex, radix: 16) {
                    t.replaceSubrange(r, with: String(UnicodeScalar(v)))
                } else { break }
            }
            decoded = t
        }
        if let wr = Range(NSRange(whole, in: s), in: out) ?? out.range(of: String(s[whole])) {
            out.replaceSubrange(wr, with: decoded)
        }
    }
    return out
}

// ═══════════════════════════════════════════════════════════
//  Client Gmail
// ═══════════════════════════════════════════════════════════

struct GmailSnapshot {
    var unread = 0
    var messages: [MailMessage] = []
    var error: String?
    var ok: Bool { error == nil }
}

enum GmailAuthMode {
    case appPassword(String)
    case oauth(String)        // chaîne XOAUTH2 déjà encodée
}

enum GmailClient {

    static let imapHost = "imap.gmail.com"
    static let smtpHost = "smtp.gmail.com"

    static func normalizedPassword(_ p: String) -> String {
        p.replacingOccurrences(of: " ", with: "")
    }

    static func fetchInbox(user: String, password: String, limit: Int = 5) -> GmailSnapshot {
        fetchInbox(user: user, auth: .appPassword(password), limit: limit)
    }

    /// Vérifie le couple adresse / mot de passe d'application.
    static func testLogin(user: String, password: String) -> String? {
        guard let s = TLSLineSocket(host: imapHost, port: 993) else {
            return "Connexion IMAP impossible (réseau ou pare-feu)."
        }
        defer { s.close() }
        _ = s.readLine()
        s.write("a1 LOGIN \"\(user)\" \"\(normalizedPassword(password))\"")
        while let l = s.readLine() {
            if l.hasPrefix("a1 OK") { s.write("a9 LOGOUT"); return nil }
            if l.hasPrefix("a1 NO") || l.hasPrefix("a1 BAD") {
                return "Gmail refuse ces identifiants. Utilisez un mot de passe d'application."
            }
        }
        return "Gmail n'a pas répondu."
    }

    /// Non-lus et derniers messages de la boîte de réception.
    static func fetchInbox(user: String, auth: GmailAuthMode, limit: Int = 5) -> GmailSnapshot {
        var snap = GmailSnapshot()
        guard let s = TLSLineSocket(host: imapHost, port: 993) else {
            snap.error = "IMAP injoignable."
            return snap
        }
        defer { s.close() }
        _ = s.readLine()

        switch auth {
        case .appPassword(let p):
            s.write("a1 LOGIN \"\(user)\" \"\(normalizedPassword(p))\"")
        case .oauth(let token):
            s.write("a1 AUTHENTICATE XOAUTH2 \(token)")
        }
        var logged = false
        while let l = s.readLine() {
            if l.hasPrefix("a1 OK") { logged = true; break }
            if l.hasPrefix("a1 NO") || l.hasPrefix("a1 BAD") { break }
            if l.hasPrefix("+ ") { s.write("") }   // Gmail attend une ligne vide après un refus XOAUTH2
        }
        guard logged else {
            snap.error = "Identifiants refusés."
            return snap
        }

        s.write("a2 SELECT INBOX")
        while let l = s.readLine() { if l.hasPrefix("a2 ") { break } }

        // Les non-lus, pour le compteur et pour marquer la liste.
        s.write("a3 UID SEARCH UNSEEN")
        var unseen: Set<String> = []
        while let l = s.readLine() {
            if l.uppercased().hasPrefix("* SEARCH") {
                unseen = Set(l.split(separator: " ").dropFirst(2).map(String.init))
            }
            if l.hasPrefix("a3 ") { break }
        }
        snap.unread = unseen.count

        // Les derniers messages, lus ou non : on répond aussi à un message lu.
        s.write("a4 UID SEARCH ALL")
        var all: [String] = []
        while let l = s.readLine() {
            if l.uppercased().hasPrefix("* SEARCH") {
                all = l.split(separator: " ").dropFirst(2).map(String.init)
            }
            if l.hasPrefix("a4 ") { break }
        }
        if all.isEmpty { all = Array(unseen) }

        for (i, uid) in all.suffix(limit).reversed().enumerated() {
            let tag = "f\(i)"
            s.write("\(tag) UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE "
                    + "REPLY-TO RETURN-PATH MESSAGE-ID AUTHENTICATION-RESULTS RECEIVED-SPF)] "
                    + "BODYSTRUCTURE)")
            var subject = "", from = "", date = "", replyTo = ""
            var ret = "", mid = "", authRes = "", spf = ""
            var structure = ""
            var lastKey = ""
            while let l = s.readLine() {
                if l.hasPrefix("\(tag) ") { break }
                // Un en-tête replié commence par une espace : il prolonge le précédent.
                if l.hasPrefix(" ") || l.hasPrefix("\t") {
                    let cont = l.trimmingCharacters(in: .whitespaces)
                    switch lastKey {
                    case "authentication-results": authRes += " " + cont
                    case "received-spf": spf += " " + cont
                    case "subject": subject += " " + cont
                    case "from": from += " " + cont
                    default: break
                    }
                    continue
                }
                if l.uppercased().contains("BODYSTRUCTURE") { structure += l }
                guard let colon = l.firstIndex(of: ":") else { continue }
                let key = l[l.startIndex..<colon].lowercased()
                let value = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                lastKey = key
                switch key {
                case "subject": subject = value
                case "from": from = value
                case "date": date = value
                case "reply-to": replyTo = value
                case "return-path": ret = value
                case "message-id": mid = value
                case "authentication-results": authRes = value
                case "received-spf": spf = value
                default: lastKey = ""
                }
            }

            var m = MailMessage(subject: decodeMimeHeader(subject),
                                sender: decodeMimeHeader(from),
                                date: date)
            m.uid = uid
            m.messageID = mid
            m.replyTo = decodeMimeHeader(replyTo)
            m.returnPath = ret
            m.authResults = authRes
            m.spf = spf
            m.unread = unseen.contains(uid)
            m.attachments = attachmentNames(in: structure)
            m.snippet = fetchSnippet(s, uid: uid, tag: "b\(i)")
            m.threat = MailGuard.analyze(m)
            snap.messages.append(m)
        }
        s.write("a9 LOGOUT")
        return snap
    }

    /// Noms de pièces jointes extraits de BODYSTRUCTURE. Le format est
    /// une liste Lisp imbriquée pénible à analyser ; les noms y figurent
    /// toujours après NAME ou FILENAME, ce qui suffit ici.
    static func attachmentNames(in structure: String) -> [String] {
        guard !structure.isEmpty,
              let re = try? NSRegularExpression(
                pattern: "\"(?:NAME|FILENAME)\"\\s+\"([^\"]{1,180})\"",
                options: [.caseInsensitive]) else { return [] }
        let r = NSRange(structure.startIndex..., in: structure)
        var out: [String] = []
        for m in re.matches(in: structure, range: r) {
            guard let rr = Range(m.range(at: 1), in: structure) else { continue }
            let name = decodeMimeHeader(String(structure[rr]))
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// Début du corps, pour l'analyse des liens et du vocabulaire.
    /// On ne lit que la première partie et on s'arrête vite : il ne s'agit
    /// pas d'afficher le message, seulement de le jauger.
    static func fetchSnippet(_ s: TLSLineSocket, uid: String, tag: String,
                             maxChars: Int = 8000) -> String {
        s.write("\(tag) UID FETCH \(uid) (BODY.PEEK[1]<0.8192>)")
        var lines: [String] = []
        var total = 0
        while let l = s.readLine() {
            if l.hasPrefix("\(tag) ") { break }
            if total < maxChars {
                lines.append(l)
                total += l.count
            }
        }
        var body = lines.joined(separator: "\n")

        // Quoted-printable : les coupures « = » en fin de ligne et les =XX.
        if body.contains("=\n") || body.range(of: "=[0-9A-Fa-f]{2}", options: .regularExpression) != nil {
            body = body.replacingOccurrences(of: "=\n", with: "")
            while let r = body.range(of: "=[0-9A-Fa-f]{2}", options: .regularExpression) {
                let hex = String(body[r]).dropFirst()
                guard let v = UInt8(hex, radix: 16) else { break }
                body.replaceSubrange(r, with: String(UnicodeScalar(v)))
            }
        }

        // Partie encodée en base64 : sans décodage, l'analyse ne verrait rien.
        let compact = body.filter { !" \n\r\t".contains($0) }
        if compact.count > 80,
           compact.range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil,
           let d = Data(base64Encoded: compact, options: .ignoreUnknownCharacters),
           let decoded = String(data: d, encoding: .utf8) {
            body = decoded
        }
        return String(body.prefix(maxChars))
    }

    /// Déplace des messages vers le dossier indésirable du compte.
    /// Renvoie nil si tout s'est bien passé.
    static func quarantine(user: String, auth: GmailAuthMode, uids: [String]) -> String? {
        guard !uids.isEmpty else { return nil }
        guard let s = TLSLineSocket(host: imapHost, port: 993) else { return "IMAP injoignable." }
        defer { s.close() }
        _ = s.readLine()

        switch auth {
        case .appPassword(let p): s.write("q1 LOGIN \"\(user)\" \"\(normalizedPassword(p))\"")
        case .oauth(let token):   s.write("q1 AUTHENTICATE XOAUTH2 \(token)")
        }
        var logged = false
        while let l = s.readLine() {
            if l.hasPrefix("q1 OK") { logged = true; break }
            if l.hasPrefix("q1 NO") || l.hasPrefix("q1 BAD") { break }
            if l.hasPrefix("+ ") { s.write("") }
        }
        guard logged else { return "Identifiants refusés." }

        // Le nom du dossier indésirable est localisé : on le demande au
        // serveur par son rôle plutôt que de le deviner.
        var junk = ""
        s.write("q2 LIST (SPECIAL-USE) \"\" \"*\"")
        while let l = s.readLine() {
            if l.hasPrefix("q2 ") { break }
            if l.contains("\\Junk"), let last = l.range(of: "\"", options: .backwards) {
                let head = l[l.startIndex..<last.lowerBound]
                if let open = head.range(of: "\"", options: .backwards) {
                    junk = String(head[open.upperBound...])
                }
            }
        }
        if junk.isEmpty { junk = "[Gmail]/Spam" }

        s.write("q3 SELECT INBOX")
        while let l = s.readLine() { if l.hasPrefix("q3 ") { break } }

        let set = uids.joined(separator: ",")
        var moved = false
        s.write("q4 UID MOVE \(set) \"\(junk)\"")
        while let l = s.readLine() {
            if l.hasPrefix("q4 OK") { moved = true; break }
            if l.hasPrefix("q4 NO") || l.hasPrefix("q4 BAD") { break }
        }
        if !moved {
            // Serveur sans UID MOVE : copie, marquage, purge.
            s.write("q5 UID COPY \(set) \"\(junk)\"")
            var copied = false
            while let l = s.readLine() {
                if l.hasPrefix("q5 OK") { copied = true; break }
                if l.hasPrefix("q5 NO") || l.hasPrefix("q5 BAD") { break }
            }
            guard copied else { s.write("q9 LOGOUT"); return "Le dossier « \(junk) » a refusé la copie." }
            s.write("q6 UID STORE \(set) +FLAGS (\\Deleted)")
            while let l = s.readLine() { if l.hasPrefix("q6 ") { break } }
            s.write("q7 EXPUNGE")
            while let l = s.readLine() { if l.hasPrefix("q7 ") { break } }
        }
        s.write("q9 LOGOUT")
        return nil
    }

    private static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    private static func expect(_ s: TLSLineSocket, _ code: String) -> (Bool, String) {
        while let l = s.readLine() {
            guard l.count >= 4 else { continue }
            let idx = l.index(l.startIndex, offsetBy: 3)
            if l[idx] == "-" { continue }          // réponse multiligne, on poursuit
            return (l.hasPrefix(code), l)
        }
        return (false, "pas de réponse du serveur")
    }

    static func send(user: String, password: String, to: String,
                     subject: String, body: String) -> String {
        send(user: user, auth: .appPassword(password), to: to, subject: subject, body: body)
    }

    /// Envoi direct par SMTP sur TLS implicite (port 465).
    /// `inReplyTo` porte le Message-ID du message d'origine : sans lui,
    /// une réponse s'affiche comme un message isolé au lieu de se ranger
    /// dans le fil de discussion.
    static func send(user: String, auth: GmailAuthMode, to: String,
                     subject: String, body: String,
                     inReplyTo: String = "") -> String {
        guard let s = TLSLineSocket(host: smtpHost, port: 465) else {
            return "Connexion SMTP impossible."
        }
        defer { s.close() }

        guard expect(s, "220").0 else { return "Gmail n'a pas ouvert la session." }
        s.write("EHLO bud.local")
        guard expect(s, "250").0 else { return "EHLO refusé." }

        switch auth {
        case .oauth(let token):
            s.write("AUTH XOAUTH2 \(token)")
            let r = expect(s, "235")
            guard r.0 else { return "Jeton Google refusé par SMTP." }
        case .appPassword(let p):
            s.write("AUTH LOGIN")
            guard expect(s, "334").0 else { return "Authentification non proposée." }
            s.write(b64(user))
            guard expect(s, "334").0 else { return "Adresse refusée." }
            s.write(b64(normalizedPassword(p)))
            guard expect(s, "235").0 else { return "Mot de passe d'application refusé." }
        }

        s.write("MAIL FROM:<\(user)>")
        guard expect(s, "250").0 else { return "Expéditeur refusé." }
        s.write("RCPT TO:<\(to)>")
        let rcpt = expect(s, "250")
        guard rcpt.0 else { return "Destinataire refusé : \(rcpt.1)" }

        s.write("DATA")
        guard expect(s, "354").0 else { return "Corps du message refusé." }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let encodedSubject = "=?UTF-8?B?\(b64(subject))?="
        // Un point en début de ligne doit être doublé (RFC 5321)
        let safeBody = body.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(".") ? "." + $0 : String($0) }
            .joined(separator: "\r\n")

        var headerLines = [
            "From: \(user)",
            "To: \(to)",
            "Subject: \(encodedSubject)",
            "Date: \(df.string(from: Date()))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
            "X-Mailer: BUD Premium"
        ]
        let ref = inReplyTo.trimmingCharacters(in: .whitespaces)
        if !ref.isEmpty {
            headerLines.append("In-Reply-To: \(ref)")
            headerLines.append("References: \(ref)")
        }
        let headers = headerLines.joined(separator: "\r\n")

        s.write(headers + "\r\n\r\n" + safeBody + "\r\n.", newline: true)
        let sent = expect(s, "250")
        s.write("QUIT")
        return sent.0 ? "Message envoyé à \(to)." : "Envoi refusé : \(sent.1)"
    }
}
EOF_BUDGMAIL_SWIFT

cat << 'EOF_BUDGUARD_SWIFT' > "$SRC_DIR/BudGuard.swift"
import Foundation
import AppKit

// ═══════════════════════════════════════════════════════════
//  Analyse de courrier indésirable, de hameçonnage et de
//  pièces jointes dangereuses.
//
//  Tout est local : aucun message, aucune adresse, aucun lien
//  n'est envoyé où que ce soit. BUD lit les en-têtes que le
//  serveur a déjà écrits (SPF, DKIM, DMARC) et applique des
//  règles de bon sens au reste.
//
//  Ce n'est pas un antivirus : BUD ne télécharge pas les pièces
//  jointes et n'inspecte pas leur contenu. Il reconnaît les
//  formes d'attaque, pas les signatures de logiciels malveillants.
// ═══════════════════════════════════════════════════════════

enum ThreatLevel: Int {
    case clean = 0, suspect = 1, dangerous = 2

    var label: String {
        switch self {
        case .clean: return "Sain"
        case .suspect: return "Suspect"
        case .dangerous: return "Dangereux"
        }
    }
    var color: NSColor {
        switch self {
        case .clean: return NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.55, alpha: 1)
        case .suspect: return NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.25, alpha: 1)
        case .dangerous: return NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.40, alpha: 1)
        }
    }
    var icon: String {
        switch self {
        case .clean: return "checkmark.shield.fill"
        case .suspect: return "exclamationmark.triangle.fill"
        case .dangerous: return "xmark.shield.fill"
        }
    }
}

struct MailThreat {
    var score: Int = 0
    var reasons: [String] = []

    var level: ThreatLevel {
        if score >= 60 { return .dangerous }
        if score >= 25 { return .suspect }
        return .clean
    }

    mutating func add(_ points: Int, _ why: String) {
        score += points
        if !reasons.contains(why) { reasons.append(why) }
    }

    var summary: String {
        reasons.isEmpty ? "Rien de suspect." : reasons.joined(separator: " · ")
    }
}

/// Un fichier douteux trouvé dans les téléchargements.
struct SuspectFile {
    var url: URL
    var reason: String
    var fromWeb: Bool
}

enum MailGuard {

    // ── Vocabulaire des règles ──

    /// Extensions exécutables : aucune raison légitime de les recevoir.
    static let lethalExtensions: Set<String> = [
        "exe", "scr", "bat", "cmd", "com", "pif", "cpl", "msi", "msp",
        "vbs", "vbe", "js", "jse", "wsf", "wsh", "hta", "ps1", "psm1",
        "jar", "lnk", "inf", "reg", "scpt", "app", "pkg", "apk", "sh", "command"
    ]

    /// Bureautique à macros : vecteur classique.
    static let macroExtensions: Set<String> = [
        "docm", "xlsm", "xlsb", "pptm", "dotm", "xltm", "potm"
    ]

    /// Archives : BUD ne peut pas regarder dedans, d'où la prudence.
    static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "iso", "img", "ace", "cab", "gz", "tgz"
    ]

    /// Marques usurpées en France, avec leurs domaines légitimes.
    static let brands: [(name: String, domains: [String])] = [
        ("paypal", ["paypal.com", "paypal.fr"]),
        ("apple", ["apple.com", "icloud.com"]),
        ("icloud", ["apple.com", "icloud.com"]),
        ("microsoft", ["microsoft.com", "outlook.com", "live.com", "office.com"]),
        ("netflix", ["netflix.com"]),
        ("amazon", ["amazon.fr", "amazon.com"]),
        ("google", ["google.com", "gmail.com", "google.fr"]),
        ("impots", ["dgfip.finances.gouv.fr", "impots.gouv.fr", "finances.gouv.fr"]),
        ("ameli", ["ameli.fr", "assurance-maladie.fr"]),
        ("chronopost", ["chronopost.fr"]),
        ("colissimo", ["colissimo.fr", "laposte.fr"]),
        ("la poste", ["laposte.fr", "laposte.net"]),
        ("dhl", ["dhl.com", "dhl.fr"]),
        ("fedex", ["fedex.com"]),
        ("ups", ["ups.com"]),
        ("orange", ["orange.fr", "orange.com"]),
        ("sfr", ["sfr.fr"]),
        ("bouygues", ["bouyguestelecom.fr"]),
        ("free", ["free.fr", "freemobile.fr"]),
        ("netflix", ["netflix.com"]),
        ("crédit agricole", ["credit-agricole.fr", "ca-", "credit-agricole.com"]),
        ("société générale", ["societegenerale.fr", "sg.fr"]),
        ("bnp", ["bnpparibas.net", "bnpparibas.com"]),
        ("boursorama", ["boursorama.com", "boursobank.com"]),
        ("revolut", ["revolut.com"]),
        ("n26", ["n26.com"]),
        ("edf", ["edf.fr"]),
        ("engie", ["engie.fr"])
    ]

    /// Tournures d'urgence ou de soutirage d'identifiants.
    static let pressurePhrases: [String] = [
        "votre compte sera suspendu", "compte suspendu", "compte bloque",
        "verifiez votre compte", "verifier votre compte", "confirmez votre identite",
        "mot de passe expire", "mettre a jour vos informations",
        "cliquez immediatement", "action requise", "derniere relance",
        "sous 24 heures", "sous 48 heures", "delai depasse",
        "remboursement", "vous avez gagne", "colis en attente",
        "frais de douane", "paiement refuse", "facture impayee",
        "regularisez", "suspension definitive",
        "verify your account", "confirm your password", "unusual activity",
        "your account has been", "click here immediately", "payment failed",
        "update your billing", "suspended", "act now"
    ]

    static let shorteners: Set<String> = [
        "bit.ly", "tinyurl.com", "cutt.ly", "is.gd", "t.co", "goo.gl",
        "ow.ly", "rb.gy", "shorturl.at", "rebrand.ly", "s.id", "lnkd.in"
    ]

    // ── Utilitaires d'adresse ──

    /// « Nom <a@b.com> » → « a@b.com »
    static func address(in s: String) -> String {
        if let o = s.range(of: "<"), let c = s.range(of: ">", range: o.upperBound..<s.endIndex) {
            return String(s[o.upperBound..<c.lowerBound])
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        // Pas de chevrons : on prend le premier jeton qui ressemble à une adresse.
        for token in s.split(whereSeparator: { " \t\"<>,;".contains($0) }) {
            if token.contains("@") { return String(token).lowercased() }
        }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// « Nom <a@b.com> » → « Nom »
    static func displayName(in s: String) -> String {
        guard let o = s.range(of: "<") else { return "" }
        return String(s[s.startIndex..<o.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'\t"))
    }

    static func domain(of address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return String(address[address.index(after: at)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " >\t")).lowercased()
    }

    /// Un domaine appartient-il vraiment à `base` ? « notpaypal.com » ne
    /// doit pas passer pour « paypal.com » : on exige la frontière du point.
    static func domain(_ d: String, isOrSub base: String) -> Bool {
        d == base || d.hasSuffix("." + base)
    }

    /// Minuscules sans accents, pour comparer du texte français.
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// Un mot mélangeant alphabet latin et cyrillique ou grec est un leurre.
    static func hasMixedScript(_ s: String) -> Bool {
        for word in s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            var latin = false, other = false
            for u in word.unicodeScalars {
                if (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A) {
                    latin = true
                } else if (u.value >= 0x0400 && u.value <= 0x04FF)      // cyrillique
                            || (u.value >= 0x0370 && u.value <= 0x03FF) { // grec
                    other = true
                }
            }
            if latin && other { return true }
        }
        return false
    }

    /// Caractères de réécriture bidirectionnelle, utilisés pour déguiser
    /// « facture\u{202E}cod.exe » en « facture exe.doc ».
    static func hasBidiTrick(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
        }
    }

    static func urls(in body: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>)\\]]+",
                                                options: [.caseInsensitive]) else { return [] }
        let r = NSRange(body.startIndex..., in: body)
        return re.matches(in: body, range: r).compactMap {
            Range($0.range, in: body).map { String(body[$0]) }
        }
    }

    static func host(ofURL u: String) -> String {
        var s = u
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[s.startIndex..<slash])
        }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[s.startIndex..<colon]) }
        return s.lowercased()
    }

    // ── L'analyse ──

    static func analyze(_ m: MailMessage) -> MailThreat {
        var t = MailThreat()

        let fromAddr = address(in: m.sender)
        let fromDom = domain(of: fromAddr)
        let name = displayName(in: m.sender)
        let foldedName = fold(name)
        let foldedSubject = fold(m.subject)
        let foldedBody = fold(m.snippet)
        let haystack = foldedSubject + " " + foldedBody

        // 1. Verdicts d'authentification écrits par le serveur receveur.
        let auth = m.authResults.lowercased()
        if auth.contains("dmarc=fail") {
            t.add(45, "DMARC en échec : l'expéditeur n'est pas autorisé par ce domaine")
        }
        if auth.contains("dkim=fail") {
            t.add(25, "signature DKIM invalide")
        }
        if auth.contains("spf=fail") || m.spf.lowercased().hasPrefix("fail") {
            t.add(30, "SPF en échec : serveur d'envoi non déclaré")
        } else if auth.contains("spf=softfail") || m.spf.lowercased().hasPrefix("softfail") {
            t.add(12, "SPF incertain")
        }

        // 2. Nom affiché qui contient une autre adresse que la vraie.
        if name.contains("@") {
            let shown = address(in: name)
            if !shown.isEmpty && shown != fromAddr && shown.contains("@") {
                t.add(32, "le nom affiché annonce \(shown) mais le message vient de \(fromAddr)")
            }
        }

        // 3. Marque usurpée : le nom cite une marque, le domaine ne suit pas.
        if !fromDom.isEmpty {
            for b in brands where foldedName.contains(b.name) {
                let legit = b.domains.contains { domain(fromDom, isOrSub: $0) || fromDom.hasPrefix($0) }
                if !legit {
                    t.add(30, "se présente comme « \(name) » depuis \(fromDom)")
                    break
                }
            }
        }

        // 4. Réponse détournée vers un autre domaine.
        if !m.replyTo.isEmpty {
            let rd = domain(of: address(in: m.replyTo))
            if !rd.isEmpty && !fromDom.isEmpty && rd != fromDom
                && !domain(rd, isOrSub: fromDom) && !domain(fromDom, isOrSub: rd) {
                t.add(22, "la réponse partirait vers \(rd), pas vers \(fromDom)")
            }
        }
        if !m.returnPath.isEmpty {
            let rp = domain(of: address(in: m.returnPath))
            if !rp.isEmpty && !fromDom.isEmpty && rp != fromDom
                && !domain(rp, isOrSub: fromDom) && !domain(fromDom, isOrSub: rp) {
                t.add(10, "chemin de retour vers \(rp)")
            }
        }

        // 5. Domaine d'expéditeur en punycode ou en écritures mélangées.
        if fromDom.contains("xn--") {
            t.add(35, "domaine en punycode, souvent un sosie typographique")
        }
        if hasMixedScript(name) || hasMixedScript(m.subject) {
            t.add(30, "caractères d'alphabets mélangés : imitation probable")
        }
        if hasBidiTrick(m.subject) {
            t.add(45, "l'objet contient des caractères d'inversion d'écriture")
        }

        // 6. Les liens.
        var sawIP = false, sawShort = false, sawPuny = false
        for u in urls(in: m.snippet) {
            let h = host(ofURL: u)
            if h.range(of: "^\\d{1,3}(\\.\\d{1,3}){3}$", options: .regularExpression) != nil {
                sawIP = true
            }
            if shorteners.contains(h) { sawShort = true }
            if h.contains("xn--") { sawPuny = true }
        }
        if sawIP { t.add(28, "lien pointant vers une adresse IP brute") }
        if sawShort { t.add(12, "lien raccourci masquant la destination") }
        if sawPuny { t.add(30, "lien vers un domaine en punycode") }

        // Texte du lien ≠ destination réelle.
        if let re = try? NSRegularExpression(
            pattern: "<a[^>]+href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let body = m.snippet
            let r = NSRange(body.startIndex..., in: body)
            for match in re.matches(in: body, range: r).prefix(40) {
                guard let hr = Range(match.range(at: 1), in: body),
                      let tr = Range(match.range(at: 2), in: body) else { continue }
                let realHost = host(ofURL: String(body[hr]))
                let shown = String(body[tr])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard shown.contains("."), !shown.contains(" "), shown.count > 4 else { continue }
                let shownHost = host(ofURL: shown)
                if !shownHost.isEmpty && !realHost.isEmpty && shownHost != realHost
                    && !domain(realHost, isOrSub: shownHost) && !domain(shownHost, isOrSub: realHost) {
                    t.add(38, "un lien affiche \(shownHost) mais mène à \(realHost)")
                    break
                }
            }
        }

        // 7. Pièces jointes.
        for file in m.attachments {
            let lower = file.lowercased()
            let ext = (lower as NSString).pathExtension
            let stem = (lower as NSString).deletingPathExtension
            let innerExt = (stem as NSString).pathExtension

            if hasBidiTrick(file) {
                t.add(60, "nom de pièce jointe truqué par inversion d'écriture : \(file)")
            }
            if lethalExtensions.contains(ext) {
                t.add(65, "pièce jointe exécutable : \(file)")
            } else if macroExtensions.contains(ext) {
                t.add(45, "document à macros : \(file)")
            } else if archiveExtensions.contains(ext) {
                t.add(15, "archive dont BUD ne peut pas voir le contenu : \(file)")
            }
            if !innerExt.isEmpty && lethalExtensions.contains(ext) == false
                && ["pdf", "doc", "docx", "jpg", "jpeg", "png", "xls", "xlsx", "txt"].contains(innerExt)
                && !["pdf", "doc", "docx", "jpg", "jpeg", "png", "xls", "xlsx", "txt"].contains(ext) {
                t.add(50, "double extension : \(file)")
            }
        }

        // 8. Pression et soutirage.
        var pressure = 0
        for p in pressurePhrases where haystack.contains(p) { pressure += 1 }
        if pressure > 0 {
            t.add(min(30, 10 * pressure), "formulation d'urgence (\(pressure) marqueur\(pressure > 1 ? "s" : ""))")
        }
        let asksSecret = haystack.contains("mot de passe") || haystack.contains("code secret")
            || haystack.contains("identifiant") || haystack.contains("carte bancaire")
            || haystack.contains("numero de carte") || haystack.contains("password")
            || haystack.contains("iban")
        if asksSecret && !urls(in: m.snippet).isEmpty {
            t.add(25, "demande des informations confidentielles avec un lien")
        }

        return t
    }

    // ── Volet local : les fichiers déjà téléchargés ──

    /// Passe les téléchargements en revue. BUD ne lit pas le contenu des
    /// fichiers : il repère les formes dangereuses et interroge Gatekeeper,
    /// qui, lui, connaît les signatures connues d'Apple.
    static func scanDownloads(limit: Int = 400) -> [SuspectFile] {
        let fm = FileManager.default
        guard let dl = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return [] }
        guard let items = try? fm.contentsOfDirectory(at: dl,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [SuspectFile] = []
        for url in items.prefix(limit) {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let stem = (name.lowercased() as NSString).deletingPathExtension
            let innerExt = (stem as NSString).pathExtension

            // Provenance : l'attribut de quarantaine signe un fichier venu du web.
            let quarantined = !shell("/usr/bin/xattr",
                                     ["-p", "com.apple.quarantine", url.path]).isEmpty

            var reason: String?
            if hasBidiTrick(name) {
                reason = "nom truqué par inversion d'écriture"
            } else if lethalExtensions.contains(ext) && quarantined && ext != "app" && ext != "pkg" {
                reason = "exécutable téléchargé depuis le web"
            } else if !innerExt.isEmpty
                        && ["pdf", "doc", "docx", "jpg", "jpeg", "png", "txt"].contains(innerExt)
                        && lethalExtensions.contains(ext) {
                reason = "double extension : se fait passer pour un \(innerExt.uppercased())"
            } else if macroExtensions.contains(ext) && quarantined {
                reason = "document à macros téléchargé"
            } else if (ext == "app" || ext == "pkg" || ext == "dmg") && quarantined {
                // Gatekeeper tranche mieux que n'importe quelle heuristique.
                let verdict = shell("/usr/sbin/spctl",
                                    ["--assess", "--type", ext == "app" ? "execute" : "install",
                                     url.path])
                if verdict.lowercased().contains("rejected") {
                    reason = "rejeté par Gatekeeper : ni signé ni notarié"
                }
            }

            if let r = reason {
                out.append(SuspectFile(url: url, reason: r, fromWeb: quarantined))
            }
        }
        return out
    }

    /// Exécute un outil système et renvoie sa sortie, erreurs comprises.
    static func shell(_ launch: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: launch) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// Met des fichiers à la corbeille plutôt que de les détruire :
    /// une fausse alerte doit rester réparable.
    @discardableResult
    static func trash(_ files: [URL]) -> Int {
        var n = 0
        for f in files {
            if (try? FileManager.default.trashItem(at: f, resultingItemURL: nil)) != nil { n += 1 }
        }
        return n
    }
}
EOF_BUDGUARD_SWIFT

cat << 'EOF_BUDMAIL_SWIFT' > "$SRC_DIR/BudMail.swift"
import Cocoa

// ═══════════════════════════════════════════════════════════
//  Courrier
//  BUD s'appuie sur Mail.app, déjà configuré avec votre compte
//  Gmail : aucun mot de passe ne transite par BUD, aucune clé
//  d'API, aucune connexion sortante de notre fait.
// ═══════════════════════════════════════════════════════════

struct MailMessage {
    let subject: String
    let sender: String
    let date: String

    // Enrichissements IMAP. Valeurs par défaut : la passerelle Mail.app
    // ne les fournit pas, et l'initialiseur à trois champs reste valable.
    var uid: String = ""
    var messageID: String = ""
    var replyTo: String = ""
    var returnPath: String = ""
    var authResults: String = ""
    var spf: String = ""
    var snippet: String = ""
    var attachments: [String] = []
    var unread: Bool = true
    var threat = MailThreat()

    /// Adresse seule, sans le nom affiché.
    var address: String { MailGuard.address(in: sender) }

    /// Ce qu'on montre dans la liste : le nom s'il existe, sinon l'adresse.
    var shortSender: String {
        let n = MailGuard.displayName(in: sender)
        return n.isEmpty ? address : n
    }
}

enum MailBridge {

    @discardableResult
    static func osa(_ script: String) -> String {
        runShell("/usr/bin/osascript", ["-e", script])
    }

    static func mailAppInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/System/Applications/Mail.app")
            || FileManager.default.fileExists(atPath: "/Applications/Mail.app")
    }

    static func mailRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.mail"
        }
    }

    /// Nombre de messages non lus, toutes boîtes de réception confondues.
    /// Renvoie -1 si Mail n'est pas joignable (fermé, ou autorisation refusée).
    static func unreadCount() -> Int {
        guard mailRunning() else { return -1 }
        let out = osa("""
        tell application "Mail"
            try
                set n to 0
                repeat with acc in every account
                    try
                        set n to n + (count of (messages of mailbox "INBOX" of acc whose read status is false))
                    end try
                end repeat
                if n = 0 then set n to (count of (messages of inbox whose read status is false))
                return n
            on error
                return -1
            end try
        end tell
        """)
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// Les derniers messages non lus de la boîte de réception.
    static func latestUnread(_ limit: Int = 5) -> [MailMessage] {
        guard mailRunning() else { return [] }
        let out = osa("""
        tell application "Mail"
            try
                set res to ""
                set msgs to (messages of inbox whose read status is false)
                set n to count of msgs
                if n > \(limit) then set n to \(limit)
                repeat with i from 1 to n
                    set m to item i of msgs
                    set res to res & (subject of m) & "|~|" & (sender of m) & "|~|" & ((date received of m) as string) & "|#|"
                end repeat
                return res
            on error
                return ""
            end try
        end tell
        """)
        return out.components(separatedBy: "|#|").compactMap { block in
            let p = block.components(separatedBy: "|~|")
            guard p.count >= 3 else { return nil }
            return MailMessage(subject: p[0].trimmingCharacters(in: .whitespacesAndNewlines),
                               sender: p[1].trimmingCharacters(in: .whitespacesAndNewlines),
                               date: p[2].trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Envoie par Mail.app. `from` vide : le compte par défaut est utilisé.
    static func send(to: String, subject: String, body: String, from: String) -> String {
        guard mailAppInstalled() else { return "Mail.app est introuvable sur ce Mac." }
        var props = "{subject:\"\(esc(subject))\", content:\"\(esc(body))\", visible:false"
        if !from.isEmpty { props += ", sender:\"\(esc(from))\"" }
        props += "}"
        let out = osa("""
        tell application "Mail"
            try
                set m to make new outgoing message with properties \(props)
                tell m
                    make new to recipient at end of to recipients with properties {address:"\(esc(to))"}
                    send
                end tell
                return "ok"
            on error errMsg
                return errMsg
            end try
        end tell
        """)
        if out.hasPrefix("ok") { return "Message envoyé à \(to)." }
        if out.isEmpty { return "Mail n'a pas répondu. Autorisez BUD dans Confidentialité → Automatisation." }
        return "Envoi refusé : \(out)"
    }

    /// Ouvre une fenêtre de rédaction pré-remplie, sans rien envoyer.
    static func compose(to: String, subject: String, body: String) {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = to
        c.queryItems = [URLQueryItem(name: "subject", value: subject),
                        URLQueryItem(name: "body", value: body)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    static func openInbox() {
        if mailAppInstalled() { runShell("/usr/bin/open", ["-a", "Mail"]) }
        else if let u = URL(string: "https://mail.google.com/") { NSWorkspace.shared.open(u) }
    }

    static func openGmailWeb() {
        if let u = URL(string: "https://mail.google.com/mail/u/0/#inbox") { NSWorkspace.shared.open(u) }
    }
}

/// Choisit la bonne voie : Gmail en direct quand un compte est enregistré,
/// Mail.app sinon.
enum MailRouter {
    /// Adresse du compte « mot de passe d'application », vide si aucun.
    static var account: String = ""
    static var appPassword: String? { account.isEmpty ? nil : BudKeychain.get(account) }

    static var oauthReady: Bool { GmailAuth.shared.isConnected }
    static var gmailReady: Bool { oauthReady || appPassword != nil }

    static var activeAddress: String {
        oauthReady ? GmailAuth.shared.email : account
    }
    static var sourceLabel: String {
        if oauthReady { return "Google" }
        if appPassword != nil { return "Gmail" }
        return "Mail.app"
    }

    private static func mode() -> (String, GmailAuthMode)? {
        if oauthReady, let x = GmailAuth.shared.xoauth2() {
            return (GmailAuth.shared.email, .oauth(x))
        }
        if let p = appPassword { return (account, .appPassword(p)) }
        return nil
    }

    static func snapshot(_ limit: Int = 5) -> (unread: Int, msgs: [MailMessage], source: String, error: String?) {
        if let (user, auth) = mode() {
            let s = GmailClient.fetchInbox(user: user, auth: auth, limit: limit)
            return (s.unread, s.messages, sourceLabel, s.error)
        }
        guard MailBridge.mailRunning() else { return (-1, [], "Mail.app", "Mail est fermé.") }
        return (MailBridge.unreadCount(), MailBridge.latestUnread(limit), "Mail.app", nil)
    }

    static func send(to: String, subject: String, body: String, mailFrom: String,
                     inReplyTo: String = "") -> String {
        if let (user, auth) = mode() {
            return GmailClient.send(user: user, auth: auth, to: to,
                                    subject: subject, body: body, inReplyTo: inReplyTo)
        }
        return MailBridge.send(to: to, subject: subject, body: body, from: mailFrom)
    }

    /// Déplace des messages vers le dossier indésirable. Possible
    /// uniquement en IMAP : la passerelle Mail.app ne l'expose pas.
    static func quarantine(_ uids: [String]) -> String? {
        guard let (user, auth) = mode() else {
            return "Reliez un compte Gmail pour isoler des messages."
        }
        return GmailClient.quarantine(user: user, auth: auth, uids: uids)
    }
}

/// Une ligne de la boîte de réception : expéditeur, objet, date et
/// verdict d'analyse. Dessinée à la main pour tenir en 46 pt sans
/// rien tronquer et pour réagir au survol.
final class MailRow: NSView {
    let message: MailMessage
    var selected = false { didSet { needsDisplay = true } }
    var onSelect: ((MailMessage) -> Void)?
    private var hover = false
    private var track: NSTrackingArea?

    init(frame: NSRect, message: MailMessage) {
        self.message = message
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = track { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        track = t
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { onSelect?(message) }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let card = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
        TH.fill(selected ? 0.16 : (hover ? 0.10 : 0.055)).setFill()
        card.fill()
        if selected {
            TH.accent.withAlphaComponent(0.55).setStroke()
            card.lineWidth = 1.5
            card.stroke()
        }

        let lvl = message.threat.level
        // Liseré de verdict à gauche : vert, ambre ou rouge.
        let bar = NSBezierPath(roundedRect: NSRect(x: 8, y: 9, width: 4, height: r.height - 18),
                               xRadius: 2, yRadius: 2)
        lvl.color.withAlphaComponent(lvl == .clean ? 0.45 : 0.95).setFill()
        bar.fill()

        // Pastille de non-lu.
        var x: CGFloat = 20
        if message.unread {
            TH.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: r.height / 2 - 3, width: 6, height: 6)).fill()
            x += 12
        }

        // Date à droite, et badge de menace s'il y a lieu.
        var rightEdge = r.width - 12
        if lvl != .clean {
            let txt = lvl.label
            let w = textWidth(txt, size: 9.5, weight: .bold) + 18
            let box = NSRect(x: rightEdge - w, y: r.height / 2 - 9, width: w, height: 18)
            lvl.color.withAlphaComponent(0.20).setFill()
            capsule(box).fill()
            lvl.color.withAlphaComponent(0.75).setStroke()
            let c = capsule(box); c.lineWidth = 1; c.stroke()
            drawString(txt, in: NSRect(x: box.minX, y: box.midY - 6.5, width: box.width, height: 13),
                       size: 9.5, weight: .bold, color: lvl.color, align: .center)
            rightEdge -= w + 8
        }
        let shortDate = String(message.date.prefix(17))
        if !shortDate.isEmpty {
            let dw = min(textWidth(shortDate, size: 9.5, weight: .regular), 110)
            drawString(shortDate,
                       in: NSRect(x: rightEdge - dw, y: r.height - 21, width: dw, height: 13),
                       size: 9.5, weight: .regular, color: TH.dim(0.38), align: .right)
            rightEdge -= dw + 10
        }

        let textW = max(60, rightEdge - x)
        drawString(message.shortSender.isEmpty ? "(inconnu)" : message.shortSender,
                   in: NSRect(x: x, y: r.height - 23, width: textW, height: 16),
                   size: 12, weight: message.unread ? .bold : .semibold, color: TH.text)
        drawString(message.subject.isEmpty ? "(sans objet)" : message.subject,
                   in: NSRect(x: x, y: 7, width: textW, height: 15),
                   size: 11, weight: .regular, color: TH.dim(0.55))

        if !message.attachments.isEmpty {
            drawSymbol("paperclip", center: NSPoint(x: r.width - 10, y: 14),
                       size: 10, weight: .semibold, color: TH.dim(0.45))
        }
    }
}

final class MailPanelView: NSView {
    private let hero: HeroHeader
    private var unreadTile: StatTile!
    private var riskTile: StatTile!
    private var stateTile: StatTile!
    private var threatCard: NSView!
    private var threatTitle: NSTextField!
    private var threatBody: NSTextField!
    private var isolateBtn: GlassButton!
    private var replyBtn: GlassButton!
    private var selected: MailMessage?
    private var lastMessages: [MailMessage] = []
    private var replyRef: String = ""
    private var listHost = NSView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var rows: [NSView] = []
    private var toField: NSTextField!
    private var subjectField: NSTextField!
    private var bodyView: NSTextView!
    private var statusLabel: NSTextField!
    private var accountLabel: NSTextField!

    var onStatus: ((String) -> Void)?
    var fromAddress: () -> String = { "" }
    var onAccountChange: ((String) -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Courrier", subtitle: "Vos messages non lus et un envoi rapide.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height

        // Trois compteurs : à lire, à surveiller, et la voie utilisée.
        unreadTile = StatTile(frame: NSRect(x: W - 384, y: H - 86, width: 118, height: 78),
                              caption: "Non lus", hint: "réception")
        riskTile = StatTile(frame: NSRect(x: W - 256, y: H - 86, width: 118, height: 78),
                            caption: "Suspects", hint: "analyse locale")
        stateTile = StatTile(frame: NSRect(x: W - 128, y: H - 86, width: 118, height: 78),
                             caption: "Voie", hint: "—")
        [unreadTile, riskTile, stateTile].forEach { addSubview($0) }

        mkSection(self, 456, W, "Boîte de réception — cliquez un message")
        scroll.frame = NSRect(x: 0, y: 278, width: W, height: 174)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        // Carte de verdict du message sélectionné.
        threatCard = mkCard(self, NSRect(x: 0, y: 210, width: W, height: 62), radius: 13, alpha: 0.07)
        threatTitle = mkLabel("Sélectionnez un message pour voir son analyse.",
                              NSRect(x: 14, y: 36, width: W - 130, height: 16), 11.5, .semibold, alpha: 0.72)
        threatCard.addSubview(threatTitle)
        threatBody = NSTextField(frame: NSRect(x: 14, y: 8, width: W - 130, height: 28))
        threatBody.isBezeled = false
        threatBody.drawsBackground = false
        threatBody.isEditable = false
        threatBody.isSelectable = true
        threatBody.font = NSFont.systemFont(ofSize: 10.5)
        threatBody.textColor = TH.dim(0.50)
        threatBody.lineBreakMode = .byWordWrapping
        threatBody.cell?.usesSingleLineMode = false
        threatBody.cell?.wraps = true
        threatBody.maximumNumberOfLines = 2
        ThemeRegistry.shared.register(threatBody, alpha: 0.50)
        threatCard.addSubview(threatBody)

        isolateBtn = GlassButton(frame: NSRect(x: W - 110, y: 14, width: 96, height: 34),
                                 title: "Isoler", icon: "tray.and.arrow.down.fill")
        isolateBtn.destructive = true
        isolateBtn.enabledFlag = false
        isolateBtn.onClick = { [weak self] _ in self?.quarantineSelected() }
        threatCard.addSubview(isolateBtn)

        mkSection(self, 190, W, "Rédiger")
        toField = NSTextField(frame: NSRect(x: 0, y: 156, width: W * 0.48, height: 30))
        toField.placeholderString = "Destinataire"
        toField.font = NSFont.systemFont(ofSize: 12.5)
        subjectField = NSTextField(frame: NSRect(x: W * 0.48 + 10, y: 156, width: W * 0.52 - 10, height: 30))
        subjectField.placeholderString = "Objet"
        subjectField.font = NSFont.systemFont(ofSize: 12.5)
        [toField, subjectField].forEach { addSubview($0) }

        accountLabel = mkLabel("", NSRect(x: 2, y: 62, width: W - 4, height: 14), 10, .regular, alpha: 0.38)
        addSubview(accountLabel)

        let bodyScroll = NSScrollView(frame: NSRect(x: 0, y: 80, width: W, height: 70))
        bodyScroll.hasVerticalScroller = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.wantsLayer = true
        bodyScroll.layer?.cornerRadius = 12
        bodyScroll.layer?.masksToBounds = true
        let big: CGFloat = 1_000_000
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: W, height: 70))
        tv.minSize = NSSize(width: 0, height: 70)
        tv.maxSize = NSSize(width: big, height: big)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: W, height: big)
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = true
        tv.backgroundColor = TH.fill(0.06)
        tv.textColor = TH.text
        tv.insertionPointColor = TH.text
        tv.font = NSFont.systemFont(ofSize: 12.5)
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 10, height: 10)
        bodyScroll.documentView = tv
        bodyView = tv
        addSubview(bodyScroll)

        statusLabel = mkLabel("", NSRect(x: 0, y: 46, width: W, height: 16), 10.5, .regular, alpha: 0.45, .center)
        addSubview(statusLabel)

        let bw = (W - 48) / 5
        let specs: [(String, String, Bool, () -> Void)] = [
            ("Envoyer", "paperplane.fill", true, { [weak self] in self?.send() }),
            ("Répondre", "arrowshape.turn.up.left.fill", false, { [weak self] in self?.reply() }),
            ("Analyser", "shield.lefthalf.filled", false, { [weak self] in self?.analyzeAll() }),
            ("Compte", "person.crop.circle", false, { [weak self] in self?.accountDialog() }),
            ("Actualiser", "arrow.clockwise", false, { [weak self] in self?.refresh() })
        ]
        var made: [GlassButton] = []
        for (i, sp) in specs.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (bw + 12), y: 0, width: bw, height: 42),
                                title: sp.0, icon: sp.1, prominent: sp.2)
            b.onClick = { _ in sp.3() }
            addSubview(b)
            made.append(b)
        }
        replyBtn = made[1]
        replyBtn.enabledFlag = false
    }

    // ── Sélection d'un message ──

    private func select(_ m: MailMessage) {
        selected = m
        replyBtn.enabledFlag = true
        isolateBtn.enabledFlag = !m.uid.isEmpty && MailRouter.gmailReady
        for r in rows { (r as? MailRow)?.selected = (r as? MailRow)?.message.uid == m.uid }

        let lvl = m.threat.level
        threatTitle.stringValue = "\(lvl.label) · \(m.shortSender) · \(m.address)"
        threatTitle.textColor = lvl == .clean ? TH.dim(0.72) : lvl.color
        var detail = m.threat.summary
        if !m.attachments.isEmpty {
            detail += "  —  pièces jointes : " + m.attachments.joined(separator: ", ")
        }
        threatBody.stringValue = detail
    }

    /// Prépare une réponse : objet préfixé, corps cité, et le Message-ID
    /// d'origine conservé pour que le fil reste groupé chez le destinataire.
    private func reply() {
        guard let m = selected else {
            statusLabel.stringValue = "Choisissez d'abord un message dans la liste."
            return
        }
        if m.threat.level == .dangerous {
            let a = NSAlert()
            a.messageText = "Répondre à un message dangereux ?"
            a.informativeText = "BUD a relevé : \(m.threat.summary)\n\n"
                + "Répondre confirme à l'expéditeur que votre adresse est active."
            a.addButton(withTitle: "Annuler")
            a.addButton(withTitle: "Répondre quand même")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertSecondButtonReturn else { return }
        }

        // Le Reply-To prime sur le From quand il est légitime ; s'il
        // pointe ailleurs, l'analyse l'a déjà signalé et on garde le From.
        var dest = m.address
        if !m.replyTo.isEmpty && m.threat.level == .clean {
            let r = MailGuard.address(in: m.replyTo)
            if r.contains("@") { dest = r }
        }
        toField.stringValue = dest
        let subj = m.subject.trimmingCharacters(in: .whitespaces)
        subjectField.stringValue = subj.lowercased().hasPrefix("re:") ? subj : "Re: \(subj)"

        let quoted = m.snippet
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(18)
            .map { "> " + $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        bodyView.string = "\n\nLe \(m.date), \(m.shortSender) a écrit :\n" + quoted
        bodyView.setSelectedRange(NSRange(location: 0, length: 0))
        replyRef = m.messageID
        window?.makeFirstResponder(bodyView)
        statusLabel.stringValue = "Réponse préparée pour \(dest)."
    }

    private func quarantineSelected() {
        guard let m = selected, !m.uid.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Isoler ce message ?"
        a.informativeText = "« \(m.subject) » de \(m.address) sera déplacé vers le dossier "
            + "des indésirables de votre compte. Rien n'est supprimé : vous pourrez l'y retrouver.\n\n"
            + m.threat.summary
        a.addButton(withTitle: "Isoler")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        statusLabel.stringValue = "Déplacement en cours…"
        let uid = m.uid
        DispatchQueue.global(qos: .userInitiated).async {
            let err = MailRouter.quarantine([uid])
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                if let e = err {
                    s.statusLabel.stringValue = e
                } else {
                    s.statusLabel.stringValue = "Message isolé dans les indésirables."
                    s.onStatus?("Message isolé")
                    s.selected = nil
                    s.refresh()
                }
            }
        }
    }

    /// Analyse complète : la boîte de réception, puis les fichiers déjà
    /// téléchargés. Le second volet interroge Gatekeeper, qui connaît les
    /// signatures qu'une heuristique ignore.
    private func analyzeAll() {
        statusLabel.stringValue = "Analyse en cours…"
        let msgs = lastMessages
        DispatchQueue.global(qos: .userInitiated).async {
            let files = MailGuard.scanDownloads()
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                let danger = msgs.filter { $0.threat.level == .dangerous }
                let suspect = msgs.filter { $0.threat.level == .suspect }

                var report = "Messages analysés : \(msgs.count)\n"
                report += "Dangereux : \(danger.count) · Suspects : \(suspect.count)\n"
                for m in (danger + suspect).prefix(6) {
                    report += "\n• \(m.threat.level.label) — \(m.shortSender)\n   \(m.threat.summary)"
                }
                if !files.isEmpty {
                    report += "\n\nTéléchargements douteux : \(files.count)"
                    for f in files.prefix(6) {
                        report += "\n• \(f.url.lastPathComponent) — \(f.reason)"
                    }
                }
                if danger.isEmpty && suspect.isEmpty && files.isEmpty {
                    report += "\nRien à signaler."
                }

                let a = NSAlert()
                a.messageText = "Analyse de sécurité"
                a.informativeText = report
                    + "\n\nBUD juge la forme des messages, pas le contenu des fichiers : "
                    + "ce n'est pas un antivirus."
                if !danger.isEmpty { a.addButton(withTitle: "Isoler les \(danger.count) dangereux") }
                if !files.isEmpty { a.addButton(withTitle: "Mettre \(files.count) fichier(s) à la corbeille") }
                a.addButton(withTitle: "Fermer")
                NSApp.activate(ignoringOtherApps: true)
                let r = a.runModal()

                var idx = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if !danger.isEmpty {
                    if r.rawValue == idx { s.isolate(danger.map { $0.uid }); return }
                    idx += 1
                }
                if !files.isEmpty, r.rawValue == idx {
                    let n = MailGuard.trash(files.map { $0.url })
                    s.statusLabel.stringValue = "\(n) fichier(s) mis à la corbeille."
                    s.onStatus?("\(n) fichier(s) douteux à la corbeille")
                }
            }
        }
    }

    private func isolate(_ uids: [String]) {
        let clean = uids.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        statusLabel.stringValue = "Isolement de \(clean.count) message(s)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let err = MailRouter.quarantine(clean)
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                s.statusLabel.stringValue = err ?? "\(clean.count) message(s) isolés."
                if err == nil { s.onStatus?("\(clean.count) message(s) isolés"); s.refresh() }
            }
        }
    }

    /// Fenêtre unique pour relier un compte : Google en un clic, ou
    /// mot de passe d'application si vous préférez.
    private func accountDialog() {
        let auth = GmailAuth.shared
        let a = NSAlert()
        a.messageText = "Compte de messagerie"
        a.informativeText = auth.isConnected
            ? "Connecté à \(auth.email) par Google OAuth."
            : (MailRouter.appPassword != nil
               ? "Connecté à \(MailRouter.account) par mot de passe d'application."
               : "Reliez votre compte Google, ou utilisez un mot de passe d'application. "
                 + "Pour tout faire depuis votre téléphone, passez par l'onglet Téléphone (⌘⌥P).")

        let v = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 176))
        func label(_ t: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.frame = NSRect(x: 0, y: y, width: 420, height: 14)
            l.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            l.textColor = .secondaryLabelColor
            v.addSubview(l)
        }
        label("IDENTIFIANT CLIENT GOOGLE (application de bureau)", 162)
        let idField = NSTextField(frame: NSRect(x: 0, y: 132, width: 420, height: 24))
        idField.placeholderString = "xxxxx.apps.googleusercontent.com"
        idField.stringValue = auth.clientID
        v.addSubview(idField)

        label("CODE SECRET CLIENT — facultatif avec PKCE", 110)
        let secretField = NSSecureTextField(frame: NSRect(x: 0, y: 80, width: 420, height: 24))
        secretField.placeholderString = "GOCSPX-… (laissez vide si non requis)"
        secretField.stringValue = auth.clientSecret
        v.addSubview(secretField)

        label("OU MOT DE PASSE D'APPLICATION", 58)
        let mailField = NSTextField(frame: NSRect(x: 0, y: 28, width: 210, height: 24))
        mailField.placeholderString = "adresse@gmail.com"
        mailField.stringValue = MailRouter.account
        let passField = NSSecureTextField(frame: NSRect(x: 218, y: 28, width: 202, height: 24))
        passField.placeholderString = "16 caractères"
        [mailField, passField].forEach { v.addSubview($0) }

        let note = NSTextField(labelWithString: "Les identifiants sont rangés dans le trousseau macOS, jamais sur disque.")
        note.frame = NSRect(x: 0, y: 4, width: 420, height: 16)
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)
        a.accessoryView = v

        a.addButton(withTitle: "Connexion Google")
        a.addButton(withTitle: "Mot de passe d'app")
        a.addButton(withTitle: auth.isConnected || MailRouter.appPassword != nil ? "Déconnecter" : "Fermer")
        a.addButton(withTitle: "Annuler")

        NSApp.activate(ignoringOtherApps: true)
        let choice = a.runModal()

        switch choice {
        case .alertFirstButtonReturn:
            let id = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.contains("apps.googleusercontent.com") else {
                statusLabel.stringValue = "Collez l'identifiant client Google (…apps.googleusercontent.com)."
                return
            }
            auth.clientID = id
            auth.clientSecret = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            startGoogleFlow()
        case .alertSecondButtonReturn:
            connectAppPassword(mail: mailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                               pass: passField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case .alertThirdButtonReturn:
            if auth.isConnected || MailRouter.appPassword != nil { disconnectAll() }
        default:
            break
        }
    }

    private func startGoogleFlow() {
        statusLabel.stringValue = "Votre navigateur s'ouvre pour le consentement Google…"
        onStatus?("Autorisation Google en cours")
        GoogleOAuth.authorize(clientID: GmailAuth.shared.clientID,
                              clientSecret: GmailAuth.shared.clientSecret) { [weak self] tokens, err in
            guard let s = self else { return }
            guard let t = tokens, !t.email.isEmpty else {
                s.statusLabel.stringValue = "Connexion Google échouée : \(err ?? "inconnu")"
                s.onStatus?("Google refusé")
                return
            }
            GmailAuth.shared.store(t)
            s.onAccountChange?(t.email)
            s.statusLabel.stringValue = "Connecté à \(t.email) — lecture et envoi directs."
            s.onStatus?("Gmail connecté")
            s.refresh()
        }
    }

    private func connectAppPassword(mail: String, pass: String) {
        guard mail.contains("@") else {
            statusLabel.stringValue = "Indiquez votre adresse Gmail complète."
            return
        }
        guard pass.count >= 12 else {
            statusLabel.stringValue = "Le mot de passe d'application fait 16 caractères."
            return
        }
        statusLabel.stringValue = "Vérification auprès de Gmail…"
        DispatchQueue.global(qos: .userInitiated).async {
            let err = GmailClient.testLogin(user: mail, password: pass)
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                if let e = err {
                    s.statusLabel.stringValue = e
                    s.onStatus?(e)
                    return
                }
                BudKeychain.set(GmailClient.normalizedPassword(pass), account: mail)
                MailRouter.account = mail
                s.onAccountChange?(mail)
                s.statusLabel.stringValue = "Compte connecté, mot de passe dans le trousseau."
                s.onStatus?("Gmail connecté")
                s.refresh()
            }
        }
    }

    private func disconnectAll() {
        GmailAuth.shared.disconnect()
        if !MailRouter.account.isEmpty {
            BudKeychain.delete(MailRouter.account)
            MailRouter.account = ""
        }
        onAccountChange?("")
        statusLabel.stringValue = "Compte déconnecté. BUD repasse par Mail.app."
        refresh()
    }

    func refresh() {
        let installed = MailBridge.mailAppInstalled()
        let running = MailBridge.mailRunning()
        let gmail = MailRouter.gmailReady

        accountLabel.stringValue = MailRouter.oauthReady
            ? "Google OAuth · \(GmailAuth.shared.email) · jetons dans le trousseau"
            : (gmail ? "Mot de passe d'application · \(MailRouter.account)"
                     : "Aucun compte relié — bouton Compte pour connecter Google.")

        stateTile.set(MailRouter.sourceLabel == "Mail.app"
                        ? (running ? "Mail.app" : (installed ? "Fermé" : "Absent"))
                        : MailRouter.sourceLabel,
                      hint: MailRouter.oauthReady ? "OAuth 2.0"
                          : (gmail ? "IMAP/SMTP" : (running ? "via Mail" : "ouvrez Mail")))

        guard gmail || running else {
            unreadTile.set("—", hint: "aucune source")
            riskTile.set("—", hint: "analyse locale")
            hero.set(subtitle: "Connectez votre compte Gmail, ou ouvrez Mail.", trailing: "")
            rebuildList([])
            return
        }

        unreadTile.set("…", hint: "lecture en cours")
        riskTile.set("…", hint: "analyse")
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = MailRouter.snapshot(8)
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                let n = snap.unread
                s.unreadTile.set(n < 0 ? "—" : "\(n)",
                                 hint: n < 0 ? (snap.error ?? "indisponible")
                                             : (n == 0 ? "boîte à jour" : "à lire"))
                s.hero.set(subtitle: n <= 0 ? "Rien à lire pour l'instant · \(snap.source)"
                                            : "\(n) message(s) non lus · \(snap.source)",
                           trailing: n > 0 ? "\(n) non lus" : "")
                let danger = snap.msgs.filter { $0.threat.level == .dangerous }.count
                let suspect = snap.msgs.filter { $0.threat.level == .suspect }.count
                s.riskTile.set(danger > 0 ? "\(danger)" : "\(suspect)",
                               hint: danger > 0 ? "dangereux" : (suspect > 0 ? "suspects" : "rien à signaler"))
                s.rebuildList(snap.msgs)
                if let e = snap.error { s.statusLabel.stringValue = e }
            }
        }
    }

    private func rebuildList(_ msgs: [MailMessage]) {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        ThemeRegistry.shared.prune()
        lastMessages = msgs

        let W = scroll.bounds.width - 6
        let rowH: CGFloat = 52
        let totalH = max(scroll.bounds.height, CGFloat(msgs.count) * rowH)
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: totalH)

        if msgs.isEmpty {
            let l = mkLabel(MailRouter.gmailReady || MailBridge.mailRunning()
                            ? "Boîte vide." : "Aucune source de courrier.",
                            NSRect(x: 0, y: totalH / 2 - 10, width: W, height: 20),
                            12, .medium, alpha: 0.35, .center)
            listHost.addSubview(l)
            rows.append(l)
            return
        }
        for (i, m) in msgs.enumerated() {
            let y = totalH - CGFloat(i + 1) * rowH + 6
            let row = MailRow(frame: NSRect(x: 0, y: y, width: W, height: rowH - 6), message: m)
            row.onSelect = { [weak self] msg in self?.select(msg) }
            listHost.addSubview(row)
            rows.append(row)
        }
        // On garde la sélection après un rafraîchissement.
        if let sel = selected, let again = msgs.first(where: { $0.uid == sel.uid && !sel.uid.isEmpty }) {
            select(again)
        } else {
            selected = nil
            replyBtn?.enabledFlag = false
            isolateBtn?.enabledFlag = false
            threatTitle?.stringValue = "Sélectionnez un message pour voir son analyse."
            threatTitle?.textColor = TH.dim(0.72)
            threatBody?.stringValue = ""
        }
    }

    private func send() {
        let to = toField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard to.contains("@") else {
            statusLabel.stringValue = "Indiquez une adresse de destinataire valide."
            return
        }
        let subject = subjectField.stringValue
        let body = bodyView.string
        let a = NSAlert()
        a.messageText = "Envoyer ce message ?"
        a.informativeText = "À : \(to)\nObjet : \(subject.isEmpty ? "(aucun)" : subject)"
            + "\nVoie : " + (MailRouter.gmailReady
                               ? "\(MailRouter.sourceLabel) (\(MailRouter.activeAddress))"
                               : "Mail.app")
        a.addButton(withTitle: "Envoyer")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        statusLabel.stringValue = "Envoi en cours…"
        let from = fromAddress()
        let ref = replyRef
        DispatchQueue.global(qos: .userInitiated).async {
            let res = MailRouter.send(to: to, subject: subject, body: body,
                                      mailFrom: from, inReplyTo: ref)
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.stringValue = res
                self?.onStatus?(res)
                if res.hasPrefix("Message envoyé") {
                    self?.toField.stringValue = ""
                    self?.subjectField.stringValue = ""
                    self?.bodyView.string = ""
                    self?.replyRef = ""
                }
            }
        }
    }

    private func composeExternally() {
        MailBridge.compose(to: toField.stringValue, subject: subjectField.stringValue, body: bodyView.string)
        statusLabel.stringValue = "Brouillon ouvert dans votre client de messagerie."
    }

    /// Pré-remplit la fenêtre depuis le chat.
    func prefill(to: String, subject: String, body: String) {
        toField.stringValue = to
        subjectField.stringValue = subject
        bodyView.string = body
    }
}
EOF_BUDMAIL_SWIFT

cat << 'EOF_BUDMUSIC_SWIFT' > "$SRC_DIR/BudMusic.swift"
import Cocoa

// ═══════════════════════════════════════════════════════════
//  Lecteur de musique
//  Apple Music et Spotify se pilotent en AppleScript.
//  Alexa n'expose aucune interface locale sur macOS : BUD ouvre
//  son lecteur web et le commande avec les touches média du
//  système, qui s'appliquent à l'onglet en cours de lecture.
// ═══════════════════════════════════════════════════════════

enum MusicSource: Int {
    case appleMusic = 0, spotify = 1, alexa = 2

    var label: String {
        switch self {
        case .appleMusic: return "Musique"
        case .spotify: return "Spotify"
        case .alexa: return "Alexa"
        }
    }
    var icon: String {
        switch self {
        case .appleMusic: return "music.note"
        case .spotify: return "waveform"
        case .alexa: return "homepod.fill"
        }
    }
    var appName: String? {
        switch self {
        case .appleMusic: return "Music"
        case .spotify: return "Spotify"
        case .alexa: return nil
        }
    }
}

struct NowPlaying {
    var title = "—"
    var artist = ""
    var playing = false
    var available = false
}

enum MusicBridge {

    // Codes des touches média du clavier Apple
    private static let keyPlay: Int32 = 16
    private static let keyNext: Int32 = 19
    private static let keyPrev: Int32 = 20

    /// Émet une touche média système : elle atteint l'application qui joue,
    /// y compris un lecteur web (Alexa, YouTube Music…).
    static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flagValue: UInt = down ? 0xA00 : 0xB00
            let data1 = Int((key << 16) | Int32(down ? 0xA00 : 0xB00))
            guard let e = NSEvent.otherEvent(with: .systemDefined,
                                             location: .zero,
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: flagValue),
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             subtype: 8, data1: data1, data2: -1) else { continue }
            e.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func appRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }

    @discardableResult
    private static func osa(_ s: String) -> String {
        runShell("/usr/bin/osascript", ["-e", s])
    }

    static func nowPlaying(_ src: MusicSource) -> NowPlaying {
        guard let app = src.appName, appRunning(app) else {
            var n = NowPlaying()
            n.available = (src == .alexa)
            if src == .alexa { n.title = "Lecteur web Alexa" ; n.artist = "piloté par les touches média" }
            else { n.title = "\(src.label) est fermé" }
            return n
        }
        let out = osa("""
        tell application "\(app)"
            try
                set st to (player state as string)
                if st is "stopped" then return "stopped|~||~|"
                return st & "|~|" & (name of current track) & "|~|" & (artist of current track)
            on error
                return "error|~||~|"
            end try
        end tell
        """)
        let p = out.components(separatedBy: "|~|")
        var n = NowPlaying()
        n.available = true
        if p.count >= 3 && p[0] != "error" && p[0] != "stopped" {
            n.playing = p[0].contains("playing")
            n.title = p[1].isEmpty ? "—" : p[1]
            n.artist = p[2]
        } else {
            n.title = "Rien en lecture"
        }
        return n
    }

    static func playPause(_ src: MusicSource) {
        guard let app = src.appName, appRunning(app) else { mediaKey(keyPlay); return }
        osa("tell application \"\(app)\" to playpause")
    }
    static func next(_ src: MusicSource) {
        guard let app = src.appName, appRunning(app) else { mediaKey(keyNext); return }
        osa("tell application \"\(app)\" to next track")
    }
    static func previous(_ src: MusicSource) {
        guard let app = src.appName, appRunning(app) else { mediaKey(keyPrev); return }
        osa("tell application \"\(app)\" to previous track")
    }
    static func setVolume(_ src: MusicSource, delta: Int) {
        guard let app = src.appName, appRunning(app) else {
            // Volume système pour le lecteur web
            let cur = Int(osa("output volume of (get volume settings)")) ?? 50
            osa("set volume output volume \(max(0, min(100, cur + delta)))")
            return
        }
        let cur = Int(osa("tell application \"\(app)\" to get sound volume")) ?? 50
        osa("tell application \"\(app)\" to set sound volume to \(max(0, min(100, cur + delta)))")
    }

    static func launch(_ src: MusicSource) {
        switch src {
        case .appleMusic: runShell("/usr/bin/open", ["-a", "Music"])
        case .spotify: runShell("/usr/bin/open", ["-a", "Spotify"])
        case .alexa:
            if let u = URL(string: "https://music.amazon.fr/") { NSWorkspace.shared.open(u) }
        }
    }

    static func openAlexaConsole() {
        if let u = URL(string: "https://alexa.amazon.fr/") { NSWorkspace.shared.open(u) }
    }
}

final class MusicPanelView: NSView {
    private let hero: HeroHeader
    private var sourceSeg: SegmentedBar!
    private var titleLabel: NSTextField!
    private var artistLabel: NSTextField!
    private var stateLabel: NSTextField!
    private var playBtn: GlassButton!
    private var noteIcon: NSImageView!
    private var hint: NSTextField!
    private var src: MusicSource = .appleMusic

    var onStatus: ((String) -> Void)?
    var onSourceChange: ((Int) -> Void)?

    init(frame: NSRect, source: Int) {
        src = MusicSource(rawValue: source) ?? .appleMusic
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Musique", subtitle: "Pilotez la lecture sans quitter votre travail.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height

        sourceSeg = SegmentedBar(frame: NSRect(x: 0, y: H - 148, width: W, height: 42),
                                 items: [SegmentedBar.Item(title: "Musique", icon: "music.note"),
                                         SegmentedBar.Item(title: "Spotify", icon: "waveform"),
                                         SegmentedBar.Item(title: "Alexa", icon: "homepod.fill")],
                                 selected: src.rawValue)
        sourceSeg.onSelect = { [weak self] i in
            self?.src = MusicSource(rawValue: i) ?? .appleMusic
            self?.onSourceChange?(i)
            self?.refresh()
        }
        addSubview(sourceSeg)

        // Carte « en lecture »
        let card = mkCard(self, NSRect(x: 0, y: H - 268, width: W, height: 104), radius: 18)
        noteIcon = mkIcon(card, "music.note", x: 22, y: 42, size: 26, alpha: 0.55)
        titleLabel = mkLabel("—", NSRect(x: 72, y: 56, width: W - 96, height: 24), 16, .bold)
        artistLabel = mkLabel("", NSRect(x: 72, y: 36, width: W - 96, height: 18), 12, .medium, alpha: 0.55)
        stateLabel = mkLabel("", NSRect(x: 72, y: 14, width: W - 96, height: 16), 10.5, .regular, alpha: 0.38)
        [titleLabel, artistLabel, stateLabel].forEach { card.addSubview($0) }

        // Transport
        let y = H - 338
        let bw = (W - 36) / 4
        let prev = GlassButton(frame: NSRect(x: 0, y: y, width: bw, height: 52),
                               title: "", icon: "backward.fill")
        prev.onClick = { [weak self] _ in self?.act { MusicBridge.previous($0) } }
        playBtn = GlassButton(frame: NSRect(x: bw + 12, y: y, width: bw, height: 52),
                              title: "", icon: "playpause.fill", prominent: true)
        playBtn.onClick = { [weak self] _ in self?.act { MusicBridge.playPause($0) } }
        let next = GlassButton(frame: NSRect(x: (bw + 12) * 2, y: y, width: bw, height: 52),
                               title: "", icon: "forward.fill")
        next.onClick = { [weak self] _ in self?.act { MusicBridge.next($0) } }
        let open = GlassButton(frame: NSRect(x: (bw + 12) * 3, y: y, width: bw, height: 52),
                               title: "", icon: "arrow.up.forward.app.fill")
        open.onClick = { [weak self] _ in
            guard let s = self else { return }
            MusicBridge.launch(s.src)
            s.onStatus?("Ouverture de \(s.src.label)")
        }
        [prev, playBtn, next, open].forEach { addSubview($0) }

        // Volume
        let vy = y - 60
        let vw = (W - 12) / 2
        let vDown = GlassButton(frame: NSRect(x: 0, y: vy, width: vw, height: 44),
                                title: "Volume −", icon: "speaker.wave.1.fill")
        vDown.onClick = { [weak self] _ in self?.act { MusicBridge.setVolume($0, delta: -10) } }
        let vUp = GlassButton(frame: NSRect(x: vw + 12, y: vy, width: vw, height: 44),
                              title: "Volume +", icon: "speaker.wave.3.fill")
        vUp.onClick = { [weak self] _ in self?.act { MusicBridge.setVolume($0, delta: 10) } }
        [vDown, vUp].forEach { addSubview($0) }

        hint = mkLabel("", NSRect(x: 0, y: 14, width: W, height: 40), 11, .regular, alpha: 0.4, .center)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.cell?.usesSingleLineMode = false
        addSubview(hint)
    }

    private func act(_ body: (MusicSource) -> Void) {
        body(src)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    func refresh() {
        let s = src
        DispatchQueue.global(qos: .userInitiated).async {
            let n = MusicBridge.nowPlaying(s)
            DispatchQueue.main.async { [weak self] in
                guard let v = self else { return }
                v.titleLabel.stringValue = n.title
                v.artistLabel.stringValue = n.artist
                v.stateLabel.stringValue = n.playing ? "En lecture" : (n.available ? "En pause" : "Indisponible")
                v.noteIcon.image = symbol(s.icon, 26, .semibold)
                v.noteIcon.contentTintColor = n.playing ? TH.accent : TH.dim(0.45)
                v.hero.set(subtitle: n.playing ? "\(n.title) — \(n.artist)"
                                               : "Pilotez la lecture sans quitter votre travail.",
                           trailing: n.playing ? "En lecture" : "")
                v.hint.stringValue = s == .alexa
                    ? "Alexa n'a pas d'interface locale sur macOS : BUD ouvre le lecteur web Amazon Music et le commande par les touches média du système. Autorisez BUD dans Confidentialité → Accessibilité."
                    : "\(s.label) est piloté directement. Autorisez BUD dans Confidentialité → Automatisation à la première commande."
            }
        }
    }

    func setSource(_ i: Int) {
        src = MusicSource(rawValue: i) ?? .appleMusic
        sourceSeg.selected = i
        refresh()
    }

    /// Commandes courtes pour le chat.
    func command(_ what: String) -> String {
        switch what {
        case "play": MusicBridge.playPause(src); refresh(); return "Lecture basculée sur \(src.label)."
        case "next": MusicBridge.next(src); refresh(); return "Morceau suivant."
        case "prev": MusicBridge.previous(src); refresh(); return "Morceau précédent."
        case "up": MusicBridge.setVolume(src, delta: 10); return "Volume augmenté."
        case "down": MusicBridge.setVolume(src, delta: -10); return "Volume baissé."
        case "alexa":
            MusicBridge.launch(.alexa)
            return "J'ouvre le lecteur Amazon Music ; les touches média le commanderont."
        default:
            let n = MusicBridge.nowPlaying(src)
            return n.playing ? "En lecture sur \(src.label) : \(n.title)\(n.artist.isEmpty ? "" : " — \(n.artist)")."
                             : "Rien en lecture sur \(src.label)."
        }
    }
}
EOF_BUDMUSIC_SWIFT

cat << 'EOF_BUDOAUTH_SWIFT' > "$SRC_DIR/BudOAuth.swift"
import Foundation
import Network
import CryptoKit
import AppKit

// ═══════════════════════════════════════════════════════════
//  OAuth 2.0 Google avec PKCE
//
//  Flux « application de bureau » : BUD ouvre le consentement dans
//  votre navigateur, écoute sur 127.0.0.1 le retour de Google, puis
//  échange le code contre des jetons. Le jeton de rafraîchissement
//  va dans le trousseau ; le jeton d'accès reste en mémoire.
//  Aucun identifiant ne transite par un serveur tiers.
// ═══════════════════════════════════════════════════════════

struct GoogleTokens {
    var access: String
    var refresh: String
    var expiry: Date
    var email: String
}

/// Petit serveur local qui attend la redirection de Google.
final class LoopbackCatcher {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fr.lahbib.bud.oauth")
    private var finished = false

    /// Démarre l'écoute et renvoie le port retenu.
    ///
    /// Deux tentatives : d'abord restreint à la boucle locale, sinon sans
    /// restriction. Sans point d'ancrage, NWListener écoute sur toutes les
    /// interfaces — n'importe qui sur le même Wi-Fi pourrait frapper à ce
    /// port, alors que Google ne redirige que vers 127.0.0.1. Mais avec
    /// « port: .any », certaines versions renvoient 0 au lieu du port réel ;
    /// on vérifie donc, et on retombe sur l'écoute large plutôt que d'échouer.
    /// (Rien à voir avec macOS 15 : accepter une connexion TCP entrante ne
    ///  demande aucune autorisation « Réseau local ».)
    func start(timeout: TimeInterval = 180,
               onResult: @escaping (String?, String?) -> Void) -> UInt16? {
        if let port = attempt(loopbackOnly: true, timeout: timeout, onResult: onResult) {
            return port
        }
        stop()
        return attempt(loopbackOnly: false, timeout: timeout, onResult: onResult)
    }

    private func attempt(loopbackOnly: Bool, timeout: TimeInterval,
                         onResult: @escaping (String?, String?) -> Void) -> UInt16? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l

        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { st in
            if case .ready = st { ready.signal() }
            if case .failed = st { ready.signal() }
        }

        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                var code: String?
                var err: String?
                if let d = data, let req = String(data: d, encoding: .utf8),
                   let line = req.split(separator: "\r\n").first {
                    // GET /?code=...&scope=... HTTP/1.1
                    let parts = line.split(separator: " ")
                    if parts.count > 1 {
                        let path = String(parts[1])
                        if let q = path.split(separator: "?").dropFirst().first {
                            for pair in q.split(separator: "&") {
                                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                                guard kv.count == 2 else { continue }
                                let value = kv[1].removingPercentEncoding ?? kv[1]
                                if kv[0] == "code" { code = value }
                                if kv[0] == "error" { err = value }
                            }
                        }
                    }
                }
                let page = """
                <!doctype html><html lang="fr"><head><meta charset="utf-8">
                <title>BUD</title></head>
                <body style="font-family:-apple-system,system-ui;background:#0b0b0c;color:#f4f4f5;
                display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
                <div style="text-align:center">
                <div style="font-size:48px">\(code != nil ? "✅" : "⚠️")</div>
                <h2 style="font-weight:600">\(code != nil ? "Compte relié à BUD" : "Connexion interrompue")</h2>
                <p style="opacity:.6">Vous pouvez fermer cet onglet et revenir à BUD.</p>
                </div></body></html>
                """
                let body = Data(page.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                guard let s = self, !s.finished else { return }
                s.finished = true
                DispatchQueue.main.async { onResult(code, err) }
                s.stop()
            }
        }

        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = l.port?.rawValue, port != 0 else {
            l.cancel()
            listener = nil
            return nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let s = self, !s.finished else { return }
            s.finished = true
            s.stop()
            onResult(nil, "délai dépassé")
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

enum GoogleOAuth {

    static let scope = "https://mail.google.com/ openid email"

    // Non privés : l'appairage par téléphone (BudPhone) construit sa
    // propre URL de consentement avec le même PKCE.
    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL()
    }

    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL()
    }

    /// Ouvre le consentement Google et renvoie les jetons.
    static func authorize(clientID: String, clientSecret: String,
                          completion: @escaping (GoogleTokens?, String?) -> Void) {
        let verifier = randomVerifier()
        let catcher = LoopbackCatcher()

        guard let port = catcher.start(onResult: { code, err in
            guard let code = code else {
                completion(nil, err ?? "aucun code reçu")
                return
            }
            exchange(clientID: clientID, clientSecret: clientSecret,
                     code: code, verifier: verifier, port: 0, completion: completion)
        }) else {
            completion(nil, "impossible d'ouvrir le port local d'écoute")
            return
        }
        lastPort = port

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = c.url else {
            completion(nil, "URL d'autorisation invalide")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static var lastPort: UInt16 = 0

    private static func post(_ url: String, _ fields: [String: String],
                             _ done: @escaping ([String: Any]?, String?) -> Void) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { k, v in
            let ev = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(k)=\(ev)"
        }.joined(separator: "&").data(using: .utf8)
        req.timeoutInterval = 25

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let e = error { done(nil, e.localizedDescription); return }
            guard let d = data,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                done(nil, "réponse illisible de Google")
                return
            }
            if let err = j["error"] as? String {
                let desc = j["error_description"] as? String ?? ""
                done(nil, "\(err) \(desc)".trimmingCharacters(in: .whitespaces))
                return
            }
            done(j, nil)
        }.resume()
    }

    private static func exchange(clientID: String, clientSecret: String, code: String,
                                 verifier: String, port: UInt16,
                                 completion: @escaping (GoogleTokens?, String?) -> Void) {
        exchangeCode(clientID: clientID, clientSecret: clientSecret, code: code,
                     verifier: verifier, redirect: "http://127.0.0.1:\(lastPort)",
                     completion: completion)
    }

    /// Échange un code d'autorisation contre des jetons. L'URI de
    /// redirection est passée telle qu'elle a servi à la demande : le
    /// flux téléphone a la sienne.
    static func exchangeCode(clientID: String, clientSecret: String, code: String,
                             verifier: String, redirect: String,
                             completion: @escaping (GoogleTokens?, String?) -> Void) {
        var fields = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect
        ]
        if !clientSecret.isEmpty { fields["client_secret"] = clientSecret }

        post("https://oauth2.googleapis.com/token", fields) { j, err in
            guard let j = j,
                  let access = j["access_token"] as? String else {
                DispatchQueue.main.async { completion(nil, err ?? "jeton absent") }
                return
            }
            let refresh = j["refresh_token"] as? String ?? ""
            let ttl = (j["expires_in"] as? Double) ?? 3500
            userEmail(access) { mail in
                let t = GoogleTokens(access: access, refresh: refresh,
                                     expiry: Date().addingTimeInterval(ttl - 60),
                                     email: mail ?? "")
                DispatchQueue.main.async { completion(t, mail == nil ? "adresse introuvable" : nil) }
            }
        }
    }

    static func refresh(clientID: String, clientSecret: String, refreshToken: String,
                        done: @escaping (String?, Date?, String?) -> Void) {
        var fields = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        post("https://oauth2.googleapis.com/token", fields) { j, err in
            guard let j = j, let a = j["access_token"] as? String else {
                done(nil, nil, err ?? "rafraîchissement refusé")
                return
            }
            let ttl = (j["expires_in"] as? Double) ?? 3500
            done(a, Date().addingTimeInterval(ttl - 60), nil)
        }
    }

    static func userEmail(_ accessToken: String, done: @escaping (String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let d = data,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                done(nil); return
            }
            done(j["email"] as? String)
        }.resume()
    }
}

extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// ═══════════════════════════════════════════════════════════
//  Session Gmail : conserve les identifiants et sert un jeton valide
// ═══════════════════════════════════════════════════════════

final class GmailAuth {
    static let shared = GmailAuth()

    private let kClientID = "oauth.client.id"
    private let kSecret = "oauth.client.secret"
    private let kRefresh = "oauth.refresh"

    private var access: String?
    private var expiry = Date.distantPast

    var email: String = ""           // rempli par l'état enregistré

    var clientID: String {
        get { BudKeychain.get(kClientID) ?? "" }
        set { BudKeychain.set(newValue, account: kClientID) }
    }
    var clientSecret: String {
        get { BudKeychain.get(kSecret) ?? "" }
        set { BudKeychain.set(newValue, account: kSecret) }
    }
    private var refreshToken: String {
        get { BudKeychain.get(kRefresh) ?? "" }
        set { BudKeychain.set(newValue, account: kRefresh) }
    }

    var isConnected: Bool { !refreshToken.isEmpty && !email.isEmpty }
    var hasClient: Bool { !clientID.isEmpty }

    func store(_ t: GoogleTokens) {
        access = t.access
        expiry = t.expiry
        if !t.refresh.isEmpty { refreshToken = t.refresh }
        if !t.email.isEmpty { email = t.email }
    }

    func disconnect() {
        access = nil
        expiry = .distantPast
        BudKeychain.delete(kRefresh)
        email = ""
    }

    func forgetClient() {
        BudKeychain.delete(kClientID)
        BudKeychain.delete(kSecret)
    }

    /// Jeton d'accès utilisable, rafraîchi si besoin. Appel bloquant court.
    func validAccessToken() -> String? {
        if let a = access, Date() < expiry { return a }
        guard !refreshToken.isEmpty, !clientID.isEmpty else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var token: String?
        GoogleOAuth.refresh(clientID: clientID, clientSecret: clientSecret,
                            refreshToken: refreshToken) { [weak self] a, exp, _ in
            if let a = a, let e = exp {
                self?.access = a
                self?.expiry = e
                token = a
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 25)
        return token
    }

    /// Chaîne XOAUTH2 attendue par IMAP et SMTP.
    func xoauth2() -> String? {
        guard let t = validAccessToken(), !email.isEmpty else { return nil }
        let raw = "user=\(email)\u{01}auth=Bearer \(t)\u{01}\u{01}"
        return Data(raw.utf8).base64EncodedString()
    }
}
EOF_BUDOAUTH_SWIFT

cat << 'EOF_BUDPHONE_SWIFT' > "$SRC_DIR/BudPhone.swift"
import AppKit
import CoreImage
import Foundation
import QuartzCore

// ═══════════════════════════════════════════════════════════
//  Appairage Gmail par téléphone
//
//  BUD affiche un QR code, vous le scannez, l'application Google
//  de votre téléphone vous identifie. Rien n'est tapé au clavier
//  du Mac, aucun serveur tiers n'intervient.
//
//  Note technique honnête : le « device flow » de Google — le code
//  à six lettres sur google.com/device — n'accepte PAS les scopes
//  Gmail. Google le restreint à email, openid, profile, deux scopes
//  Drive et deux YouTube. D'où les deux voies ci-dessous.
//
//    Voie 1 · Mot de passe d'application (recommandée)
//      Le téléphone ouvre la page des mots de passe d'application,
//      déjà authentifié. Seize lettres à recopier dans BUD.
//
//    Voie 2 · OAuth Google
//      Le téléphone ouvre le consentement. La redirection pointe
//      vers le Mac et échoue donc sur le téléphone : son adresse
//      contient le code d'autorisation, qu'il suffit de coller.
//      Le vérificateur PKCE n'a jamais quitté le Mac, le code seul
//      ne vaut donc rien pour un tiers.
// ═══════════════════════════════════════════════════════════

let appPasswordURL = "https://myaccount.google.com/apppasswords"

enum QRCode {
    /// Rendu net : un module occupe un nombre entier de pixels,
    /// agrandi sans interpolation pour garder des arêtes franches.
    static func image(_ text: String, scale: CGFloat = 12) -> NSImage? {
        guard !text.isEmpty, let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        // Une charge longue grossit la matrice : on baisse la redondance
        // pour garder des modules assez larges à l'écran.
        f.setValue(text.count > 180 ? "L" : "M", forKey: "inputCorrectionLevel")
        guard var out = f.outputImage else { return nil }

        if let fc = CIFilter(name: "CIFalseColor") {
            fc.setValue(out, forKey: kCIInputImageKey)
            fc.setValue(CIColor(red: 0.04, green: 0.04, blue: 0.05), forKey: "inputColor0")
            fc.setValue(CIColor(red: 1, green: 1, blue: 1), forKey: "inputColor1")
            if let o = fc.outputImage { out = o }
        }

        let big = out.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: big)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// ═══════════════════════════════════════════════════════════
//  La plaque : fond blanc, QR net, équerres d'accent, balayage
// ═══════════════════════════════════════════════════════════

final class QRPlate: NSView {
    var payload: String = "" {
        didSet {
            guard payload != oldValue else { return }
            qr = QRCode.image(payload)
            needsDisplay = true
        }
    }
    var paired = false { didSet { needsDisplay = true } }

    private var qr: NSImage?
    private var scanT: CGFloat = 0
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    func startScan() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            // Inutile de peindre un panneau masqué : le balayage dort.
            guard s.window != nil, !s.isHiddenOrHasHiddenAncestor else { return }
            s.scanT += 1.0 / 30.0
            if s.scanT > 2.6 { s.scanT = 0 }
            s.needsDisplay = true
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    func stopScan() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)

        // Plaque claire : un QR se lit mal sur fond sombre.
        let plate = NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20)
        NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
        plate.fill()
        TH.accent.withAlphaComponent(0.22).setStroke()
        plate.lineWidth = 1
        plate.stroke()

        let inner = r.insetBy(dx: 16, dy: 16)

        if let img = qr {
            ctx.saveGraphicsState()
            ctx.imageInterpolation = .none
            // Côté entier : évite qu'un module soit coupé en deux pixels.
            let side = floor(min(inner.width, inner.height))
            let box = NSRect(x: inner.midX - side / 2, y: inner.midY - side / 2,
                             width: side, height: side)
            img.draw(in: box, from: .zero, operation: .sourceOver, fraction: paired ? 0.18 : 1)
            ctx.restoreGraphicsState()

            // Équerres d'accent aux quatre angles. Les bornes sont
            // calculées une par une : un tuple mixte CGFloat/Double
            // rend l'inférence ambiguë sur x86_64.
            let arm: CGFloat = 20, thick: CGFloat = 2.5
            TH.accent.setFill()
            let c = box.insetBy(dx: -7, dy: -7)
            let corners: [NSRect] = [
                NSRect(x: c.minX, y: c.maxY - thick, width: arm, height: thick),
                NSRect(x: c.minX, y: c.maxY - arm, width: thick, height: arm),
                NSRect(x: c.maxX - arm, y: c.maxY - thick, width: arm, height: thick),
                NSRect(x: c.maxX - thick, y: c.maxY - arm, width: thick, height: arm),
                NSRect(x: c.minX, y: c.minY, width: arm, height: thick),
                NSRect(x: c.minX, y: c.minY, width: thick, height: arm),
                NSRect(x: c.maxX - arm, y: c.minY, width: arm, height: thick),
                NSRect(x: c.maxX - thick, y: c.minY, width: thick, height: arm)
            ]
            for bracket in corners { NSBezierPath(rect: bracket).fill() }

            // Balayage : une bande d'accent descend puis disparaît.
            if !paired {
                let p = min(1, scanT / 1.5)
                if scanT < 1.5 {
                    let y = box.maxY - p * box.height
                    let band = NSRect(x: box.minX, y: y - 26, width: box.width, height: 26)
                    ctx.saveGraphicsState()
                    NSBezierPath(rect: box).setClip()
                    let fade = sin(p * .pi)
                    let g = NSGradient(colors: [TH.accent.withAlphaComponent(0),
                                                TH.accent.withAlphaComponent(0.30 * fade)])
                    g?.draw(in: band, angle: 90)
                    TH.accent.withAlphaComponent(0.65 * fade).setFill()
                    NSBezierPath(rect: NSRect(x: box.minX, y: y - 1.2, width: box.width, height: 1.2)).fill()
                    ctx.restoreGraphicsState()
                }
            }
        } else {
            drawString("QR indisponible", in: NSRect(x: inner.minX, y: inner.midY + 8,
                                                     width: inner.width, height: 18),
                       size: 12.5, weight: .semibold,
                       color: NSColor(calibratedWhite: 0.25, alpha: 1), align: .center)
            drawString("Utilisez « Copier le lien »", in: NSRect(x: inner.minX, y: inner.midY - 12,
                                                                 width: inner.width, height: 16),
                       size: 11, weight: .regular,
                       color: NSColor(calibratedWhite: 0.45, alpha: 1), align: .center)
        }

        if paired {
            let d: CGFloat = 76
            let ring = NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            TH.accent.setFill()
            NSBezierPath(ovalIn: ring).fill()
            drawSymbol("checkmark", center: NSPoint(x: r.midX, y: r.midY),
                       size: 36, weight: .bold, color: NSColor(calibratedWhite: 0.07, alpha: 0.95))
        }
    }
}

/// Fenêtre d'agrandissement : un QR confortable à scanner de loin.
final class QRZoom {
    static var panel: NSPanel?

    static func show(_ payload: String, title: String) {
        close()
        // 460 pt : l'URL de consentement fait ~69 modules, il faut
        // au moins 5 pt par module pour un appareil photo de téléphone.
        let side: CGFloat = 460
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side + 54),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = title
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side + 54))
        let plate = QRPlate(frame: NSRect(x: 18, y: 54, width: side - 36, height: side - 36))
        plate.payload = payload
        host.addSubview(plate)

        let hint = NSTextField(labelWithString: "Scannez avec l'appareil photo du téléphone.")
        hint.frame = NSRect(x: 0, y: 20, width: side, height: 18)
        hint.alignment = .center
        hint.font = NSFont.systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        host.addSubview(hint)

        p.contentView = host
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// ═══════════════════════════════════════════════════════════
//  OAuth démarré sur le Mac, consenti sur le téléphone
// ═══════════════════════════════════════════════════════════

final class PhoneOAuth {
    static let shared = PhoneOAuth()

    private var verifier = ""
    private var stateTok = ""
    private var redirect = ""
    private var catcher: LoopbackCatcher?

    var authURL: String = ""
    var armed: Bool { !verifier.isEmpty && !authURL.isEmpty }

    /// Prépare l'URL de consentement. Le guetteur local reste actif :
    /// si vous ouvrez le lien sur le Mac, l'appairage se termine seul.
    func arm(clientID: String, onAuto: @escaping (GoogleTokens?, String?) -> Void) -> String? {
        cancel()
        verifier = GoogleOAuth.randomVerifier()
        stateTok = String(GoogleOAuth.randomVerifier().prefix(24))

        let c = LoopbackCatcher()
        catcher = c
        guard let port = c.start(timeout: 900, onResult: { [weak self] code, err in
            guard let s = self else { return }
            guard let code = code else {
                if let e = err, e != "délai dépassé" { onAuto(nil, e) }
                return
            }
            s.exchange(clientID: clientID, code: code, completion: onAuto)
        }) else {
            return nil
        }
        redirect = "http://127.0.0.1:\(port)"

        var u = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        u.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuth.scope),
            URLQueryItem(name: "code_challenge", value: GoogleOAuth.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: stateTok)
        ]
        authURL = u.url?.absoluteString ?? ""
        return authURL.isEmpty ? nil : authURL
    }

    /// Accepte l'adresse complète recopiée du téléphone, ou le code seul.
    func finish(pasted raw: String, clientID: String,
                completion: @escaping (GoogleTokens?, String?) -> Void) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { completion(nil, "Rien à coller."); return }
        guard armed else { completion(nil, "Relancez l'appairage : la demande a expiré."); return }

        var code = s
        var seenState: String?

        if s.contains("code=") {
            // Une adresse : on lit ses paramètres, avec ou sans « ? ».
            // Pas d'indexation directe : une adresse finissant par « ? »
            // ne produit qu'un seul morceau et ferait planter [1].
            let query = s.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? s
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let v = kv[1].removingPercentEncoding ?? kv[1]
                if kv[0] == "code" { code = v }
                if kv[0] == "state" { seenState = v }
                if kv[0] == "error" { completion(nil, "Google a répondu : \(v)"); return }
            }
        }

        if let st = seenState, st != stateTok {
            completion(nil, "Jeton d'état incohérent, appairage abandonné.")
            return
        }
        guard code.count > 12, !code.contains(" ") else {
            completion(nil, "Code d'autorisation introuvable dans ce texte.")
            return
        }
        exchange(clientID: clientID, code: code, completion: completion)
    }

    private func exchange(clientID: String, code: String,
                          completion: @escaping (GoogleTokens?, String?) -> Void) {
        let v = verifier, r = redirect
        cancel()
        GoogleOAuth.exchangeCode(clientID: clientID,
                                 clientSecret: GmailAuth.shared.clientSecret,
                                 code: code, verifier: v, redirect: r,
                                 completion: completion)
    }

    func cancel() {
        catcher?.stop()
        catcher = nil
        verifier = ""
        stateTok = ""
        authURL = ""
    }
}

// ═══════════════════════════════════════════════════════════
//  Le panneau
// ═══════════════════════════════════════════════════════════

final class PhonePanelView: NSView, NSTextFieldDelegate {
    private let hero: HeroHeader
    private var seg: SegmentedBar!
    private var plate: QRPlate!
    private var stepLabels: [NSTextField] = []
    private var hintLabel: NSTextField!
    private var statusLabel: NSTextField!

    private var emailField: NSTextField!
    private var passField: NSTextField!
    private var clientField: NSTextField!
    private var pasteField: NSTextField!
    private var actionBtn: GlassButton!
    private var zoomBtn: GlassButton!
    private var copyBtn: GlassButton!
    private var openBtn: GlassButton!
    private var disconnectBtn: GlassButton!
    private var linkedCard: NSView!
    private var linkedLabel: NSTextField!

    private var mode = 0          // 0 = mot de passe d'app, 1 = OAuth
    private var busy = false

    var onStatus: ((String) -> Void)?
    var onAccountChange: ((String) -> Void)?
    var prefillAddress: () -> String = { "" }

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Téléphone",
                          subtitle: "Reliez Gmail depuis l'application Google de votre téléphone.")
        super.init(frame: frame)
        build()
        applyMode()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        addSubview(hero)

        seg = SegmentedBar(frame: NSRect(x: 0, y: H - 134, width: W, height: 36),
                           items: [SegmentedBar.Item(title: "Mot de passe d'app", icon: "key.fill"),
                                   SegmentedBar.Item(title: "OAuth Google", icon: "checkmark.shield.fill")])
        seg.onSelect = { [weak self] i in
            self?.mode = i
            self?.applyMode()
        }
        addSubview(seg)

        plate = QRPlate(frame: NSRect(x: 0, y: 226, width: 200, height: 200))
        addSubview(plate)

        // Colonne de droite : les trois étapes.
        let cx: CGFloat = 220, cw = W - 220
        addSubview(mkLabel("ÉTAPES", NSRect(x: cx, y: 408, width: cw, height: 14), 9.5, .bold, alpha: 0.32))
        var y: CGFloat = 348
        for i in 0..<3 {
            mkCard(self, NSRect(x: cx, y: y, width: cw, height: 56), radius: 12, alpha: 0.055)
            let dot = NSView(frame: NSRect(x: cx + 14, y: y + 17, width: 22, height: 22))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 11
            dot.layer?.backgroundColor = TH.accent.withAlphaComponent(0.18).cgColor
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = TH.accent.withAlphaComponent(0.35).cgColor
            addSubview(dot)
            addSubview(mkLabel("\(i + 1)", NSRect(x: cx + 14, y: y + 20, width: 22, height: 16),
                               11, .bold, alpha: 0.85, .center))

            let t = NSTextField(frame: NSRect(x: cx + 46, y: y + 8, width: cw - 60, height: 40))
            t.isBezeled = false
            t.drawsBackground = false
            t.isEditable = false
            t.isSelectable = false
            t.font = NSFont.systemFont(ofSize: 11.5)
            t.textColor = TH.dim(0.68)
            t.lineBreakMode = .byWordWrapping
            t.cell?.usesSingleLineMode = false
            t.cell?.wraps = true
            t.maximumNumberOfLines = 3
            ThemeRegistry.shared.register(t, alpha: 0.68)
            addSubview(t)
            stepLabels.append(t)
            y -= 64
        }

        hintLabel = NSTextField(frame: NSRect(x: 0, y: 186, width: W, height: 30))
        hintLabel.isBezeled = false
        hintLabel.drawsBackground = false
        hintLabel.isEditable = false
        hintLabel.isSelectable = false
        hintLabel.font = NSFont.systemFont(ofSize: 10.5)
        hintLabel.textColor = TH.dim(0.40)
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.cell?.usesSingleLineMode = false
        hintLabel.cell?.wraps = true
        hintLabel.maximumNumberOfLines = 2
        ThemeRegistry.shared.register(hintLabel, alpha: 0.40)
        addSubview(hintLabel)

        // Rangée 1 : adresse (voie 1) ou identifiant client (voie 2).
        emailField = NSTextField(frame: NSRect(x: 0, y: 150, width: 300, height: 30))
        emailField.placeholderString = "adresse@gmail.com"
        emailField.font = NSFont.systemFont(ofSize: 12.5)
        addSubview(emailField)

        passField = NSTextField(frame: NSRect(x: 310, y: 150, width: 190, height: 30))
        passField.placeholderString = "abcd efgh ijkl mnop"
        passField.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        addSubview(passField)

        clientField = NSTextField(frame: NSRect(x: 0, y: 150, width: 500, height: 30))
        clientField.placeholderString = "Identifiant client Google — …apps.googleusercontent.com"
        clientField.font = NSFont.systemFont(ofSize: 11.5)
        clientField.delegate = self
        addSubview(clientField)

        pasteField = NSTextField(frame: NSRect(x: 0, y: 112, width: 500, height: 30))
        pasteField.placeholderString = "Collez ici l'adresse copiée sur le téléphone"
        pasteField.font = NSFont.systemFont(ofSize: 11.5)
        addSubview(pasteField)

        actionBtn = GlassButton(frame: NSRect(x: 510, y: 148, width: W - 510, height: 34),
                                title: "Relier", icon: "link", prominent: true)
        actionBtn.onClick = { [weak self] _ in self?.commit() }
        addSubview(actionBtn)

        linkedCard = mkCard(self, NSRect(x: 0, y: 108, width: W, height: 44), radius: 12, alpha: 0.08)
        mkIcon(linkedCard, "checkmark.seal.fill", x: 14, y: 14, size: 15, alpha: 0.8)
        linkedLabel = mkLabel("", NSRect(x: 40, y: 13, width: W - 54, height: 18), 12, .semibold, alpha: 0.82)
        linkedCard.addSubview(linkedLabel)

        statusLabel = mkLabel("", NSRect(x: 0, y: 58, width: W, height: 34), 11, .medium, alpha: 0.55)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.usesSingleLineMode = false
        statusLabel.cell?.wraps = true
        statusLabel.maximumNumberOfLines = 2
        addSubview(statusLabel)

        let bw = (W - 36) / 4
        let specs: [(String, String, () -> Void)] = [
            ("Agrandir", "viewfinder", { [weak self] in self?.zoom() }),
            ("Copier le lien", "doc.on.doc", { [weak self] in self?.copyLink() }),
            ("Ouvrir ici", "arrow.up.right.square", { [weak self] in self?.openHere() }),
            ("Déconnecter", "xmark.circle", { [weak self] in self?.disconnect() })
        ]
        var btns: [GlassButton] = []
        for (i, s) in specs.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (bw + 12), y: 0, width: bw, height: 42),
                                title: s.0, icon: s.1)
            b.onClick = { _ in s.2() }
            addSubview(b)
            btns.append(b)
        }
        zoomBtn = btns[0]; copyBtn = btns[1]; openBtn = btns[2]; disconnectBtn = btns[3]
        disconnectBtn.destructive = true
    }

    // ── Bascule entre les deux voies ──

    private func applyMode() {
        let a = prefillAddress()
        if emailField.stringValue.isEmpty {
            emailField.stringValue = MailRouter.account.isEmpty ? a : MailRouter.account
        }
        if clientField.stringValue.isEmpty { clientField.stringValue = GmailAuth.shared.clientID }

        if mode == 0 {
            stepLabels[0].stringValue = "Scannez ce code avec l'appareil photo du téléphone."
            stepLabels[1].stringValue = "L'application Google vous identifie, puis créez un mot de passe nommé « BUD »."
            stepLabels[2].stringValue = "Recopiez les seize lettres affichées, les espaces sont ignorés."
            hintLabel.stringValue = "Demande la validation en deux étapes sur le compte Google. Aucun identifiant client n'est nécessaire."
            plate.payload = appPasswordURL
            actionBtn.title = "Relier"
            actionBtn.iconName = "link"
        } else {
            stepLabels[0].stringValue = "Collez votre identifiant client, puis scannez le code — « Agrandir » le rend plus facile à viser."
            stepLabels[1].stringValue = "Autorisez BUD sur le téléphone. La page suivante ne se chargera pas — c'est normal, elle pointe vers votre Mac."
            stepLabels[2].stringValue = "Copiez l'adresse de cette page et collez-la ci-dessous."
            hintLabel.stringValue = "Demande un identifiant client Google de type « application de bureau ». Le vérificateur PKCE ne quitte jamais le Mac."
            armOAuth()
            actionBtn.title = "Terminer"
            actionBtn.iconName = "checkmark"
        }
        refresh()
    }

    private func armOAuth() {
        let id = clientField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.contains("apps.googleusercontent.com") else {
            plate.payload = ""
            statusLabel.stringValue = "Collez l'identifiant client, le QR code apparaîtra aussitôt."
            return
        }
        GmailAuth.shared.clientID = id
        guard let url = PhoneOAuth.shared.arm(clientID: id, onAuto: { [weak self] t, err in
            self?.settle(t, err, source: "Mac")
        }) else {
            plate.payload = ""
            statusLabel.stringValue = "Port local indisponible, réessayez dans un instant."
            return
        }
        plate.payload = url
        statusLabel.stringValue = "Prêt. Scannez le code, ou cliquez « Ouvrir ici » pour rester sur le Mac."
    }

    // ── Actions ──

    private func commit() {
        guard !busy else { return }
        if mode == 0 { linkAppPassword() } else { linkOAuth() }
    }

    private func linkAppPassword() {
        let mail = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = GmailClient.normalizedPassword(passField.stringValue)
        guard mail.contains("@") else {
            statusLabel.stringValue = "Indiquez l'adresse Gmail complète."
            return
        }
        guard pass.count == 16 else {
            statusLabel.stringValue = "Un mot de passe d'application fait seize lettres — \(pass.count) saisie(s)."
            return
        }
        busy = true
        actionBtn.enabledFlag = false
        statusLabel.stringValue = "Vérification auprès de Gmail…"
        onStatus?("Vérification du compte Gmail")

        DispatchQueue.global(qos: .userInitiated).async {
            let err = GmailClient.testLogin(user: mail, password: pass)
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                s.busy = false
                s.actionBtn.enabledFlag = true
                if let e = err {
                    s.statusLabel.stringValue = e
                    s.onStatus?("Gmail a refusé le mot de passe")
                    return
                }
                _ = BudKeychain.set(pass, account: mail)
                GmailAuth.shared.disconnect()
                MailRouter.account = mail
                s.passField.stringValue = ""
                s.celebrate("Compte relié · \(mail)")
                s.onAccountChange?(mail)
            }
        }
    }

    private func linkOAuth() {
        let id = clientField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.contains("apps.googleusercontent.com") else {
            statusLabel.stringValue = "Collez d'abord l'identifiant client Google."
            return
        }
        guard PhoneOAuth.shared.armed else {
            armOAuth()
            statusLabel.stringValue = "Appairage relancé : scannez le nouveau code."
            return
        }
        busy = true
        actionBtn.enabledFlag = false
        statusLabel.stringValue = "Échange du code contre les jetons…"
        PhoneOAuth.shared.finish(pasted: pasteField.stringValue, clientID: id) { [weak self] t, err in
            self?.settle(t, err, source: "téléphone")
        }
    }

    private func settle(_ t: GoogleTokens?, _ err: String?, source: String) {
        busy = false
        actionBtn.enabledFlag = true
        guard let t = t, !t.email.isEmpty else {
            if let e = err {
                statusLabel.stringValue = "Échec : \(e)"
                onStatus?("Appairage refusé")
            }
            refresh()
            return
        }
        GmailAuth.shared.store(t)
        if !MailRouter.account.isEmpty {
            BudKeychain.delete(MailRouter.account)
            MailRouter.account = ""
        }
        pasteField.stringValue = ""
        PhoneOAuth.shared.cancel()
        celebrate("Compte relié par OAuth · \(t.email) · validé depuis le \(source)")
        onAccountChange?(t.email)
    }

    private func celebrate(_ msg: String) {
        statusLabel.stringValue = msg
        onStatus?("Gmail connecté")
        plate.paired = true
        plate.stopScan()
        refresh()
        // La coche arrive en fondu : l'ancrage du calque d'une NSView
        // est en bas à gauche, une mise à l'échelle décalerait la plaque.
        plate.alphaValue = 0.35
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            plate.animator().alphaValue = 1
        }
        linkedCard.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            linkedCard.animator().alphaValue = 1
        }
    }

    private func zoom() {
        guard !plate.payload.isEmpty else {
            statusLabel.stringValue = "Aucun code à agrandir pour l'instant."
            return
        }
        QRZoom.show(plate.payload, title: mode == 0 ? "Mots de passe d'application" : "Autorisation Google")
    }

    private func copyLink() {
        let link = mode == 0 ? appPasswordURL : PhoneOAuth.shared.authURL
        guard !link.isEmpty else {
            statusLabel.stringValue = "Aucun lien disponible pour l'instant."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        statusLabel.stringValue = "Lien copié. Envoyez-le à votre téléphone comme vous voulez."
        onStatus?("Lien d'appairage copié")
    }

    private func openHere() {
        let link = mode == 0 ? appPasswordURL : PhoneOAuth.shared.authURL
        guard !link.isEmpty, let u = URL(string: link) else {
            statusLabel.stringValue = "Aucun lien disponible pour l'instant."
            return
        }
        NSWorkspace.shared.open(u)
        statusLabel.stringValue = mode == 0
            ? "La page des mots de passe d'application s'ouvre sur le Mac."
            : "Consentement ouvert sur le Mac : BUD terminera tout seul."
    }

    private func disconnect() {
        GmailAuth.shared.disconnect()
        if !MailRouter.account.isEmpty {
            BudKeychain.delete(MailRouter.account)
            MailRouter.account = ""
        }
        PhoneOAuth.shared.cancel()
        plate.paired = false
        passField.stringValue = ""
        pasteField.stringValue = ""
        statusLabel.stringValue = "Compte déconnecté. BUD repasse par Mail.app."
        onStatus?("Compte Gmail déconnecté")
        onAccountChange?("")
        applyMode()
    }

    // ── Rafraîchissement ──

    func refresh() {
        // Le compte enregistré n'est restauré qu'après la construction
        // des panneaux : on complète les champs dès qu'il arrive.
        if emailField.stringValue.isEmpty {
            let known = MailRouter.account.isEmpty ? prefillAddress() : MailRouter.account
            emailField.stringValue = known
        }
        if clientField.stringValue.isEmpty { clientField.stringValue = GmailAuth.shared.clientID }

        let oauth = MailRouter.oauthReady
        let app = MailRouter.appPassword != nil
        let linked = oauth || app

        linkedCard.isHidden = !linked
        linkedLabel.stringValue = oauth
            ? "OAuth Google · \(GmailAuth.shared.email) · jetons dans le trousseau"
            : (app ? "Mot de passe d'application · \(MailRouter.account) · trousseau"
                   : "")
        disconnectBtn.enabledFlag = linked
        plate.paired = linked
        // En OAuth le code est dense : on met l'agrandissement en avant.
        zoomBtn.prominent = (mode == 1 && !linked)

        let showForm = !linked
        emailField.isHidden = !(showForm && mode == 0)
        passField.isHidden = !(showForm && mode == 0)
        clientField.isHidden = !(showForm && mode == 1)
        pasteField.isHidden = !(showForm && mode == 1)
        actionBtn.isHidden = !showForm
        zoomBtn.enabledFlag = !linked && !plate.payload.isEmpty
        copyBtn.enabledFlag = !linked

        if linked { plate.stopScan() } else { plate.startScan() }
        if linked && statusLabel.stringValue.isEmpty {
            statusLabel.stringValue = "Compte déjà relié. « Déconnecter » pour en changer."
        }
    }

    /// L'identifiant client vient d'être collé : on réarme le QR aussitôt.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === clientField, mode == 1 else { return }
        armOAuth()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { plate.stopScan() }
    }
}
EOF_BUDPHONE_SWIFT

cat << 'EOF_BUDREMINDERS_SWIFT' > "$SRC_DIR/BudReminders.swift"
import Cocoa

// ═══════════════════════════════════════════════════════════
//  Rappels et alarmes
//  Stockage local : reminders.json. L'alarme sonne dans le notch,
//  avec report ou validation, même si aucune autre app n'est ouverte.
// ═══════════════════════════════════════════════════════════

struct Reminder: Codable {
    var id: String
    var title: String
    var fireAt: TimeInterval
    var repeatMode: Int        // 0 aucun · 1 chaque jour · 2 chaque semaine
    var done: Bool

    var date: Date { Date(timeIntervalSince1970: fireAt) }
    var repeatLabel: String {
        switch repeatMode {
        case 1: return "chaque jour"
        case 2: return "chaque semaine"
        default: return "une fois"
        }
    }
    var whenLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        if Calendar.current.isDateInToday(date) { f.dateFormat = "'aujourd''hui à' HH'h'mm" }
        else if Calendar.current.isDateInTomorrow(date) { f.dateFormat = "'demain à' HH'h'mm" }
        else { f.dateFormat = "EEEE d MMMM 'à' HH'h'mm" }
        return f.string(from: date)
    }
}

final class ReminderStore {
    static let shared = ReminderStore()
    private let url = budSupportDir.appendingPathComponent("reminders.json")
    private(set) var items: [Reminder] = []

    init() { load() }

    func load() {
        if let d = try? Data(contentsOf: url),
           let r = try? JSONDecoder().decode([Reminder].self, from: d) { items = r }
        sort()
    }
    private func sort() { items.sort { $0.fireAt < $1.fireAt } }

    func save() {
        sort()
        let e = JSONEncoder()
        e.outputFormatting = .prettyPrinted
        if let d = try? e.encode(items) { try? d.write(to: url, options: .atomic) }
    }

    @discardableResult
    func add(title: String, at date: Date, repeatMode: Int = 0) -> Reminder {
        let r = Reminder(id: UUID().uuidString, title: title,
                         fireAt: date.timeIntervalSince1970, repeatMode: repeatMode, done: false)
        items.append(r)
        save()
        return r
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func complete(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].repeatMode == 0 {
            items.remove(at: i)
        } else {
            let step: TimeInterval = items[i].repeatMode == 1 ? 86400 : 604800
            var next = items[i].fireAt
            while next <= Date().timeIntervalSince1970 { next += step }
            items[i].fireAt = next
            items[i].done = false
        }
        save()
    }

    func snooze(id: String, minutes: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].fireAt = Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970
        items[i].done = false
        save()
    }

    /// Le premier rappel dont l'heure est passée.
    func due() -> Reminder? {
        let now = Date().timeIntervalSince1970
        return items.first { !$0.done && $0.fireAt <= now }
    }

    func next() -> Reminder? {
        let now = Date().timeIntervalSince1970
        return items.first { $0.fireAt > now }
    }
}

/// Analyse une formulation française : « dans 20 minutes », « à 18h30 », « demain à 9h ».
enum ReminderParser {
    static func parse(_ raw: String) -> (title: String, date: Date)? {
        let lower = raw.lowercased()
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        var when: Date?
        var cut: String?

        if let r = lower.range(of: #"dans\s+(\d+)\s*(min|minute|minutes|h|heure|heures)"#,
                               options: .regularExpression) {
            let frag = String(lower[r])
            let n = Int(frag.filter { $0.isNumber }) ?? 0
            let isHour = frag.contains("h") && !frag.contains("min")
            when = Date().addingTimeInterval(Double(n) * (isHour ? 3600 : 60))
            cut = frag
        } else if let r = lower.range(of: #"(\d{1,2})\s*(h|:)\s*(\d{2})?"#, options: .regularExpression) {
            let frag = String(lower[r])
            let nums = frag.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let hour = nums.first, hour < 24 else { return nil }
            let minute = nums.count > 1 ? min(59, nums[1]) : 0
            var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            c.hour = hour
            c.minute = minute
            var d = Calendar.current.date(from: c) ?? Date()
            if lower.contains("demain") { d = d.addingTimeInterval(86400) }
            else if d < Date() { d = d.addingTimeInterval(86400) }
            when = d
            cut = frag
        } else if lower.contains("demain") {
            var c = Calendar.current.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400))
            c.hour = 9
            c.minute = 0
            when = Calendar.current.date(from: c)
            cut = "demain"
        }

        guard let date = when else { return nil }

        // Titre : on retire les mots de commande et l'expression temporelle
        var title = raw
        for m in ["rappelle-moi de", "rappelle moi de", "rappelle-moi", "rappelle moi",
                  "rappel :", "rappel:", "n'oublie pas de", "pense à", "pense a"] {
            if let r = title.lowercased().range(of: m) {
                title = String(title[r.upperBound...])
                break
            }
        }
        if let c = cut, let r = title.lowercased().range(of: c) {
            title.removeSubrange(r)
        }
        for w in [" demain", "demain ", " à ", " a "] {
            title = title.replacingOccurrences(of: w, with: " ")
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Rappel" }
        return (title, date)
    }
}

final class RemindersPanelView: NSView {
    private let hero: HeroHeader
    private var nextTile: StatTile!, countTile: StatTile!
    private let scroll = NSScrollView(frame: .zero)
    private let listHost = NSView(frame: .zero)
    private var rows: [NSView] = []
    private var quickField: NSTextField!

    var onStatus: ((String) -> Void)?
    var onChanged: (() -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Rappels", subtitle: "Une alarme dans le notch, même app fermée.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height

        nextTile = StatTile(frame: NSRect(x: W - 330, y: H - 86, width: 190, height: 78),
                            caption: "Prochain", hint: "—")
        countTile = StatTile(frame: NSRect(x: W - 130, y: H - 86, width: 120, height: 78),
                             caption: "En attente", hint: "rappels actifs")
        [nextTile, countTile].forEach { addSubview($0) }

        mkSection(self, H - 116, W, "Ajouter")
        quickField = NSTextField(frame: NSRect(x: 0, y: H - 156, width: W - 230, height: 34))
        quickField.placeholderString = "Sortir les poubelles à 19h30 · dans 20 minutes · demain"
        quickField.font = NSFont.systemFont(ofSize: 12.5)
        quickField.target = self
        quickField.action = #selector(addFromField)
        addSubview(quickField)

        let bAdd = GlassButton(frame: NSRect(x: W - 222, y: H - 158, width: 106, height: 38),
                               title: "Ajouter", icon: "plus", prominent: true)
        bAdd.onClick = { [weak self] _ in self?.addFromField() }
        let bIn15 = GlassButton(frame: NSRect(x: W - 108, y: H - 158, width: 108, height: 38),
                                title: "Dans 15 min", icon: "clock", compact: true)
        bIn15.onClick = { [weak self] _ in
            guard let s = self else { return }
            let t = s.quickField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            s.create(title: t.isEmpty ? "Rappel" : t, date: Date().addingTimeInterval(900), repeatMode: 0)
        }
        [bAdd, bIn15].forEach { addSubview($0) }

        mkSection(self, H - 184, W, "À venir")
        scroll.frame = NSRect(x: 0, y: 56, width: W, height: H - 250)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        addSubview(mkLabel("Écrivez l'heure dans la phrase : BUD la comprend et garde le reste comme titre.",
                           NSRect(x: 0, y: 12, width: W, height: 16), 11, .regular, alpha: 0.33, .center))
    }

    @objc private func addFromField() {
        let raw = quickField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if let p = ReminderParser.parse(raw) {
            create(title: p.title, date: p.date, repeatMode: 0)
        } else {
            create(title: raw, date: Date().addingTimeInterval(3600), repeatMode: 0)
            onStatus?("Heure non comprise : rappel posé dans une heure.")
        }
    }

    private func create(title: String, date: Date, repeatMode: Int) {
        let r = ReminderStore.shared.add(title: title, at: date, repeatMode: repeatMode)
        quickField.stringValue = ""
        refresh()
        onChanged?()
        onStatus?("Rappel « \(r.title) » \(r.whenLabel)")
    }

    func refresh() {
        let items = ReminderStore.shared.items
        countTile.set("\(items.count)", hint: items.isEmpty ? "aucun rappel" : "rappels actifs")
        if let n = ReminderStore.shared.next() {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = "HH'h'mm"
            nextTile.set(f.string(from: n.date), hint: n.title)
            hero.set(subtitle: "Prochain : \(n.title), \(n.whenLabel).", trailing: "\(items.count)")
        } else {
            nextTile.set("—", hint: "rien de prévu")
            hero.set(subtitle: "Aucun rappel programmé.", trailing: "")
        }

        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        ThemeRegistry.shared.prune()

        let W = scroll.bounds.width - 6
        let rowH: CGFloat = 56
        let totalH = max(scroll.bounds.height, CGFloat(items.count) * rowH)
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: totalH)

        let now = Date().timeIntervalSince1970
        for (i, r) in items.enumerated() {
            let y = totalH - CGFloat(i + 1) * rowH + 6
            let row = mkCard(listHost, NSRect(x: 0, y: y, width: W, height: rowH - 10), radius: 12)
            rows.append(row)
            let rh = row.bounds.height
            let late = r.fireAt <= now

            let iv = mkIcon(row, late ? "bell.badge.fill" : "bell.fill", x: 14, y: rh / 2 - 8, size: 14, alpha: 0.55)
            if late { iv.contentTintColor = warnColor }

            row.addSubview(mkFitLabel(r.title, x: 40, y: rh - 28, 12.5, .semibold))
            row.addSubview(mkFitLabel("\(r.whenLabel) · \(r.repeatLabel)", x: 40, y: 8, 10.5, .regular, alpha: 0.45))

            let bDone = GlassButton(frame: NSRect(x: W - 176, y: rh / 2 - 16, width: 82, height: 32),
                                    title: "Terminé", compact: true)
            bDone.onClick = { [weak self] _ in
                ReminderStore.shared.complete(id: r.id)
                self?.refresh()
                self?.onChanged?()
            }
            let bDel = GlassButton(frame: NSRect(x: W - 88, y: rh / 2 - 16, width: 80, height: 32),
                                   title: "Supprimer", compact: true)
            bDel.destructive = true
            bDel.onClick = { [weak self] _ in
                ReminderStore.shared.remove(id: r.id)
                self?.refresh()
                self?.onChanged?()
            }
            [bDone, bDel].forEach { row.addSubview($0) }
        }
    }
}
EOF_BUDREMINDERS_SWIFT

cat << 'EOF_BUDSNIPPETS_SWIFT' > "$SRC_DIR/BudSnippets.swift"
import Cocoa
import Carbon.HIToolbox

// ═══════════════════════════════════════════════════════════
//  Dictée rapide, snippets et notes éclair
//  Persistance : snippets.json + quicknotes.md dans Application Support
// ═══════════════════════════════════════════════════════════

struct Snippet: Codable {
    var title: String
    var body: String
}

final class SnippetStore {
    static let shared = SnippetStore()
    private let url = budSupportDir.appendingPathComponent("snippets.json")
    private(set) var items: [Snippet] = []

    init() { load() }

    func load() {
        if let d = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode([Snippet].self, from: d) {
            items = s
        } else {
            items = [
                Snippet(title: "Signature", body: "Bien à toi,\nLahbib"),
                Snippet(title: "Disponibilités", body: "Je suis disponible cette semaine, dis-moi ce qui t'arrange."),
                Snippet(title: "Relance douce", body: "Petit rappel au sujet de ma demande précédente, merci d'avance.")
            ]
            save()
        }
    }

    func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? e.encode(items) { try? d.write(to: url, options: .atomic) }
    }

    func add(_ s: Snippet) { items.insert(s, at: 0); save() }
    func remove(at i: Int) { guard items.indices.contains(i) else { return }; items.remove(at: i); save() }
    func update(_ i: Int, _ s: Snippet) { guard items.indices.contains(i) else { return }; items[i] = s; save() }
}

/// Journal des captures rapides, en Markdown lisible hors de l'app.
final class QuickNotesStore {
    static let shared = QuickNotesStore()
    let url = budSupportDir.appendingPathComponent("quicknotes.md")

    func append(_ text: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let entry = "\n- **\(f.string(from: Date()))** — \(text.replacingOccurrences(of: "\n", with: "  \n  "))\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(entry.data(using: .utf8)!)
            try? h.close()
        } else {
            let header = "# Notes rapides BUD\n"
            try? (header + entry).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func recent(_ n: Int) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- **") }
            .suffix(n).reversed()
            .map { $0.replacingOccurrences(of: "- **", with: "").replacingOccurrences(of: "** — ", with: " · ") }
    }
}

// ── Collage dans l'app active (nécessite l'accès Accessibilité) ──

func accessibilityGranted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

@discardableResult
func pasteIntoFrontApp() -> Bool {
    guard accessibilityGranted(prompt: false) else { return false }
    guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
    let v = CGKeyCode(kVK_ANSI_V)
    let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    return true
}

/// Tente de déclencher la dictée système (raccourci « appuyer deux fois sur Fn »).
@discardableResult
func triggerSystemDictation() -> Bool {
    guard accessibilityGranted(prompt: true) else { return false }
    guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
    let fn = CGKeyCode(kVK_Function)
    for _ in 0..<2 {
        CGEvent(keyboardEventSource: src, virtualKey: fn, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: fn, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    return true
}

// ── Fenêtre de capture rapide ──

final class CaptureWindow: NSPanel, NSTextViewDelegate {
    private var textView: NSTextView!
    private var hintLabel: NSTextField!
    var onSubmit: ((String, CaptureTarget) -> Void)?

    enum CaptureTarget { case clipboard, note, snippet }

    init() {
        let size = NSSize(width: 520, height: 196)
        let sf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let origin = NSPoint(x: sf.midX - size.width / 2, y: sf.midY - size.height / 2 + 80)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        build(size)
    }

    override var canBecomeKey: Bool { true }

    private func build(_ size: NSSize) {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        contentView = host

        let blur = NSVisualEffectView(frame: host.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.masksToBounds = true
        host.addSubview(blur)

        let bg = NSView(frame: host.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.backgroundColor = TH.base.withAlphaComponent(TH.glass == 0 ? 1 : 0.55).cgColor
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = TH.fill(0.12).cgColor
        host.addSubview(bg)

        host.addSubview(mkLabel("Capture rapide", NSRect(x: 22, y: size.height - 36, width: 300, height: 20), 14, .bold))
        hintLabel = mkLabel("⏎ copier · ⇧⏎ note · Échap fermer",
                            NSRect(x: size.width - 262, y: size.height - 34, width: 240, height: 16),
                            10.5, .medium, alpha: 0.4, .right)
        host.addSubview(hintLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 60, width: size.width - 40, height: size.height - 108))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true

        let big: CGFloat = 1_000_000
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width - 40, height: size.height - 108))
        tv.minSize = NSSize(width: 0, height: size.height - 108)
        tv.maxSize = NSSize(width: big, height: big)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: size.width - 40, height: big)
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = true
        tv.backgroundColor = TH.fill(0.07)
        tv.textColor = TH.text
        tv.insertionPointColor = TH.text
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.delegate = self
        scroll.documentView = tv
        textView = tv
        host.addSubview(scroll)

        let bw = (size.width - 52) / 4
        let b1 = GlassButton(frame: NSRect(x: 20, y: 16, width: bw, height: 34),
                             title: "Copier", icon: "doc.on.doc.fill", prominent: true, compact: true)
        b1.onClick = { [weak self] _ in self?.submit(.clipboard) }
        let b2 = GlassButton(frame: NSRect(x: 24 + bw, y: 16, width: bw, height: 34),
                             title: "Note", icon: "note.text", compact: true)
        b2.onClick = { [weak self] _ in self?.submit(.note) }
        let b3 = GlassButton(frame: NSRect(x: 28 + bw * 2, y: 16, width: bw, height: 34),
                             title: "Snippet", icon: "text.badge.plus", compact: true)
        b3.onClick = { [weak self] _ in self?.submit(.snippet) }
        let b4 = GlassButton(frame: NSRect(x: 32 + bw * 3, y: 16, width: bw, height: 34),
                             title: "Dicter", icon: "mic.fill", compact: true)
        b4.onClick = { [weak self] _ in self?.dictate() }
        [b1, b2, b3, b4].forEach { host.addSubview($0) }
    }

    func present() {
        textView.string = ""
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(textView)
    }

    private func dictate() {
        makeFirstResponder(textView)
        if !triggerSystemDictation() {
            hintLabel.stringValue = "Autorise BUD dans Confidentialité → Accessibilité"
        } else {
            hintLabel.stringValue = "Parle… (ou appuie deux fois sur Fn)"
        }
    }

    private func submit(_ target: CaptureTarget) {
        let t = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        orderOut(nil)
        guard !t.isEmpty else { return }
        onSubmit?(t, target)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            submit(NSEvent.modifierFlags.contains(.shift) ? .note : .clipboard)
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            orderOut(nil)
            return true
        }
        return false
    }
}

/// Panneau Dictée & snippets.
final class SnippetsPanelView: NSView {
    private let hero: HeroHeader
    private var rows: [NSView] = []
    private let listHost = NSView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var statusLabel: NSTextField!

    var onStatus: ((String) -> Void)?
    var onCapture: (() -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Dictée & snippets",
                          subtitle: "⌘⌥D ouvre la capture, où que vous soyez.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        addSubview(hero)

        let bCap = GlassButton(frame: NSRect(x: 0, y: H - 148, width: W * 0.54 - 6, height: 44),
                               title: "Capture rapide  ⌘⌥D", icon: "mic.fill", prominent: true)
        bCap.onClick = { [weak self] _ in self?.onCapture?() }
        let bNew = GlassButton(frame: NSRect(x: W * 0.54 + 6, y: H - 148, width: W * 0.46 - 6, height: 44),
                               title: "Nouveau snippet", icon: "plus")
        bNew.onClick = { [weak self] _ in self?.editSnippet(nil) }
        [bCap, bNew].forEach { addSubview($0) }

        mkSection(self, H - 174, W, "Snippets enregistrés")

        scroll.frame = NSRect(x: 0, y: 44, width: W, height: H - 226)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        statusLabel = mkLabel("Un clic copie le snippet dans le presse-papiers.",
                              NSRect(x: 0, y: 8, width: W, height: 18), 11, .regular, alpha: 0.4, .center)
        addSubview(statusLabel)
    }

    func setStatus(_ s: String) { statusLabel.stringValue = s }

    func refresh() {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        ThemeRegistry.shared.prune()

        let items = SnippetStore.shared.items
        hero.set(trailing: items.isEmpty ? "" : "\(items.count) snippets")

        let W = scroll.bounds.width - 6
        let rowH: CGFloat = 62
        let totalH = max(scroll.bounds.height, CGFloat(items.count) * rowH)
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: totalH)

        for (i, s) in items.enumerated() {
            let y = totalH - CGFloat(i + 1) * rowH + 6
            let row = mkCard(listHost, NSRect(x: 0, y: y, width: W, height: rowH - 10), radius: 12)
            rows.append(row)
            let rh = row.bounds.height

            mkIcon(row, "text.quote", x: 14, y: rh - 28, size: 13, alpha: 0.55)
            row.addSubview(mkFitLabel(s.title, x: 38, y: rh - 28, 12.5, .semibold))

            let preview = s.body.replacingOccurrences(of: "\n", with: " · ")
            let prev = mkLabel(String(preview.prefix(90)), NSRect(x: 38, y: 8, width: W - 200, height: 15),
                               10.5, .regular, alpha: 0.42)
            row.addSubview(prev)

            let copy = GlassButton(frame: NSRect(x: W - 190, y: 10, width: 76, height: 32),
                                   title: "Copier", compact: true)
            copy.idx = i
            copy.onClick = { [weak self] b in self?.copySnippet(b.idx) }
            let edit = GlassButton(frame: NSRect(x: W - 108, y: 10, width: 54, height: 32),
                                   title: "", icon: "pencil", compact: true)
            edit.idx = i
            edit.onClick = { [weak self] b in self?.editSnippet(b.idx) }
            let del = GlassButton(frame: NSRect(x: W - 48, y: 10, width: 44, height: 32),
                                  title: "", icon: "trash", compact: true)
            del.destructive = true
            del.idx = i
            del.onClick = { [weak self] b in
                SnippetStore.shared.remove(at: b.idx)
                self?.refresh()
            }
            [copy, edit, del].forEach { row.addSubview($0) }
        }
    }

    private func copySnippet(_ i: Int) {
        guard SnippetStore.shared.items.indices.contains(i) else { return }
        let s = SnippetStore.shared.items[i]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.body, forType: .string)
        onStatus?("« \(s.title) » copié dans le presse-papiers")
    }

    private func editSnippet(_ i: Int?) {
        let existing = i.flatMap { SnippetStore.shared.items.indices.contains($0) ? SnippetStore.shared.items[$0] : nil }
        let a = NSAlert()
        a.messageText = existing == nil ? "Nouveau snippet" : "Modifier le snippet"
        a.informativeText = "Un titre court, puis le contenu à coller."
        a.addButton(withTitle: "Enregistrer")
        a.addButton(withTitle: "Annuler")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        let titleField = NSTextField(frame: NSRect(x: 0, y: 110, width: 380, height: 24))
        titleField.placeholderString = "Titre"
        titleField.stringValue = existing?.title ?? ""
        container.addSubview(titleField)

        let sc = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 100))
        sc.hasVerticalScroller = true
        sc.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 100))
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 12.5)
        tv.string = existing?.body ?? ""
        sc.documentView = tv
        container.addSubview(sc)
        a.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = tv.string
        guard !title.isEmpty || !body.isEmpty else { return }
        let s = Snippet(title: title.isEmpty ? String(body.prefix(24)) : title, body: body)
        if let idx = i { SnippetStore.shared.update(idx, s) } else { SnippetStore.shared.add(s) }
        refresh()
    }
}
EOF_BUDSNIPPETS_SWIFT

cat << 'EOF_BUDSTORAGE_SWIFT' > "$SRC_DIR/BudStorage.swift"
import Cocoa

// ═══════════════════════════════════════════════════════════
//  Stockage interne et externe
// ═══════════════════════════════════════════════════════════

struct VolumeInfo {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isBoot: Bool

    var used: Int64 { max(0, total - free) }
    var usedRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var freePercent: Int { total > 0 ? Int((Double(free) / Double(total)) * 100.0) : 0 }
    var icon: String {
        if isBoot { return "internaldrive.fill" }
        if isRemovable { return "externaldrive.fill" }
        return isInternal ? "internaldrive" : "externaldrive.connected.to.line.below"
    }
    var tag: String {
        if isBoot { return "Démarrage" }
        if isRemovable { return "Externe" }
        return isInternal ? "Interne" : "Réseau"
    }
}

func scanVolumes() -> [VolumeInfo] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                  .volumeAvailableCapacityForImportantUsageKey,
                                  .volumeAvailableCapacityKey,
                                  .volumeIsRemovableKey, .volumeIsEjectableKey,
                                  .volumeIsInternalKey, .volumeIsBrowsableKey]
    let fm = FileManager.default
    guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                          options: [.skipHiddenVolumes]) else { return [] }
    var out: [VolumeInfo] = []
    for u in urls {
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
        guard v.volumeIsBrowsable ?? true else { continue }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        guard total > 0 else { continue }
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        let removable = (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)
        out.append(VolumeInfo(url: u,
                              name: v.volumeName ?? u.lastPathComponent,
                              total: total,
                              free: max(0, free),
                              isInternal: (v.volumeIsInternal ?? false) && !removable,
                              isRemovable: removable,
                              isBoot: u.path == "/"))
    }
    return out.sorted { a, b in
        if a.isBoot != b.isBoot { return a.isBoot }
        if a.isInternal != b.isInternal { return a.isInternal }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

func bootVolume() -> VolumeInfo? {
    let v = scanVolumes()
    return v.first { $0.isBoot } ?? v.first
}

final class StoragePanelView: NSView {

    private let hero: HeroHeader
    private let ring = GaugeRing(frame: .zero)
    private var tileFree: StatTile!, tileUsed: StatTile!, tileTotal: StatTile!, tileCount: StatTile!
    private var vitalCpu: NSTextField!, vitalMem: NSTextField!, vitalUp: NSTextField!
    private let scroll = NSScrollView(frame: .zero)
    private let listHost = NSView(frame: .zero)
    private var rowViews: [NSView] = []

    var onEject: ((String) -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Stockage", subtitle: "Vos disques internes et externes, en un coup d'œil.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        addSubview(hero)

        ring.frame = NSRect(x: W - 116, y: H - 86, width: 80, height: 80)
        addSubview(ring)

        let gap: CGFloat = 12
        let tw = (W - gap * 3) / 4
        let ty = H - 184
        tileFree  = StatTile(frame: NSRect(x: 0, y: ty, width: tw, height: 78), caption: "Libre")
        tileUsed  = StatTile(frame: NSRect(x: tw + gap, y: ty, width: tw, height: 78), caption: "Occupé")
        tileTotal = StatTile(frame: NSRect(x: (tw + gap) * 2, y: ty, width: tw, height: 78), caption: "Capacité")
        tileCount = StatTile(frame: NSRect(x: (tw + gap) * 3, y: ty, width: tw, height: 78), caption: "Volumes")
        [tileFree, tileUsed, tileTotal, tileCount].forEach { addSubview($0) }

        mkSection(self, H - 208, W, "Volumes")

        scroll.frame = NSRect(x: 0, y: 96, width: W, height: H - 312)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = listHost
        addSubview(scroll)

        // Constantes du Mac
        let cw = (W - 24) / 3
        vitalCpu = mkStatRow(self, 52, 0, cw, "cpu", "CPU")
        vitalMem = mkStatRow(self, 52, cw + 12, cw, "memorychip", "RAM")
        vitalUp  = mkStatRow(self, 52, (cw + 12) * 2, cw, "clock.arrow.circlepath", "Veille")

        let b1 = GlassButton(frame: NSRect(x: 0, y: 0, width: cw, height: 40),
                             title: "Actualiser", icon: "arrow.clockwise")
        b1.onClick = { [weak self] _ in self?.refresh(animated: true) }
        let b2 = GlassButton(frame: NSRect(x: cw + 12, y: 0, width: cw, height: 40),
                             title: "Volumes", icon: "folder.fill")
        b2.onClick = { _ in NSWorkspace.shared.open(URL(fileURLWithPath: "/Volumes")) }
        let b3 = GlassButton(frame: NSRect(x: (cw + 12) * 2, y: 0, width: cw, height: 40),
                             title: "Tout éjecter", icon: "eject.fill")
        b3.onClick = { [weak self] _ in
            guard let s = self else { return }
            s.onEject?(s.ejectAll())
        }
        [b1, b2, b3].forEach { addSubview($0) }
    }

    func stepRing() { ring.step() }

    func refresh(animated: Bool = false) {
        let vols = scanVolumes()

        if let boot = vols.first(where: { $0.isBoot }) ?? vols.first {
            let pct = Int((boot.usedRatio * 100).rounded())
            ring.set(pct, caption: "occupé", animated: animated)
            tileFree.set(formatBytes(boot.free), hint: "\(boot.freePercent) % encore libres")
            tileUsed.set(formatBytes(boot.used), hint: "\(pct) % du disque")
            tileTotal.set(formatBytes(boot.total), hint: "disque de démarrage")
            hero.set(subtitle: "\(boot.name) · \(formatBytes(boot.free)) encore disponibles",
                     trailing: boot.freePercent <= 10 ? "Disque saturé" : "")
        }
        let ext = vols.filter { !$0.isBoot }.count
        tileCount.set("\(vols.count)", hint: ext == 0 ? "aucun volume externe" : "\(ext) en plus du démarrage")

        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        ThemeRegistry.shared.prune()

        let rowH: CGFloat = 64
        let W = scroll.bounds.width - 6
        let totalH = max(scroll.bounds.height, CGFloat(vols.count) * rowH)
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: totalH)

        for (i, v) in vols.enumerated() {
            let y = totalH - CGFloat(i + 1) * rowH + 6
            let row = mkCard(listHost, NSRect(x: 0, y: y, width: W, height: rowH - 10), radius: 12)
            rowViews.append(row)
            let rh = row.bounds.height           // 54

            // Colonne droite : pourcentage puis bouton, largeurs mesurées
            let pctTxt = "\(Int((v.usedRatio * 100).rounded())) %"
            let pctW = textWidth(pctTxt, size: 14, weight: .bold, mono: true) + 10
            let ejectable = v.isRemovable || (!v.isInternal && !v.isBoot)
            let btnTitle = ejectable ? "Éjecter" : "Ouvrir"
            let btnW = max(74, textWidth(btnTitle, size: 11.5, weight: .semibold) + 26)
            let rightEdge = W - 12 - btnW - 10 - pctW

            // Ligne 1 : icône, nom, étiquette de type
            let iv = mkIcon(row, v.icon, x: 13, y: rh - 22, size: 15, alpha: 0.6)
            if v.isRemovable { iv.contentTintColor = TH.accent }

            let tagW = textWidth(v.tag, size: 9.5, weight: .semibold) + 16
            let nameMax = rightEdge - 38 - tagW - 14
            var name = v.name
            if textWidth(name, size: 12.5, weight: .semibold) > nameMax {
                while name.count > 4 && textWidth(name + "…", size: 12.5, weight: .semibold) > nameMax {
                    name.removeLast()
                }
                name += "…"
            }
            let nameW = textWidth(name, size: 12.5, weight: .semibold) + 10
            row.addSubview(mkLabel(name, NSRect(x: 37, y: rh - 22, width: nameW, height: 18), 12.5, .semibold))

            let tagRect = NSRect(x: 37 + nameW + 4, y: rh - 21, width: tagW, height: 16)
            let tagView = mkCard(row, tagRect, radius: 8, alpha: 0.09)
            tagView.addSubview(mkLabel(v.tag, NSRect(x: 0, y: 0, width: tagW, height: 14),
                                       9.5, .semibold, alpha: 0.55, .center))

            // Ligne 2 : barre puis volumétrie, bien séparées du nom
            let bar = ProgressBar(frame: NSRect(x: 37, y: 23, width: rightEdge - 45, height: 5))
            bar.value = CGFloat(v.usedRatio)
            bar.tint = v.freePercent <= 10 ? dangerColor : (v.freePercent <= 20 ? warnColor : nil)
            row.addSubview(bar)

            let detail = "\(formatBytes(v.free)) libres sur \(formatBytes(v.total))"
            row.addSubview(mkLabel(detail, NSRect(x: 37, y: 3, width: rightEdge - 45, height: 15),
                                   10.5, .regular, alpha: 0.5))

            row.addSubview(mkLabel(pctTxt, NSRect(x: rightEdge, y: rh / 2 - 9, width: pctW, height: 19),
                                   14, .bold, alpha: 1, .right, mono: true))

            let action = GlassButton(frame: NSRect(x: W - 12 - btnW, y: rh / 2 - 16, width: btnW, height: 32),
                                     title: btnTitle, compact: true)
            let url = v.url
            if ejectable {
                action.onClick = { [weak self] _ in self?.eject(url) }
            } else {
                action.onClick = { _ in NSWorkspace.shared.open(url) }
            }
            row.addSubview(action)
        }

        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        vitalCpu.stringValue = String(format: "%.2f", l[0])
        let m = memoryStats()
        vitalMem.stringValue = m.total > 0 ? String(format: "%.1f Go", m.used / 1_073_741_824) : "—"
        vitalUp.stringValue = formatUptime(ProcessInfo.processInfo.systemUptime)
    }

    /// Éjecte tous les volumes amovibles ou réseau. Renvoie un compte rendu.
    @discardableResult
    func ejectAll() -> String {
        let candidates = scanVolumes().filter { !$0.isBoot && ($0.isRemovable || !$0.isInternal) }
        guard !candidates.isEmpty else { return "Aucun disque externe monté." }
        var done: [String] = []
        var failed: [String] = []
        for v in candidates {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
                done.append(v.name)
            } catch {
                failed.append(v.name)
            }
        }
        refresh()
        if done.isEmpty { return "Éjection refusée : \(failed.joined(separator: ", ")) est encore utilisé." }
        var msg = "Éjecté : \(done.joined(separator: ", "))"
        if !failed.isEmpty { msg += " · encore occupé : \(failed.joined(separator: ", "))" }
        return msg
    }

    private func eject(_ url: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            onEject?("\(url.lastPathComponent) éjecté proprement")
        } catch {
            onEject?("Impossible d'éjecter \(url.lastPathComponent)")
        }
        refresh()
    }
}
EOF_BUDSTORAGE_SWIFT

cat << 'EOF_BUDUI_SWIFT' > "$SRC_DIR/BudUI.swift"
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
func mkCard(_ parent: NSView, _ f: NSRect, radius: CGFloat = 14, alpha: CGFloat = 0.06) -> NSView {
    let v = NSView(frame: f)
    v.wantsLayer = true
    v.layer?.cornerRadius = radius
    v.layer?.backgroundColor = TH.fill(alpha).cgColor
    parent.addSubview(v)
    ThemeRegistry.shared.register(box: v, alpha: alpha)
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
    parent.addSubview(mkLabel(t.uppercased(), NSRect(x: 2, y: y, width: w, height: 14), 9.5, .bold, alpha: 0.32))
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
        let path = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
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
                   size: 22, weight: .bold, color: TH.text)
        drawString(subtitleText, in: NSRect(x: 22, y: r.height - 74, width: r.width - 160, height: 20),
                   size: 12, weight: .medium, color: TH.dim(0.6))
        if !trailing.isEmpty {
            let w = textWidth(trailing, size: 11.5, weight: .semibold) + 26
            let cap = NSRect(x: r.maxX - w - 18, y: r.height - 44, width: w, height: 26)
            TH.fill(0.12).setFill()
            capsule(cap).fill()
            drawString(trailing, in: NSRect(x: cap.minX, y: cap.midY - 8, width: cap.width, height: 16),
                       size: 11.5, weight: .semibold, color: TH.text, align: .center)
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  Boutons
// ═══════════════════════════════════════════════════════════

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
        let tint = destructive ? dangerColor : TH.accent

        if !enabledFlag {
            TH.fill(0.04).setFill()
            path.fill()
        } else if prominent || selected {
            let top = tint.blended(withFraction: 0.16, of: NSColor.white) ?? tint
            let bottom = tint.blended(withFraction: 0.14, of: NSColor.black) ?? tint
            if let g = NSGradient(starting: top, ending: bottom) { g.draw(in: path, angle: -90) }
            else { tint.setFill(); path.fill() }
            if hoverT > 0.01 {
                NSColor.white.withAlphaComponent(0.10 * hoverT).setFill()
                path.fill()
            }
        } else {
            TH.fill(0.07 + 0.07 * hoverT + 0.06 * pressT).setFill()
            path.fill()
            let gloss = NSBezierPath(roundedRect: NSRect(x: r.minX + 6, y: r.midY + 1,
                                                         width: max(1, r.width - 12),
                                                         height: max(1, r.height / 2 - 2)),
                                     xRadius: r.height / 3, yRadius: r.height / 3)
            TH.fill(0.04 + 0.03 * hoverT).setFill()
            gloss.fill()
            TH.fill(0.10 + 0.10 * hoverT).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let fg: NSColor = !enabledFlag ? TH.dim(0.25)
                        : ((prominent || selected) ? TH.onAccent : (destructive ? dangerColor : TH.text))
        let fontSize: CGFloat = compact ? 11.5 : 12
        let tw = textWidth(title, size: fontSize, weight: .semibold)

        if title.isEmpty {
            if let icon = iconName {
                drawSymbol(icon, center: NSPoint(x: r.midX, y: r.midY), size: compact ? 12 : 13,
                           weight: .semibold, color: fg)
            }
            return
        }

        if alignLeft {
            var x = r.minX + 14
            if let icon = iconName {
                drawSymbol(icon, center: NSPoint(x: x + 7, y: r.midY), size: compact ? 12 : 13,
                           weight: .semibold, color: fg)
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
                           weight: .semibold, color: fg)
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
        sprite.draw(in: bounds.insetBy(dx: 1, dy: 1), detail: bounds.width >= 40,
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
    var chips: [(String, String)] = []
    var progress: CGFloat = 0
    var badge: NSColor?
    var alertCount = 0
    var dropActive = false { didSet { needsDisplay = true } }
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    let sprite = BudSprite()
    private var phase: CGFloat = 0, dash: CGFloat = 0
    private var frames = 0

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
    override func mouseUp(with e: NSEvent) { if state != .open { onClick?() } }

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
        let r = budRect()
        var dirty = sprite.step(follow: follow, in: self, anchor: NSPoint(x: r.midX, y: r.midY))
        if dropActive || state != .collapsed { dirty = true }
        if state == .collapsed && frames % 2 == 0 { dirty = true }
        if dirty && state != .open { needsDisplay = true }
    }

    func wave() { sprite.wave() }
    func poke() { sprite.poke() }

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
            sprite.draw(in: budRect(), detail: false,
                        glowColor: alertCount > 0 ? warnColor : TH.accent)
            let t = clockString()
            let tw = textWidth(t, size: 12.5, weight: .semibold, mono: true)
            drawString(t, in: NSRect(x: b.midX - tw / 2 + 6, y: b.midY - 8, width: tw + 2, height: 17),
                       size: 12.5, weight: .semibold, color: TH.text, mono: true)
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
        sprite.draw(in: budRect(), detail: true,
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

        if !chips.isEmpty {
            let gap: CGFloat = 8
            let cw = (b.width - 44 - gap * CGFloat(chips.count - 1)) / CGFloat(chips.count)
            for (i, chip) in chips.enumerated() {
                let r = NSRect(x: 22 + CGFloat(i) * (cw + gap), y: top - 128, width: cw, height: 28)
                TH.fill(0.09).setFill()
                capsule(r).fill()
                let sp = capsule(r)
                TH.fill(0.07).setStroke()
                sp.lineWidth = 1
                sp.stroke()
                drawSymbol(chip.0, center: NSPoint(x: r.minX + 17, y: r.midY), size: 11.5,
                           weight: .semibold, color: TH.dim(0.68))
                let maxW = r.width - 32
                drawString(chip.1, in: NSRect(x: r.minX + 28, y: r.midY - 8, width: maxW, height: 16),
                           size: 11.5, weight: .semibold, color: TH.text, mono: true)
            }
        }

        drawString("Cliquer pour ouvrir · déposer des fichiers ici",
                   in: NSRect(x: 0, y: 8, width: b.width, height: 14),
                   size: 9.5, weight: .medium, color: TH.dim(0.26), align: .center)
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
        let container = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        TH.fill(0.05).setFill()
        container.fill()
        TH.fill(0.09).setStroke()
        container.lineWidth = 1
        container.stroke()

        let w = r.width / CGFloat(items.count)
        for (i, it) in items.enumerated() {
            let cell = NSRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: w, height: r.height).insetBy(dx: 3, dy: 3)
            if i == selected {
                TH.fill(0.16).setFill()
                NSBezierPath(roundedRect: cell, xRadius: 9.5, yRadius: 9.5).fill()
                TH.accent.withAlphaComponent(0.35).setStroke()
                let p = NSBezierPath(roundedRect: cell, xRadius: 9.5, yRadius: 9.5)
                p.lineWidth = 1
                p.stroke()
            } else if i == hoverIndex {
                TH.fill(0.07).setFill()
                NSBezierPath(roundedRect: cell, xRadius: 9.5, yRadius: 9.5).fill()
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
EOF_BUDUI_SWIFT

cat << 'EOF_BUDUPDATE_SWIFT' > "$SRC_DIR/BudUpdate.swift"
import Cocoa

// ═══════════════════════════════════════════════════════════
//  Vérification de mise à jour
//  BUD interroge un petit fichier JSON hébergé où vous voulez :
//  { "version": "14.1", "notes": "…", "url": "https://…/Installer.command" }
// ═══════════════════════════════════════════════════════════

struct UpdateInfo {
    let version: String
    let notes: String
    let url: String
}

enum BudUpdater {

    static let defaultChannel =
        "https://raw.githubusercontent.com/Lahbib-colab/bud-premium/main/version.json"

    /// Compare « 14.10 » et « 14.9 » correctement, segment par segment.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func check(_ channel: String, done: @escaping (UpdateInfo?, String?) -> Void) {
        guard let url = URL(string: channel) else {
            done(nil, "adresse de canal invalide")
            return
        }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let e = err { done(nil, e.localizedDescription); return }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    done(nil, "canal introuvable (code \(http.statusCode))")
                    return
                }
                guard let d = data,
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let v = j["version"] as? String else {
                    done(nil, "fichier de version illisible")
                    return
                }
                done(UpdateInfo(version: v,
                                notes: j["notes"] as? String ?? "",
                                url: j["url"] as? String ?? ""), nil)
            }
        }.resume()
    }
}

/// Carte « À propos » : version, signature, et vérification animée.
final class UpdateCardView: NSView {

    enum Phase { case idle, checking, upToDate, available, failed }

    private var phase: Phase = .idle
    private var spin: CGFloat = 0
    private var pop: CGFloat = 0           // rebond du résultat
    private var pulse: CGFloat = 0
    private var timer: Timer?
    private var message = "Vérifiez si une nouvelle version existe."
    private var found: UpdateInfo?
    private var actionBtn: GlassButton!
    private var channelBtn: GlassButton!

    var channel: () -> String = { BudUpdater.defaultChannel }
    var onChannelEdit: (() -> Void)?
    var onStatus: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        actionBtn = GlassButton(frame: NSRect(x: W - 232, y: H / 2 - 18, width: 118, height: 36),
                                title: "Vérifier", icon: "arrow.triangle.2.circlepath", compact: true)
        actionBtn.onClick = { [weak self] _ in self?.primaryAction() }
        channelBtn = GlassButton(frame: NSRect(x: W - 106, y: H / 2 - 18, width: 98, height: 36),
                                 title: "Canal", icon: "antenna.radiowaves.left.and.right", compact: true)
        channelBtn.onClick = { [weak self] _ in self?.onChannelEdit?() }
        [actionBtn, channelBtn].forEach { addSubview($0) }
    }

    private func startTicking() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] tm in
            guard let s = self else { tm.invalidate(); return }
            s.spin += s.phase == .checking ? 0.22 : 0
            s.pulse += 0.06
            if s.pop > 0 { s.pop = max(0, s.pop - 0.035) }
            if s.phase != .checking && s.pop == 0 {
                tm.invalidate()
                s.timer = nil
            }
            s.needsDisplay = true
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func primaryAction() {
        if phase == .available, let f = found, let u = URL(string: f.url), !f.url.isEmpty {
            NSWorkspace.shared.open(u)
            onStatus?("Téléchargement de la version \(f.version)")
            return
        }
        check()
    }

    func check(silent: Bool = false) {
        guard phase != .checking else { return }
        phase = .checking
        pop = 0
        message = "Interrogation du canal de mise à jour…"
        actionBtn.title = "Vérification"
        actionBtn.enabledFlag = false
        startTicking()
        needsDisplay = true

        BudUpdater.check(channel()) { [weak self] info, err in
            guard let s = self else { return }
            s.actionBtn.enabledFlag = true
            s.pop = 1
            s.startTicking()
            if let e = err {
                s.phase = .failed
                s.message = "Canal injoignable : \(e)"
                s.actionBtn.title = "Réessayer"
                if !silent { s.onStatus?("Mise à jour : canal injoignable") }
            } else if let i = info, BudUpdater.isNewer(i.version, than: budVersion) {
                s.phase = .available
                s.found = i
                s.message = "Version \(i.version) disponible" + (i.notes.isEmpty ? "" : " · \(i.notes)")
                s.actionBtn.title = "Télécharger"
                s.actionBtn.iconName = "arrow.down.circle.fill"
                s.actionBtn.prominent = true
                s.onStatus?("BUD \(i.version) disponible")
            } else {
                s.phase = .upToDate
                s.message = "BUD \(budVersion) est à jour."
                s.actionBtn.title = "Vérifier"
                s.actionBtn.iconName = "arrow.triangle.2.circlepath"
                s.actionBtn.prominent = false
                if !silent { s.onStatus?("BUD est à jour") }
            }
            s.needsDisplay = true
        }
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let card = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        TH.fill(0.05).setFill()
        card.fill()
        TH.fill(0.08).setStroke()
        card.lineWidth = 1
        card.stroke()

        // Pastille animée à gauche
        let c = NSPoint(x: r.minX + 40, y: r.midY)
        let radius: CGFloat = 19 + (phase == .checking ? CGFloat(sin(pulse * 2)) * 1.2 : 0)
        let tint: NSColor = phase == .available ? warnColor
                          : (phase == .failed ? dangerColor : TH.accent)

        tint.withAlphaComponent(0.14 + (pop * 0.18)).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()

        if phase == .checking {
            // Arc qui tourne
            let arc = NSBezierPath()
            let start = spin * 57.3
            arc.appendArc(withCenter: c, radius: radius - 3,
                          startAngle: start, endAngle: start + 250)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            tint.setStroke()
            arc.stroke()
        } else {
            let scale = 1 + pop * 0.35
            let icon = phase == .available ? "arrow.down.circle.fill"
                     : (phase == .failed ? "exclamationmark.triangle.fill"
                        : (phase == .upToDate ? "checkmark.circle.fill" : "sparkles"))
            drawSymbol(icon, center: c, size: 20 * scale, weight: .semibold, color: tint)
        }

        // Textes
        let textW = r.width - 80 - 240
        drawString("BUD Premium \(budVersion)",
                   in: NSRect(x: r.minX + 72, y: r.midY + 3, width: textW, height: 20),
                   size: 13.5, weight: .bold, color: TH.text)
        drawString(message, in: NSRect(x: r.minX + 72, y: r.midY - 17, width: textW, height: 18),
                   size: 11, weight: .medium, color: TH.dim(0.5))
    }
}
EOF_BUDUPDATE_SWIFT

cat << 'EOF_MAIN_SWIFT' > "$SRC_DIR/main.swift"
import Cocoa

// Point d'entrée : avec plusieurs fichiers, le code au niveau racine
// doit obligatoirement se trouver dans un fichier nommé main.swift.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let budDelegate = BudDelegate()
app.delegate = budDelegate
app.run()
EOF_MAIN_SWIFT

cat << 'EOF_MAKEICON_X9' > "$TOOLS_DIR/MakeIcon.swift"
import Cocoa

// Génère l'iconset de BUD : un squircle dégradé portant le visage du compagnon.
// Usage : budicon <dossier .iconset>

let accent = NSColor(calibratedRed: 0.22, green: 0.85, blue: 0.62, alpha: 1)
let accentDeep = NSColor(calibratedRed: 0.06, green: 0.42, blue: 0.36, alpha: 1)

/// Le corps du compagnon, identique à squirclePath() de BudFace.swift.
/// Dupliqué parce que ce générateur se compile seul.
func budSquircle(size: CGFloat, ratio: CGFloat = 0.30) -> NSBezierPath {
    let h = size / 2, r = size * ratio, k = r / 3
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

func squircle(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func renderIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!
    ctx.imageInterpolation = .high

    let u = size / 1024.0
    let pad = 92 * u
    let body = NSRect(x: pad, y: pad, width: size - pad * 2, height: size - pad * 2)
    let corner = body.width * 0.236

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 40 * u
    shadow.shadowOffset = NSSize(width: 0, height: -18 * u)
    ctx.saveGraphicsState()
    shadow.set()
    let shape = squircle(body, corner)
    let night = NSGradient(colors: [NSColor(calibratedWhite: 0.17, alpha: 1),
                                    NSColor(calibratedWhite: 0.04, alpha: 1)])
    night?.draw(in: shape, angle: -90)
    ctx.restoreGraphicsState()

    ctx.saveGraphicsState()
    shape.addClip()

    // Halo d'accent
    let haloR = body.width * 0.40
    NSGradient(colors: [accent.withAlphaComponent(0.50), accent.withAlphaComponent(0.0)])?
        .draw(in: NSBezierPath(ovalIn: NSRect(x: body.midX - haloR, y: body.midY - haloR * 0.95,
                                              width: haloR * 2, height: haloR * 2)),
              relativeCenterPosition: NSPoint(x: 0, y: 0))

    // ── Le compagnon : même squircle que dans l'application ──
    ctx.saveGraphicsState()
    ctx.cgContext.translateBy(x: body.midX, y: body.midY - body.height * 0.01)
    let s = body.width * 0.60

    let shell = budSquircle(size: s, ratio: 0.30)
    NSColor.white.setFill()
    shell.fill()

    // Liseré interne, comme le style à plat
    ctx.saveGraphicsState()
    shell.addClip()
    let ring = budSquircle(size: s, ratio: 0.30)
    ring.lineWidth = s * 0.065
    NSColor(calibratedRed: 0.847, green: 0.886, blue: 0.910, alpha: 0.85).setStroke()
    ring.stroke()
    ctx.restoreGraphicsState()

    // Joues
    NSColor(calibratedRed: 1.00, green: 0.710, blue: 0.710, alpha: 1).setFill()
    for side in [CGFloat(-1), CGFloat(1)] {
        NSBezierPath(ovalIn: NSRect(x: side * s * 0.235 - s * 0.072,
                                    y: -s * 0.095 - s * 0.041,
                                    width: s * 0.144, height: s * 0.082)).fill()
    }

    // Yeux
    let ink = NSColor(calibratedRed: 0.137, green: 0.152, blue: 0.200, alpha: 1)
    let eyeR = s * 0.044
    for side in [CGFloat(-1), CGFloat(1)] {
        let cxE = side * s * 0.145, cyE = -s * 0.012
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: cxE - eyeR, y: cyE - eyeR,
                                    width: eyeR * 2, height: eyeR * 2)).fill()
        NSColor.white.withAlphaComponent(0.72).setFill()
        let g = eyeR * 0.26
        NSBezierPath(ovalIn: NSRect(x: cxE - eyeR * 0.30 - g, y: cyE + eyeR * 0.30 - g,
                                    width: g * 2, height: g * 1.5)).fill()
    }

    // Bouche en « O » et langue rose
    let my = -s * 0.125, mw = s * 0.042, mh = s * 0.056
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: -mw, y: my - mh, width: mw * 2, height: mh * 2)).fill()
    ctx.saveGraphicsState()
    NSBezierPath(ovalIn: NSRect(x: -mw * 0.78, y: my - mh * 0.80,
                                width: mw * 1.56, height: mh * 1.60)).addClip()
    NSColor(calibratedRed: 1.00, green: 0.557, blue: 0.620, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: -mw * 0.72, y: my - mh * 0.90,
                                width: mw * 1.44, height: mh * 1.04)).fill()
    ctx.restoreGraphicsState()

    ctx.restoreGraphicsState()

    // Verre sur la moitié haute
    let gloss = NSBezierPath()
    gloss.move(to: NSPoint(x: body.minX, y: body.midY + body.height * 0.18))
    gloss.curve(to: NSPoint(x: body.maxX, y: body.midY + body.height * 0.32),
                controlPoint1: NSPoint(x: body.midX - body.width * 0.1, y: body.midY + body.height * 0.42),
                controlPoint2: NSPoint(x: body.midX + body.width * 0.1, y: body.midY + body.height * 0.12))
    gloss.line(to: NSPoint(x: body.maxX, y: body.maxY))
    gloss.line(to: NSPoint(x: body.minX, y: body.maxY))
    gloss.close()
    NSColor.white.withAlphaComponent(0.06).setFill()
    gloss.fill()
    ctx.restoreGraphicsState()

    accent.withAlphaComponent(0.28).setStroke()
    shape.lineWidth = 3 * u
    shape.stroke()

    img.unlockFocus()
    return img
}

func writePNG(_ img: NSImage, _ px: Int, _ url: URL) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    renderIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: url) }
}

let args = CommandLine.arguments
guard args.count > 1 else { exit(1) }
let out = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (px, name) in sizes {
    writePNG(NSImage(), px, out.appendingPathComponent(name))
}
print("iconset écrit : \(out.path)")
EOF_MAKEICON_X9

cat << 'EOF_BUDBUILD_7K2' > "$SUPPORT_DIR/build.sh"
#!/bin/bash
#
#  BUD Premium — compilation et installation
#
#  Usage :
#    ./build.sh            compile et installe dans ~/Applications, puis lance
#    ./build.sh check      compile seulement, sans rien installer (utilisé par la CI)
#    ./build.sh install    comme sans argument
#
#  Options :
#    --src DIR     dossier des sources Swift      (défaut : ./Sources)
#    --tools DIR   dossier des outils annexes     (défaut : ./Tools)
#    --app DIR     paquet .app à produire         (défaut : ~/Applications/BUD.app)
#    --no-open     ne pas lancer l'application à la fin
#
#  Ce fichier est le seul endroit où vit la logique de compilation.
#  L'installeur en un seul fichier (dist/) embarque les sources puis
#  appelle ce script : il n'y a donc rien à tenir en double.
#
set -euo pipefail

MODE="install"
SRC_DIR=""
TOOLS_DIR=""
APP_DIR="$HOME/Applications/BUD.app"
DO_OPEN=1

while [ $# -gt 0 ]; do
  case "$1" in
    check|install) MODE="$1"; shift ;;
    --src)   SRC_DIR="$2"; shift 2 ;;
    --tools) TOOLS_DIR="$2"; shift 2 ;;
    --app)   APP_DIR="$2"; shift 2 ;;
    --no-open) DO_OPEN=0; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "$SRC_DIR" ]   || SRC_DIR="$HERE/Sources"
[ -n "$TOOLS_DIR" ] || TOOLS_DIR="$HERE/Tools"

if [ ! -d "$SRC_DIR" ]; then
  echo "Sources introuvables : $SRC_DIR" >&2
  exit 1
fi

ARCH="$(uname -m)"
OSVER="$(sw_vers -productVersion 2>/dev/null || echo inconnue)"
VERSION="$(sed -n 's/^let budVersion = "\(.*\)"/\1/p' "$SRC_DIR/BudCore.swift" | head -1)"
[ -n "$VERSION" ] || VERSION="0.0"

# ─────────────────────────────────────────────────────────────────
#  Chaîne d'outils
#
#  swiftc est TOUJOURS appelé par xcrun, jamais par son chemin
#  résolu : c'est xcrun qui positionne SDKROOT. Sans lui, le
#  compilateur ne trouve pas la bibliothèque standard et échoue sur
#  « unable to load standard library ».
# ─────────────────────────────────────────────────────────────────

unset TOOLCHAINS || true          # une chaîne tierce sélectionnée fausserait tout

SWIFT_VIA="xcrun"
run_swiftc() {
  if [ "$SWIFT_VIA" = "plain" ]; then
    command swiftc "$@"
  else
    xcrun --sdk macosx swiftc "$@"
  fi
}

sdk_version() { xcrun --show-sdk-version 2>/dev/null || echo 0; }

if ! command -v swiftc >/dev/null 2>&1 && ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc est introuvable. Installez les outils : xcode-select --install" >&2
  exit 1
fi

SDKVER="$(sdk_version)"
SDKMAJ="${SDKVER%%.*}"
[ -n "$SDKMAJ" ] || SDKMAJ=0

# Outils antérieurs à Big Sur mais Xcode complet présent : on bascule
# dessus pour cette exécution, sans sudo ni modification du système.
if [ "$SDKMAJ" -ge 1 ] 2>/dev/null && [ "$SDKMAJ" -lt 11 ] 2>/dev/null; then
  for X in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$X/Contents/Developer" ]; then
      export DEVELOPER_DIR="$X/Contents/Developer"
      NEW="$(sdk_version)"; NEWMAJ="${NEW%%.*}"
      if [ "${NEWMAJ:-0}" -ge 11 ] 2>/dev/null; then
        SDKVER="$NEW"; SDKMAJ="$NEWMAJ"
        echo "Outils de ligne de commande trop anciens : bascule sur $X."
        break
      fi
      unset DEVELOPER_DIR
    fi
  done
fi

SDKPATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[ -n "$SDKPATH" ] && export SDKROOT="$SDKPATH"

echo "BUD Premium $VERSION — macOS ${OSVER} · ${ARCH}"
echo "Outils     : $(xcode-select -p 2>/dev/null || echo inconnu)"
if [ "$SDKMAJ" -ge 1 ] 2>/dev/null; then
  echo "SDK macOS  : $SDKVER"
else
  echo "SDK macOS  : illisible (xcrun muet)"
fi

# Un SDK à 0 veut dire « illisible », pas « ancien » : seul un numéro
# réellement antérieur à 11 justifie ce verdict.
if [ "$SDKMAJ" -ge 1 ] 2>/dev/null && [ "$SDKMAJ" -lt 11 ] 2>/dev/null; then
  cat <<'DIAG' >&2

────────────────────────────────────────────────────────────────
  Vos outils de développement sont antérieurs à macOS 11, alors
  que BUD a besoin d'API apparues avec Big Sur.

    sudo rm -rf /Library/Developer/CommandLineTools
    sudo xcode-select --install

  Si Xcode complet est installé :

    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
────────────────────────────────────────────────────────────────

DIAG
  exit 1
fi

# ─────────────────────────────────────────────────────────────────
#  Cible de déploiement
#
#  Les chaînes récentes écrivent « macos12.0 », les anciennes
#  « macosx12.0 ». On sonde pour de vrai plutôt que de supposer.
# ─────────────────────────────────────────────────────────────────

BUILD_TMP="$(mktemp -d)"
cleanup() { rm -rf "$BUILD_TMP"; }
trap cleanup EXIT
PROBE="$BUILD_TMP/budprobe.swift"
echo 'public let budProbe = 1' > "$PROBE"

probe_compile() {
  if [ -n "${1:-}" ]; then
    run_swiftc -target "$1" -typecheck "$PROBE" >/dev/null 2>&1
  else
    run_swiftc -typecheck "$PROBE" >/dev/null 2>&1
  fi
}

if ! probe_compile ""; then
  # xcrun peut être en cause alors que le swiftc du PATH fonctionne.
  SWIFT_VIA="plain"
  if probe_compile ""; then
    echo "xcrun indisponible : utilisation directe de swiftc."
  else
    SWIFT_VIA="xcrun"
  fi
fi

if ! probe_compile ""; then
  RESCUED=""
  for X in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$X/Contents/Developer" ]; then
      export DEVELOPER_DIR="$X/Contents/Developer"
      SDKPATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
      [ -n "$SDKPATH" ] && export SDKROOT="$SDKPATH"
      if probe_compile ""; then
        RESCUED="$X"
        echo "Chaîne d'outils inutilisable : bascule sur $X."
        break
      fi
    fi
  done
  if [ -z "$RESCUED" ]; then
    cat <<'DIAG' >&2

────────────────────────────────────────────────────────────────
  Le compilateur Swift est présent mais ne trouve pas sa
  bibliothèque standard. L'installation des outils est incomplète.

    sudo rm -rf /Library/Developer/CommandLineTools
    sudo xcode-select --install

  Vérification :

    echo 'print(1)' > /tmp/t.swift && xcrun swiftc -typecheck /tmp/t.swift
────────────────────────────────────────────────────────────────

DIAG
    exit 1
  fi
fi

TARGET=""
for T in "${ARCH}-apple-macos12.0" "${ARCH}-apple-macosx12.0"; do
  if probe_compile "$T"; then TARGET="$T"; break; fi
done
if [ -n "$TARGET" ]; then
  echo "Cible      : $TARGET"
else
  export MACOSX_DEPLOYMENT_TARGET=12.0
  echo "Cible      : par défaut du SDK, MACOSX_DEPLOYMENT_TARGET=12.0"
fi

FRAMEWORKS=(-framework Cocoa -framework IOKit -framework Carbon
            -framework Security -framework Network -framework CoreImage)

# ─────────────────────────────────────────────────────────────────
#  Compilation
# ─────────────────────────────────────────────────────────────────

if [ "$MODE" = "check" ]; then
  OUT="$BUILD_TMP/BUD"
  echo "Compilation de contrôle…"
  # shellcheck disable=SC2086
  run_swiftc -O -suppress-warnings -swift-version 5 ${TARGET:+-target "$TARGET"} \
    "$SRC_DIR"/*.swift "${FRAMEWORKS[@]}" -o "$OUT"
  echo "Compilation du générateur d'icône…"
  run_swiftc -O -suppress-warnings -swift-version 5 ${TARGET:+-target "$TARGET"} \
    "$TOOLS_DIR/MakeIcon.swift" -framework Cocoa -o "$BUILD_TMP/budicon"
  echo "BUD Premium $VERSION compile."
  exit 0
fi

pkill -x BUD 2>/dev/null || true
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "Compilation native…"
# shellcheck disable=SC2086
run_swiftc -O -suppress-warnings -swift-version 5 ${TARGET:+-target "$TARGET"} \
  "$SRC_DIR"/*.swift "${FRAMEWORKS[@]}" \
  -o "$APP_DIR/Contents/MacOS/BUD"

# ── Icône ──
if [ -f "$TOOLS_DIR/MakeIcon.swift" ]; then
  TMPI="$BUILD_TMP/icon"; mkdir -p "$TMPI"
  if run_swiftc -O -suppress-warnings -swift-version 5 ${TARGET:+-target "$TARGET"} \
       "$TOOLS_DIR/MakeIcon.swift" -framework Cocoa -o "$TMPI/budicon" 2>/dev/null; then
    "$TMPI/budicon" "$TMPI/BUD.iconset" >/dev/null 2>&1 || true
    if [ -d "$TMPI/BUD.iconset" ]; then
      iconutil -c icns "$TMPI/BUD.iconset" -o "$APP_DIR/Contents/Resources/BUD.icns" 2>/dev/null \
        && echo "Icône créée." || echo "iconutil indisponible, icône ignorée."
    fi
  else
    echo "Icône non générée."
  fi
fi

# ── Info.plist ──
#  ATTENTION : seules CFBundleShortVersionString et CFBundleVersion
#  suivent la version. LSMinimumSystemVersion doit RESTER 12.0, sinon
#  macOS refuse de lancer l'application (erreur -10825).
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>BUD</string>
  <key>CFBundleIconFile</key>
  <string>BUD</string>
  <key>CFBundleIconName</key>
  <string>BUD</string>
  <key>CFBundleIdentifier</key>
  <string>local.lahbib.bud.assistant.monterey</string>
  <key>CFBundleName</key>
  <string>BUD Premium</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>BUD utilise les événements système pour piloter Mail, la musique et l'apparence.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>BUD range les fichiers que vous déposez sur le notch.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>BUD range les fichiers que vous déposez sur le notch.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>BUD analyse les fichiers téléchargés et range ceux que vous déposez.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>BUD affiche et éjecte vos disques externes.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>BUD ouvre un champ de saisie compatible avec la dictée système.</string>
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR" 2>/dev/null || true

# ── Signature ad hoc ──
#  Obligatoire pour exécuter du arm64 : remplacer le binaire d'un
#  paquet signé invalide la signature et macOS tue l'application.
if codesign --force --sign - "$APP_DIR" 2>/dev/null; then
  echo "Signature ad hoc apposée."
else
  echo "Signature ad hoc impossible (sans effet sur Intel)."
fi

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP_DIR" >/dev/null 2>&1 || true

echo ""
echo "BUD Premium $VERSION installé dans $APP_DIR"
[ "$DO_OPEN" -eq 1 ] && open "$APP_DIR"
exit 0
EOF_BUDBUILD_7K2

chmod +x "$SUPPORT_DIR/build.sh"

cat << 'EOF_BUDASK_M4' > "$SUPPORT_DIR/bud-ask"
#!/bin/bash
# bud-ask "Titre" "Détail" [chemin]
# Dépose une demande dans BUD, attend la réponse, l'affiche puis sort.
# Code de sortie : 0 = validé, 1 = refusé, 2 = délai dépassé.
DIR="$HOME/Library/Application Support/BUD-Assistant/agents"
mkdir -p "$DIR"
ID=$(uuidgen)
SRC_NAME="${BUD_SOURCE:-$(basename "${SHELL:-agent}")}"
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'; }
printf '{"id":"%s","source":"%s","title":"%s","detail":"%s","path":"%s","kind":"%s","created":%s}\n' \
  "$ID" "$(esc "$SRC_NAME")" "$(esc "${1:-Validation requise}")" "$(esc "${2:-}")" \
  "$(esc "${3:-}")" "${BUD_KIND:-approval}" "$(date +%s)" > "$DIR/$ID.json"
TIMEOUT="${BUD_TIMEOUT:-600}"
WAITED=0
while [ ! -f "$DIR/$ID.reply" ]; do
  sleep 1
  WAITED=$((WAITED+1))
  if [ "$WAITED" -ge "$TIMEOUT" ]; then
    rm -f "$DIR/$ID.json"
    echo "timeout"
    exit 2
  fi
done
REPLY=$(cat "$DIR/$ID.reply")
rm -f "$DIR/$ID.reply"
echo "$REPLY"
[ "$REPLY" = "approved" ] && exit 0 || exit 1
EOF_BUDASK_M4
chmod +x "$SUPPORT_DIR/bud-ask"

xattr -cr "$SUPPORT_DIR" 2>/dev/null || true

# Toute la compilation vit dans build.sh, partagé avec le dépôt.
bash "$SUPPORT_DIR/build.sh" install --src "$SRC_DIR" --tools "$TOOLS_DIR"

echo "Passerelle agents : \"$SUPPORT_DIR/bud-ask\" \"Titre\" \"Détail\" \"$PWD\""
