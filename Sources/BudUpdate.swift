import Cocoa
import CryptoKit

// ═══════════════════════════════════════════════════════════
//  Mise à jour intégrée
//
//  BUD interroge l'API des releases GitHub, seule source de
//  vérité : la release porte à la fois le numéro de version,
//  l'archive et les empreintes. Rien n'ouvre le navigateur.
//
//  Le parcours, et ce qui l'arrête :
//
//    1. Vérifier    la release est plus récente que ce paquet
//    2. Télécharger l'archive .zip, avec progression réelle
//    3. Contrôler   SHA-256 publié, puis le paquet extrait :
//                   identifiant, version, architecture
//    4. Installer   un script détaché attend la fin de BUD
//                   (par son PID), échange les paquets,
//                   relance, et revient à l'ancien si le
//                   nouveau ne tient pas debout
//
//  Tant que l'étape 4 n'a pas commencé, l'installation
//  actuelle n'est pas touchée : tout le reste se passe dans
//  un dossier temporaire. Un échec avant ce point ne coûte
//  qu'un téléchargement.
//
//  Un canal personnalisé au vieux format reste accepté :
//  { "version": "…", "notes": "…", "url": "…" }
// ═══════════════════════════════════════════════════════════

struct UpdateInfo {
    let version: String
    let notes: String
    let url: String            // l'archive que BUD télécharge
    var pageURL: String = ""   // la page de la release
    var assetName: String = "" // son nom, pour retrouver sa ligne d'empreinte
    var sha256URL: String = "" // SHA256.txt publié avec la release
    var size: Int64 = 0        // annoncée par GitHub, pour la progression

    /// Une archive s'installe sans intervention ; un .dmg demanderait
    /// qu'on le monte et qu'on glisse — ce n'est plus de l'intégré.
    var installable: Bool { url.lowercased().hasSuffix(".zip") }

    /// La première ligne utile des notes, pour une bannière d'une ligne.
    var headline: String {
        notes.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-> ").union(.whitespaces)) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// Les outils sans état : lecture du canal, comparaison, empreintes.
enum BudUpdater {

    static let repo = "Lahbib-colab/bud-premium"
    static let defaultChannel =
        "https://api.github.com/repos/Lahbib-colab/bud-premium/releases/latest"

    /// L'architecture de CE binaire, décidée à la compilation.
    static var myArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// La version de ce paquet, lue dans son Info.plist — celle que macOS
    /// affiche — avec la constante du code en secours.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? budVersion
    }

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
        // L'API GitHub refuse les requêtes sans identification de client.
        req.setValue("BUD-Premium/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let e = err { done(nil, e.localizedDescription); return }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    done(nil, http.statusCode == 404 ? "aucune version publiée pour l'instant"
                              : (http.statusCode == 403 ? "GitHub limite les requêtes, réessayez dans une heure"
                                 : "canal introuvable (code \(http.statusCode))"))
                    return
                }
                guard let d = data,
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    done(nil, "réponse illisible")
                    return
                }

                // Forme 1 : une release GitHub.
                if let tag = j["tag_name"] as? String {
                    let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                    var zip = "", zipName = "", other = "", sums = ""
                    var size: Int64 = 0
                    for a in j["assets"] as? [[String: Any]] ?? [] {
                        guard let raw = a["name"] as? String,
                              let u = a["browser_download_url"] as? String else { continue }
                        let name = raw.lowercased()
                        if name.hasSuffix(".zip") {
                            zip = u; zipName = raw
                            size = (a["size"] as? NSNumber)?.int64Value ?? 0
                        } else if name.hasSuffix(".dmg") && other.isEmpty { other = u }
                        else if name == "sha256.txt" { sums = u }
                    }
                    var info = UpdateInfo(version: v, notes: j["body"] as? String ?? "",
                                          url: zip.isEmpty ? other : zip,
                                          pageURL: j["html_url"] as? String ?? "")
                    info.assetName = zipName
                    info.sha256URL = sums
                    info.size = size
                    done(info, nil)
                    return
                }

                // Forme 2 : un canal personnalisé à l'ancien format.
                guard let v = j["version"] as? String else {
                    done(nil, "fichier de version illisible")
                    return
                }
                done(UpdateInfo(version: v, notes: j["notes"] as? String ?? "",
                                url: j["url"] as? String ?? ""), nil)
            }
        }.resume()
    }

    /// La ligne du fichier d'empreintes qui correspond à l'archive.
    /// Appelée depuis un fil de fond : l'attente synchrone est voulue.
    static func publishedHash(_ info: UpdateInfo) -> String? {
        guard let u = URL(string: info.sha256URL), !info.assetName.isEmpty else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.setValue("BUD-Premium/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var text: String?
        URLSession.shared.dataTask(with: req) { d, _, _ in
            if let d = d { text = String(data: d, encoding: .utf8) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        guard let body = text else { return nil }
        // Format de shasum : « <64 hex>  <nom de fichier> »
        for line in body.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0]), name = String(parts[parts.count - 1])
            if name == info.assetName && hash.count == 64 { return hash }
        }
        return nil
    }

    /// SHA-256 lu par tranches d'un mégaoctet : l'archive n'est jamais
    /// chargée entière en mémoire.
    static func sha256(ofFile url: URL) -> String? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Insère un chemin dans un script sans se faire piéger par une
    /// apostrophe ou une espace.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// ═══════════════════════════════════════════════════════════
