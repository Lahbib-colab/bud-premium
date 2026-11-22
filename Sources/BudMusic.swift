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
    /// Pourquoi Musique n'a rien dit, quand elle n'a rien dit. Une phrase
    /// en clair, jamais un code : une liste vide sans explication laissait
    /// croire à une panne, mais « erreur de syntaxe (-2741) » n'explique
    /// rien à qui n'écrit pas d'AppleScript.
    var trouble = ""
    /// L'autorisation Automatisation manque : le panneau propose alors
    /// d'ouvrir le bon volet des réglages.
    var needsAuth = false

    /// Ce que BUD a vraiment pu lire. Ce qu'il ne sait pas, il ne
    /// l'affiche pas comme valant zéro : un curseur de volume à 50 quand
    /// la valeur est inconnue est un mensonge, et on cherche longtemps
    /// pourquoi le son ne suit pas.
    var volumeKnown = false
    var modesKnown = false         // aléatoire et répétition
    var positionKnown = false

    enum Source { case none, script, core, feed }
    var source: Source = .none

    var hasTrack: Bool { !title.isEmpty }

    /// « 1:42 / 3:58 ». Vide si la position n'est pas connue : mieux vaut
    /// pas de minuterie qu'une minuterie fausse.
    var timeText: String {
        guard duration > 0, positionKnown else { return "" }
        return "\(mmss(position)) / \(mmss(duration))"
    }
    var progress: Double {
        guard duration > 0, positionKnown else { return 0 }
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

    /// Complète par ce que Musique a annoncé d'elle-même.
    ///
    /// Deux cas, et la différence compte. Quand le script a parlé, il fait
    /// foi : s'il dit « rien en lecture », c'est qu'il n'y a rien, et une
    /// annonce ancienne ne doit pas ressusciter le morceau précédent.
    /// Quand le script n'a rien pu dire, l'annonce devient la seule source.
    mutating func fill(from a: MusicAnnounce?, scriptSpoke: Bool, estimate: Double?) {
        guard let a = a, a.hasTrack else { return }
        if scriptSpoke {
            if duration <= 0 { duration = a.duration }
            if album.isEmpty { album = a.album }
            return
        }
        source = .feed
        title = a.title
        artist = a.artist
        album = a.album
        playing = a.playing
        duration = a.duration
        trackKey = a.trackKey
        if let p = estimate {
            position = p
            positionKnown = true
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  Ce qui peut mal tourner
//
//  Trois familles, et elles ne se disent pas pareil.
//
//  L'autorisation manquante est l'affaire de l'utilisateur :
//  on dit où cliquer. Musique fermée est un fait : on le dit.
//
//  Une erreur de syntaxe, en revanche, est une faute de BUD —
//  il a mal formé sa demande. L'afficher revient à montrer la
//  trace d'une pile à quelqu'un qui voulait écouter un disque.
//  Elle part donc dans un journal, et l'interface se contente
//  de dire ce qu'elle sait faire malgré tout.
// ═══════════════════════════════════════════════════════════

enum MusicFault {
    case none
    case notAuthorized
    case notRunning
    case malformed(String)
    case other(String)

    /// La phrase montrée. Vide quand il n'y a rien d'utile à dire.
    var userText: String {
        switch self {
        case .none, .malformed:
            return ""
        case .notAuthorized:
            return "Musique est ouverte mais BUD n'a pas le droit de la piloter. "
                + "Réglages Système → Confidentialité et sécurité → Automatisation → BUD, "
                + "puis cochez Musique. Une mise à jour de BUD peut retirer cette coche."
        case .notRunning:
            return "Musique s'est fermée."
        case .other:
            return "Musique n'a pas répondu."
        }
    }

    var needsAuth: Bool { if case .notAuthorized = self { return true }; return false }

    static func classify(_ err: String) -> MusicFault {
        if err.isEmpty { return .none }
        let low = err.lowercased()
        if err.contains("-1743") || low.contains("not authorized") { return .notAuthorized }
        if err.contains("-600") || err.contains("-609") || low.contains("isn't running") {
            return .notRunning
        }
        // -2741 et -2740 : le script n'a pas compilé. -1708 : un terme que
        // l'application ne connaît pas. Dans les deux cas BUD a tort.
        if low.contains("syntax error") || err.contains("-2741")
            || err.contains("-2740") || err.contains("-1708") {
            return .malformed(err)
        }
        return .other(err)
    }
}

enum MusicBridge {
    static let appName = "Music"
    static let bundleID = "com.apple.Music"

    /// Toute demande à Musique passe par là. Une file série, pour deux
    /// raisons : jamais deux osascript en vol en même temps — l'export de
    /// pochette et la lecture d'état se chevauchaient et se volaient leurs
    /// messages d'erreur — et jamais rien sur le fil principal.
    private static let q = DispatchQueue(label: "fr.lahbib.bud.music.script",
                                         qos: .userInitiated)

    /// Sans lancer de processus : la liste des applications actives
    /// suffit, et un sondage toutes les quatre secondes doit rester gratuit
    /// quand Music est fermée.
    static func running() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    // ─────────────────────────────────────────────────────────
    //  AppleScript
    //
    //  Les variables portent toutes un préfixe « bud ». Ce n'est
    //  pas de la coquetterie : `st` est un mot réservé
    //  d'AppleScript — un suffixe ordinal, comme dans « 1st
    //  item » — et `set st to "stopped"` empêchait le script
    //  **entier** de compiler. Les blocs `try` n'y pouvaient
    //  rien : ils attrapent les erreurs d'exécution, et une
    //  erreur de compilation arrive avant que la première ligne
    //  ne s'exécute. Un seul mot de deux lettres rendait donc
    //  muets à la fois l'état de lecture et la pochette.
    //
    //  Un identifiant préfixé ne peut collisionner ni avec un
    //  mot du langage ni avec un terme du dictionnaire de
    //  Musique, aujourd'hui ni dans la version d'après.
    // ─────────────────────────────────────────────────────────

    private struct Reply {
        let out: String
        let fault: MusicFault
        var ok: Bool { if case .none = fault { return true }; return false }
    }

    private static func osa(_ script: String) -> Reply {
        let r = runShellDetailed("/usr/bin/osascript", ["-e", script])
        let fault = r.status == 0 ? MusicFault.none : MusicFault.classify(r.err)
        if case .malformed(let detail) = fault { logFault(detail) }
        return Reply(out: r.out, fault: fault)
    }

    /// Un script mal formé est un défaut à corriger, pas un message à
    /// afficher. Il est donc écrit là où on peut le retrouver, et le
    /// journal est borné pour ne pas grossir sans fin.
    private static func logFault(_ detail: String) {
        let url = budSupportDir.appendingPathComponent("music.log")
        let line = "\(shortDateString()) \(detail.prefix(400))\n"
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += line
        if text.count > 32_768 { text = String(text.suffix(24_576)) }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// AppleScript peut rendre « 12,345 » selon la langue du système.
    private static func num(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private static let sep = "|~|"

    /// Le relevé complet. Chaque propriété dans son propre `try` : si une
    /// version de Musique n'expose plus la répétition, on perd cette seule
    /// information — mais seulement si le script compile, d'où le palier
    /// suivant.
    private static let fullScript = """
    tell application "Music"
        set budState to "stopped"
        set budName to ""
        set budArtist to ""
        set budAlbum to ""
        set budPos to -1
        set budDur to 0
        set budVol to -1
        set budShuffle to "unknown"
        set budRepeat to "unknown"
        set budIdent to ""
        try
            set budState to (player state as text)
        end try
        try
            set budVol to (sound volume as integer)
        end try
        try
            set budShuffle to (shuffle enabled as text)
        end try
        try
            set budRepeat to (song repeat as text)
        end try
        try
            set budItem to current track
            set budName to (name of budItem as text)
            set budArtist to (artist of budItem as text)
            set budAlbum to (album of budItem as text)
            set budDur to (duration of budItem)
            try
                set budPos to (player position)
                if budPos is missing value then set budPos to -1
            end try
            try
                set budIdent to (persistent ID of budItem as text)
            end try
        end try
        set budOut to budState & "|~|" & budName & "|~|" & budArtist & "|~|" & budAlbum
        set budOut to budOut & "|~|" & (budPos as text) & "|~|" & (budDur as text)
        set budOut to budOut & "|~|" & (budVol as text) & "|~|" & budShuffle & "|~|" & budRepeat
        set budOut to budOut & "|~|" & budIdent
        return budOut
    end tell
    """

    /// Le noyau sûr : quatre termes, inchangés depuis iTunes. Il sert quand
    /// le relevé complet ne compile pas, pour qu'un terme disparu du
    /// dictionnaire coûte le volume et les modes, pas le titre du morceau.
    private static let coreScript = """
    tell application "Music"
        set budState to "stopped"
        set budName to ""
        set budArtist to ""
        set budAlbum to ""
        try
            set budState to (player state as text)
        end try
        try
            set budItem to current track
            set budName to (name of budItem as text)
            set budArtist to (artist of budItem as text)
            set budAlbum to (album of budItem as text)
        end try
        return budState & "|~|" & budName & "|~|" & budArtist & "|~|" & budAlbum
    end tell
    """

    /// Vrai tant que le relevé complet compile. Mis à faux au premier
    /// script mal formé pour ne pas relancer un processus condamné toutes
    /// les quatre secondes.
    private static var fullUsable = true

    /// L'état, lu sur la file `q`. L'annonce et l'estimation arrivent en
    /// paramètres : elles sont écrites sur le fil principal, et deux files
    /// qui touchent la même variable, c'est une course.
    private static func readState(feed: MusicAnnounce?, estimate: Double?) -> NowPlaying {
        var n = NowPlaying()
        guard running() else {
            DispatchQueue.main.async { MusicFeed.forget() }
            return n
        }
        n.available = true

        if fullUsable {
            let r = osa(fullScript)
            let p = r.out.components(separatedBy: sep)
            if r.ok && p.count >= 10 {
                n.source = .script
                n.playing = p[0].lowercased().contains("playing")
                n.title = clean(p[1])
                n.artist = clean(p[2])
                n.album = clean(p[3])
                let pos = num(p[4])
                n.position = max(0, pos)
                n.positionKnown = pos >= 0
                n.duration = num(p[5])
                let vol = Int(num(p[6]))
                n.volume = vol < 0 ? 50 : min(100, vol)
                n.volumeKnown = vol >= 0
                let sh = clean(p[7]).lowercased()
                let rp = clean(p[8]).lowercased()
                n.modesKnown = sh != "unknown" && rp != "unknown"
                n.shuffle = sh.contains("true")
                n.repeatMode = n.modesKnown ? rp : "off"
                let ident = clean(p[9])
                n.trackKey = ident.isEmpty
                    ? (n.title.isEmpty ? "" : "\(n.title)|\(n.artist)|\(n.album)")
                    : ident
                n.fill(from: feed, scriptSpoke: true, estimate: estimate)
                return n
            }
            if case .malformed = r.fault { fullUsable = false }
            else {
                // Autorisation refusée, Musique partie : inutile d'essayer
                // le noyau, il échouerait de la même façon.
                n.trouble = r.fault.userText
                n.needsAuth = r.fault.needsAuth
                n.fill(from: feed, scriptSpoke: false, estimate: estimate)
                return n
            }
        }

        let r = osa(coreScript)
        let p = r.out.components(separatedBy: sep)
        if r.ok && p.count >= 4 {
            n.source = .core
            n.playing = p[0].lowercased().contains("playing")
            n.title = clean(p[1])
            n.artist = clean(p[2])
            n.album = clean(p[3])
            n.trackKey = n.title.isEmpty ? "" : "\(n.title)|\(n.artist)|\(n.album)"
            n.fill(from: feed, scriptSpoke: true, estimate: estimate)
            return n
        }

        // Plus rien du côté des scripts : il reste ce que Musique annonce
        // d'elle-même. On le dit sans jargon, et sans prétendre que la
        // liste est vide alors qu'on n'en sait rien.
        n.trouble = r.fault.userText
        n.needsAuth = r.fault.needsAuth
        n.fill(from: feed, scriptSpoke: false, estimate: estimate)
        if n.trouble.isEmpty && !n.hasTrack {
            n.trouble = "BUD attend le prochain changement de morceau pour connaître le titre."
        }
        return n
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lit l'état hors du fil principal et rend le résultat sur le fil
    /// principal. C'est la seule entrée publique : il n'existe plus de
    /// version bloquante, donc plus de façon d'attendre osascript sous
    /// l'animation.
    static func read(_ done: @escaping (NowPlaying) -> Void) {
        let snapshot = {
            let feed = MusicFeed.last
            let estimate = MusicFeed.estimatedPosition()
            q.async {
                let n = readState(feed: feed, estimate: estimate)
                DispatchQueue.main.async { done(n) }
            }
        }
        if Thread.isMainThread { snapshot() }
        else { DispatchQueue.main.async(execute: snapshot) }
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
    static func exportArtwork(_ done: @escaping ((key: String, image: NSImage?)?) -> Void) {
        guard running() else { done(nil); return }
        q.async {
            let r = artworkNow()
            DispatchQueue.main.async { done(r) }
        }
    }

    private static func artworkNow() -> (key: String, image: NSImage?)? {
        let path = budSupportDir.appendingPathComponent("cover.dat").path

        let r = osa("""
        set budKey to ""
        set budStatus to "none"
        set budData to missing value
        tell application "Music"
            try
                set budItem to current track
                try
                    set budKey to (persistent ID of budItem as text)
                end try
                if budKey is "" then
                    set budKey to ((name of budItem as text) & "|" & (artist of budItem as text) & "|" & (album of budItem as text))
                end if
                if (count of artworks of budItem) > 0 then
                    set budData to (raw data of artwork 1 of budItem)
                end if
            end try
        end tell
        if budData is not missing value then
            try
                set budFile to open for access (POSIX file "\(path)") with write permission
                set eof budFile to 0
                write budData to budFile
                close access budFile
                set budStatus to "ok"
            on error
                try
                    close access (POSIX file "\(path)")
                end try
                set budStatus to "err"
            end try
        end if
        return budKey & "|~|" & budStatus
        """)

        let p = r.out.components(separatedBy: sep)
        guard p.count >= 2 else { return nil }
        let key = clean(p[0])
        let status = clean(p[1])
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

    // ─────────────────────────────────────────────────────────
    //  Les commandes
    //
    //  Toutes rendent la main tout de suite. Le panneau n'attend
    //  donc plus la réponse de Musique pour bouger : il change
    //  son bouton au clic et la confirmation vient après. C'est
    //  ce qui fait la différence entre un bouton vif et un
    //  bouton qu'on reclique parce qu'on doute.
    // ─────────────────────────────────────────────────────────

    private static func tell(_ cmd: String) {
        guard running() else { launch(); return }
        q.async { _ = osa("tell application \"\(appName)\" to \(cmd)") }
    }

    static func playPause() { tell("playpause") }
    static func play()      { tell("play") }
    static func pause()     { tell("pause") }
    static func next()      { tell("next track") }
    static func previous()  { tell("previous track") }

    /// Arrêt, et non pause : Musique revient au début du morceau. Les deux
    /// ne font pas la même chose, et un lecteur qui n'offre que « pause »
    /// oblige à rouvrir Musique pour l'autre.
    static func stop() { tell("stop") }

    /// Recule ou avance dans le morceau. Music accepte l'écriture
    /// directe de la position, sans passer par les touches média.
    static func seek(by delta: Double) {
        guard running() else { return }
        q.async {
            _ = osa("""
            tell application "Music"
                try
                    set budPos to (player position)
                    set budDur to (duration of current track)
                    set budTarget to budPos + (\(delta))
                    if budTarget < 0 then set budTarget to 0
                    if budTarget > (budDur - 1) then set budTarget to (budDur - 1)
                    set player position to budTarget
                end try
            end tell
            """)
        }
    }

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
    ///
    /// CoreAudio seul : c'est un appel direct au pilote, qui revient en
    /// quelques microsecondes. Il n'y a donc rien à sortir du fil
    /// principal ici, et surtout plus d'osascript de secours — lancer un
    /// processus pour lire un volume était la latence que vous sentiez.
    static func systemVolume() -> (level: Int, muted: Bool, settable: Bool) {
        guard let v = SystemAudio.volume() else { return (50, false, false) }
        return (Int((v * 100).rounded()), SystemAudio.muted() ?? false, true)
    }

    /// CoreAudio d'abord. Le filet AppleScript ne sert plus qu'aux rares
    /// sorties dont CoreAudio n'expose pas le volume, et il part sur la
    /// file série : écrire un volume ne doit pas retenir le fil principal.
    static func setSystemVolume(_ v: Int) {
        let n = max(0, min(100, v))
        if SystemAudio.setVolume(Float(n) / 100) { return }
        q.async { _ = osa("set volume output volume \(n)") }
    }

    static func setSystemMuted(_ m: Bool) {
        if SystemAudio.setMuted(m) { return }
        q.async { _ = osa("set volume output muted \(m)") }
    }

    // ─────────────────────────────────────────────────────────
    //  Volume de Musique
    //
    //  Le curseur est continu : un glissement produit des
    //  dizaines de valeurs. Lancer un osascript par valeur
    //  saturait la file et le son suivait le doigt avec une
    //  seconde de retard. On n'en garde donc qu'une en attente,
    //  la dernière, et une seule écriture en vol.
    // ─────────────────────────────────────────────────────────

    private static var pendingVolume: Int?
    private static var volumeWriting = false

    static func setVolume(_ v: Int) {
        let n = max(0, min(100, v))
        if Thread.isMainThread { pendingVolume = n; pumpVolume() }
        else { DispatchQueue.main.async { pendingVolume = n; pumpVolume() } }
    }

    /// Sur le fil principal, qui sérialise l'accès aux deux variables.
    private static func pumpVolume() {
        guard !volumeWriting, let n = pendingVolume else { return }
        pendingVolume = nil
        volumeWriting = true
        q.async {
            _ = osa("tell application \"Music\" to set sound volume to \(n)")
            DispatchQueue.main.async {
                volumeWriting = false
                pumpVolume()
            }
        }
    }

    /// Monte ou baisse le volume de Musique d'un cran. La lecture et
    /// l'écriture restent sur la même file série : sans cela, deux « monte
    /// le son » rapprochés lisaient tous deux l'ancienne valeur et le
    /// second annulait le premier.
    static func changeVolume(by delta: Int) {
        guard running() else { return }
        q.async {
            let r = osa("tell application \"Music\" to get sound volume")
            guard r.ok else { return }
            let target = max(0, min(100, Int(num(r.out)) + delta))
            _ = osa("tell application \"Music\" to set sound volume to \(target)")
        }
    }

    static func toggleShuffle() {
        guard running() else { return }
        q.async {
            _ = osa("""
            tell application "Music"
                try
                    set shuffle enabled to not (shuffle enabled)
                end try
            end tell
            """)
        }
    }

    /// off → all → one → off
    static func cycleRepeat() {
        guard running() else { return }
        q.async {
            _ = osa("""
            tell application "Music"
                try
                    set budMode to (song repeat as text)
                    if budMode is "off" then
                        set song repeat to all
                    else if budMode is "all" then
                        set song repeat to one
                    else
                        set song repeat to off
                    end if
                end try
            end tell
            """)
        }
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

        // L'export part sur la file série de la passerelle, celle qui porte
        // déjà la lecture d'état : deux osascript en vol se gênaient, et le
        // retour arrive sur le fil principal, où vit ce cache.
        MusicBridge.exportArtwork { r in
            loading = false
            // La clé rendue par le script prime : c'est le morceau
            // réellement exporté, qui n'est pas forcément celui demandé.
            if let got = r, !got.key.isEmpty { key = got.key } else { key = k }
            image = r?.image
            let served = waiting
            waiting = []
            served.forEach { $0(image) }
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
    private var authBtn: GlassButton!
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
        // Chaque bouton dit d'abord ce qu'il attend, puis le demande. Le
        // saut de quinze secondes bouge la barre tout de suite ; la lecture
        // retourne l'icône tout de suite ; l'arrêt éteint l'égaliseur tout
        // de suite. Musique confirme quatre dixièmes plus tard, et corrige
        // si elle a refusé.
        let specs: [(String, () -> Void)] = [
            ("gobackward.15", { [weak self] in
                self?.act({ $0.position = max(0, $0.position - 15) }) { MusicBridge.seek(by: -15) } }),
            ("backward.fill", { [weak self] in
                self?.act({ _ in }) { MusicBridge.previous() } }),
            ("play.fill", { [weak self] in
                self?.act({ $0.playing.toggle() }) { MusicBridge.playPause() } }),
            ("stop.fill", { [weak self] in
                self?.act({ $0.playing = false; $0.position = 0 }) { MusicBridge.stop() } }),
            ("forward.fill", { [weak self] in
                self?.act({ _ in }) { MusicBridge.next() } }),
            ("goforward.15", { [weak self] in
                self?.act({ $0.position = min($0.duration, $0.position + 15) }) { MusicBridge.seek(by: 15) } })
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
        shuffleBtn.onClick = { [weak self] _ in
            self?.act({ $0.shuffle.toggle() }) { MusicBridge.toggleShuffle() }
        }
        repeatBtn = GlassButton(frame: NSRect(x: mw + 12, y: my, width: mw, height: 46),
                                title: "Répétition", icon: "repeat")
        repeatBtn.onClick = { [weak self] _ in
            self?.act({ n in
                n.repeatMode = n.repeatMode == "off" ? "all"
                             : (n.repeatMode == "all" ? "one" : "off")
            }) { MusicBridge.cycleRepeat() }
        }
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

        authBtn = GlassButton(frame: NSRect(x: (W - 230) / 2, y: 54, width: 230, height: 30),
                              title: "Ouvrir les réglages d'automatisation",
                              icon: "lock.open", compact: true)
        authBtn.onClick = { [weak self] _ in self?.openAutomationSettings() }
        authBtn.isHidden = true
        addSubview(authBtn)

        followSystemVolume()

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
        MusicBridge.setSystemVolume(v)   // appel direct : aucune attente
        // Monter le son d'un Mac coupé doit le rallumer : autrement le
        // curseur bouge et rien ne sort.
        if sysMuted && v > 0 {
            MusicBridge.setSystemMuted(false)
            sysMuted = false
            muteBtn.selected = false
        }
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(releaseSystemVolume), object: nil)
        // Court délai : il ne sert plus qu'à ignorer l'écho de notre propre
        // écriture, pas à attendre une relecture. Huit dixièmes étaient
        // calés sur AppleScript ; un cinquième suffit à CoreAudio.
        perform(#selector(releaseSystemVolume), with: nil, afterDelay: 0.2)
    }

    @objc private func releaseSystemVolume() { sysHeld = false }

    private func toggleMute() {
        sysMuted.toggle()
        MusicBridge.setSystemMuted(sysMuted)
        muteBtn.selected = sysMuted
        hint.stringValue = sysMuted ? "Son du Mac coupé." : "Son du Mac rétabli."
    }

    /// Relit le volume du Mac.
    ///
    /// Appelé par l'écouteur CoreAudio, qui prévient dès que le volume
    /// change — touches du clavier, centre de contrôle, autre application.
    /// Plus de sondage : il n'y a rien à interroger, le système parle.
    private func refreshSystemVolume() {
        guard !sysHeld else { return }
        let v = MusicBridge.systemVolume()
        sysSlider.doubleValue = Double(v.level)
        sysSlider.isEnabled = v.settable
        muteBtn.enabledFlag = v.settable
        sysLabel.stringValue = !v.settable ? "n/d" : (v.muted ? "coupé" : "\(v.level)")
        sysMuted = v.muted
        muteBtn.selected = v.muted
    }

    /// Branche le panneau sur les changements de volume du système.
    private func followSystemVolume() {
        SystemAudio.onChange = { [weak self] in
            guard let s = self else { return }
            // Pendant un glissement, c'est le doigt qui commande : on
            // ignore l'écho du système, sans quoi le curseur sauterait
            // entre la valeur tenue et celle qui revient.
            guard !s.sysHeld else { return }
            s.refreshSystemVolume()
        }
        SystemAudio.startObserving()
        refreshSystemVolume()
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

    /// Exécute une commande, et montre tout de suite ce qu'elle va faire.
    ///
    /// L'ordre compte. Avant, le bouton attendait la réponse de Musique
    /// pour changer d'aspect : trois dixièmes de seconde pendant lesquels
    /// rien ne bougeait, assez pour qu'on reclique. Maintenant l'affichage
    /// part devant — `expect` applique l'effet attendu localement — et la
    /// relecture ne sert plus qu'à corriger si Musique a refusé.
    private func act(_ expect: (inout NowPlaying) -> Void, _ body: @escaping () -> Void) {
        var guess = last
        expect(&guess)
        apply(guess, confirmed: false)
        body()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        MusicBridge.read { [weak self] n in self?.apply(n) }
    }

    // ─────────────────────────────────────────────────────────
    //  L'horloge de lecture
    //
    //  L'état est relu toutes les quatre secondes. Avec ça
    //  seul, le compteur avançait par bonds de quatre et la
    //  barre sautait. Le temps, lui, passe tout seul : il
    //  suffit de l'ajouter entre deux relectures, et de se
    //  recaler sur la vérité quand elle arrive.
    // ─────────────────────────────────────────────────────────

    private var clockTimer: Timer?
    private var clockBase: Double = 0
    private var clockAt = Date()

    private func startClock() {
        guard clockTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tickClock() }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func tickClock() {
        guard last.playing, last.positionKnown, last.duration > 0 else { return }
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let p = min(last.duration, clockBase + Date().timeIntervalSince(clockAt))
        last.position = p
        timeLabel.stringValue = last.timeText
        bar.value = CGFloat(last.progress)
    }

    func apply(_ n: NowPlaying) { apply(n, confirmed: true) }

    /// `confirmed` distingue l'état relu de l'état supposé. Un état supposé
    /// bouge les boutons mais ne touche ni la pochette ni l'horloge : on
    /// n'a pas de raison de croire que le morceau a changé parce qu'on
    /// vient d'appuyer sur « aléatoire ».
    func apply(_ n: NowPlaying, confirmed: Bool) {
        let trackChanged = n.trackKey != last.trackKey
        let positionMoved = abs(n.position - last.position) > 1.5
        last = n
        onNowPlaying?(n)

        if confirmed && (trackChanged || positionMoved || !n.playing) {
            clockBase = n.position
            clockAt = Date()
        }
        if n.playing && n.positionKnown { startClock() } else { stopClock() }

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

        // Un volume inconnu n'est pas un volume à 50 : le curseur se
        // désactive au lieu de montrer un chiffre inventé, et c'est le
        // volume du Mac juste au-dessus qui reste la vraie poignée.
        if !volumeHeld {
            volSlider.isEnabled = n.volumeKnown
            volSlider.doubleValue = Double(n.volume)
            volLabel.stringValue = n.volumeKnown ? "\(n.volume)" : "n/d"
        }
        // L'icône dit l'action à venir, pas l'état présent : pendant la
        // lecture on offre la pause, à l'arrêt on offre la lecture.
        playBtn.iconName = n.playing ? "pause.fill" : "play.fill"
        stopBtn.enabledFlag = n.playing || n.hasTrack

        shuffleBtn.enabledFlag = n.modesKnown
        repeatBtn.enabledFlag = n.modesKnown
        shuffleBtn.prominent = n.shuffle
        repeatBtn.prominent = n.repeatMode != "off"
        repeatBtn.title = n.repeatMode == "one" ? "Répéter ce titre"
                        : (n.repeatMode == "all" ? "Répéter tout" : "Répétition")
        repeatBtn.iconName = n.repeatMode == "one" ? "repeat.1" : "repeat"

        // Un obstacle l'emporte sur tout le reste : tant qu'on ne dit pas
        // pourquoi rien ne s'affiche, l'utilisateur croit à une panne.
        // Mais la phrase est toujours en clair, et le bouton d'autorisation
        // n'apparaît que si c'est bien l'autorisation qui manque — le
        // proposer pour n'importe quel ennui envoyait cocher une case déjà
        // cochée.
        if !n.trouble.isEmpty {
            hint.stringValue = n.trouble
            hint.textColor = warnColor
            authBtn.isHidden = !n.needsAuth
        } else {
            hint.textColor = TH.dim(0.42)
            authBtn.isHidden = true
            hint.stringValue = n.playing
                ? "BUD s'animera dans le notch pendant la lecture."
                : (n.hasTrack ? "En pause." : "Lancez un morceau dans Musique.")
        }
    }

    /// Ouvre directement le volet d'automatisation des réglages système.
    /// Quand l'autorisation a été retirée, la redemander par un événement
    /// Apple ne provoque plus de dialogue : macOS refuse en silence. Il
    /// faut y retourner à la main, et autant y conduire.
    @objc private func openAutomationSettings() {
        let u = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }

    /// Intentions du chat. Renvoie la phrase que BUD répondra.
    ///
    /// Le chat répond depuis le dernier état connu, jamais en interrogeant
    /// Musique sur-le-champ : cette fonction est appelée sur le fil
    /// principal, et un osascript synchrone y gelait la frappe le temps
    /// d'un aller-retour. L'état a au plus quatre secondes, et l'annonce de
    /// Musique le corrige dès qu'un morceau change.
    func command(_ what: String) -> String {
        switch what {
        case "play", "pause", "playpause", "toggle":
            act({ $0.playing.toggle() }) { MusicBridge.playPause() }
            return "C'est fait."
        case "next":
            act({ _ in }) { MusicBridge.next() }
            return "Morceau suivant."
        case "previous", "prev":
            act({ _ in }) { MusicBridge.previous() }
            return "Morceau précédent."
        case "volup", "up":
            MusicBridge.changeVolume(by: 10); refresh()
            return "Volume monté."
        case "voldown", "down":
            MusicBridge.changeVolume(by: -10); refresh()
            return "Volume baissé."
        case "shuffle", "aleatoire":
            act({ $0.shuffle.toggle() }) { MusicBridge.toggleShuffle() }
            return "Lecture aléatoire basculée."
        case "open":
            MusicBridge.launch()
            return "J'ouvre Musique."
        default:
            refresh()
            if !MusicBridge.running() { return "Musique est fermée." }
            var n = last
            n.fill(from: MusicFeed.last, scriptSpoke: n.hasTrack,
                   estimate: MusicFeed.estimatedPosition())
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
