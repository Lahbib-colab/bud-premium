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