//  Le gestionnaire
//
//  Un seul état pour toute l'application : la carte « À
//  propos » et la bannière de la barre latérale l'observent
//  et ne peuvent donc jamais se contredire — l'une qui dit
//  « à jour » pendant que l'autre télécharge.
// ═══════════════════════════════════════════════════════════

final class BudUpdateManager: NSObject, URLSessionDownloadDelegate {
    static let shared = BudUpdateManager()

    enum Phase: Equatable {
        case idle, checking, upToDate, available
        case downloading, verifying, extracting, installing
        case failed
    }

    private(set) var phase: Phase = .idle
    /// 0…1, ou négatif quand la durée n'est pas connue : la barre passe
    /// alors en navette plutôt que d'inventer un pourcentage.
    private(set) var fraction: Double = -1
    /// L'étape en mots : « Téléchargement… 42 % ».
    private(set) var message = "Vérifiez si une nouvelle version existe."
    /// Le détail sous l'étape : « 8,1 Mo sur 19 Mo ».
    private(set) var detail = ""
    private(set) var found: UpdateInfo?

    var channel: () -> String = { BudUpdater.defaultChannel }
    var onStatus: ((String) -> Void)?
    /// Le même chemin que les outils et les agents : bureau, encoche, Flux.
    var onMood: ((BudExpression, TimeInterval) -> Void)?

    private var observers: [() -> Void] = []
    func observe(_ f: @escaping () -> Void) { observers.append(f) }
    private func changed() { observers.forEach { $0() } }

