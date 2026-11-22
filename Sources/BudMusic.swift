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

    /// Identité du morceau, pour savoir quand la pochette a changé.
    /// L'identifiant persistant de Music quand il existe ; sinon le
    /// couple titre/artiste, qui suffit pour une radio ou un flux.
    var trackKey = ""

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
            set pid to ""
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
                try
                    set pid to (persistent ID of t as string)
                end try
            end try
            set out to st & "|~|" & nm & "|~|" & ar & "|~|" & al
            set out to out & "|~|" & (pp as string) & "|~|" & (du as string)
            set out to out & "|~|" & (vol as string) & "|~|" & sh & "|~|" & rp
            set out to out & "|~|" & pid
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

        // L'identifiant persistant est lu à part : un champ manquant ne doit
        // pas faire perdre les huit autres, d'où le test plutôt qu'un index.
        let pid = p.count >= 10 ? p[9].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        n.trackKey = pid.isEmpty ? (n.title.isEmpty ? "" : "\(n.title)|\(n.artist)|\(n.album)")
                                 : pid
        return n
    }

    /// Exporte la pochette du morceau courant et la rend décodée, avec la
    /// clé du morceau qu'elle représente vraiment.
    ///
    /// Deux précautions. L'écriture du fichier se fait **hors** du bloc
    /// `tell application "Music"` : `open for access` appartient aux
    /// Standard Additions, et Music publie son propre verbe `open` — à
    /// l'intérieur du bloc, c'est le sien qui gagnerait.
    ///
    /// Et le script renvoie la piste qu'il a lue, pas celle qu'on croyait
    /// lire : si le morceau change pendant l'export, la pochette doit être
    /// rangée sous la bonne clé, sinon elle resterait collée au suivant.
    static func exportArtwork() -> (key: String, image: NSImage?)? {
        guard running() else { return nil }
        let path = budSupportDir.appendingPathComponent("cover.dat").path

        let out = osa("""
        set k to ""
        set st to "none"
        set d to missing value
        tell application "Music"
            try
                set t to current track
                try
                    set k to (persistent ID of t as string)
                end try
                if k is "" then set k to ((name of t) & "|" & (artist of t) & "|" & (album of t))
                if (count of artworks of t) > 0 then set d to (raw data of artwork 1 of t)
            end try
        end tell
        if d is not missing value then
            try
                set f to open for access (POSIX file "\(path)") with write permission
                set eof f to 0
                write d to f
                close access f
                set st to "ok"
            on error
                try
                    close access (POSIX file "\(path)")
                end try
                set st to "err"
            end try
        end if
        k & "|~|" & st
        """)

        let p = out.components(separatedBy: "|~|")
        guard p.count >= 2 else { return nil }
        let key = p[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let status = p[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == "ok" else { return (key, nil) }

        // On relit les octets plutôt que de passer le chemin à NSImage :
        // le fichier porte toujours le même nom, et une image construite
        // depuis un chemin peut rendre la précédente.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty, let img = NSImage(data: data) else { return (key, nil) }
        return (key, img)
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

    /// Arrêt, et non pause : Musique revient au début du morceau. Les deux
    /// ne font pas la même chose, et un lecteur qui n'offre que « pause »
    /// oblige à rouvrir Musique pour l'autre.
    static func stop() { tell("stop") }

    // ─────────────────────────────────────────────────────────
    //  Volume du Mac
    //
    //  À ne pas confondre avec celui de Musique. `sound volume`
    //  règle le niveau de l'application dans le mélangeur ;
    //  `output volume` règle la sortie de la machine, celle des
    //  touches du clavier. Baisser l'un n'agit pas sur l'autre,
    //  et chercher pourquoi « le volume ne fait rien » quand
    //  c'est l'autre qui est à zéro peut durer longtemps. BUD
    //  montre donc les deux, nommés.
    // ─────────────────────────────────────────────────────────

    /// Volume de sortie du Mac, 0 à 100, et son état de coupure.
    static func systemVolume() -> (level: Int, muted: Bool) {
        let out = runShell("/usr/bin/osascript",
                           ["-e", "set v to output volume of (get volume settings)",
                            "-e", "set m to output muted of (get volume settings)",
                            "-e", "return (v as string) & \"|\" & (m as string)"])
        let p = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard p.count >= 2 else { return (50, false) }
        // Un Mac sans sortie réglable renvoie -1 : on n'en fait pas un 0,
        // qui laisserait croire que le son est coupé.
        let lvl = Int(p[0].trimmingCharacters(in: .whitespaces)) ?? 50
        let muted = p[1].trimmingCharacters(in: .whitespaces).lowercased() == "true"
        return (lvl < 0 ? 50 : min(100, lvl), muted)
    }

    static func setSystemVolume(_ v: Int) {
        let n = max(0, min(100, v))
        runShell("/usr/bin/osascript", ["-e", "set volume output volume \(n)"])
    }

    static func setSystemMuted(_ m: Bool) {
        runShell("/usr/bin/osascript", ["-e", "set volume output muted \(m)"])
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
//  La pochette
//
//  Un export coûte un aller-retour AppleScript et quelques
//  centaines de kilo-octets : on ne la redemande donc qu'au
//  changement de morceau. Les deux endroits qui l'affichent —
//  le notch et le panneau — passent par ce cache commun, et
//  tous les appelants en attente sont servis par le même
//  export plutôt que d'en déclencher un chacun.
//
//  État mutable partagé, donc : tout s'y fait sur le fil
//  principal, l'export seul part en arrière-plan.
// ═══════════════════════════════════════════════════════════

enum ArtworkStore {
    private static var key = ""
    private static var image: NSImage?
    private static var loading = false
    private static var waiting: [(NSImage?) -> Void] = []

    static func clear() { key = ""; image = nil }

    /// Rend la pochette si elle est déjà là. Sinon lance l'export et
    /// appelle `onLoad` dès qu'elle arrive — y compris pour un morceau
    /// sans pochette, où elle vaut `nil` et où la clé est tout de même
    /// retenue, afin de ne pas réessayer à chaque sondage.
    @discardableResult
    static func request(_ k: String, onLoad: @escaping (NSImage?) -> Void) -> NSImage? {
        guard !k.isEmpty else { clear(); return nil }
        if k == key { return image }

        waiting.append(onLoad)
        guard !loading else { return nil }
        loading = true

        DispatchQueue.global(qos: .utility).async {
            let r = MusicBridge.exportArtwork()
            DispatchQueue.main.async {
                loading = false
                // La clé rendue par le script prime : c'est le morceau
                // réellement exporté, qui n'est pas forcément celui demandé.
                if let got = r, !got.key.isEmpty { key = got.key } else { key = k }
                image = r?.image
                let served = waiting
                waiting = []
                served.forEach { $0(image) }
            }
        }
        return nil
    }
}

/// La pochette, coins arrondis, recadrée sans déformation. Sans image,
/// une note de musique tient la place au lieu d'un carré vide.
final class CoverPlate: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var dim = false { didSet { needsDisplay = true } }
    var radius: CGFloat = 12

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let b = bounds
        let p = NSBezierPath(roundedRect: b, xRadius: radius, yRadius: radius)
        TH.fill(0.10).setFill()
        p.fill()

        if let img = image, img.size.width > 0, img.size.height > 0 {
            NSGraphicsContext.current?.saveGraphicsState()
            p.addClip()
            let s = img.size
            let k = max(b.width / s.width, b.height / s.height)
            let w = s.width * k, h = s.height * k
            img.draw(in: NSRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h))
            NSGraphicsContext.current?.restoreGraphicsState()
            if dim {
                NSColor.black.withAlphaComponent(0.34).setFill()
                p.fill()
            }
        } else {
            drawSymbol("music.note", center: NSPoint(x: b.midX, y: b.midY),
                       size: max(10, b.width * 0.40), weight: .semibold,
                       color: TH.dim(dim ? 0.30 : 0.46))
        }

        TH.fill(0.08).setStroke()
        p.lineWidth = 1
        p.stroke()
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
    private var sysLabel: NSTextField!
    private var sysSlider: NSSlider!
    private var muteBtn: GlassButton!
    private var stopBtn: GlassButton!
    private var sysHeld = false
    private var sysMuted = false
    private var eq: EqualizerView!
    private var hint: NSTextField!
    private var cover: CoverPlate!
    private var last = NowPlaying()
    private var volumeHeld = false

    var onStatus: ((String) -> Void)?
    /// Prévient l'application que l'état de lecture a changé, pour que
    /// le notch et l'animation de BUD suivent sans attendre le sondage.
    var onNowPlaying: ((NowPlaying) -> Void)?

    // « override » : en retirant le paramètre source, cette signature est
    // devenue celle de NSView.init(frame:), qu'il faut donc redéclarer.
    override init(frame: NSRect) {
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
        // La pochette prend la place de l'ancienne note : 68 pt, assez
        // grands pour reconnaître un album d'un coup d'œil.
        cover = CoverPlate(frame: NSRect(x: 24, y: 66, width: 68, height: 68))
        card.addSubview(cover)

        let tx: CGFloat = 108
        let tw2 = W - tx - 132          // 132 : la largeur réservée à l'égaliseur
        titleLabel = mkLabel("—", NSRect(x: tx, y: 110, width: tw2, height: 26), 17, .bold)
        artistLabel = mkLabel("", NSRect(x: tx, y: 88, width: tw2, height: 18), 12.5, .medium, alpha: 0.6)
        albumLabel = mkLabel("", NSRect(x: tx, y: 68, width: tw2, height: 16), 11, .regular, alpha: 0.4)
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
        let tw = (W - 60) / 6
        let specs: [(String, () -> Void)] = [
            ("gobackward.15", { [weak self] in self?.run { MusicBridge.seek(by: -15) } }),
            ("backward.fill", { [weak self] in self?.run { MusicBridge.previous() } }),
            ("play.fill", { [weak self] in self?.run { MusicBridge.playPause() } }),
            ("stop.fill", { [weak self] in self?.run { MusicBridge.stop() } }),
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
        stopBtn = made[3]

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

        // ── Les deux volumes ──
        //
        //  Celui du Mac d'abord : c'est celui des touches du clavier, et
        //  celui qu'on cherche neuf fois sur dix. Celui de Musique ensuite,
        //  qui n'est que le niveau de l'application dans le mélangeur.
        //  Les confondre, c'est passer un quart d'heure à monter l'un
        //  pendant que l'autre est à zéro.
        mkSection(self, my - 26, W, "Volume du Mac")
        muteBtn = GlassButton(frame: NSRect(x: 0, y: my - 58, width: 44, height: 28),
                              title: "", icon: "speaker.slash.fill")
        muteBtn.onClick = { [weak self] _ in self?.toggleMute() }
        addSubview(muteBtn)
        sysSlider = NSSlider(frame: NSRect(x: 54, y: my - 56, width: W - 118, height: 24))
        sysSlider.minValue = 0
        sysSlider.maxValue = 100
        sysSlider.doubleValue = 50
        sysSlider.isContinuous = true
        sysSlider.target = self
        sysSlider.action = #selector(systemVolumeChanged(_:))
        addSubview(sysSlider)
        sysLabel = mkLabel("50", NSRect(x: W - 58, y: my - 56, width: 58, height: 20),
                           13, .semibold, alpha: 0.7, .right)
        sysLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        addSubview(sysLabel)

        mkSection(self, my - 84, W, "Volume de Musique")
        volSlider = NSSlider(frame: NSRect(x: 0, y: my - 116, width: W - 64, height: 24))
        volSlider.minValue = 0
        volSlider.maxValue = 100
        volSlider.doubleValue = 50
        volSlider.isContinuous = true
        volSlider.target = self
        volSlider.action = #selector(volumeChanged(_:))
        addSubview(volSlider)
        volLabel = mkLabel("50", NSRect(x: W - 58, y: my - 116, width: 58, height: 20),
                           13, .semibold, alpha: 0.7, .right)
        volLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        addSubview(volLabel)

        hint = NSTextField(frame: NSRect(x: 0, y: 8, width: W, height: 40))
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

    /// Le volume du Mac, écrit pendant le glissement et relu seulement
    /// après : relire en même temps ferait sauter le curseur sous le doigt.
    @objc private func systemVolumeChanged(_ s: NSSlider) {
        let v = Int(s.doubleValue.rounded())
        sysLabel.stringValue = "\(v)"
        sysHeld = true
        MusicBridge.setSystemVolume(v)
        // Monter le son d'un Mac coupé doit le rallumer : autrement le
        // curseur bouge et rien ne sort.
        if sysMuted && v > 0 {
            MusicBridge.setSystemMuted(false)
            sysMuted = false
            muteBtn.selected = false
        }
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(releaseSystemVolume), object: nil)
        perform(#selector(releaseSystemVolume), with: nil, afterDelay: 0.8)
    }

    @objc private func releaseSystemVolume() { sysHeld = false }

    private func toggleMute() {
        sysMuted.toggle()
        MusicBridge.setSystemMuted(sysMuted)
        muteBtn.selected = sysMuted
        hint.stringValue = sysMuted ? "Son du Mac coupé." : "Son du Mac rétabli."
    }

    /// Relit le volume du Mac. Appelé par le sondage du panneau, pas par
    /// un minuteur à lui : un aller-retour AppleScript par seconde pour
    /// un curseur serait cher payé.
    private func refreshSystemVolume() {
        guard !sysHeld else { return }
        let (lvl, muted) = MusicBridge.systemVolume()
        sysSlider.doubleValue = Double(lvl)
        sysLabel.stringValue = muted ? "coupé" : "\(lvl)"
        sysMuted = muted
        muteBtn.selected = muted
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
            bar.value = 0
            eq.playing = false
            hint.stringValue = "Ouvrez Musique pour que BUD prenne la main. "
                + "Le pilotage demande l'autorisation Automatisation au premier usage."
            cover.image = nil
            cover.dim = true
            ArtworkStore.clear()
            // Le volume du Mac ne dépend pas de Musique : il reste réglable
            // même l'application fermée, et c'est souvent là qu'on le cherche.
            refreshSystemVolume()
            return
        }

        // En pause, la pochette reste affichée mais s'assombrit : l'album
        // ne change pas parce que la lecture s'arrête.
        cover.dim = !n.playing
        cover.image = ArtworkStore.request(n.trackKey) { [weak self] img in
            self?.cover.image = img
        }
        titleLabel.stringValue = n.hasTrack ? n.title : "Rien en lecture"
        artistLabel.stringValue = n.artist
        albumLabel.stringValue = n.album
        timeLabel.stringValue = n.timeText
        bar.value = CGFloat(n.progress)
        eq.playing = n.playing

        if !volumeHeld {
            volSlider.doubleValue = Double(n.volume)
            volLabel.stringValue = "\(n.volume)"
        }
        refreshSystemVolume()

        // L'icône dit l'action à venir, pas l'état présent : pendant la
        // lecture on offre la pause, à l'arrêt on offre la lecture.
        playBtn.iconName = n.playing ? "pause.fill" : "play.fill"
        stopBtn.enabledFlag = n.playing || n.hasTrack

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
