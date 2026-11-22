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

    static func fetchInbox(user: String, password: String, limit: Int = 5) -> GmailSnapshot {
        fetchInbox(user: user, auth: .appPassword(password), limit: limit)
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
    static func fetchInbox(user: String, auth: GmailAuthMode, limit: Int = 5) -> GmailSnapshot {
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

        for (i, uid) in all.suffix(limit).reversed().enumerated() {
            let tag = "f\(i)"
            s.write("\(tag) UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE "
                    + "REPLY-TO RETURN-PATH MESSAGE-ID AUTHENTICATION-RESULTS RECEIVED-SPF)] "
                    + "BODYSTRUCTURE)")
            var subject = "", from = "", date = "", replyTo = ""
            var ret = "", mid = "", authRes = "", spf = ""
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
            m.attachments = attachmentNames(in: structure)
            m.snippet = fetchSnippet(s, uid: uid, tag: "b\(i)")
            m.threat = MailGuard.analyze(m)
            snap.messages.append(m)
        }
        s.write("a9 LOGOUT")
        return snap
    }

    /// Noms de pièces jointes extraits de BODYSTRUCTURE. Le format est
    /// une liste Lisp imbriquée pénible à analyser ; les noms y figurent
    /// toujours après NAME ou FILENAME, ce qui suffit ici.
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
        while let l = s.readLine() {
            if l.hasPrefix("\(tag) ") { break }
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
    static func quarantine(user: String, auth: GmailAuthMode, uids: [String]) -> String? {
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

        // Le nom du dossier indésirable est localisé : on le demande au
        // serveur par son rôle plutôt que de le deviner.
        var junk = ""
        s.write("q2 LIST (SPECIAL-USE) \"\" \"*\"")
        while let l = s.readLine() {
            if l.hasPrefix("q2 ") { break }
            if l.contains("\\Junk"), let last = l.range(of: "\"", options: .backwards) {
                let head = l[l.startIndex..<last.lowerBound]
                if let open = head.range(of: "\"", options: .backwards) {
                    junk = String(head[open.upperBound...])
                }
            }
        }
        if junk.isEmpty { junk = "[Gmail]/Spam" }

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
