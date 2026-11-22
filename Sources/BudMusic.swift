import Cocoa
import Foundation

// ═══════════════════════════════════════════════════════════
//  Musique — Apple Music seule
//
//  Spotify et Alexa ont été retirés. Alexa surtout : Amazon
//  n'expose aucune interface locale sur macOS, et le piloter
//  par les touches média d'un lecteur web était un bricolage
//  qui réclamait l'autorisation Accessibilité pour un résultat
//  imprévisible. Mieux vaut une seule source bien tenue.
//
//  Tout passe par AppleScript, l'interface que Music.app
//  publie officiellement. Un seul aller-retour rapporte l'état
//  complet : titre, artiste, album, position, durée, volume,
//  lecture aléatoire et répétition.
// ═══════════════════════════════════════════════════════════

struct NowPlaying {
    var available = false          // Music.app est lancée
    var playing = false
    var title = ""
    var artist = ""
    var album = ""
    var position: Double = 0
    var duration: Double = 0
    var volume: Int = 50
    var shuffle = false
    var repeatMode = "off"         // off · one · all

    var hasTrack: Bool { !title.isEmpty }

    /// « 1:42 / 3:58 »
    var timeText: String {
        guard duration > 0 else { return "" }
        return "\(mmss(position)) / \(mmss(duration))"
    }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, position / duration))
    }
    private func mmss(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Ce que le notch affiche : « Titre — Artiste », tronqué par l'appelant.
    var oneLine: String {
        if title.isEmpty { return "" }
        return artist.isEmpty ? title : "\(title) — \(artist)"
    }
}

enum MusicBridge {
    static let appName = "Music"
    static let bundleID = "com.apple.Music"

    /// Sans lancer de processus : la liste des applications actives
    /// suffit, et un sondage toutes les cinq secondes doit rester gratuit
    /// quand Music est fermée.
    static func running() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    @discardableResult
    private static func osa(_ s: String) -> String {
        runShell("/usr/bin/osascript", ["-e", s])
    }

    /// AppleScript peut rendre « 12,345 » selon la langue du système.
    private static func num(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// Un seul appel pour tout l'état. Chaque propriété est lue dans son
    /// propre `try` : si une version de Music n'expose plus la répétition,
    /// on perd cette seule information, pas la totalité.
    static func nowPlaying() -> NowPlaying {
        var n = NowPlaying()
        guard running() else { return n }
        n.available = true

        let out = osa("""
        tell application "Music"
            set st to "stopped"
            set nm to ""
            set ar to ""
            set al to ""
            set pp to 0
            set du to 0
            set vol to 50
            set sh to "false"
            set rp to "off"
            try
                set st to (player state as string)
            end try
            try
                set vol to (sound volume as integer)
            end try
            try
                set sh to (shuffle enabled as string)
            end try
            try
                set rp to (song repeat as string)
            end try
            try
                set t to current track
                set nm to (name of t)
                set ar to (artist of t)
                set al to (album of t)
                set du to (duration of t)
                set pp to (player position)
            end try
            set out to st & "|~|" & nm & "|~|" & ar & "|~|" & al
            set out to out & "|~|" & (pp as string) & "|~|" & (du as string)
            set out to out & "|~|" & (vol as string) & "|~|" & sh & "|~|" & rp
            return out
        end tell
        """)

        let p = out.components(separatedBy: "|~|")
        guard p.count >= 9 else { return n }
        n.playing = p[0].contains("playing")
        n.title = p[1].trimmingCharacters(in: .whitespacesAndNewlines)
        n.artist = p[2].trimmingCharacters(in: .whitespacesAndNewlines)
        n.album = p[3].trimmingCharacters(in: .whitespacesAndNewlines)
        n.position = num(p[4])
        n.duration = num(p[5])
        n.volume = Int(num(p[6]))
        n.shuffle = p[7].lowercased().contains("true")
        n.repeatMode = p[8].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n
    }

    static func launch() {
        runShell("/usr/bin/open", ["-a", appName])
    }

    private static func tell(_ cmd: String) {
        guard running() else { launch(); return }
        osa("tell application \"\(appName)\" to \(cmd)")
    }

    static func playPause() { tell("playpause") }
    static func play()      { tell("play") }
    static func pause()     { tell("pause") }
    static func next()      { tell("next track") }
    static func previous()  { tell("previous track") }

    /// Recule ou avance dans le morceau. Music accepte l'écriture
    /// directe de la position, sans passer par les touches média.
    static func seek(by delta: Double) {
        guard running() else { return }
        osa("""
        tell application "Music"
            try
                set p to (player position)
                set d to (duration of current track)
                set np to p + (\(delta))
                if np < 0 then set np to 0
                if np > (d - 1) then set np to (d - 1)
                set player position to np
            end try
        end tell
        """)
    }

    static func setVolume(_ v: Int) {
        guard running() else { return }
        osa("tell application \"Music\" to set sound volume to \(max(0, min(100, v)))")
    }

    static func changeVolume(by delta: Int) {
        guard running() else { return }
        let cur = Int(num(osa("tell application \"Music\" to get sound volume")))
        setVolume(cur + delta)
    }

    static func toggleShuffle() {
        guard running() else { return }
        osa("""
        tell application "Music"
            try
                set shuffle enabled to not (shuffle enabled)
            end try
        end tell
        """)
    }

    /// off → all → one → off
    static func cycleRepeat() {
        guard running() else { return }
        osa("""
        tell application "Music"
            try
                set r to (song repeat as string)
                if r is "off" then
                    set song repeat to all
                else if r is "all" then
                    set song repeat to one
                else
                    set song repeat to off
                end if
            end try
        end tell
        """)
    }
}

// ═══════════════════════════════════════════════════════════
//  Le panneau
// ═══════════════════════════════════════════════════════════

final class MusicPanelView: NSView {
    private let hero: HeroHeader
    private var titleLabel: NSTextField!
    private var artistLabel: NSTextField!
    private var albumLabel: NSTextField!
    private var timeLabel: NSTextField!
    private var bar: ProgressBar!
    private var playBtn: GlassButton!
    private var shuffleBtn: GlassButton!
    private var repeatBtn: GlassButton!
    private var volLabel: NSTextField!
    private var volSlider: NSSlider!
    private var eq: EqualizerView!
    private var hint: NSTextField!
    private var noteIcon: NSImageView!
    private var last = NowPlaying()
    private var volumeHeld = false

