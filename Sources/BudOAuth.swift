import Foundation
import Network
import CryptoKit
import AppKit

// ═══════════════════════════════════════════════════════════
//  OAuth 2.0 Google avec PKCE
//
//  Flux « application de bureau » : BUD ouvre le consentement dans
//  votre navigateur, écoute sur 127.0.0.1 le retour de Google, puis
//  échange le code contre des jetons. Le jeton de rafraîchissement
//  va dans le trousseau ; le jeton d'accès reste en mémoire.
//  Aucun identifiant ne transite par un serveur tiers.
// ═══════════════════════════════════════════════════════════

struct GoogleTokens {
    var access: String
    var refresh: String
    var expiry: Date
    var email: String
}

/// Petit serveur local qui attend la redirection de Google.
final class LoopbackCatcher {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fr.lahbib.bud.oauth")
    private var finished = false

    /// Démarre l'écoute et renvoie le port retenu.
    ///
    /// Deux tentatives : d'abord restreint à la boucle locale, sinon sans
    /// restriction. Sans point d'ancrage, NWListener écoute sur toutes les
    /// interfaces — n'importe qui sur le même Wi-Fi pourrait frapper à ce
    /// port, alors que Google ne redirige que vers 127.0.0.1. Mais avec
    /// « port: .any », certaines versions renvoient 0 au lieu du port réel ;
    /// on vérifie donc, et on retombe sur l'écoute large plutôt que d'échouer.
    /// (Rien à voir avec macOS 15 : accepter une connexion TCP entrante ne
    ///  demande aucune autorisation « Réseau local ».)
    func start(timeout: TimeInterval = 180,
               onResult: @escaping (String?, String?) -> Void) -> UInt16? {
        if let port = attempt(loopbackOnly: true, timeout: timeout, onResult: onResult) {
            return port
        }
        stop()
        return attempt(loopbackOnly: false, timeout: timeout, onResult: onResult)
    }

    private func attempt(loopbackOnly: Bool, timeout: TimeInterval,
                         onResult: @escaping (String?, String?) -> Void) -> UInt16? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if loopbackOnly {
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l

        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { st in
            if case .ready = st { ready.signal() }
            if case .failed = st { ready.signal() }
        }

        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                var code: String?
                var err: String?
                if let d = data, let req = String(data: d, encoding: .utf8),
                   let line = req.split(separator: "\r\n").first {
                    // GET /?code=...&scope=... HTTP/1.1
                    let parts = line.split(separator: " ")
                    if parts.count > 1 {
                        let path = String(parts[1])
                        if let q = path.split(separator: "?").dropFirst().first {
                            for pair in q.split(separator: "&") {
                                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                                guard kv.count == 2 else { continue }
                                let value = kv[1].removingPercentEncoding ?? kv[1]
                                if kv[0] == "code" { code = value }
                                if kv[0] == "error" { err = value }
                            }
                        }
                    }
                }
                let page = """
                <!doctype html><html lang="fr"><head><meta charset="utf-8">
                <title>BUD</title></head>
                <body style="font-family:-apple-system,system-ui;background:#0b0b0c;color:#f4f4f5;
                display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
                <div style="text-align:center">
                <div style="font-size:48px">\(code != nil ? "✅" : "⚠️")</div>
                <h2 style="font-weight:600">\(code != nil ? "Compte relié à BUD" : "Connexion interrompue")</h2>
                <p style="opacity:.6">Vous pouvez fermer cet onglet et revenir à BUD.</p>
                </div></body></html>
                """
                let body = Data(page.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                guard let s = self, !s.finished else { return }
                s.finished = true
                DispatchQueue.main.async { onResult(code, err) }
                s.stop()
            }
        }

        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = l.port?.rawValue, port != 0 else {
            l.cancel()
            listener = nil
            return nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let s = self, !s.finished else { return }
            s.finished = true
            s.stop()
            onResult(nil, "délai dépassé")
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

enum GoogleOAuth {

    static let scope = "https://mail.google.com/ openid email"

    // Non privés : l'appairage par téléphone (BudPhone) construit sa
    // propre URL de consentement avec le même PKCE.
    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL()
    }

    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL()
    }