    var busy: Bool {
        [.checking, .downloading, .verifying, .extracting, .installing].contains(phase)
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var lastPercent = -1
    private let work = DispatchQueue(label: "fr.lahbib.bud.update")

    private func set(_ p: Phase, _ msg: String, fraction f: Double = -1, detail d: String = "") {
        phase = p
        message = msg
        fraction = f
        detail = d
        changed()
    }

    // ═════════════ 1. Vérifier ═════════════

    func check(silent: Bool = false) {
        guard !busy else { return }
        set(.checking, "Interrogation du canal de mise à jour…")
        BudUpdater.check(channel()) { [weak self] info, err in
            guard let s = self else { return }
            if let e = err {
                s.set(.failed, "Canal injoignable : \(e)")
                if !silent { s.onStatus?("Mise à jour : canal injoignable"); s.onMood?(.sad, 3) }
            } else if let i = info, BudUpdater.isNewer(i.version, than: BudUpdater.currentVersion) {
                s.found = i
                s.set(.available, "Version \(i.version) disponible", detail: i.headline)
                s.onStatus?("BUD \(i.version) disponible")
                // Une bonne nouvelle, même trouvée en silence : BUDs le montre.
                s.onMood?(.cool, 3)
            } else {
                s.found = nil
                s.set(.upToDate, "BUD \(BudUpdater.currentVersion) est à jour.")
                if !silent { s.onStatus?("BUD est à jour"); s.onMood?(.happy, 2) }
            }
        }
    }

    // ═════════════ 2. Télécharger ═════════════

    /// Où ce paquet peut-il être remplacé, et faut-il un mot de passe ?
    /// `nil` dans `error` : on peut y aller.
    func preflight() -> (admin: Bool, error: String?) {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let path = app.path
        // Lancé depuis l'image disque, ou « transloqué » par Gatekeeper :
        // le paquet vit dans un endroit en lecture seule, ou qui disparaîtra.
        if path.hasPrefix("/Volumes/") {
            return (false, "BUD tourne depuis l'image disque. Glissez-le dans Applications, puis relancez-le.")
        }
        if path.contains("/AppTranslocation/") {
            return (false, "macOS a isolé BUD (translocation). Déplacez-le dans Applications et relancez-le.")
        }
        let fm = FileManager.default
        let parent = app.deletingLastPathComponent().path
        // Il faut pouvoir écrire dans le dossier parent (renommer le paquet)
        // ET dans le paquet (effacer l'ancien) : un BUD.app possédé par root
        // dans un /Applications ouvert à l'utilisateur ne passerait que la
        // première épreuve, et laisserait une sauvegarde impossible à effacer.
        let admin = !fm.isWritableFile(atPath: parent)
            || !fm.isWritableFile(atPath: path)
            || !fm.isWritableFile(atPath: app.appendingPathComponent("Contents").path)
        return (admin, nil)
    }

    func install() {
        guard !busy, let f = found else { return }
        guard f.installable, let url = URL(string: f.url) else {
            set(.failed, "Cette version ne fournit pas d'archive installable.")
            onMood?(.sad, 3)
            return
        }
        let pre = preflight()
        if let e = pre.error {
            set(.failed, e)
            onMood?(.sad, 4)
            return
        }

        lastPercent = -1
        let total = f.size > 0 ? " sur \(formatBytes(f.size))" : ""
        set(.downloading, "Téléchargement…", fraction: 0, detail: "0 Mo\(total)")
        onStatus?("Téléchargement de BUD \(f.version)")
        onMood?(.working, 600)

        // Une session à nous, avec délégué : elle rapporte chaque bloc reçu,
        // et l'annulation la referme proprement. Pas de cache : une archive
        // à moitié servie par un proxy serait pire qu'un échec.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
        var req = URLRequest(url: url)
        req.setValue("BUD-Premium/\(BudUpdater.currentVersion)", forHTTPHeaderField: "User-Agent")
        let t = s.downloadTask(with: req)
        session = s
        task = t
        t.resume()
    }

    /// Possible tant que l'installation n'a pas commencé.
    func cancel() {
        guard phase == .downloading else { return }
        task?.cancel()
        teardown()
        set(.available, "Téléchargement annulé.", detail: found?.headline ?? "")
        onMood?(.neutral, 2)
    }

    private func teardown() {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        let total = expected > 0 ? expected : (found?.size ?? 0)
        let frac = total > 0 ? Double(written) / Double(total) : -1
        // Un rappel par bloc de quelques kilo-octets : on ne redessine qu'à
        // chaque point de pourcentage, sinon l'interface travaille pour rien.
        let pc = frac >= 0 ? Int(frac * 100) : Int(written / 1_000_000)
        guard pc != lastPercent else { return }
        lastPercent = pc
        let d = formatBytes(written) + (total > 0 ? " sur \(formatBytes(total))" : "")
        DispatchQueue.main.async {
            guard self.phase == .downloading else { return }
            self.set(.downloading, frac >= 0 ? "Téléchargement… \(Int(frac * 100)) %" : "Téléchargement…",
                     fraction: frac, detail: d)
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo tmp: URL) {
        // Le fichier temporaire disparaît au retour de cette méthode : on le
        // met de côté avant toute autre chose, ici même, sur ce fil.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let fm = FileManager.default
        let keep = fm.temporaryDirectory.appendingPathComponent("bud-dl-\(UUID().uuidString).zip")
        let moved = (try? fm.moveItem(at: tmp, to: keep)) != nil
        DispatchQueue.main.async {
            self.teardown()
            guard status == 200 else { return self.fail("téléchargement refusé (code \(status))") }
            guard moved else { return self.fail("archive non conservée") }
            self.verifyAndInstall(keep)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let e = error as NSError? else { return }
        // L'annulation est un choix, pas une erreur : `cancel` a déjà parlé.
        if e.code == NSURLErrorCancelled { return }
        DispatchQueue.main.async {
            self.teardown()
            self.fail(e.code == NSURLErrorNotConnectedToInternet ? "pas de connexion Internet"
                                                                  : e.localizedDescription)
        }
    }

    private func fail(_ why: String) {
        set(.failed, "Mise à jour impossible : \(why)", detail: "L'installation actuelle n'a pas été touchée.")
        onStatus?("Mise à jour échouée")
        onMood?(.sad, 4)
    }

    // ═════════════ 3. Contrôler, puis 4. installer ═════════════

    private func verifyAndInstall(_ archive: URL) {
        guard let f = found else { return }
        set(.verifying, "Vérification de l'empreinte…")
        let pre = preflight()

        work.async {
            let fm = FileManager.default
            let report: (Phase, String) -> Void = { p, m in DispatchQueue.main.async { self.set(p, m) } }
            let abort: (String) -> Void = { why in
                try? fm.removeItem(at: archive)
                DispatchQueue.main.async { self.fail(why) }
            }

            // ── L'empreinte publiée ──
            //  Une archive abîmée en route, ou remplacée, n'a pas la même.
            var integrity = "empreinte non publiée"
            if !f.sha256URL.isEmpty {
                guard let expected = BudUpdater.publishedHash(f) else {
                    return abort("empreinte publiée illisible")
                }
                guard let got = BudUpdater.sha256(ofFile: archive) else {
                    return abort("empreinte incalculable")
                }
                guard got.lowercased() == expected.lowercased() else {
                    return abort("empreinte incorrecte — téléchargement abîmé, réessayez")
                }
                integrity = "empreinte conforme"
            }

            // ── Extraction, dans un dossier à part ──
            report(.extracting, "Extraction…")
            let stage = fm.temporaryDirectory.appendingPathComponent("bud-update-\(UUID().uuidString)")
            do { try fm.createDirectory(at: stage, withIntermediateDirectories: true) }
            catch { return abort("dossier de travail impossible") }
            // ditto plutôt qu'unzip : il restitue les attributs étendus et la
            // signature, et c'est lui qui a fabriqué l'archive en CI.
            let x = runShellDetailed("/usr/bin/ditto", ["-x", "-k", archive.path, stage.path])
            try? fm.removeItem(at: archive)
            guard x.status == 0 else {
                try? fm.removeItem(at: stage)
                return abort("archive illisible — \(x.err.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            // ── Le paquet extrait ──
            report(.extracting, "Vérification du paquet…")
            if let why = BudUpdateManager.validate(stage, expecting: f.version) {
                try? fm.removeItem(at: stage)
                return abort(why)
            }
            let newApp = stage.appendingPathComponent("BUD.app")

            // ── Le script, puis la main ──
            let script: URL
            do { script = try BudUpdateManager.writeSwapScript(in: stage, newApp: newApp, version: f.version) }
            catch {
                try? fm.removeItem(at: stage)
                return abort("script de remplacement impossible")
            }
            report(.installing, "Installation et redémarrage…")
            let launched = BudUpdateManager.launchDetached(script, admin: pre.admin)
            DispatchQueue.main.async {
                if let why = launched {
                    try? fm.removeItem(at: stage)
                    self.fail(why)
                    return
                }
                self.set(.installing, "Installation et redémarrage…", fraction: 1, detail: integrity)
                self.onStatus?("BUD redémarre sur la version \(f.version)")
                // Le script attend la fin de ce processus : à nous de la lui
                // offrir. Un temps pour que la barre pleine soit vue.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
            }
        }
    }

    /// Le paquet extrait doit être BUD, dans la bonne version, pour cette
    /// machine. Renvoie le motif du refus, ou `nil`.
    static func validate(_ stage: URL, expecting version: String) -> String? {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: stage.path)) ?? []
        let apps = items.filter { $0.hasSuffix(".app") }
        // Exactement un paquet, à la racine, nommé BUD.app : une archive qui
        // en contient deux, ou un dossier intermédiaire, n'est pas la nôtre.
        guard apps == ["BUD.app"] else {
            return apps.isEmpty ? "aucune application dans l'archive"
                                : "archive inattendue (\(apps.joined(separator: ", ")))"
        }
        let app = stage.appendingPathComponent("BUD.app")
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            return "Info.plist manquant"
        }
        // Même identifiant que ce paquet : une archive qui contiendrait une
        // autre application ne prendra pas la place de BUD.
        if let mine = Bundle.main.bundleIdentifier,
           (plist["CFBundleIdentifier"] as? String) != mine {
            return "l'archive contient une autre application"
        }
        // La version annoncée : une release mal assemblée réinstallerait
        // sinon l'ancienne, en boucle, à chaque vérification.
        if let got = plist["CFBundleShortVersionString"] as? String, !version.isEmpty, got != version {
            return "l'archive contient la version \(got), pas \(version)"
        }
        let exe = (plist["CFBundleExecutable"] as? String) ?? "BUD"
        let bin = app.appendingPathComponent("Contents/MacOS/\(exe)")
        guard fm.isExecutableFile(atPath: bin.path) else { return "l'archive ne contient pas d'exécutable" }
        // Une version compilée pour la seule autre architecture serait tuée
        // au lancement, sans un mot.
        let archs = runShellDetailed("/usr/bin/lipo", ["-archs", bin.path]).out
        if !archs.isEmpty && !archs.contains(BudUpdater.myArch) {
            return "cette version ne contient pas \(BudUpdater.myArch)"
        }
        return nil
    }

    // ─────────────────────────────────────────────────────────
    //  Le script de remplacement
    //
    //  Détaché, il survit à BUD. Il attend ce processus-ci par
    //  son PID — et non par son nom, qui désignerait aussi un
    //  second BUD lancé à côté —, met l'ancien paquet de côté
    //  au lieu de l'effacer, pose le nouveau, le relance, et
    //  regarde s'il tient debout. S'il ne démarre pas, ou meurt
    //  dans les secondes qui suivent, l'ancien revient à sa place
    //  et c'est lui qui redémarre.
    //
    //  Il laisse une ligne dans `update-result`, que BUD lit au
    //  lancement suivant pour dire ce qui s'est passé.
    // ─────────────────────────────────────────────────────────

    static var resultFile: URL { budSupportDir.appendingPathComponent("update-result") }
    static var logFile: URL { budSupportDir.appendingPathComponent("update.log") }

    static func writeSwapScript(in stage: URL, newApp: URL, version: String) throws -> URL {
        let q = BudUpdater.shellQuote
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let body = """
        #!/bin/bash
        # Remplacement de BUD — écrit par BUD \(BudUpdater.currentVersion), version visée \(version).
        APP=\(q(app))
        NEW=\(q(newApp.path))
        STAGE=\(q(stage.path))
        PID=\(ProcessInfo.processInfo.processIdentifier)
        OWNER=\(getuid())
        VERSION=\(q(version))
        RESULT=\(q(resultFile.path))
        LOG=\(q(logFile.path))
        BACKUP="$APP.bud-old"
        exec >>"$LOG" 2>&1
        echo "== $(date '+%F %T') · vers $VERSION · $(id -un)"

        # Relance en tant que l'utilisateur, même quand le script tourne en
        # administrateur : un BUD lancé par root aurait d'autres réglages,
        # un autre trousseau, et n'afficherait rien au bon endroit.
        launch() {
          if [ "$(id -u)" = 0 ]; then
            /bin/launchctl asuser "$OWNER" /usr/bin/sudo -u "#$OWNER" /usr/bin/open -n "$1"
          else
            /usr/bin/open -n "$1"
          fi
        }
        finish() {
          echo "$1" > "$RESULT"
          [ "$(id -u)" = 0 ] && /usr/sbin/chown "$OWNER" "$RESULT" "$LOG" 2>/dev/null
          rm -rf "$STAGE"
        }

        # 1. Attendre la fin de BUD : 20 s de politesse, puis on insiste.
        for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        if kill -0 "$PID" 2>/dev/null; then
          kill -TERM "$PID"; sleep 2; kill -KILL "$PID" 2>/dev/null; sleep 0.5
        fi

        # 2. Mettre l'ancien de côté, sans l'effacer.
        rm -rf "$BACKUP"
        if [ -d "$APP" ] && ! mv "$APP" "$BACKUP"; then
          echo "sauvegarde impossible"; finish "fail $VERSION sauvegarde impossible"; launch "$APP"; exit 1
        fi

        # 3. Poser le nouveau. Un échec ici remet l'ancien.
        if ! /usr/bin/ditto "$NEW" "$APP"; then
          echo "copie impossible"
          rm -rf "$APP"; mv "$BACKUP" "$APP"
          finish "rollback $VERSION copie impossible"; launch "$APP"; exit 1
        fi
        # Rendre le paquet à son propriétaire d'origine si root l'a posé.
        if [ "$(id -u)" = 0 ] && [ -d "$BACKUP" ]; then
          /usr/sbin/chown -R "$(/usr/bin/stat -f '%u:%g' "$BACKUP")" "$APP"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        /usr/bin/codesign --force --sign - "$APP" 2>/dev/null

        # 4. Relancer, et vérifier qu'il tient : présent en 15 s, encore là 4 s après.
        launch "$APP"
        BIN="$APP/Contents/MacOS/"
        up=0
        for i in $(seq 1 30); do /usr/bin/pgrep -f "$BIN" >/dev/null && { up=1; break; }; sleep 0.5; done
        [ $up = 1 ] && { sleep 4; /usr/bin/pgrep -f "$BIN" >/dev/null || up=0; }

        if [ $up = 1 ]; then
          rm -rf "$BACKUP"
          finish "ok $VERSION"
        else
          echo "le nouveau paquet ne démarre pas : retour à l'ancien"
          /usr/bin/pkill -f "$BIN" 2>/dev/null
          rm -rf "$APP"; mv "$BACKUP" "$APP"
          finish "rollback $VERSION la nouvelle version ne démarrait pas"
          launch "$APP"
        fi
        """
        let script = stage.appendingPathComponent("swap.sh")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    /// Lance le script hors de BUD. En mode administrateur, c'est macOS qui
    /// demande le mot de passe, et BUD attend la réponse : si l'on refuse,
    /// BUD ne quitte pas — se fermer pour rien serait pire que l'échec.
    /// Renvoie le motif d'un échec, ou `nil`.
    static func launchDetached(_ script: URL, admin: Bool) -> String? {
        if !admin {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return "lancement du remplacement impossible" }
            return nil
        }
        // « do shell script » rend la main dès que la commande est partie en
        // arrière-plan : le script continue en administrateur, BUD peut quitter.
        let cmd = "/bin/bash " + BudUpdater.shellQuote(script.path) + " >/dev/null 2>&1 &"
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(escaped)\" with prompt "
            + "\"BUD a besoin de votre mot de passe pour se mettre à jour dans ce dossier.\" "
            + "with administrator privileges"
        let r = runShellDetailed("/usr/bin/osascript", ["-e", src])
        if r.status != 0 {
            return r.err.contains("-128") ? "autorisation refusée" : "autorisation impossible"
        }
        return nil
    }

    /// Lu une fois au lancement : ce que le dernier remplacement a donné.
    /// `ok`, `rollback` ou `fail`, suivis de la version et d'un motif.
    func consumeLastResult() -> (ok: Bool, text: String)? {
        let f = BudUpdateManager.resultFile
        guard let raw = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: f)
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let v = String(parts[1]), why = parts.count > 2 ? String(parts[2]) : ""
        switch parts[0] {
        case "ok":       return (true, "BUD est passé en version \(v).")
        case "rollback": return (false, "La version \(v) a été annulée : \(why). L'ancienne est revenue.")
        default:         return (false, "La mise à jour vers \(v) a échoué : \(why).")
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  La barre de progression
//
//  Une piste en creux, un remplissage dégradé dans la couleur
//  d'accent avec un reflet qui la parcourt — c'est ce qui dit
//  « ça avance » même quand le pourcentage stagne —, et une
//  navette quand la durée est inconnue. L'avancée est lissée :
//  la barre glisse vers sa valeur au lieu de sauter.
// ═══════════════════════════════════════════════════════════

final class BudProgressBar: NSView {
    var target: Double = 0 { didSet { wake() } }
    var tint: NSColor = TH.accent { didSet { needsDisplay = true } }
    private var shown: CGFloat = 0
    private var t: CGFloat = 0
    private var timer: Timer?

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    private func wake() {
        guard timer == nil else { return }
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tm in
            guard let s = self, s.window != nil, !s.isHiddenOrHasHiddenAncestor else {
                tm.invalidate(); self?.timer = nil; return
            }
            s.t += 1.0 / 60.0
            if s.target >= 0 { s.shown += (CGFloat(s.target) - s.shown) * 0.18 }
            s.needsDisplay = true
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { wake() } }
    override func viewDidUnhide() { super.viewDidUnhide(); wake() }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let track = capsule(r)
        TH.fill(0.12).setFill()
        track.fill()
        NSGraphicsContext.current?.saveGraphicsState()
        track.addClip()
        if target < 0 {
            // Navette : la durée est inconnue, on montre seulement le travail.
            let w = r.width * 0.32
            let x = r.minX + (r.width - w) * (sin(t * 2.4) + 1) / 2
            NSGradient(colors: [tint.withAlphaComponent(0.2), tint, tint.withAlphaComponent(0.2)])?
                .draw(in: NSRect(x: x, y: r.minY, width: w, height: r.height), angle: 0)
        } else {
            let w = max(r.height, r.width * min(1, shown))
            let fill = NSRect(x: r.minX, y: r.minY, width: w, height: r.height)
            NSGradient(colors: [tint.blended(withFraction: 0.25, of: .white) ?? tint, tint])?
                .draw(in: capsule(fill), angle: 0)
            // Le reflet qui parcourt la partie remplie.
            let gw = r.height * 6
            let gx = r.minX - gw + (t * 0.8).truncatingRemainder(dividingBy: 1) * (w + gw)
            NSGraphicsContext.current?.saveGraphicsState()
            capsule(fill).addClip()
            NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.45), NSColor(white: 1, alpha: 0)])?
                .draw(in: NSRect(x: gx, y: r.minY, width: gw, height: r.height), angle: 0)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

// ═══════════════════════════════════════════════════════════
//  La bannière
//
//  Elle n'existe que lorsqu'il y a quelque chose à dire : une
//  version disponible, une installation en cours, un échec.
//  Elle vit en bas de la barre latérale, au-dessus de la
//  pastille d'état : visible depuis n'importe quel onglet,
//  sans couvrir aucun panneau.
// ═══════════════════════════════════════════════════════════

final class BudUpdateView: NSView {
    static let height: CGFloat = 112
    private let bar: BudProgressBar
    private let button: GlassButton
    private let notes: GlassButton
    /// La barre latérale se range quand la bannière apparaît ou disparaît.
    var onVisibility: ((Bool) -> Void)?

    override init(frame: NSRect) {
        let W = frame.width
        bar = BudProgressBar(frame: NSRect(x: 14, y: 46, width: W - 28, height: 6))
        button = GlassButton(frame: NSRect(x: 12, y: 10, width: W - 24 - 34, height: 28),
                             title: "Mettre à jour maintenant", icon: "arrow.down.circle.fill",
                             prominent: true, compact: true)
        notes = GlassButton(frame: NSRect(x: W - 12 - 28, y: 10, width: 28, height: 28),
                            title: "", icon: "doc.text", compact: true)
        super.init(frame: frame)
        wantsLayer = true
        addSubview(bar)
        addSubview(button)
        addSubview(notes)
        notes.toolTip = "Lire les notes de version"
        button.onClick = { [weak self] _ in self?.primary() }
        notes.onClick = { [weak self] _ in self?.showNotes() }
        setAccessibilityRole(.group)
        BudUpdateManager.shared.observe { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var wanted: Bool {
        let p = BudUpdateManager.shared.phase
        return p == .available || p == .downloading || p == .verifying || p == .extracting
            || p == .installing || (p == .failed && BudUpdateManager.shared.found != nil)
    }

    func refresh() {
        let m = BudUpdateManager.shared
        let show = wanted
        if show != !isHidden {
            if show {
                isHidden = false
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    self.animator().alphaValue = 1
                }
            } else {
                isHidden = true
            }
            onVisibility?(show)
        }
        bar.isHidden = !(m.busy || m.phase == .installing)
        bar.target = m.fraction
        bar.tint = m.phase == .failed ? dangerColor : TH.accent
        switch m.phase {
        case .downloading:
            button.title = "Annuler"; button.iconName = "xmark"; button.prominent = false
            button.enabledFlag = true
        case .verifying, .extracting, .installing:
            button.title = "Un instant…"; button.iconName = "hourglass"; button.prominent = false
            button.enabledFlag = false
        case .failed:
            button.title = "Réessayer"; button.iconName = "arrow.clockwise"; button.prominent = true
            button.enabledFlag = true
        default:
            button.title = "Mettre à jour maintenant"; button.iconName = "arrow.down.circle.fill"
            button.prominent = true; button.enabledFlag = true
        }
        notes.isHidden = m.found?.notes.isEmpty ?? true
        setAccessibilityLabel(m.message)
        needsDisplay = true
    }

    private func primary() {
        let m = BudUpdateManager.shared
        switch m.phase {
        case .downloading: m.cancel()
        case .available, .failed:
            // Une confirmation courte : BUD va quitter et revenir.
            let pre = m.preflight()
            if let e = pre.error {
                let a = NSAlert(); a.messageText = "Mise à jour impossible ici"; a.informativeText = e
                a.runModal()
                return
            }
            let a = NSAlert()
            a.messageText = "Installer BUD \(m.found?.version ?? "") ?"
            a.informativeText = "BUD va télécharger la nouvelle version, se fermer, se remplacer et se rouvrir. "
                + "Vos réglages, notes et rappels sont conservés."
                + (pre.admin ? "\n\nCe dossier est protégé : macOS vous demandera votre mot de passe." : "")
            a.addButton(withTitle: "Installer et redémarrer")
            a.addButton(withTitle: "Plus tard")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { m.install() }
        default: break
        }
    }

    /// Les notes, dans BUD : la page web n'est plus nécessaire pour savoir
    /// ce qui change.
    private func showNotes() {
        guard let f = BudUpdateManager.shared.found else { return }
        let a = NSAlert()
        a.messageText = "Nouveautés de BUD \(f.version)"
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))
        tv.string = f.notes
        tv.isEditable = false
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        let sc = NSScrollView(frame: tv.frame)
        sc.hasVerticalScroller = true
        sc.documentView = tv
        a.accessoryView = sc
        a.addButton(withTitle: "Fermer")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    override func draw(_ dirty: NSRect) {
        let m = BudUpdateManager.shared
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        drawLiquidGlass(p, in: r, active: m.phase == .available, hover: 0)

        let failed = m.phase == .failed
        let tint = failed ? dangerColor : TH.accent
        let c = NSPoint(x: r.minX + 22, y: r.maxY - 22)
        tint.withAlphaComponent(0.2).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)).fill()
        let icon = failed ? "exclamationmark.triangle.fill"
                 : (m.busy || m.phase == .installing ? "arrow.down" : "sparkles")
        drawSymbol(icon, center: c, size: 10, weight: .bold, color: tint)

        let title = m.phase == .available ? "BUD \(m.found?.version ?? "") est là" : m.message
        drawString(title, in: NSRect(x: r.minX + 40, y: r.maxY - 30, width: r.width - 48, height: 16),
                   size: 12, weight: .bold, color: TH.text)
        let sub: String
        switch m.phase {
        case .available: sub = m.detail.isEmpty ? "Une nouvelle version est prête." : m.detail
        case .failed:    sub = m.detail
        default:         sub = m.detail
        }
        drawString(sub, in: NSRect(x: r.minX + 14, y: r.maxY - 56, width: r.width - 26, height: 15),
                   size: 10.5, weight: .medium, color: failed ? dangerColor.withAlphaComponent(0.9) : TH.dim(0.55))
    }
}

// ═══════════════════════════════════════════════════════════
//  La carte « À propos »
//
//  Elle montre la version, vérifie à la demande, et suit le
//  même état que la bannière.
// ═══════════════════════════════════════════════════════════

final class UpdateCardView: NSView {
    private var spin: CGFloat = 0
    private var timer: Timer?
    private var actionBtn: GlassButton!
    private var channelBtn: GlassButton!
    private var bar: BudProgressBar!

