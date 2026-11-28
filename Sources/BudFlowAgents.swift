import Cocoa

// ═══════════════════════════════════════════════════════════
//  Les trois premiers agents du Flux
//
//  Chacun suit la même forme : `run` lit le vrai Mac, hors du
//  fil principal ; `simulate` parcourt le même chemin sur les
//  données de `BudFlowSamples`. Aucun des deux ne supprime
//  quoi que ce soit : ce qui touche au disque est rendu sous
//  forme de fiche d'approbation, et c'est l'utilisateur qui
//  coche.
// ═══════════════════════════════════════════════════════════

private let tintCleanup  = NSColor(calibratedRed: 0.36, green: 0.84, blue: 0.62, alpha: 1)
private let tintSecurity = NSColor(calibratedRed: 1.00, green: 0.46, blue: 0.42, alpha: 1)
private let tintSky      = NSColor(calibratedRed: 0.42, green: 0.70, blue: 1.00, alpha: 1)

// ═══════════════════════════════════════════════════════════
//  1. Nettoyage & Rangement
// ═══════════════════════════════════════════════════════════

/// Une application qui dort, et ce qu'elle a laissé dans la bibliothèque.
struct DormantApp {
    var url: URL
    var name: String
    var bundleID: String
    var lastUsed: Date?
    var bytes: Int64
    var fromAppStore: Bool
    var leftovers: [URL]
}

/// Un fichier des téléchargements qui mérite un regard.
struct ClutterFile {
    var url: URL
    var reason: String
    var bytes: Int64
    /// Coché d'avance dans la fiche : seulement les installeurs anciens,
    /// le cas où l'on ne regrette jamais.
    var preselect: Bool
}

enum CleanupScan {
    static let day: TimeInterval = 86_400