    var onStatus: ((String) -> Void)?
    /// Prévient l'application que l'état de lecture a changé, pour que
    /// le notch et l'animation de BUD suivent sans attendre le sondage.
    var onNowPlaying: ((NowPlaying) -> Void)?

    init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Musique", subtitle: "Apple Music, piloté sans quitter votre travail.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        addSubview(hero)

        // ── Carte « en lecture » avec l'égaliseur ──
        let card = mkCard(self, NSRect(x: 0, y: H - 258, width: W, height: 152), radius: 18, alpha: 0.07)
        noteIcon = mkIcon(card, "music.note", x: 24, y: 118, size: 20, alpha: 0.5)
        titleLabel = mkLabel("—", NSRect(x: 58, y: 110, width: W - 190, height: 26), 17, .bold)
        artistLabel = mkLabel("", NSRect(x: 58, y: 88, width: W - 190, height: 18), 12.5, .medium, alpha: 0.6)
        albumLabel = mkLabel("", NSRect(x: 58, y: 68, width: W - 190, height: 16), 11, .regular, alpha: 0.4)
        [titleLabel, artistLabel, albumLabel].forEach { card.addSubview($0) }

        eq = EqualizerView(frame: NSRect(x: W - 118, y: 74, width: 94, height: 58))
        card.addSubview(eq)

        bar = ProgressBar(frame: NSRect(x: 24, y: 38, width: W - 48, height: 10))
        card.addSubview(bar)
        timeLabel = mkLabel("", NSRect(x: 24, y: 14, width: W - 48, height: 16),
                            11, .medium, alpha: 0.45, .center)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        card.addSubview(timeLabel)

        // ── Transport : reculer · précédent · lecture · suivant · avancer ──
        let ty = H - 326
        let tw = (W - 48) / 5
        let specs: [(String, () -> Void)] = [
            ("gobackward.15", { [weak self] in self?.run { MusicBridge.seek(by: -15) } }),
            ("backward.fill", { [weak self] in self?.run { MusicBridge.previous() } }),
            ("playpause.fill", { [weak self] in self?.run { MusicBridge.playPause() } }),
            ("forward.fill", { [weak self] in self?.run { MusicBridge.next() } }),
            ("goforward.15", { [weak self] in self?.run { MusicBridge.seek(by: 15) } })
        ]
        var made: [GlassButton] = []
        for (i, sp) in specs.enumerated() {
            let b = GlassButton(frame: NSRect(x: CGFloat(i) * (tw + 12), y: ty, width: tw, height: 56),
                                title: "", icon: sp.0, prominent: i == 2)
            b.onClick = { _ in sp.1() }
            addSubview(b)
            made.append(b)
        }
        playBtn = made[2]