    var onChannelEdit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let W = bounds.width, H = bounds.height
        actionBtn = GlassButton(frame: NSRect(x: W - 232, y: H / 2 - 18, width: 118, height: 36),
                                title: "Vérifier", icon: "arrow.triangle.2.circlepath", compact: true)
        actionBtn.onClick = { [weak self] _ in self?.primaryAction() }
        channelBtn = GlassButton(frame: NSRect(x: W - 106, y: H / 2 - 18, width: 98, height: 36),
                                 title: "Canal", icon: "antenna.radiowaves.left.and.right", compact: true)
        channelBtn.onClick = { [weak self] _ in self?.onChannelEdit?() }
        bar = BudProgressBar(frame: NSRect(x: 72, y: 9, width: W - 72 - 248, height: 5))
        addSubview(actionBtn)
        addSubview(channelBtn)
        addSubview(bar)
        BudUpdateManager.shared.observe { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Gardé pour les appels existants.
    func check(silent: Bool = false) { BudUpdateManager.shared.check(silent: silent) }

    private func primaryAction() {
        let m = BudUpdateManager.shared
        switch m.phase {
        case .available:   m.install()
        case .downloading: m.cancel()
        default:           m.check()
        }
    }

    private func refresh() {
        let m = BudUpdateManager.shared
        bar.isHidden = !(m.busy && m.phase != .checking) && m.phase != .installing
        bar.target = m.fraction
        channelBtn.enabledFlag = !m.busy
        switch m.phase {
        case .checking:
            actionBtn.title = "Vérification"; actionBtn.enabledFlag = false
        case .available:
            actionBtn.title = "Installer"; actionBtn.iconName = "arrow.down.circle.fill"
            actionBtn.prominent = true; actionBtn.enabledFlag = true
        case .downloading:
            actionBtn.title = "Annuler"; actionBtn.iconName = "xmark"
            actionBtn.prominent = false; actionBtn.enabledFlag = true
        case .verifying, .extracting, .installing:
            actionBtn.title = "En cours"; actionBtn.enabledFlag = false
        case .failed:
            actionBtn.title = "Réessayer"; actionBtn.iconName = "arrow.clockwise"
            actionBtn.prominent = false; actionBtn.enabledFlag = true
        default:
            actionBtn.title = "Vérifier"; actionBtn.iconName = "arrow.triangle.2.circlepath"
            actionBtn.prominent = false; actionBtn.enabledFlag = true
        }
        if m.busy && timer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] tm in
                guard let s = self else { tm.invalidate(); return }
                s.spin += 0.22
                if !BudUpdateManager.shared.busy { tm.invalidate(); s.timer = nil }
                s.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let m = BudUpdateManager.shared
        let r = bounds
        let card = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        TH.fill(0.05).setFill()
        card.fill()
        TH.fill(0.08).setStroke()
        card.lineWidth = 1
        card.stroke()

        let c = NSPoint(x: r.minX + 40, y: r.midY)
        let tint: NSColor = m.phase == .available ? warnColor : (m.phase == .failed ? dangerColor : TH.accent)
        tint.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 19, y: c.y - 19, width: 38, height: 38)).fill()
        if m.busy {
            let arc = NSBezierPath()
            let start = spin * 57.3
            arc.appendArc(withCenter: c, radius: 16, startAngle: start, endAngle: start + 250)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            tint.setStroke()
            arc.stroke()
        } else {
            let icon = m.phase == .available ? "arrow.down.circle.fill"
                     : (m.phase == .failed ? "exclamationmark.triangle.fill"
                        : (m.phase == .upToDate ? "checkmark.circle.fill" : "sparkles"))
            drawSymbol(icon, center: c, size: 20, weight: .semibold, color: tint)
        }

        let textW = r.width - 80 - 240
        drawString("BUD Premium \(BudUpdater.currentVersion)",
                   in: NSRect(x: r.minX + 72, y: r.midY + 5, width: textW, height: 20),
                   size: 13.5, weight: .bold, color: TH.text)
        let line = m.detail.isEmpty || m.phase == .available ? m.message : "\(m.message) · \(m.detail)"
        drawString(line, in: NSRect(x: r.minX + 72, y: r.midY - 14, width: textW, height: 18),
                   size: 11, weight: .medium, color: m.phase == .failed ? dangerColor : TH.dim(0.5))
    }
}
