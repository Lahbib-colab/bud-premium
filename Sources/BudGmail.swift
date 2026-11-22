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
    /// Le prochain identifiant que le serveur attribuera. C'est ce qui
    /// permet de savoir qu'il n'y a rien de neuf sans rapatrier un seul
    /// message : si UIDNEXT n'a pas bougé, aucun message n'est arrivé.
    var uidNext: String = ""
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

    static func fetchInbox(user: String, password: String, limit: Int = 5,
                           snippetLimit: Int = 12) -> GmailSnapshot {
        fetchInbox(user: user, auth: .appPassword(password), limit: limit,
                   snippetLimit: snippetLimit)
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
    static func fetchInbox(user: String, auth: GmailAuthMode, limit: Int = 5,
                           snippetLimit: Int = 12) -> GmailSnapshot {
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

        // Le prochain identifiant se déduit du plus grand rencontré. On
        // l'enregistre pour que le sondage de fond puisse comparer sans
        // refaire ce travail.
        if let maxUID = all.compactMap({ Int($0) }).max() {
            snap.uidNext = String(maxUID + 1)
        }

        for (i, uid) in all.suffix(limit).reversed().enumerated() {
            let tag = "f\(i)"
            // LIST-UNSUBSCRIBE, LIST-ID et PRECEDENCE servent au classement
            // par type. Un message portant un lien de désabonnement est un
            // envoi en masse — signal bien plus sûr qu'un mot-clé dans
            // l'objet, puisque c'est l'expéditeur lui-même qui le déclare.
            s.write("\(tag) UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE "
                    + "REPLY-TO RETURN-PATH MESSAGE-ID AUTHENTICATION-RESULTS RECEIVED-SPF "
                    + "LIST-UNSUBSCRIBE LIST-ID PRECEDENCE)] "
                    + "BODYSTRUCTURE)")
            var subject = "", from = "", date = "", replyTo = ""
            var ret = "", mid = "", authRes = "", spf = "", bulk = ""
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
                case "list-unsubscribe", "list-id", "precedence":
                    // Les trois disent la même chose — « envoi en masse ».
                    // Un seul suffit, et les réunir évite trois champs.
                    bulk += " " + value
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
            m.parts = parts(in: structure)
            // Les noms restent renseignés : l'analyse de hameçonnage les
            // lit encore, et une passerelle sans BODYSTRUCTURE n'aurait
            // pas de parties.
            m.attachments = m.parts.filter { $0.isAttachment }.map { $0.name }
            if m.attachments.isEmpty { m.attachments = attachmentNames(in: structure) }
            m.bulkHeaders = bulk.trimmingCharacters(in: .whitespaces)
            // Le corps n'est rapatrié que pour les premiers messages : à
            // soixante, un aller-retour de 8 Ko chacun ferait attendre une
            // minute avant le premier affichage. Les suivants le chargent
            // à l'ouverture, et l'aperçu de leur ligne reste vide d'ici là.
            if i < snippetLimit {
                m.snippet = fetchSnippet(s, uid: uid, tag: "b\(i)")
            }
            m.category = MailSorter.categorize(m)
            m.threat = MailGuard.analyze(m)
            snap.messages.append(m)
        }
        s.write("a9 LOGOUT")
        return snap
    }

    /// Noms de pièces jointes extraits de BODYSTRUCTURE. Le format est
    /// une liste Lisp imbriquée pénible à analyser ; les noms y figurent
    /// toujours après NAME ou FILENAME, ce qui suffit ici.
    // ─────────────────────────────────────────────────────────
    //  BODYSTRUCTURE
    //
    //  Une liste imbriquée à la Lisp, que le serveur rend sur une
    //  ligne. On l'analyse pour de bon plutôt que d'y pêcher des noms
    //  de fichiers à l'expression régulière : sans les **numéros de
    //  section**, on sait qu'une pièce jointe existe mais pas où elle
    //  est, donc on ne peut ni l'ouvrir ni dire son poids.
    //
    //  La numérotation suit la RFC 3501 : les enfants d'une partie
    //  multiple portent son préfixe suivi de leur rang — 1, 2, puis
    //  1.1, 1.2 pour un multiple imbriqué dans le premier.
    // ─────────────────────────────────────────────────────────

    /// Un nœud de la structure : une chaîne, ou une liste de nœuds.
    private indirect enum SNode {
        case atom(String)
        case list([SNode])

        var text: String { if case .atom(let s) = self { return s }; return "" }
        var children: [SNode] { if case .list(let l) = self { return l }; return [] }
        var isList: Bool { if case .list = self { return true }; return false }
    }

    private static func tokenize(_ s: String) -> SNode {
        let chars = Array(s)
        var i = 0

        func parseList() -> SNode {
            var out: [SNode] = []
            i += 1                                  // la parenthèse ouvrante
            while i < chars.count {
                let c = chars[i]
                if c == ")" { i += 1; return .list(out) }
                if c == " " { i += 1; continue }
                if c == "(" { out.append(parseList()); continue }
                if c == "\"" {
                    var buf = ""
                    i += 1
                    while i < chars.count && chars[i] != "\"" {
                        if chars[i] == "\\" && i + 1 < chars.count {
                            buf.append(chars[i + 1]); i += 2; continue
                        }
                        buf.append(chars[i]); i += 1
                    }
                    i += 1
                    out.append(.atom(buf)); continue
                }
                var j = i
                while j < chars.count && chars[j] != " " && chars[j] != "(" && chars[j] != ")" {
                    j += 1
                }
                out.append(.atom(String(chars[i..<j])))
                i = j
            }
            return .list(out)
        }

        while i < chars.count && chars[i] != "(" { i += 1 }
        return i < chars.count ? parseList() : .list([])
    }

    /// Les parties d'un message, numérotées.
    static func parts(in structure: String) -> [MailPart] {
        guard !structure.isEmpty else { return [] }
        var out: [MailPart] = []
        walk(tokenize(structure), prefix: "", into: &out)
        return out
    }

    private static func walk(_ node: SNode, prefix: String, into out: inout [MailPart]) {
        let kids = node.children
        // Une partie multiple commence par ses enfants, qui sont des listes.
        if let first = kids.first, first.isList {
            var rank = 0
            for child in kids {
                guard child.isList else { break }
                rank += 1
                let p = prefix.isEmpty ? "\(rank)" : "\(prefix).\(rank)"
                walk(child, prefix: p, into: &out)
            }
            return
        }

        var part = MailPart()
        part.section = prefix.isEmpty ? "1" : prefix
        part.type = kids.count > 0 ? kids[0].text.uppercased() : ""
        part.subtype = kids.count > 1 ? kids[1].text.uppercased() : ""
        part.encoding = kids.count > 5 ? kids[5].text.uppercased() : ""
        part.size = kids.count > 6 ? (Int(kids[6].text) ?? 0) : 0

        // Le nom se trouve dans les paramètres, ou dans la disposition.
        // Les deux existent, et l'un sans l'autre est courant.
        if kids.count > 2, case .list(let params) = kids[2] {
            part.name = value(of: "NAME", in: params)
        }
        for el in kids where el.isList {
            let l = el.children
            guard let head = l.first, case .atom(let word) = head,
                  ["ATTACHMENT", "INLINE"].contains(word.uppercased()),
                  l.count > 1, case .list(let d) = l[1] else { continue }
            let f = value(of: "FILENAME", in: d)
            if !f.isEmpty { part.name = f }
        }
        part.name = decodeMimeHeader(part.name)
        out.append(part)
    }

    private static func value(of key: String, in pairs: [SNode]) -> String {
        var i = 0
        while i + 1 < pairs.count {
            if pairs[i].text.uppercased() == key { return pairs[i + 1].text }
            i += 2
        }
        return ""
    }

    /// Rapatrie une partie précise et la décode.
    static func fetchPart(user: String, auth: GmailAuthMode,
                          uid: String, part: MailPart) -> Data? {
        guard !uid.isEmpty, !part.section.isEmpty,
              part.section.range(of: "^[0-9]+(\\.[0-9]+)*$",
                                 options: .regularExpression) != nil,
              let s = TLSLineSocket(host: imapHost, port: 993) else { return nil }
        defer { s.close() }
        _ = s.readLine()
        switch auth {
        case .appPassword(let p): s.write("p1 LOGIN \"\(user)\" \"\(normalizedPassword(p))\"")
        case .oauth(let token):   s.write("p1 AUTHENTICATE XOAUTH2 \(token)")
        }
        var logged = false
        while let l = s.readLine() {
            if l.hasPrefix("p1 OK") { logged = true; break }
            if l.hasPrefix("p1 NO") || l.hasPrefix("p1 BAD") { break }
            if l.hasPrefix("+ ") { s.write("") }
        }
        guard logged else { return nil }
        // EXAMINE : ouvrir une pièce jointe ne doit pas marquer le message
        // comme lu dans votre boîte.
        s.write("p2 EXAMINE INBOX")
        while let l = s.readLine() { if l.hasPrefix("p2 ") { break } }

        s.write("p3 UID FETCH \(uid) (BODY.PEEK[\(part.section)])")
        var lines: [String] = []
        var first = true
        while let l = s.readLine() {
            if l.hasPrefix("p3 ") { break }
            if first {
                first = false
                if l.hasPrefix("*") && l.uppercased().contains("FETCH") { continue }
            }
            if l.trimmingCharacters(in: .whitespaces) == ")" { continue }
            lines.append(l)
        }
        s.write("p9 LOGOUT")

        let raw = lines.joined(separator: "\n")
        guard !raw.isEmpty else { return nil }
        if part.encoding == "BASE64" {
            let compact = raw.filter { !" \n\r\t".contains($0) }
            return Data(base64Encoded: compact, options: .ignoreUnknownCharacters)
        }
        return raw.data(using: .utf8)
    }

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
        var first = true
        while let l = s.readLine() {
            if l.hasPrefix("\(tag) ") { break }

            // La réponse d'un FETCH n'est pas que le corps. Elle s'ouvre sur
            // une ligne non étiquetée — « * 9284 FETCH (UID 9284 BODY[1]<0>
            // {2048} » — et se referme sur une parenthèse seule. Les garder
            // revenait à afficher la commande IMAP en tête du message, ce
            // qu'on voyait dans le lecteur, et à la donner à l'analyse de
            // hameçonnage comme si c'était du texte de l'expéditeur.
            if first {
                first = false
                if l.hasPrefix("*") && l.uppercased().contains("FETCH") {
                    // Corps court : certains serveurs le renvoient entre
                    // guillemets sur cette même ligne plutôt qu'en littéral.
                    if let q = l.range(of: "BODY[", options: .caseInsensitive),
                       let open = l.range(of: "\"", range: q.upperBound..<l.endIndex),
                       let close = l.range(of: "\"", options: .backwards),
                       open.upperBound <= close.lowerBound {
                        lines.append(String(l[open.upperBound..<close.lowerBound]))
                    }
                    continue
                }
            }
            // La parenthèse de fermeture, seule sur sa ligne.
            if l.trimmingCharacters(in: .whitespaces) == ")" { continue }

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
    /// L'état de la boîte en une commande, sans rapatrier un seul message :
    /// le prochain identifiant et le nombre de non-lus.
    ///
    /// C'est la clé du sondage de fond. Un relevé complet ouvre une session
    /// TLS, s'authentifie, cherche, puis rapatrie soixante en-têtes et douze
    /// corps : plusieurs secondes. Un STATUS, lui, coûte un aller-retour.
    /// On sonde donc souvent avec STATUS, et on ne paie le relevé complet
    /// que lorsqu'il a vraiment changé quelque chose.
    ///
    /// Ce que cela ne voit pas : une suppression faite ailleurs ne change ni
    /// UIDNEXT ni le nombre de non-lus si le message était déjà lu. Le
    /// bouton Actualiser reste donc utile, et il force le relevé complet.
    static func status(user: String, auth: GmailAuthMode) -> (uidNext: String, unseen: Int)? {
        guard let s = TLSLineSocket(host: imapHost, port: 993) else { return nil }
        defer { s.close() }
        _ = s.readLine()
        switch auth {
        case .appPassword(let p): s.write("s1 LOGIN \"\(user)\" \"\(normalizedPassword(p))\"")
        case .oauth(let token):   s.write("s1 AUTHENTICATE XOAUTH2 \(token)")
        }
        var logged = false
        while let l = s.readLine() {
            if l.hasPrefix("s1 OK") { logged = true; break }
            if l.hasPrefix("s1 NO") || l.hasPrefix("s1 BAD") { break }
            if l.hasPrefix("+ ") { s.write("") }
        }
        guard logged else { return nil }

        s.write("s2 STATUS INBOX (UIDNEXT UNSEEN)")
        var next = "", unseen = -1
        while let l = s.readLine() {
            if l.hasPrefix("s2 ") { break }
            if l.hasPrefix("*") && l.uppercased().contains("STATUS") {
                if let r = l.range(of: "UIDNEXT ([0-9]+)", options: .regularExpression) {
                    next = String(l[r]).components(separatedBy: " ").last ?? ""
                }
                if let r = l.range(of: "UNSEEN ([0-9]+)", options: .regularExpression) {
                    unseen = Int(String(l[r]).components(separatedBy: " ").last ?? "") ?? -1
                }
            }
        }
        s.write("s9 LOGOUT")
        return next.isEmpty ? nil : (next, unseen)
    }

    /// Rapatrie le corps d'un seul message, pour ceux que le relevé n'a
    /// pas chargés. Une connexion pour un message : c'est le prix de ne
    /// pas faire attendre une minute à l'ouverture de la boîte.
    static func body(user: String, auth: GmailAuthMode, uid: String) -> String? {
        guard !uid.isEmpty, let s = TLSLineSocket(host: imapHost, port: 993) else { return nil }
        defer { s.close() }
        _ = s.readLine()
        switch auth {
        case .appPassword(let p): s.write("c1 LOGIN \"\(user)\" \"\(normalizedPassword(p))\"")
        case .oauth(let token):   s.write("c1 AUTHENTICATE XOAUTH2 \(token)")
        }
        var logged = false
        while let l = s.readLine() {
            if l.hasPrefix("c1 OK") { logged = true; break }
            if l.hasPrefix("c1 NO") || l.hasPrefix("c1 BAD") { break }
            if l.hasPrefix("+ ") { s.write("") }
        }
        guard logged else { return nil }
        // EXAMINE et non SELECT : la boîte est ouverte en lecture seule,
        // pour qu'ouvrir un message ne le marque pas comme lu à l'insu
        // de l'utilisateur.
        s.write("c2 EXAMINE INBOX")
        while let l = s.readLine() { if l.hasPrefix("c2 ") { break } }
        let body = fetchSnippet(s, uid: uid, tag: "c3")
        s.write("c9 LOGOUT")
        return body.isEmpty ? nil : body
    }

    /// Déplace des messages vers l'indésirable.
    static func quarantine(user: String, auth: GmailAuthMode, uids: [String]) -> String? {
        move(user: user, auth: auth, uids: uids, role: "\\Junk", fallback: "[Gmail]/Spam")
    }

    /// Déplace des messages vers la corbeille du compte. Un courriel n'est
    /// jamais effacé : il va dans la corbeille, où le serveur le gardera le
    /// temps qu'il voudra, et d'où l'utilisateur peut le reprendre.
    static func trash(user: String, auth: GmailAuthMode, uids: [String]) -> String? {
        move(user: user, auth: auth, uids: uids, role: "\\Trash", fallback: "[Gmail]/Trash")
    }

    /// Le déplacement, commun aux deux. Le dossier est demandé au serveur
    /// par son rôle : son nom est localisé, et le deviner marcherait chez
    /// Gmail en anglais et nulle part ailleurs.
    private static func move(user: String, auth: GmailAuthMode, uids: [String],
                             role: String, fallback: String) -> String? {
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

        var junk = ""
        s.write("q2 LIST (SPECIAL-USE) \"\" \"*\"")
        while let l = s.readLine() {
            if l.hasPrefix("q2 ") { break }
            if l.contains(role), let last = l.range(of: "\"", options: .backwards) {
                let head = l[l.startIndex..<last.lowerBound]
                if let open = head.range(of: "\"", options: .backwards) {
                    junk = String(head[open.upperBound...])
                }
            }
        }
        if junk.isEmpty { junk = fallback }

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