        // ── Aléatoire et répétition ──
        let my = ty - 60
        let mw = (W - 12) / 2
        shuffleBtn = GlassButton(frame: NSRect(x: 0, y: my, width: mw, height: 46),
                                 title: "Aléatoire", icon: "shuffle")
        shuffleBtn.onClick = { [weak self] _ in self?.run { MusicBridge.toggleShuffle() } }
        repeatBtn = GlassButton(frame: NSRect(x: mw + 12, y: my, width: mw, height: 46),
                                title: "Répétition", icon: "repeat")
        repeatBtn.onClick = { [weak self] _ in self?.run { MusicBridge.cycleRepeat() } }
        [shuffleBtn, repeatBtn].forEach { addSubview($0) }

        // ── Volume : un curseur plutôt que deux boutons ──
        mkSection(self, my - 24, W, "Volume")
        volSlider = NSSlider(frame: NSRect(x: 0, y: my - 78, width: W - 64, height: 24))
        volSlider.minValue = 0
        volSlider.maxValue = 100
        volSlider.doubleValue = 50
        volSlider.isContinuous = true
        volSlider.target = self
        volSlider.action = #selector(volumeChanged(_:))
        addSubview(volSlider)
        volLabel = mkLabel("50", NSRect(x: W - 58, y: my - 76, width: 58, height: 20),
                           13, .semibold, alpha: 0.7, .right)
        volLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        addSubview(volLabel)

        hint = NSTextField(frame: NSRect(x: 0, y: 58, width: W, height: 34))
        hint.isBezeled = false
        hint.drawsBackground = false
        hint.isEditable = false
        hint.isSelectable = false
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = TH.dim(0.42)
        hint.alignment = .center
        hint.lineBreakMode = .byWordWrapping
        hint.cell?.usesSingleLineMode = false
        hint.cell?.wraps = true
        hint.maximumNumberOfLines = 2
        ThemeRegistry.shared.register(hint, alpha: 0.42)
        addSubview(hint)

        let bw = (W - 12) / 2
        let openBtn = GlassButton(frame: NSRect(x: 0, y: 0, width: bw, height: 44),
                                  title: "Ouvrir Musique", icon: "arrow.up.forward.app.fill")
        openBtn.onClick = { [weak self] _ in
            MusicBridge.launch()
            self?.onStatus?("Ouverture de Musique")
        }
        let refreshBtn = GlassButton(frame: NSRect(x: bw + 12, y: 0, width: bw, height: 44),
                                     title: "Actualiser", icon: "arrow.clockwise")
        refreshBtn.onClick = { [weak self] _ in self?.refresh() }
        [openBtn, refreshBtn].forEach { addSubview($0) }
    }

    @objc private func volumeChanged(_ s: NSSlider) {
        let v = Int(s.doubleValue.rounded())
        volLabel.stringValue = "\(v)"
        // On écrit tout de suite, mais sans relire : un sondage pendant
        // le glissement ferait sauter le curseur sous le doigt.
        volumeHeld = true
        MusicBridge.setVolume(v)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(releaseVolume), object: nil)
        perform(#selector(releaseVolume), with: nil, afterDelay: 0.8)
    }

    @objc private func releaseVolume() { volumeHeld = false }