    static func size(_ u: URL) -> Int64 {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { return 0 }
        if dir.boolValue { return Cleaner.sizeOf(u, limit: 20_000).bytes }
        return Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                        .totalFileAllocatedSize ?? 0)
    }

    static func downloads(limit: Int = 40) -> [ClutterFile] {
        let fm = FileManager.default
        guard let dl = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let items = try? fm.contentsOfDirectory(
                at: dl, includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }
        let now = Date()
        var out: [ClutterFile] = []
        let suspects = Dictionary(MailGuard.scanDownloads().map { ($0.url.path, $0.reason) },
                                  uniquingKeysWith: { a, _ in a })
        for u in items {
            let v = try? u.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            let touched = max(v?.contentAccessDate ?? .distantPast, v?.contentModificationDate ?? .distantPast)
            let age = now.timeIntervalSince(touched) / day
            let ext = u.pathExtension.lowercased()

            if let why = suspects[u.path] {
                out.append(ClutterFile(url: u, reason: "Suspect : \(why)", bytes: size(u), preselect: false))
            } else if ["dmg", "pkg", "mpkg"].contains(ext), age > 7 {
                out.append(ClutterFile(url: u, reason: "Installeur, ouvert il y a \(Int(age)) j",
                                       bytes: size(u), preselect: true))
            } else if age > 90 {
                let b = size(u)
                // Les petits fichiers anciens ne valent pas une ligne : la
                // fiche serait longue, et le gain nul.
                if b > 50_000_000 {
                    out.append(ClutterFile(url: u, reason: "Pas ouvert depuis \(Int(age)) j",
                                           bytes: b, preselect: false))
                }
            }
            if out.count >= limit { break }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Applications non ouvertes depuis `days` jours.
    ///
    /// Exclues d'office : celles d'Apple, celles du système, celles qui
    /// tournent en ce moment, et BUD lui-même. La date d'usage vient de
    /// Spotlight ; sans elle, on prend la date d'accès du paquet, et sans
    /// aucune des deux, on ne propose rien — on ne désinstalle pas sur
    /// une supposition.
    static func dormantApps(excluding running: Set<String>, days: Double = 120) -> [DormantApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        let lib = home.appendingPathComponent("Library")
        let now = Date()
        var out: [DormantApp] = []

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for u in items where u.pathExtension == "app" {
                let path = u.standardizedFileURL.path
                if running.contains(path) || path.hasPrefix("/System/") { continue }
                guard let b = Bundle(url: u), let id = b.bundleIdentifier,
                      !id.hasPrefix("com.apple.") else { continue }

                var last = NSMetadataItem(url: u)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
                if last == nil {
                    last = (try? u.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
                }
                guard let used = last, now.timeIntervalSince(used) / day > days else { continue }

                let name = (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? u.deletingPathExtension().lastPathComponent
                let candidates = [
                    lib.appendingPathComponent("Application Support/\(name)"),
                    lib.appendingPathComponent("Application Support/\(id)"),
                    lib.appendingPathComponent("Caches/\(id)"),
                    lib.appendingPathComponent("Preferences/\(id).plist"),
                    lib.appendingPathComponent("Saved Application State/\(id).savedState")
                ]
                let left = candidates.filter { fm.fileExists(atPath: $0.path) }
                let mas = fm.fileExists(atPath: u.appendingPathComponent("Contents/_MASReceipt").path)
                out.append(DormantApp(url: u, name: name, bundleID: id, lastUsed: used,
                                      bytes: size(u), fromAppStore: mas, leftovers: left))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Met à la corbeille, jamais à la destruction : une erreur doit rester
    /// réparable depuis le Finder.
    static func trash(_ items: [ApprovalItem]) -> (freed: Int64, ok: Int, failed: Int) {
        var freed: Int64 = 0, ok = 0, failed = 0
        for it in items {
            guard let u = it.url else { continue }
            if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil {
                freed += it.bytes; ok += 1
            } else {
                failed += 1
            }
        }
        return (freed, ok, failed)
    }
}

final class CleanupAgent: BudAgent {
    let id = "cleanup"
    let name = "Nettoyage & Rangement"
    let summary = "Téléchargements oubliés, installeurs, applications dormantes. Rien ne part sans votre accord."
    let icon = "sparkles"
    var tint: NSColor { tintCleanup }
    let sources = [
        FlowSource(id: "downloads", title: "Téléchargements", icon: "arrow.down.circle.fill",
                   tint: NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.00, alpha: 1),
                   note: "Noms, tailles et dates du dossier, lus sur place. Le contenu n'est pas ouvert."),
        FlowSource(id: "apps", title: "Applications", icon: "square.grid.2x2.fill",
                   tint: NSColor(calibratedRed: 0.74, green: 0.52, blue: 1.00, alpha: 1),
                   note: "Date de dernier usage selon Spotlight. Apps d'Apple et apps ouvertes exclues.")
    ]

    func run(_ ctx: AgentContext, done: @escaping (AgentResult) -> Void) {
        // Lu sur le fil principal : la liste des applications ouvertes.
        var running = Set(NSWorkspace.shared.runningApplications
                            .compactMap { $0.bundleURL?.standardizedFileURL.path })
        running.insert(Bundle.main.bundleURL.standardizedFileURL.path)
        DispatchQueue.global(qos: .utility).async {
            ctx.progress("Lecture des téléchargements…")
            let files = CleanupScan.downloads()
            if ctx.cancelled { return done(Self.empty) }
            ctx.progress("Applications dormantes…")
            let apps = CleanupScan.dormantApps(excluding: running)
            done(Self.result(files: files, apps: apps, simulated: false))
        }
    }

    func simulate(_ ctx: AgentContext, done: @escaping (AgentResult) -> Void) {
        ctx.progress("Lecture des téléchargements…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            ctx.progress("Applications dormantes…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                done(Self.result(files: BudFlowSamples.clutter, apps: BudFlowSamples.dormant, simulated: true))
            }
        }
    }

    private static let empty = AgentResult(status: .idle, expression: .neutral, headline: "Interrompu.")

    static func result(files: [ClutterFile], apps: [DormantApp], simulated: Bool) -> AgentResult {
        let fileBytes = files.reduce(Int64(0)) { $0 + $1.bytes }
        let appBytes = apps.reduce(Int64(0)) { $0 + $1.bytes }
        let suspects = files.filter { $0.reason.hasPrefix("Suspect") }.count

        var cards = [
            BudCard(icon: "arrow.down.circle.fill", title: "TÉLÉCHARGEMENTS",
                    value: files.isEmpty ? "Rangés" : formatBytes(fileBytes),
                    detail: "\(files.count) élément\(files.count > 1 ? "s" : "") à revoir",
                    tint: NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.00, alpha: 1)),
            BudCard(icon: "square.grid.2x2.fill", title: "APPS DORMANTES",
                    value: apps.isEmpty ? "Aucune" : "\(apps.count)",
                    detail: apps.isEmpty ? "Tout sert" : "\(formatBytes(appBytes)) · 120 j sans usage",
                    tint: NSColor(calibratedRed: 0.74, green: 0.52, blue: 1.00, alpha: 1))
        ]
        if suspects > 0 {
            cards.append(BudCard(icon: "exclamationmark.shield.fill", title: "SUSPECTS",
                                 value: "\(suspects)", detail: "Dans les téléchargements",
                                 tint: dangerColor))
        }

        guard !files.isEmpty || !apps.isEmpty else {
            return AgentResult(status: .success, expression: .happy,
                               headline: "Rien à ranger : tout est propre.", cards: cards)
        }

        // La fiche. Les installeurs anciens sont cochés ; tout le reste —
        // fichiers, applications, restes — attend votre coche.
        var items: [ApprovalItem] = files.map {
            ApprovalItem(id: $0.url.path, label: $0.url.lastPathComponent, detail: $0.reason,
                         icon: $0.reason.hasPrefix("Suspect") ? "exclamationmark.shield.fill" : "doc.fill",
                         bytes: $0.bytes, selected: $0.preselect, url: $0.url)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateFormat = "d MMM yyyy"
        for a in apps {
            let used = a.lastUsed.map { "ouverte le \(df.string(from: $0))" } ?? "jamais ouverte"
            items.append(ApprovalItem(id: a.url.path, label: a.name,
                                      detail: "Application, \(used)" + (a.fromAppStore ? " · réinstallable depuis l'App Store" : ""),
                                      icon: "app.fill", bytes: a.bytes, selected: false, url: a.url))
            for l in a.leftovers {
                items.append(ApprovalItem(id: l.path, label: "Restes de \(a.name)",
                                          detail: "~/Library/" + l.pathComponents.suffix(2).joined(separator: "/"),
                                          icon: "folder.fill", bytes: simulated ? 0 : CleanupScan.size(l),
                                          selected: false, url: l))
            }
        }

        let total = fileBytes + appBytes
        let req = ApprovalRequest(
            title: "Mettre à la corbeille ?",
            message: simulated
                ? "Simulation : aucun fichier réel n'est concerné. Cochez, validez, et regardez BUDs réagir."
                : "Tout part à la corbeille, d'où vous pouvez le récupérer. Les applications ouvertes et celles d'Apple ne sont jamais proposées.",
            items: items,
            confirmLabel: "Mettre à la corbeille",
            destructive: true,
            perform: { chosen, finish in
                if simulated {
                    let b = chosen.reduce(Int64(0)) { $0 + $1.bytes }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        finish(AgentResult(status: .success, expression: .happy,
                                           headline: "Simulation : \(chosen.count) élément\(chosen.count > 1 ? "s" : ""), \(formatBytes(b)) — rien n'a été touché."))
                    }
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = CleanupScan.trash(chosen)
                    let expr: BudExpression = r.failed == 0 ? .happy : (r.ok == 0 ? .sad : .dizzy)
                    let status: NodeStatus = r.failed == 0 ? .success : (r.ok == 0 ? .failure : .warning)
                    var line = "\(r.ok) à la corbeille, \(formatBytes(r.freed)) libérés."
                    if r.failed > 0 {
                        line += " \(r.failed) refusé\(r.failed > 1 ? "s" : "") par macOS (droits ou app protégée)."
                    }
                    finish(AgentResult(status: status, expression: expr, headline: line))
                }
            })

        // Plus de cinq gigaoctets de désordre : BUDs en a la tête qui tourne.
        let expr: BudExpression = total > 5_000_000_000 ? .dizzy : .reflection
        return AgentResult(status: .needsApproval, expression: expr,
                           headline: "\(items.count) élément\(items.count > 1 ? "s" : "") à examiner, \(formatBytes(total)) récupérables.",
                           cards: cards, approval: req, hold: 5)
    }
}

// ═══════════════════════════════════════════════════════════
//  2. Cybersécurité — liens, domaines, courrier
// ═══════════════════════════════════════════════════════════

/// L'analyse d'un lien, entièrement locale. Les règles complètent celles
/// du courrier (`MailGuard`) et en reprennent le vocabulaire : marques
/// usurpées, raccourcisseurs, écritures mélangées.
enum LinkGuard {
    static let riskyTLDs: Set<String> = [
        "zip", "mov", "xyz", "top", "click", "country", "gq", "tk", "ml", "cf", "ga",
        "work", "support", "rest", "cam", "icu", "sbs", "buzz", "monster", "cfd"
    ]
    static let lureWords = ["login", "signin", "verify", "verif", "secure", "update", "account",
                            "compte", "connexion", "identifiant", "paiement", "facture", "colis",
                            "douane", "remboursement", "banque", "suspendu"]

    static func analyze(_ url: String) -> MailThreat {
        var t = MailThreat()
        let lower = url.lowercased()
        let host = MailGuard.host(ofURL: url)
        guard !host.isEmpty else { return t }

        if lower.hasPrefix("http://") { t.add(15, "connexion non chiffrée (http)") }
        let afterScheme = lower.components(separatedBy: "://").dropFirst().first ?? lower
        let authority = afterScheme.split(separator: "/").first.map(String.init) ?? afterScheme
        if authority.contains("@") { t.add(40, "adresse déguisée par un « @ »") }
        if host.range(of: "^[0-9.]+$", options: .regularExpression) != nil {
            t.add(35, "adresse IP au lieu d'un nom")
        }
        if host.contains("xn--") { t.add(35, "nom de domaine en punycode") }
        if MailGuard.hasMixedScript(host) { t.add(50, "lettres cyrilliques ou grecques mêlées") }
        if MailGuard.shorteners.contains(host) { t.add(20, "lien raccourci : destination cachée") }

        let parts = host.split(separator: ".")
        if let tld = parts.last, riskyTLDs.contains(String(tld)) {
            t.add(20, "extension « .\(tld) » très prisée des fraudeurs")
        }
        if parts.count >= 5 { t.add(15, "nombreux sous-domaines") }
        if host.filter({ $0 == "-" }).count >= 3 { t.add(10, "nom fait de mots accolés") }

        // Les marques : le nom apparaît dans l'adresse, mais l'adresse
        // n'est pas la sienne. On teste aussi la version « déchiffrée » —
        // paypa1 → paypal, micros0ft → microsoft.
        let swaps: [Character: Character] = ["0": "o", "1": "l", "3": "e", "5": "s", "4": "a"]
        let decodedHost = String(host.replacingOccurrences(of: "rn", with: "m").map { swaps[$0] ?? $0 })
        // Un nom court — « ups », « sfr », « free » — n'est cherché que comme
        // mot entier de l'adresse : « groups » n'imite pas UPS.
        func mentions(_ h: String, _ token: String) -> Bool {
            if token.count >= 5 { return h.contains(token) }
            return h.split(whereSeparator: { $0 == "." || $0 == "-" }).contains { String($0) == token }
        }
        for b in MailGuard.brands {
            let token = MailGuard.fold(b.name).replacingOccurrences(of: " ", with: "")
            guard token.count >= 3 else { continue }
            if b.domains.contains(where: { MailGuard.domain(host, isOrSub: $0) }) { break }
            if mentions(host, token) {
                t.add(45, "imite \(b.name.capitalized) sans en être")
                break
            }
            if mentions(decodedHost, token) {
                t.add(55, "sosie de \(b.name.capitalized) (chiffres à la place des lettres)")
                break
            }
        }

        if t.score > 0, lureWords.contains(where: { lower.contains($0) }) {
            t.add(10, "vocabulaire d'identification ou de paiement")
        }
        if url.count > 160 { t.add(5, "adresse anormalement longue") }
        return t
    }
}

/// Le complément en ligne, facultatif : Google Safe Browsing, API
/// Lookup v4, gratuite pour un usage non commercial. Sans clé, rien ne
/// part. Avec une clé — rangée dans le trousseau, jamais sur disque —
/// seules les adresses des liens sont envoyées, pas le courrier.
enum SafeBrowsing {
    static let account = "safebrowsing-key"
    static var key: String? {
        guard let k = BudKeychain.get(account), !k.isEmpty else { return nil }
        return k
    }

    /// Rend l'ensemble des liens signalés, ou `nil` si la question n'a pas
    /// pu être posée — ce qui n'est pas la même chose que « aucun ».
    static func check(_ urls: [String], done: @escaping (Set<String>?) -> Void) {
        guard let k = key, !urls.isEmpty,
              var c = URLComponents(string: "https://safebrowsing.googleapis.com/v4/threatMatches:find")
        else { done(nil); return }
        c.queryItems = [URLQueryItem(name: "key", value: k)]
        guard let url = c.url else { done(nil); return }
        let body: [String: Any] = [
            "client": ["clientId": "bud-premium", "clientVersion": budVersion],
            "threatInfo": [
                "threatTypes": ["MALWARE", "SOCIAL_ENGINEERING", "UNWANTED_SOFTWARE",
                                "POTENTIALLY_HARMFUL_APPLICATION"],
                "platformTypes": ["ANY_PLATFORM"],
                "threatEntryTypes": ["URL"],
                "threatEntries": urls.prefix(100).map { ["url": $0] }
            ]
        ]
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { done(nil); return }
            let hits = (o["matches"] as? [[String: Any]] ?? []).compactMap {
                ($0["threat"] as? [String: Any])?["url"] as? String
            }
            done(Set(hits))
        }.resume()
    }
}

final class SecurityAgent: BudAgent {
    let id = "security"
    let name = "Cybersécurité"
    let summary = "Liens, domaines et courrier : hameçonnage, sosies de marques, adresses truquées."
    let icon = "lock.shield.fill"
    var tint: NSColor { tintSecurity }
    let sources = [
        FlowSource(id: "mail", title: "Courrier", icon: "envelope.fill",
                   tint: NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.00, alpha: 1),
                   note: "Les trente derniers messages déjà relevés par BUD. Analyse sur place."),
        FlowSource(id: "clipboard", title: "Presse-papiers", icon: "doc.on.clipboard.fill",
                   tint: NSColor(calibratedRed: 1.00, green: 0.70, blue: 0.30, alpha: 1),
                   note: "Lu seulement au lancement de l'agent, jamais en continu.")
    ]

    private let mail: () -> [MailMessage]
    /// Un lien tapé dans l'inspecteur : analysé en plus, puis oublié.
    var input: String?

    init(mail: @escaping () -> [MailMessage]) { self.mail = mail }

    func run(_ ctx: AgentContext, done: @escaping (AgentResult) -> Void) {
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        let typed = input ?? ""
        input = nil
        let messages = mail()
        DispatchQueue.global(qos: .userInitiated).async {
            ctx.progress("Analyse locale…")
            var links = MailGuard.urls(in: typed + "\n" + clip)
            // Un domaine nu, tapé sans « https:// », est un lien aussi.
            let bare = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if links.isEmpty, !bare.isEmpty, !bare.contains(" "), bare.contains(".") {
                links.append("https://" + bare)
            }
            for m in messages.prefix(30) { links += MailGuard.urls(in: m.snippet) }
            var seen = Set<String>()
            links = links.filter { seen.insert($0).inserted }
            let mails = messages.prefix(30).map { ($0, MailGuard.analyze($0)) }
            let base = links.map { ($0, LinkGuard.analyze($0)) }

            guard SafeBrowsing.key != nil, !links.isEmpty else {
                done(Self.result(links: base, mails: Array(mails), online: nil))
                return
            }
            ctx.progress("Vérification Safe Browsing…")
            SafeBrowsing.check(links) { hits in
                let merged = base.map { (u, t) -> (String, MailThreat) in
                    var t = t
                    if hits?.contains(u) == true { t.add(80, "signalé par Google Safe Browsing") }
                    return (u, t)
                }
                done(Self.result(links: merged, mails: Array(mails), online: hits != nil))
            }
        }
    }

    func simulate(_ ctx: AgentContext, done: @escaping (AgentResult) -> Void) {
        ctx.progress("Analyse locale…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            // Les vraies règles, sur de faux liens : la simulation éprouve
            // l'analyse autant que l'affichage.
            let links = BudFlowSamples.links.map { ($0, LinkGuard.analyze($0)) }
            let mails = BudFlowSamples.mails.map { ($0, MailGuard.analyze($0)) }
            done(Self.result(links: links, mails: mails, online: nil))
        }
    }

    static func result(links: [(String, MailThreat)], mails: [(MailMessage, MailThreat)],
                       online: Bool?) -> AgentResult {
        guard !links.isEmpty || !mails.isEmpty else {
            return AgentResult(status: .idle, expression: .neutral,
                               headline: "Rien à analyser : copiez un lien ou tapez-le ici.",
                               cards: [BudCard(icon: "link", title: "LIENS", value: "0",
                                               detail: "Presse-papiers vide", tint: tintSecurity)])
        }
        let worstLinks = links.sorted { $0.1.score > $1.1.score }
        let dangerous = links.filter { $0.1.level == .dangerous }.count
            + mails.filter { $0.1.level == .dangerous }.count
        let suspect = links.filter { $0.1.level == .suspect }.count
            + mails.filter { $0.1.level == .suspect }.count
        let worst: ThreatLevel = dangerous > 0 ? .dangerous : (suspect > 0 ? .suspect : .clean)

        var cards: [BudCard] = [
            BudCard(icon: worst.icon, title: "NIVEAU DE RISQUE", value: worst.label,
                    detail: "\(links.count) lien\(links.count > 1 ? "s" : ""), \(mails.count) message\(mails.count > 1 ? "s" : "")",
                    tint: worst.color)
        ]
        for (u, t) in worstLinks.prefix(2) where t.level != .clean {
            cards.append(BudCard(icon: t.level.icon, title: MailGuard.host(ofURL: u).uppercased(),
                                 value: "\(min(100, t.score))/100",
                                 detail: t.reasons.first ?? "", tint: t.level.color))
        }
        if let top = mails.sorted(by: { $0.1.score > $1.1.score }).first, top.1.level != .clean {
            cards.append(BudCard(icon: "envelope.badge.fill", title: "COURRIER",
                                 value: top.1.level.label,
                                 detail: top.0.shortSender + " · " + (top.1.reasons.first ?? ""),
                                 tint: top.1.level.color))
        }
        if let o = online {
            cards.append(BudCard(icon: "globe", title: "SAFE BROWSING",
                                 value: o ? "Consulté" : "Injoignable",
                                 detail: o ? "Liens seulement" : "Analyse locale seule",
                                 tint: tintSky))
        }

        switch worst {
        case .dangerous:
            return AgentResult(status: .warning, expression: .annoyed,
                               headline: "\(dangerous) élément\(dangerous > 1 ? "s" : "") dangereux. N'ouvrez pas ces liens.",
                               cards: cards, hold: 6)
        case .suspect:
            return AgentResult(status: .warning, expression: .reflection,
                               headline: "\(suspect) élément\(suspect > 1 ? "s" : "") suspect\(suspect > 1 ? "s" : "") : prudence.",
                               cards: cards, hold: 5)
        case .clean:
            return AgentResult(status: .success, expression: .happy,
                               headline: "Rien de suspect dans \(links.count + mails.count) élément\(links.count + mails.count > 1 ? "s" : "").",
                               cards: cards)
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  3. Météo & Maison
//
//  Il ne refait ni la météo ni la maison : il lit le service
//  météo et les raccourcis déjà chargés, et les rend en cartes.
//  Rien de plus à télécharger, rien de plus à garder en
//  mémoire.
// ═══════════════════════════════════════════════════════════

final class WeatherHomeAgent: BudAgent {
    let id = "weatherhome"
    let name = "Météo & Maison"
    let summary = "Le ciel du moment, et vos commandes de chauffage, de lumières et de caméra."
    let icon = "cloud.sun.fill"
    var tint: NSColor { tintSky }
    let sources = [
        FlowSource(id: "sky", title: "Ciel · Open-Meteo", icon: "cloud.sun.fill", tint: tintSky,
                   note: "Seules les coordonnées de la ville partent, arrondies au kilomètre."),
        FlowSource(id: "home", title: "Raccourcis Maison", icon: "house.fill",
                   tint: NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.25, alpha: 1),
                   note: "Les raccourcis de votre dossier Maison. BUD ne voit pas vos appareils.")
    ]

    private let city: () -> String
    private let runHome: (String, @escaping (Bool, String) -> Void) -> Void

    init(city: @escaping () -> String, runHome: @escaping (String, @escaping (Bool, String) -> Void) -> Void) {
        self.city = city
        self.runHome = runHome
    }

    func run(_ ctx: AgentContext, done: @escaping (AgentResult) -> Void) {
        let w = WeatherService.shared
        if let r = w.report, Date().timeIntervalSince(r.fetchedAt) < 35 * 60 {
            done(build(r, scenes: HomeShortcuts.shared.scenes.map { $0.name }, simulated: false))
            return
        }
        ctx.progress("Relevé du ciel…")
        let before = w.report?.fetchedAt
        w.refresh(city: city(), force: true)
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] tm in
            tries += 1
            guard let s = self else { tm.invalidate(); return }
            if w.report?.fetchedAt != before || !w.trouble.isEmpty || tries > 30 || ctx.cancelled {
                tm.invalidate()
                done(s.build(w.report, scenes: HomeShortcuts.shared.scenes.map { $0.name }, simulated: false))
            }
        }
    }

    func simulate(_ ctx: AgentContext, done: @escaping (AgentResult) -> Void) {
        ctx.progress("Relevé du ciel…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let s = self else { return }
            done(s.build(BudFlowSamples.weather, scenes: BudFlowSamples.homeScenes, simulated: true))
        }
    }

    /// Les trois familles de commandes et les mots qui les désignent.
    private static let controls: [(title: String, icon: String, keys: [String], tint: NSColor, fallback: String)] = [
        ("CHAUFFAGE", "thermometer", ["chauffage", "thermostat", "radiateur", "clim"],
         NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.30, alpha: 1), "com.apple.shortcuts"),
        ("LUMIÈRES", "lightbulb.fill", ["lumiere", "lampe", "eclairage", "ampoule", "led"],
         NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.26, alpha: 1), "com.apple.shortcuts"),
        ("CAMÉRA", "video.fill", ["camera", "alarme", "securite"],
         NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.45, alpha: 1), "com.apple.Home")
    ]

    private func build(_ r: WeatherReport?, scenes: [String], simulated: Bool) -> AgentResult {
        var cards: [BudCard] = []
        let expr: BudExpression
        let headline: String

        if let r = r {
            let c = r.condition
            var detail = c.label
            if let d = r.days.first { detail += " · \(Int(d.tmin.rounded()))° / \(Int(d.tmax.rounded()))°" }
            cards.append(BudCard(style: .weather, icon: c.symbol, title: r.place.name.uppercased(),
                                 value: "\(Int(r.temp.rounded()))°", detail: detail, tint: tintSky,
                                 weatherCode: r.code, isDay: r.isDay))
            switch c.scene {
            case .clear:                  expr = .cool
            case .partly, .cloudy:        expr = .happy
            case .fog:                    expr = .reflection
            case .drizzle, .rain, .snow:  expr = .sad
            case .storm:                  expr = .dizzy
            }
            headline = "\(r.place.name) : \(Int(r.temp.rounded()))°, \(c.label.lowercased())."
        } else {
            expr = .sad
            headline = WeatherService.shared.trouble.isEmpty ? "Météo indisponible." : WeatherService.shared.trouble
            cards.append(BudCard(icon: "cloud.fill", title: "MÉTÉO", value: "—", detail: headline, tint: tintSky))
        }

        for k in Self.controls {
            let matches = scenes.filter { n in
                let f = MailGuard.fold(n)
                return k.keys.contains { f.contains($0) }
            }
            let runHome = self.runHome
            if let first = matches.first {
                cards.append(BudCard(style: .control, icon: k.icon, title: k.title,
                                     value: matches.count == 1 ? first : "\(matches.count) commandes",
                                     detail: simulated ? "Simulation" : "Toucher : « \(first) »",
                                     tint: k.tint,
                                     action: { finish in
                                        if simulated {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                                finish(true, "Simulation : « \(first) » lancé.")
                                            }
                                        } else {
                                            runHome(first, finish)
                                        }
                                     }))
            } else {
                let bundle = k.fallback
                cards.append(BudCard(style: .control, icon: k.icon, title: k.title, value: "À configurer",
                                     detail: bundle == "com.apple.Home" ? "Ouvrir Maison" : "Ajouter un raccourci",
                                     tint: k.tint.withAlphaComponent(0.55),
                                     action: { finish in
                                        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                                            NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration(),
                                                                               completionHandler: nil)
                                            finish(true, "Ouvert.")
                                        } else {
                                            finish(false, "Application introuvable.")
                                        }
                                     }))
            }
        }
        return AgentResult(status: r == nil ? .failure : .success, expression: expr,
                           headline: headline, cards: cards)
    }
}
