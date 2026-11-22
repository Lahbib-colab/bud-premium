import Cocoa

// ═══════════════════════════════════════════════════════════
//  Mise à jour
//
//  BUD interroge l'API des releases GitHub, qui est la seule
//  source de vérité : la release porte à la fois le numéro de
//  version et les installeurs. Plus de fichier de version à
//  tenir en parallèle, donc plus de risque de divergence.
//
//  Le bouton télécharge l'archive de l'application, remplace
//  le paquet et relance BUD. Il n'ouvre plus de page web.
//
//  Un canal personnalisé au vieux format reste accepté :
//  { "version": "…", "notes": "…", "url": "…" }
// ═══════════════════════════════════════════════════════════

struct UpdateInfo {
    let version: String
    let notes: String
    let url: String            // l'archive que BUD télécharge
    var pageURL: String = ""   // la page de la release, pour la lire

    /// Une archive s'installe sans intervention ; tout autre format
    /// (.dmg, .command) demande l'utilisateur, donc on l'ouvre.
    var installable: Bool { url.lowercased().hasSuffix(".zip") }
}

enum BudUpdater {

    static let repo = "Lahbib-colab/bud-premium"

    static let defaultChannel =
        "https://api.github.com/repos/Lahbib-colab/bud-premium/releases/latest"