    /// Exécute une commande puis relit l'état : Music met un instant
    /// à répondre, d'où le léger délai avant le rafraîchissement.
    private func run(_ body: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            body()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let n = MusicBridge.nowPlaying()
            DispatchQueue.main.async { [weak self] in self?.apply(n) }
        }
    }

    func apply(_ n: NowPlaying) {
        last = n
        onNowPlaying?(n)

        if !n.available {
            titleLabel.stringValue = "Musique est fermée"
            artistLabel.stringValue = ""
            albumLabel.stringValue = ""
            timeLabel.stringValue = ""
            bar.set(0, caption: "", animated: false)
            eq.playing = false
            hint.stringValue = "Ouvrez Musique pour que BUD prenne la main. "
                + "Le pilotage demande l'autorisation Automatisation au premier usage."
            noteIcon.alphaValue = 0.3
            return
        }

        noteIcon.alphaValue = n.playing ? 0.85 : 0.5
        titleLabel.stringValue = n.hasTrack ? n.title : "Rien en lecture"
        artistLabel.stringValue = n.artist
        albumLabel.stringValue = n.album
        timeLabel.stringValue = n.timeText
        bar.set(Int((n.progress * 100).rounded()), caption: "", animated: false)
        eq.playing = n.playing

        if !volumeHeld {
            volSlider.doubleValue = Double(n.volume)
            volLabel.stringValue = "\(n.volume)"
        }

        shuffleBtn.prominent = n.shuffle
        repeatBtn.prominent = n.repeatMode != "off"
        repeatBtn.title = n.repeatMode == "one" ? "Répéter ce titre"
                        : (n.repeatMode == "all" ? "Répéter tout" : "Répétition")
        repeatBtn.iconName = n.repeatMode == "one" ? "repeat.1" : "repeat"

        hint.stringValue = n.playing
            ? "BUD s'animera dans le notch pendant la lecture."
            : (n.hasTrack ? "En pause." : "Lancez un morceau dans Musique.")
    }

    /// Intentions du chat. Renvoie la phrase que BUD répondra.
    func command(_ what: String) -> String {
        switch what {
        case "play", "pause", "playpause", "toggle":
            MusicBridge.playPause(); refresh()
            return "C'est fait."
        case "next":
            MusicBridge.next(); refresh()
            return "Morceau suivant."
        case "previous", "prev":
            MusicBridge.previous(); refresh()
            return "Morceau précédent."
        case "volup", "up":
            MusicBridge.changeVolume(by: 10); refresh()
            return "Volume monté."
        case "voldown", "down":
            MusicBridge.changeVolume(by: -10); refresh()
            return "Volume baissé."
        case "shuffle", "aleatoire":
            MusicBridge.toggleShuffle(); refresh()
            return "Lecture aléatoire basculée."
        case "open":
            MusicBridge.launch()
            return "J'ouvre Musique."
        default:
            let n = MusicBridge.nowPlaying()
            if !n.available { return "Musique est fermée." }
            return n.hasTrack
                ? (n.playing ? "En lecture : \(n.oneLine)." : "En pause sur \(n.oneLine).")
                : "Rien en lecture."
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  L'égaliseur
//
//  Honnêteté : macOS n'expose aucun niveau audio en sortie sans
//  capturer le flux, ce que BUD ne fait pas. Ces barres ne
//  mesurent donc rien — elles sont synthétiques, pilotées par
//  plusieurs sinusoïdes de fréquences premières entre elles pour
//  éviter tout motif qui se répète visiblement. C'est un signe
//  de vie, pas un instrument de mesure.
// ═══════════════════════════════════════════════════════════

final class EqualizerView: NSView {
    var playing = false {
        didSet {
            guard playing != oldValue else { return }
            if playing { start() } else { stop() }
            needsDisplay = true
        }
    }
    var bars = 5
    var tint: NSColor? = nil

    private var levels: [CGFloat] = []
    private var clock: CGFloat = 0
    private var timer: Timer?
    // Fréquences volontairement non harmoniques.
    private let freq: [CGFloat] = [5.3, 7.1, 4.3, 8.7, 6.1, 9.3, 3.7]
    private let phase: [CGFloat] = [0, 1.7, 0.9, 2.4, 3.1, 1.2, 0.4]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        levels = Array(repeating: 0.15, count: 7)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            guard s.window != nil, !s.isHiddenOrHasHiddenAncestor else { return }
            s.step()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        for i in levels.indices { levels[i] = 0.12 }
    }

    func step() {
        clock += 1.0 / 24.0
        for i in 0..<min(bars, levels.count) {
            let a = sin(clock * freq[i] + phase[i])
            let b = sin(clock * freq[(i + 3) % freq.count] * 0.37 + phase[i])
            // Deux sinusoïdes et un grain aléatoire : jamais de motif net.
            var v = 0.5 + 0.34 * a + 0.16 * b
            v += CGFloat.random(in: -0.07...0.07)
            levels[i] = max(0.08, min(1, levels[i] * 0.45 + v * 0.55))
        }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let n = max(1, min(bars, levels.count))
        let gap: CGFloat = 4
        let w = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        guard w > 0 else { return }
        let c = tint ?? TH.accent

        for i in 0..<n {
            let lvl = playing ? levels[i] : 0.12
            let h = max(3, bounds.height * lvl)
            let r = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: h)
            let p = NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2)
            c.withAlphaComponent(playing ? 0.55 + 0.4 * lvl : 0.22).setFill()
            p.fill()
        }
    }
}