    /// Ouvre le consentement Google et renvoie les jetons.
    static func authorize(clientID: String, clientSecret: String,
                          completion: @escaping (GoogleTokens?, String?) -> Void) {
        let verifier = randomVerifier()
        let catcher = LoopbackCatcher()

        guard let port = catcher.start(onResult: { code, err in
            guard let code = code else {
                completion(nil, err ?? "aucun code reçu")
                return
            }
            exchange(clientID: clientID, clientSecret: clientSecret,
                     code: code, verifier: verifier, port: 0, completion: completion)
        }) else {
            completion(nil, "impossible d'ouvrir le port local d'écoute")
            return
        }
        lastPort = port

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = c.url else {
            completion(nil, "URL d'autorisation invalide")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static var lastPort: UInt16 = 0

    private static func post(_ url: String, _ fields: [String: String],
                             _ done: @escaping ([String: Any]?, String?) -> Void) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { k, v in
            let ev = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
            return "\(k)=\(ev)"
        }.joined(separator: "&").data(using: .utf8)
        req.timeoutInterval = 25

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let e = error { done(nil, e.localizedDescription); return }
            guard let d = data,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                done(nil, "réponse illisible de Google")
                return
            }
            if let err = j["error"] as? String {
                let desc = j["error_description"] as? String ?? ""
                done(nil, "\(err) \(desc)".trimmingCharacters(in: .whitespaces))
                return
            }
            done(j, nil)
        }.resume()
    }

    private static func exchange(clientID: String, clientSecret: String, code: String,
                                 verifier: String, port: UInt16,
                                 completion: @escaping (GoogleTokens?, String?) -> Void) {
        exchangeCode(clientID: clientID, clientSecret: clientSecret, code: code,
                     verifier: verifier, redirect: "http://127.0.0.1:\(lastPort)",
                     completion: completion)
    }

    /// Échange un code d'autorisation contre des jetons. L'URI de
    /// redirection est passée telle qu'elle a servi à la demande : le
    /// flux téléphone a la sienne.
    static func exchangeCode(clientID: String, clientSecret: String, code: String,
                             verifier: String, redirect: String,
                             completion: @escaping (GoogleTokens?, String?) -> Void) {
        var fields = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect
        ]
        if !clientSecret.isEmpty { fields["client_secret"] = clientSecret }

        post("https://oauth2.googleapis.com/token", fields) { j, err in
            guard let j = j,
                  let access = j["access_token"] as? String else {
                DispatchQueue.main.async { completion(nil, err ?? "jeton absent") }
                return
            }
            let refresh = j["refresh_token"] as? String ?? ""
            let ttl = (j["expires_in"] as? Double) ?? 3500
            userEmail(access) { mail in
                let t = GoogleTokens(access: access, refresh: refresh,
                                     expiry: Date().addingTimeInterval(ttl - 60),
                                     email: mail ?? "")
                DispatchQueue.main.async { completion(t, mail == nil ? "adresse introuvable" : nil) }
            }
        }
    }

    static func refresh(clientID: String, clientSecret: String, refreshToken: String,
                        done: @escaping (String?, Date?, String?) -> Void) {
        var fields = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        post("https://oauth2.googleapis.com/token", fields) { j, err in
            guard let j = j, let a = j["access_token"] as? String else {
                done(nil, nil, err ?? "rafraîchissement refusé")
                return
            }
            let ttl = (j["expires_in"] as? Double) ?? 3500
            done(a, Date().addingTimeInterval(ttl - 60), nil)
        }
    }

    static func userEmail(_ accessToken: String, done: @escaping (String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let d = data,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                done(nil); return
            }
            done(j["email"] as? String)
        }.resume()
    }
}

extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// ═══════════════════════════════════════════════════════════
//  Session Gmail : conserve les identifiants et sert un jeton valide
// ═══════════════════════════════════════════════════════════

final class GmailAuth {
    static let shared = GmailAuth()

    private let kClientID = "oauth.client.id"
    private let kSecret = "oauth.client.secret"
    private let kRefresh = "oauth.refresh"

    private var access: String?
    private var expiry = Date.distantPast

    var email: String = ""           // rempli par l'état enregistré

    var clientID: String {
        get { BudKeychain.get(kClientID) ?? "" }
        set { BudKeychain.set(newValue, account: kClientID) }
    }
    var clientSecret: String {
        get { BudKeychain.get(kSecret) ?? "" }
        set { BudKeychain.set(newValue, account: kSecret) }
    }
    private var refreshToken: String {
        get { BudKeychain.get(kRefresh) ?? "" }
        set { BudKeychain.set(newValue, account: kRefresh) }
    }

    var isConnected: Bool { !refreshToken.isEmpty && !email.isEmpty }
    var hasClient: Bool { !clientID.isEmpty }

    func store(_ t: GoogleTokens) {
        access = t.access
        expiry = t.expiry
        if !t.refresh.isEmpty { refreshToken = t.refresh }
        if !t.email.isEmpty { email = t.email }
    }

    func disconnect() {
        access = nil
        expiry = .distantPast
        BudKeychain.delete(kRefresh)
        email = ""
    }

    func forgetClient() {
        BudKeychain.delete(kClientID)
        BudKeychain.delete(kSecret)
    }

    /// Jeton d'accès utilisable, rafraîchi si besoin. Appel bloquant court.
    func validAccessToken() -> String? {
        if let a = access, Date() < expiry { return a }
        guard !refreshToken.isEmpty, !clientID.isEmpty else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var token: String?
        GoogleOAuth.refresh(clientID: clientID, clientSecret: clientSecret,
                            refreshToken: refreshToken) { [weak self] a, exp, _ in
            if let a = a, let e = exp {
                self?.access = a
                self?.expiry = e
                token = a
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 25)
        return token
    }

    /// Chaîne XOAUTH2 attendue par IMAP et SMTP.
    func xoauth2() -> String? {
        guard let t = validAccessToken(), !email.isEmpty else { return nil }
        let raw = "user=\(email)\u{01}auth=Bearer \(t)\u{01}\u{01}"
        return Data(raw.utf8).base64EncodedString()
    }
}