    /// L'architecture de CE binaire, décidée à la compilation : c'est la
    /// seule façon fiable de savoir ce qu'il faut retrouver dans l'archive.
    static var myArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
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
        req.setValue("BUD-Premium/\(budVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let e = err { done(nil, e.localizedDescription); return }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    done(nil, http.statusCode == 404
                            ? "aucune version publiée pour l'instant"
                            : "canal introuvable (code \(http.statusCode))")
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
                    var zip = "", other = ""
                    if let assets = j["assets"] as? [[String: Any]] {
                        for a in assets {
                            guard let name = (a["name"] as? String)?.lowercased(),
                                  let u = a["browser_download_url"] as? String else { continue }
                            if name.hasSuffix(".zip") { zip = u }
                            else if name.hasSuffix(".dmg") && other.isEmpty { other = u }
                        }
                    }
                    done(UpdateInfo(version: v,
                                    notes: j["body"] as? String ?? "",
                                    url: zip.isEmpty ? other : zip,
                                    pageURL: j["html_url"] as? String ?? ""), nil)
                    return
                }

                // Forme 2 : un canal personnalisé à l'ancien format.
                guard let v = j["version"] as? String else {
                    done(nil, "fichier de version illisible")
                    return
                }
                done(UpdateInfo(version: v,
                                notes: j["notes"] as? String ?? "",
                                url: j["url"] as? String ?? ""), nil)
            }
        }.resume()
    }

    // ═══════ Installation ═══════

    /// Télécharge l'archive, vérifie qu'elle contient bien l'architecture
    /// de cette machine, remplace le paquet et relance BUD.
    ///
    /// Le remplacement est confié à un petit script : une application ne
    /// peut pas se réécrire proprement pendant qu'elle tourne. Le script
    /// attend la fin de BUD, échange les paquets, et restaure l'ancien si
    /// le nouveau ne démarre pas.
    static func install(_ info: UpdateInfo,
                        progress: @escaping (Double) -> Void,
                        done: @escaping (String?) -> Void) {
        guard let url = URL(string: info.url), info.installable else {
            done("Cette version ne fournit pas d'archive installable.")
            return
        }

        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url) { tmp, resp, err in
            if let e = err { DispatchQueue.main.async { done(e.localizedDescription) }; return }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                DispatchQueue.main.async { done("téléchargement refusé (code \(http.statusCode))") }
                return
            }
            guard let tmp = tmp else {
                DispatchQueue.main.async { done("archive introuvable") }
                return
            }
            let err2 = unpackAndSwap(tmp)
            DispatchQueue.main.async { done(err2) }
        }

        // Progression du téléchargement, relayée telle quelle.
        let obs = task.progress.observe(\.fractionCompleted) { p, _ in
            DispatchQueue.main.async { progress(p.fractionCompleted) }
        }
        progressTokens.append(obs)
        task.resume()
    }

    private static var progressTokens: [NSKeyValueObservation] = []

    /// Renvoie nil si tout s'est bien passé, sinon le motif de l'échec.
    private static func unpackAndSwap(_ archive: URL) -> String? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("bud-update-\(UUID().uuidString)")
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
        catch { return "dossier de travail impossible" }

        // ditto plutôt que unzip : il restitue les attributs étendus et la
        // signature du paquet, ce qu'unzip ne garantit pas.
        let out = runShell("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])
        guard let items = try? fm.contentsOfDirectory(atPath: work.path) else {
            return "archive illisible"
        }
        guard let appName = items.first(where: { $0.hasSuffix(".app") }) else {
            return "aucune application dans l'archive\(out.isEmpty ? "" : " — \(out)")"
        }
        let newApp = work.appendingPathComponent(appName)
        let newBin = newApp.appendingPathComponent("Contents/MacOS/BUD")
        guard fm.isExecutableFile(atPath: newBin.path) else {
            return "l'archive ne contient pas d'exécutable BUD"
        }

        // Garde-fou décisif : une version compilée pour la seule autre
        // architecture serait tuée au lancement, sans explication.
        let archs = runShell("/usr/bin/lipo", ["-archs", newBin.path])
        if !archs.isEmpty && !archs.contains(myArch) {
            return "cette version ne contient pas \(myArch) (mais \(archs.trimmingCharacters(in: .whitespacesAndNewlines)))"
        }

        let appPath = Bundle.main.bundlePath
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/bash
        APP=\(shellQuote(appPath))
        NEW=\(shellQuote(newApp.path))
        WORK=\(shellQuote(work.path))

        # Laisser BUD se fermer de lui-même avant de toucher au paquet.
        for i in $(seq 1 60); do
          pgrep -x BUD >/dev/null 2>&1 || break
          sleep 0.2
        done
        pkill -x BUD 2>/dev/null
        sleep 0.5

        rm -rf "$APP.old"
        [ -d "$APP" ] && mv "$APP" "$APP.old"
        /usr/bin/ditto "$NEW" "$APP"
        /usr/bin/xattr -cr "$APP" 2>/dev/null
        /usr/bin/codesign --force --sign - "$APP" 2>/dev/null

        if [ -x "$APP/Contents/MacOS/BUD" ]; then
          rm -rf "$APP.old"
        else
          # Le nouveau paquet est inutilisable : on remet l'ancien.
          rm -rf "$APP"
          [ -d "$APP.old" ] && mv "$APP.old" "$APP"
        fi
        /usr/bin/open "$APP"
        sleep 2
        rm -rf "$WORK"
        """
        do { try body.write(to: script, atomically: true, encoding: .utf8) }
        catch { return "script de remplacement impossible" }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        do { try p.run() } catch { return "lancement du remplacement impossible" }
        return nil
    }

    /// Insère un chemin dans un script sans se faire piéger par une
    /// apostrophe ou une espace.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        guard phase == .available, let f = found, !f.url.isEmpty else { check(); return }

        // Une archive s'installe seule. Tout autre format — .dmg, .command —
        // demande un geste de l'utilisateur : on ouvre la page de la version.
        guard f.installable else {
            let target = f.pageURL.isEmpty ? f.url : f.pageURL
            if let u = URL(string: target) { NSWorkspace.shared.open(u) }
            onStatus?("Version \(f.version) ouverte dans le navigateur")
            return
        }

        let a = NSAlert()
        a.messageText = "Installer la version \(f.version) ?"
        var text = "BUD va télécharger la nouvelle version, remplacer l'application "
                 + "et redémarrer. Vos réglages, notes et rappels sont conservés."
        if !f.notes.isEmpty {
            text += "\n\n" + String(f.notes.prefix(600))
        }
        a.informativeText = text
        a.addButton(withTitle: "Installer et redémarrer")
        a.addButton(withTitle: "Annuler")
        a.addButton(withTitle: "Voir les notes")
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()

        if r == .alertThirdButtonReturn {
            let target = f.pageURL.isEmpty ? f.url : f.pageURL
            if let u = URL(string: target) { NSWorkspace.shared.open(u) }
            return
        }
        guard r == .alertFirstButtonReturn else { return }

        // La phase « checking » fait tourner l'indicateur : inutile d'en
        // ajouter une, le message porte la progression.
        phase = .checking
        pop = 0
        message = "Téléchargement…"
        actionBtn.enabledFlag = false
        actionBtn.title = "En cours"
        startTicking()
        needsDisplay = true
        onStatus?("Téléchargement de la version \(f.version)")

        BudUpdater.install(f, progress: { [weak self] p in
            guard let s = self else { return }
            s.message = "Téléchargement… \(Int((p * 100).rounded())) %"
            s.needsDisplay = true
        }, done: { [weak self] err in
            guard let s = self else { return }
            if let e = err {
                s.phase = .failed
                s.pop = 1
                s.message = "Installation impossible : \(e)"
                s.actionBtn.title = "Réessayer"
                s.actionBtn.enabledFlag = true
                s.onStatus?("Mise à jour échouée")
                s.needsDisplay = true
                return
            }
            s.message = "Redémarrage de BUD…"
            s.needsDisplay = true
            s.onStatus?("BUD redémarre sur la version \(f.version)")
            // Le script de remplacement attend la fin du processus :
            // c'est à nous de le lui offrir.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
            }
        })
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
