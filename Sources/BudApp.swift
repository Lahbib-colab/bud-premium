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
                           NavEntry(icon: "bell.badge.fill", title: "Agents"),
                           NavEntry(icon: "point.3.connected.trianglepath.dotted", title: "Flux")]),
        ("Communication", [NavEntry(icon: "envelope.fill", title: "Courrier"),
                           NavEntry(icon: "iphone", title: "Téléphone"),
                           NavEntry(icon: "alarm.fill", title: "Rappels"),
                           NavEntry(icon: "music.note", title: "Musique")]),
        ("Maison",        [NavEntry(icon: "cloud.sun.fill", title: "Météo"),
                           NavEntry(icon: "house.fill", title: "Maison")]),
        ("Travail",       [NavEntry(icon: "internaldrive.fill", title: "Stockage"),
                           NavEntry(icon: "sparkles", title: "Nettoyage"),
                           NavEntry(icon: "timer", title: "Focus"),
                           NavEntry(icon: "note.text", title: "Notes"),
                           NavEntry(icon: "text.badge.plus", title: "Snippets"),
                           NavEntry(icon: "doc.on.clipboard", title: "Presse-papiers"),
                           NavEntry(icon: "tray.full.fill", title: "Rangement")]),
        ("Système",       [NavEntry(icon: "slider.horizontal.3", title: "Réglages")])
    ]
    private let tabCompanion = 0, tabChat = 1, tabAgents = 2, tabFlow = 3, tabMail = 4,
                tabPhone = 5, tabReminders = 6, tabMusic = 7, tabWeather = 8,
                tabHome = 9, tabStorage = 10, tabClean = 11, tabFocus = 12,
                tabNotes = 13, tabSnippets = 14, tabClipboard = 15, tabSorting = 16,
                tabSettings = 17

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
    private var weatherPanel: WeatherPanelView!
    private var flowPanel: FlowPanelView!
    private var homePanel: HomePanelView!
    private var capture: CaptureWindow!

    // Panneaux maison
    private var companionHero: HeroHeader!, focusHero: HeroHeader!, notesHero: HeroHeader!
    private var clipHero: HeroHeader!, sortHero: HeroHeader!, settingsHero: HeroHeader!
    private var bubbleLabel: NSTextField!
    private var updateCard: UpdateCardView!
    private var navScroll: NSScrollView!
    private var updateBanner: BudUpdateView!
    private var focusTime: NSTextField!, focusPhaseLabel: NSTextField!, focusStats: NSTextField!
    private var focusBar: ProgressBar!, focusBtn: GlassButton!
    fileprivate var notesView: NSTextView!
    private var notesCount: NSTextField!
    private var clipButtons: [GlassButton] = []
    private var clipHistory: [String] = []
    private var lastClipChange = NSPasteboard.general.changeCount
    /// Le compte à rebours demandé depuis le chat. Un seul à la fois :
    /// en demander un second remplace le premier, et BUD le dit.
    private var countdown: Timer?
    private var shortcutsWin: ShortcutsWindow?
    // Une seule zone de compte rendu pour tout l'onglet : deux étiquettes
    // de statut dans le même panneau, l'une sous les outils système et
    // l'autre sous la capture, se faisaient concurrence.
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
    private var nowPlayingTitle = ""
    private var musicPollInFlight = false
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
        // Le splash en premier, avant la construction des vues : c'est
        // précisément ce temps-là qu'il couvre. Il ne retient rien — la
        // construction continue derrière lui et il s'efface seul.
        SplashWindow.present(sound: state.soundEnabled)
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

        // Musique parle d'elle-même : on l'écoute avant de commencer à
        // l'interroger. C'est la source qui ne demande aucune autorisation
        // et qui ne coûte aucun processus.
        MusicFeed.onChange = { [weak self] in self?.musicAnnounced() }
        MusicFeed.start()

        wireWakeWord()

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
        chrome.onChipClick = { [weak self] i in self?.openChip(i) }
        chrome.onPlayer = { [weak self] a in self?.playerAction(a) }
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

    /// Relit l'état de Music hors du fil principal : osascript coûte
    /// une centaine de millisecondes, ce qui se verrait sur l'animation.
    ///
    /// Ce sondage n'est plus la source principale. Musique annonce ses
    /// changements d'elle-même, et `MusicFeed` fait suivre le notch dans
    /// la seconde ; le sondage vient derrière, confirmer la position, le
    /// volume et les modes, que l'annonce ne porte pas.
    private func pollMusic() {
        guard MusicBridge.running() else {
            if nowPlayingTitle != "" || chrome.musicPlaying { applyNowPlaying(NowPlaying()) }
            return
        }
        guard !musicPollInFlight else { return }
        musicPollInFlight = true
        MusicBridge.read { [weak self] n in
            guard let s = self else { return }
            s.musicPollInFlight = false
            s.applyNowPlaying(n)
            if s.currentTab == s.tabMusic { s.musicPanel.apply(n) }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  Les humeurs
    //
    //  Une humeur qui ne dit rien de vrai est un gadget. Chacune
    //  est donc attachée à un fait : BUD réfléchit quand il
    //  travaille vraiment, se fâche quand il a trouvé quelque
    //  chose de dangereux, s'étourdit quand une opération a
    //  échoué. Le reste du temps il est normal, et c'est bien.
    //
    //  Elles sont passagères par construction : rien à remettre
    //  en place après coup, l'échéance s'en charge. Un état
    //  d'humeur qu'il faut penser à annuler finit toujours par
    //  rester allumé.
    // ═══════════════════════════════════════════════════════════

    func mood(_ m: BudMood, _ seconds: TimeInterval = 3) {
        avatar?.sprite.flash(m, for: seconds)
        chrome.sprite.flash(m, for: seconds)
        avatar?.needsDisplay = true
        chrome.needsDisplay = true
    }

    /// Les quatre humeurs à la suite, pour les voir. Joué une fois quand
    /// vous choisissez l'habillage BUDs : une démonstration qu'on ne
    /// demande pas deux fois vaut mieux qu'un écran de réglages de plus.
    private func demoMoods() {
        // Les sept visages, une humeur pour chacun : la démonstration
        // montre les rendus, pas les treize humeurs qui se les partagent.
        let show: [(BudMood, String)] = [
            (.happy, "Content"), (.listening, "Attentif"), (.thinking, "Réfléchi"),
            (.proud, "Cool"), (.sad, "Déçu"), (.angry, "Colère"), (.dizzy, "Étourdi")
        ]
        // Treize dixièmes chacune : le fondu et le petit bond du changement
        // prennent quatre dixièmes, il reste de quoi voir la posture
        // s'installer. Elle se rejoue en recliquant sur l'habillage.
        for (i, s) in show.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.3) { [weak self] in
                self?.mood(s.0, 1.4)
                self?.setStatus("Humeur : \(s.1)")
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  « Hey Bud »
    //
    //  Le mot d'activation déverrouille, la phrase qui suit est
    //  la commande. Une seule intention est traitée ici — celle
    //  qui ouvre une réponse à un message — parce qu'elle
    //  déclenche une action sur le monde. Tout le reste est
    //  renvoyé au chat, qui sait déjà interpréter une phrase et
    //  qui, lui, ne fait rien d'irréversible.
    // ═══════════════════════════════════════════════════════════

    private func wireWakeWord() {
        let v = BudVoice.shared
        v.onWake = { [weak self] in
            guard let s = self else { return }
            // On montre qu'on écoute avant d'avoir compris : sans ce
            // signe, on répète la phrase en croyant n'avoir pas été
            // entendu, et les deux se mélangent.
            s.mood(.listening, 3.4)
            s.coucou("Je vous écoute", "", hold: 3)
            s.avatar?.needsDisplay = true
        }
        v.onWakeCommand = { [weak self] text in self?.handleWakeCommand(text) }
        if state.wakeWord { v.armWake() }
    }

    private func handleWakeCommand(_ said: String) {
        let t = MailReader.fold(said)
        guard !t.isEmpty else { return }

        // « Réponds au mail de Free », « réponse au message de la banque » :
        // on cherche le verbe, puis ce qui suit « de ».
        let wantsReply = ["repond", "reponds", "reponse", "repondre", "reponre"]
            .contains { t.contains($0) }
        let aboutMail = ["mail", "message", "courriel", "courrier", "mel"]
            .contains { t.contains($0) }

        if wantsReply && aboutMail, let who = Self.targetName(in: t) {
            openPanel()
            selectTab(tabMail)
            guard let m = mailPanel.findBySpokenName(who) else {
                mood(.dizzy, 3)
                coucou("Aucun message trouvé", "Rien de « \(who) » dans la boîte.", hold: 6)
                setStatus("Aucun message de « \(who) » dans les messages relevés.")
                return
            }
            mood(.thinking, 4)
            mailPanel.composeReply(to: m) { [weak self] msg in self?.setStatus(msg) }
            coucou("Réponse préparée", m.shortSender, hold: 5)
            return
        }

        // Rien de reconnu comme action sur le courrier : au chat, qui
        // répondra ou dira qu'il n'a pas compris.
        openPanel()
        selectTab(tabChat)
        chatPanel.send(said)
    }

    /// Le nom visé : ce qui suit « de » ou « du », jusqu'à la fin.
    ///
    /// « reponds au mail de free » → « free ». Les articles sont écartés,
    /// et un nom vide vaut mieux qu'un faux : sans nom, BUD le dit au lieu
    /// de répondre au premier message venu.
    static func targetName(in folded: String) -> String? {
        let words = folded.split(separator: " ").map(String.init)
        let markers = ["de", "du", "des", "d"]
        guard let i = words.lastIndex(where: { markers.contains($0) }),
              i + 1 < words.count else { return nil }
        let tail = words[(i + 1)...]
            .filter { !["la", "le", "les", "l", "mon", "ma", "mes"].contains($0) }
        let name = tail.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Ce que Musique vient d'annoncer, répercuté sans attendre le sondage.
    ///
    /// Le titre et l'état suffisent au notch et à la danse de BUD, et ils
    /// arrivent entiers dans la notification. Le reste — position, volume,
    /// modes — attend la relecture, qu'on déclenche aussitôt puisqu'on sait
    /// maintenant qu'il y a du nouveau.
    private func musicAnnounced() {
        guard let a = MusicFeed.last else {
            applyNowPlaying(NowPlaying())
            return
        }
        var n = NowPlaying()
        n.available = true
        n.source = .feed
        n.title = a.title
        n.artist = a.artist
        n.album = a.album
        n.playing = a.playing
        n.duration = a.duration
        n.trackKey = a.trackKey
        applyNowPlaying(n)
        pollMusic()
    }

    /// Répercute la lecture sur le notch et sur le personnage.
    private func applyNowPlaying(_ n: NowPlaying) {
        let line = n.playing ? n.oneLine : ""
        if line != nowPlayingTitle {
            nowPlayingTitle = line
            chrome.nowPlaying = line
        }
        if chrome.musicPlaying != n.playing {
            chrome.musicPlaying = n.playing
            avatar?.musicPlaying = n.playing
            chrome.needsDisplay = true
        }

        // Le lecteur réduit montre le morceau en pause aussi : c'est
        // justement là qu'on veut le relancer.
        chrome.playerTitle = n.title
        chrome.playerArtist = n.artist
        chrome.setPlayback(position: n.position, duration: n.duration,
                           known: n.positionKnown)

        // La pochette, dès qu'il y a un morceau. Le replié ne la montre
        // que pendant la lecture — il le vérifie lui-même — mais le
        // lecteur réduit en a besoin en pause. Le cache fait le reste :
        // un seul export par morceau, partagé avec le panneau.
        if n.hasTrack {
            chrome.nowPlayingArt = ArtworkStore.request(n.trackKey) { [weak self] img in
                self?.chrome.nowPlayingArt = img
            }
        } else if chrome.nowPlayingArt != nil {
            chrome.nowPlayingArt = nil
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

        navScroll = NSScrollView(frame: NSRect(x: 0, y: 58, width: sidebarW, height: H - 150))
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

        // La bannière de mise à jour, au-dessus de la pastille d'état. Cachée
        // tant qu'il n'y a rien à dire ; quand elle paraît, la navigation
        // remonte d'autant au lieu d'être recouverte.
        updateBanner = BudUpdateView(frame: NSRect(x: 10, y: 56, width: sidebarW - 20, height: BudUpdateView.height))
        updateBanner.isHidden = true
        updateBanner.onVisibility = { [weak self] shown in
            guard let s = self else { return }
            let bottom: CGFloat = shown ? 56 + BudUpdateView.height + 6 : 58
            s.navScroll.frame = NSRect(x: 0, y: bottom, width: s.sidebarW, height: H - 92 - bottom)
        }
        content.addSubview(updateBanner)
        wireUpdates()

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
        flowPanel = FlowPanelView(frame: pf)
        mailPanel = MailPanelView(frame: pf)
        phonePanel = PhonePanelView(frame: pf)
        remindersPanel = RemindersPanelView(frame: pf)
        musicPanel = MusicPanelView(frame: pf)
        weatherPanel = WeatherPanelView(frame: pf)
        homePanel = HomePanelView(frame: pf)
        storagePanel = StoragePanelView(frame: pf)
        cleanPanel = CleanupPanelView(frame: pf)
        let focus = NSView(frame: pf)
        let notes = NSView(frame: pf)
        snippetsPanel = SnippetsPanelView(frame: pf)
        let clip = NSView(frame: pf)
        let sorting = NSView(frame: pf)
        let settings = NSView(frame: pf)

        panels = [companion, chatPanel, agentsPanel, flowPanel, mailPanel, phonePanel, remindersPanel,
                  musicPanel, weatherPanel, homePanel, storagePanel, cleanPanel, focus, notes, snippetsPanel,
                  clip, sorting, settings]
        panels.forEach { p in
            p.isHidden = true
            content.addSubview(p)
        }

        storagePanel.onEject = { [weak self] msg in self?.setStatus(msg) }
        storagePanel.lowThreshold = state.lowDiskThreshold
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
        chatPanel.onSpoke = { [weak self] understood in
            // Parler quand il a compris, être perplexe sinon. C'est la
            // seule humeur qui soit déclenchée par une absence de
            // résultat, et elle vaut mieux qu'un sourire poli devant un
            // « je n'ai pas saisi ».
            self?.mood(understood ? .speaking : .confused, understood ? 2.2 : 3.2)
        }
        mailPanel.onStatus = { [weak self] msg in self?.setStatus(msg) }
        mailPanel.onDanger = { [weak self] n in
            // La colère est réservée à ça : un message dangereux arrivé
            // dans la boîte. Si elle servait aussi pour un relevé qui
            // échoue ou un disque plein, elle ne voudrait plus rien dire.
            self?.mood(.angry, 5)
            self?.coucou(n == 1 ? "Message dangereux" : "\(n) messages dangereux",
                         "Ouvrez Courrier pour voir lesquels.", hold: 8)
        }
        // La boîte se tient à jour d'elle-même : sondage toutes les
        // quatre-vingt-dix secondes, relevé complet seulement si le serveur
        // dit que quelque chose a changé.
        // Les sous-agents d'exemple sont posés une fois, et jamais
        // réécrits : vos modifications survivent aux mises à jour.
        ScriptAgents.shared.installExamples()

        mailPanel.followBackgroundSync()
        MailSync.shared.warmUp()
        if MailRouter.gmailReady { MailSync.shared.startPolling() }
        mailPanel.fromAddress = { [weak self] in self?.state.mailFrom ?? "" }
        mailPanel.onAccountChange = { [weak self] addr in
            guard let s = self else { return }
            MailSync.shared.forget()
            MailSync.shared.startPolling()
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
        wireWeatherAndHome()
        // Le notch suit la lecture dès que le panneau relit l'état.
        musicPanel.onNowPlaying = { [weak self] n in self?.applyNowPlaying(n) }
        wireChat()

        buildCompanion(companion)
        buildFocus(focus)
        buildNotes(notes)
        buildClipboard(clip)
        buildSorting(sorting)
        buildSettings(settings)
    }

    private func addHero(_ p: NSView, _ title: String, _ subtitle: String) -> HeroHeader {
        let h = HeroHeader(frame: NSRect(x: 0, y: p.bounds.height - 92, width: p.bounds.width, height: 92),
                           title: title, subtitle: subtitle)
        p.addSubview(h)
        return h
    }

    /// La mise à jour parle par les mêmes canaux que le reste : la barre
    /// d'état, et le visage de BUDs — au travail pendant le téléchargement,
    /// déçu si le réseau lâche.
    private func wireUpdates() {
        let m = BudUpdateManager.shared
        m.channel = { [weak self] in
            let c = self?.state.updateChannel ?? ""
            return c.isEmpty ? BudUpdater.defaultChannel : c
        }
        m.onStatus = { [weak self] msg in self?.setStatus(msg) }
        m.onMood = { [weak self] e, hold in
            guard let s = self else { return }
            s.mood(e.mood, hold)
            s.flowPanel?.show(e, hold: hold)
        }
        // Ce que le dernier remplacement a donné, dit une fois.
        if let r = m.consumeLastResult() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.setStatus(r.text)
                self?.mood(r.ok ? BudMood.proud : BudMood.sad, 4)
                self?.coucou(r.ok ? "Mis à jour" : "Mise à jour annulée", r.text, hold: 5)
            }
        }
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
                                       SegmentedBar.Item(title: "Métal", icon: "cpu"),
                                       SegmentedBar.Item(title: "BUDs", icon: "face.smiling")],
                               selected: state.budSkin)
        skinSeg.onSelect = { [weak self] i in self?.setBudSkin(i) }
        p.addSubview(skinSeg)

        mkSection(p, 106, W, "À propos")
        updateCard = UpdateCardView(frame: NSRect(x: 0, y: 32, width: W, height: 68))
        updateCard.onChannelEdit = { [weak self] in self?.editUpdateChannel() }
        p.addSubview(updateCard)

        p.addSubview(mkLabel("Glissez des fichiers sur le notch pour les classer · ⌘⌥D pour la capture rapide.",
                             NSRect(x: 0, y: 10, width: W, height: 16), 11, .regular, alpha: 0.33, .center))
    }

    /// Change l'habillage du personnage et le fait réagir, pour qu'on voie
    /// aussitôt le nouveau rendu bouger.
    private func setBudSkin(_ i: Int) {
        state.budSkin = max(0, min(3, i))
        // L'ancien drapeau v17 reste dans le fichier pour les retours en
        // arrière : on le garde cohérent, sinon la migration au prochain
        // lancement réimposerait le nacré.
        state.budPremium = (state.budSkin == 1)
        BudStore.shared.save(state)
        applyBudStyle()
        avatar?.react()
        if state.budSkin == 3 && BudArt.hasCompanion {
            demoMoods()
        } else {
            setStatus(["Compagnon à plat", "Compagnon nacré", "Compagnon métal",
                       "BUDs indisponible dans ce paquet : dessin conservé."][state.budSkin])
        }
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

    /// Quatre groupes titrés, un seul rythme vertical.
    ///
    /// L'onglet mêlait des rangées de 42, 44 et 48 pt, un seul intertitre
    /// pour quatre groupes, un trou de 60 pt au-dessus du pied, et deux
    /// étiquettes de statut qui se faisaient concurrence. Tout passe par
    /// `row(_:)` et `section(_:)`, qui descendent d'un pas constant : les
    /// positions ne sont plus calculées une à une, donc elles ne peuvent
    /// plus se contredire.
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
            ("alarmSound", "Son des alarmes", "alarm.fill"),
            ("wake", "Écoute « Hey Bud »", "waveform")
        ]
        // Quatre colonnes et non trois : les treize interrupteurs tiennent
        // alors en quatre rangées au lieu de cinq, et la rangée gagnée
        // laisse la place au bouton des raccourcis, qui n'était accessible
        // que depuis l'onglet Outils.
        let cols: CGFloat = 4
        let ow = (W - 36) / cols
        for (i, o) in opts.enumerated() {
            let col = CGFloat(i % Int(cols)), row = CGFloat(i / Int(cols))
            let t = ToggleRow(frame: NSRect(x: col * (ow + 12), y: H - 380 - row * 46, width: ow, height: 42),
                              title: o.1, icon: o.2)
            t.onToggle = { [weak self] in self?.toggleOption(o.0) }
            p.addSubview(t)
            toggleRows[o.0] = t
        }

        let keysBtn = GlassButton(frame: NSRect(x: 0, y: 6, width: W, height: 42),
                                  title: "Raccourcis clavier et pastilles de l'aperçu…",
                                  icon: "keyboard", prominent: true)
        keysBtn.onClick = { [weak self] _ in self?.openShortcuts() }
        p.addSubview(keysBtn)
    }

    // ═══════════ Chat ═══════════

    /// La météo se relève seule toutes les trente minutes ; la maison se
    /// lit une fois au lancement, pour que la voix trouve les commandes
    /// sans qu'on ait ouvert le panneau.
    private func wireWeatherAndHome() {
        let w = WeatherService.shared
        w.onUpdate = { [weak self] r in
            guard let s = self else { return }
            s.weatherPanel.apply(r, city: s.state.weatherCity, trouble: w.trouble)
        }
        weatherPanel.apply(w.report, city: state.weatherCity, trouble: w.trouble)
        weatherPanel.onCity = { [weak self] city in
            guard let s = self else { return }
            s.state.weatherCity = city
            BudStore.shared.save(s.state)
            w.refresh(city: city, force: true)
        }
        weatherPanel.onRefresh = { [weak self] in
            guard let s = self else { return }
            w.refresh(city: s.state.weatherCity, force: true)
        }
        w.start { [weak self] in self?.state.weatherCity ?? "Paris" }

        homePanel.folder = { [weak self] in self?.state.homeFolder ?? "BUD Maison" }
        homePanel.onFolder = { [weak self] f in
            guard let s = self else { return }
            s.state.homeFolder = f
            BudStore.shared.save(s.state)
        }
        homePanel.onRan = { [weak self] _, ok in
            self?.mood(ok ? .proud : .confused, 2.5)
        }
        homePanel.reload()
        wireFlow()
        wireTools()
    }

    /// Les outils du chat reçoivent quelques gestes de l'application, et
    /// rien d'autre.
    private func wireTools() {
        var h = ToolHost()
        h.hidePanel = { [weak self] in self?.collapse() }
        h.showChat = { [weak self] in
            guard let s = self else { return }
            s.openPanel()
            s.selectTab(s.tabChat)
        }
        h.openTab = { [weak self] key in
            guard let s = self else { return }
            s.openPanel()
            s.selectTab(key == "flow" ? s.tabFlow : s.tabChat)
        }
        h.lockScreen = { [weak self] in self?.lockScreenNow() ?? "" }
        h.setAppearance = { [weak self] w in self?.setSystemAppearance(w) ?? "" }
        h.emptyTrash = { [weak self] done in self?.cleanPanel.emptyTrashOnly(done) }
        h.openKeyboardShortcuts = { [weak self] in self?.openShortcuts() }
        h.battery = { batteryLine() }
        h.network = { networkLine() }
        let m = BudToolManager.shared
        m.host = h
        m.onExpression = { [weak self] e, hold in
            guard let s = self else { return }
            s.mood(e.mood, hold)
            s.flowPanel.show(e, hold: hold)
        }
        BudToolCatalog.registerDefaults()
    }

    /// Le Flux : les agents s'inscrivent, et leurs expressions passent par
    /// le même chemin que toutes les autres humeurs de BUDs — bureau,
    /// encoche et nœud du graphe ensemble.
    private func wireFlow() {
        BudAgentCatalog.registerDefaults(
            mail: { [weak self] in self?.mailPanel.recentMessages ?? [] },
            city: { [weak self] in self?.state.weatherCity ?? "Paris" },
            runHome: { [weak self] name, done in
                guard let s = self else { done(false, "Indisponible."); return }
                s.homePanel.launch(named: name, done: done)
            })
        let m = BudAgentManager.shared
        m.onExpression = { [weak self] e, hold in
            guard let s = self else { return }
            s.mood(e.mood, hold)
            s.flowPanel.show(e, hold: hold)
        }
        m.onStatus = { [weak self] line in self?.setStatus(line) }
        flowPanel.refresh()
    }

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
        a.weather = { [weak self] late in
            guard let s = self else { return "" }
            let w = WeatherService.shared
            if let r = w.report, Date().timeIntervalSince(r.fetchedAt) < 60 * 60 {
                return w.summary()
            }
            // Pas de relevé, ou trop vieux : on le demande et on répond
            // quand il arrive. `onUpdate` est déjà pris par le panneau.
            let before = w.report?.fetchedAt
            w.refresh(city: s.state.weatherCity, force: true)
            var tries = 0
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { tm in
                tries += 1
                if w.report?.fetchedAt != before || !w.trouble.isEmpty || tries > 40 {
                    tm.invalidate(); late(w.summary())
                }
            }
            return "Je regarde le ciel de \(s.state.weatherCity)…"
        }
        a.home = { [weak self] phrase, late in
            guard let s = self, let scene = HomeShortcuts.shared.match(phrase) else { return nil }
            s.homePanel.launch(named: scene.name) { ok, msg in
                late(ok ? (msg.isEmpty ? "C'est fait : \(scene.name)." : msg)
                        : "« \(scene.name) » n'a pas abouti : \(msg)")
            }
            return "Je lance « \(scene.name) »…"
        }
        a.tellJoke = { budJokes.randomElement() ?? "" }
        a.giveTip = { [weak self] in
            let pool = tipsFor(self?.state.personality ?? 0)
            return pool.randomElement() ?? ""
        }
        a.batteryReport = { batteryLine() }
        a.networkReport = { networkLine() }
        // Ces trois-là passent par les outils : même confirmation, même
        // bulle, mêmes expressions que la pilule. La réponse vide dit au
        // chat que l'outil parle lui-même dans le fil.
        a.lockScreen = { [weak self] in self?.chatPanel.runTool("lock"); return "" }
        a.sleepDisplay = { [weak self] in self?.chatPanel.runTool("sleep-display"); return "" }
        a.setAppearance = { [weak self] which in self?.setSystemAppearance(which) ?? "" }
        a.screenshot = { [weak self] kind in
            let id = kind == "window" ? "capture-window" : (kind == "selection" ? "capture-zone" : "capture-screen")
            self?.chatPanel.runTool(id)
            return ""
        }
        a.startTimer = { [weak self] minutes, raw in self?.startCountdown(minutes, raw) ?? "" }
        a.webSearch = { q in
            guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://duckduckgo.com/?q=\(enc)") else {
                return "Je n'ai pas pu composer cette recherche."
            }
            NSWorkspace.shared.open(url)
            return "J'ouvre une recherche sur « \(q) »."
        }
        a.runAgent = { name, payload, reply in
            ScriptAgents.shared.run(name, payload: payload) { [weak self] out in
                guard out.ok else {
                    self?.mood(.sad, 3)
                    reply(out.error ?? "Le sous-agent a échoué.")
                    return
                }
                self?.mood(.proud, 2.6)
                var lines = [out.summary]
                for i in out.items.prefix(12) {
                    let mark = i.level == "warning" ? "⚠︎" : (i.level == "action" ? "▸" : "·")
                    lines.append("\(mark) \(i.title)" + (i.detail.isEmpty ? "" : " — \(i.detail)"))
                }
                if out.items.count > 12 {
                    lines.append("… et \(out.items.count - 12) de plus.")
                }
                reply(lines.joined(separator: "\n"))
            }
        }
        a.listAgents = {
            let all = ScriptAgents.shared.discover()
            guard !all.isEmpty else {
                return "Aucun sous-agent installé. Ils vivent dans "
                    + "\(ScriptAgents.shared.dir.path)."
            }
            return "Sous-agents installés :\n"
                + all.map { "• \($0.title) — \($0.detail)" }.joined(separator: "\n")
        }
        chatPanel.actions = a
    }

    // ═══════════ Les pastilles de l'aperçu ═══════════

    /// Ce qu'affiche une pastille. Tout doit tenir en quelques caractères :
    /// quatre capsules se partagent 470 pt, et une valeur tronquée vaut
    /// moins que pas de valeur du tout.
    private func chipValue(_ key: String, boot: VolumeInfo?, ext: Int, focus: String) -> String {
        switch key {
        case "disk":      return boot.map { formatBytes($0.free) } ?? "—"
        case "external":  return ext > 0 ? "\(ext)" : "—"
        case "agents":    return pendingAgents > 0 ? "\(pendingAgents)" : "—"
        case "focus":     return focus
        case "clock":     return clockString()
        case "battery":   return batteryShort()
        case "mail":      return lastUnread >= 0 ? "\(lastUnread)" : "—"
        case "reminders": return nextReminderShort()
        case "music":     return nowPlayingTitle.isEmpty
                                ? "—" : String(nowPlayingTitle.prefix(14))
        case "memory":    return memoryShort()
        case "weather":   return WeatherService.shared.report.map { "\(Int($0.temp.rounded()))°" } ?? "—"
        default:          return "—"
        }
    }

    /// « 87 % » ou « — » sur une machine sans batterie. La phrase complète
    /// de `batteryLine()` ne tiendrait pas dans une capsule.
    private func batteryShort() -> String {
        let out = runShell("/usr/bin/pmset", ["-g", "batt"])
        guard out.contains("InternalBattery"),
              let r = out.range(of: "[0-9]{1,3}%", options: .regularExpression) else { return "—" }
        return String(out[r])
    }

    /// L'heure du prochain rappel non fait, ou « — ».
    private func nextReminderShort() -> String {
        let due = ReminderStore.shared.items
            .filter { !$0.done }
            .sorted { $0.date < $1.date }
        guard let n = due.first else { return "—" }
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = Calendar.current.isDateInToday(n.date) ? "HH:mm" : "d MMM"
        return f.string(from: n.date)
    }

    /// Mémoire libre, en gigaoctets.
    private func memoryShort() -> String {
        let m = memoryStats()
        let free = m.total - m.used
        return free > 0 ? String(format: "%.1f Go", free / 1_073_741_824) : "—"
    }

    /// Les commandes du lecteur réduit.
    ///
    /// Chacune repousse la fermeture de l'aperçu : on ne veut pas qu'il
    /// se replie entre deux « suivant ». Lecture et pause changent l'icône
    /// tout de suite, sans attendre Musique — la relecture qui suit
    /// corrige si elle a refusé.
    private func playerAction(_ a: NotchChrome.PlayerAction) {
        holdUntil = Date().addingTimeInterval(12)
        switch a {
        case .previous:
            MusicBridge.previous()
        case .next:
            MusicBridge.next()
        case .toggle:
            // `playPause` lance Musique si elle est fermée : depuis « Rien
            // en lecture », le bouton fait donc ce qu'il promet.
            MusicBridge.playPause()
            chrome.musicPlaying.toggle()
        case .open:
            chrome.hidePlayer(instant: true)
            openPanel()
            selectTab(tabMusic)
            return
        case .close:
            chrome.hidePlayer()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.pollMusic()
        }
    }

    /// Le clic sur une pastille mène à ce qu'elle montre.
    private func openChip(_ index: Int) {
        let keys = PreviewChips.current(state)
        guard index >= 0, index < keys.count, let c = PreviewChips.chip(keys[index]) else {
            openPanel(); return
        }
        switch c.target {
        case "storage":   openPanel(); selectTab(tabStorage)
        case "agents":    openPanel(); selectTab(tabAgents)
        case "mail":      openPanel(); selectTab(tabMail)
        case "reminders": openPanel(); selectTab(tabReminders)
        case "music":
            // Le lecteur réduit, sur place. Le grand panneau reste à un
            // clic : la pochette et le titre y mènent.
            chrome.showPlayer(fromChip: index)
            holdUntil = Date().addingTimeInterval(12)
            pollMusic()
        case "focus":     openPanel(); selectTab(tabFocus)
        case "weather":   openPanel(); selectTab(tabWeather)
        default:          openPanel()
        }
    }

    // ═══════════ Ce que BUD sait faire en plus, depuis le chat ═══════════

    /// Verrouille la session si le Mac en offre le moyen, et dit
    /// honnêtement ce qui s'est passé sinon : mettre l'écran en veille
    /// n'est un verrouillage que si le réglage du mot de passe le veut.
    private func lockScreenNow() -> String {
        let cg = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        if FileManager.default.isExecutableFile(atPath: cg) {
            runShell(cg, ["-suspend"])
            return "Session verrouillée."
        }
        runShell("/usr/bin/pmset", ["displaysleepnow"])
        return "Écran mis en veille. Le verrouillage dépend de votre réglage "
            + "« demander le mot de passe après la mise en veille »."
    }

    private func setSystemAppearance(_ which: String) -> String {
        let value: String
        switch which {
        case "dark":  value = "true"
        case "light": value = "false"
        default:      value = "not dark mode"
        }
        runShell("/usr/bin/osascript",
                 ["-e", "tell application \"System Events\" to tell appearance preferences "
                      + "to set dark mode to \(value)"])
        let label = which == "dark" ? "sombre" : (which == "light" ? "clair" : "basculée")
        return "Apparence système : \(label). Sans effet ? Autorisez BUD dans "
            + "Confidentialité et sécurité → Automatisation."
    }

    private func startCountdown(_ minutes: Int, _ raw: String) -> String {
        countdown?.invalidate()
        let fires = Date().addingTimeInterval(TimeInterval(minutes * 60))
        countdown = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60),
                                         repeats: false) { [weak self] _ in
            self?.coucou("C'est l'heure", "Vous m'aviez dit : « \(String(raw.prefix(70))) »",
                         hold: 8, sound: true)
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "HH:mm"
        return "Entendu — je vous préviens à \(f.string(from: fires))."
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
        // Le lecteur réduit n'existe que dans l'aperçu. Rouvert plus tard,
        // l'aperçu retrouve ses pastilles, pas un lecteur à demi replié.
        if s != .glance { chrome.hidePlayer(instant: true) }
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
        // L'heure de l'entête était posée une seule fois, à l'ouverture de
        // l'aperçu, tandis que la pastille se rafraîchissait chaque seconde :
        // après une minute de survol, les deux affichaient une minute
        // différente. Une seule écriture, au même instant, pour les deux.
        if notchState == .glance {
            chrome.subtitle = longDateString() + " · " + clockString()
        }

        chrome.chips = PreviewChips.current(state).map { key -> (String, String, NSColor?) in
            guard let c = PreviewChips.chip(key) else { return ("questionmark", "—", nil) }
            var icon = c.icon
            if key == "weather", let r = WeatherService.shared.report { icon = r.condition.symbol }
            return (icon, chipValue(key, boot: boot, ext: ext, focus: focusTxt), c.color)
        }
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

    /// Les raccourcis ne sont plus écrits en dur : on compare l'événement
    /// à ce que l'utilisateur a choisi, action par action.
    private func handleHotkey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.intersection([.command, .control, .option]).isEmpty,
              let ch = e.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty else { return false }

        for action in Shortcuts.actions {
            guard let (m, c) = Shortcuts.decode(Shortcuts.current(action.key, in: state)),
                  c == ch, m == mods else { continue }
            run(shortcut: action.key)
            return true
        }
        return false
    }

    private func run(shortcut key: String) {
        switch key {
        case "panel":     togglePanel()
        case "hello":     sayHello()
        case "focus":     toggleFocus()
        case "capture":   showCapture()
        case "voice":     openPanel(); selectTab(tabChat); chatPanel.startDictation()
        case "chat":      openPanel(); selectTab(tabChat)
        case "mail":      openPanel(); selectTab(tabMail)
        case "reminders": openPanel(); selectTab(tabReminders)
        case "agents":    openPanel(); selectTab(tabAgents)
        case "phone":     openPanel(); selectTab(tabPhone)
        default: break
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
        case "wake":
            // Un interrupteur, pas un réglage par défaut : le micro reste
            // ouvert et la reconnaissance tourne tant qu'il est armé.
            state.wakeWord.toggle()
            if state.wakeWord { BudVoice.shared.armWake() }
            else { BudVoice.shared.disarmWake() }
            setStatus(state.wakeWord
                      ? "BUD écoute « Hey Bud ». Le micro reste ouvert, et cela consomme."
                      : "Écoute permanente arrêtée.")
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
        switch state.budSkin {
        case 3:  BudSprite.style = .logo
        case 2:  BudSprite.style = .metal
        case 1:  BudSprite.style = .premium
        default: BudSprite.style = .flat
        }
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
            "mailWatch": state.mailWatch, "alarmSound": state.alarmSound,
            "wake": state.wakeWord
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
        // Musique : toutes les 4 s si Music tourne, sinon rien. Le test
        // d'exécution passe par NSWorkspace, donc sans lancer de processus.
        if ticks % 4 == 0 { pollMusic() }
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

        // Activer un mode mérite un accusé de réception, et c'est le
        // personnage qui le donne : il salue quand on vient le voir,
        // il tressaille quand on ouvre un autre panneau. Seulement au
        // changement — rejouer l'animation sur un clic répété donnerait
        // l'air d'une application qui n'a pas compris.
        if changed {
            if i == tabCompanion { avatar?.wave() } else { avatar?.react() }
        }

        // L'indicateur de sélection glisse d'une entrée à l'autre
        if sidebarItems.indices.contains(i) {
            let target = sidebarItems[i].frame.insetBy(dx: 0, dy: 1)
            if navIndicator.frame == .zero {
                navIndicator.frame = target
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.base
                    ctx.timingFunction = Motion.enter
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
        case tabFlow: flowPanel.refresh()
        case tabWeather:
            let w = WeatherService.shared
            weatherPanel.apply(w.report, city: state.weatherCity, trouble: w.trouble)
            w.refresh(city: state.weatherCity)
        case tabHome: homePanel.reload()
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




    /// Ouvre la fenêtre des raccourcis, ou la ramène devant si elle est
    /// déjà là. Une seule instance, sinon deux fenêtres se disputeraient
    /// le même état.
    private func openShortcuts() {
        if shortcutsWin == nil {
            let w = ShortcutsWindow(current: { [weak self] key in
                guard let s = self else { return "" }
                return Shortcuts.current(key, in: s.state)
            })
            w.onSet = { [weak self] key, combo in
                guard let s = self else { return }
                s.state.shortcuts[key] = combo
                BudStore.shared.save(s.state)
            }
            w.onReset = { [weak self] in
                guard let s = self else { return }
                s.state.shortcuts = [:]
                BudStore.shared.save(s.state)
            }
            w.chipsNow = { [weak self] in
                guard let s = self else { return PreviewChips.fallback }
                return PreviewChips.current(s.state)
            }
            w.onChipSet = { [weak self] slot, key in
                guard let s = self else { return }
                var keys = PreviewChips.current(s.state)
                guard slot >= 0, slot < keys.count else { return }
                keys[slot] = key
                s.state.previewChips = keys
                BudStore.shared.save(s.state)
                // L'aperçu se redessine au prochain battement, mais on ne
                // fait pas attendre : le réglage doit se voir tout de suite.
                s.refreshChips()
            }
            shortcutsWin = w
        }
        shortcutsWin?.refresh()
        shortcutsWin?.showWindow(nil)
        shortcutsWin?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }


    @objc private func quitApp() {
        BudStore.shared.save(state)
        NSApp.terminate(nil)
    }
}
