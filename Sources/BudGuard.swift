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

struct MailThreat: Codable {
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
