import Cocoa

// ═══════════════════════════════════════════════════════════
//  Synchronisation du courrier
//
//  Le défaut auquel ce fichier répond : ouvrir l'onglet Courrier
//  lançait un relevé complet et affichait une liste vide en
//  attendant. Session TLS, authentification, recherche, soixante
//  en-têtes, douze corps — plusieurs secondes de page blanche, à
//  chaque ouverture, pour des messages qui n'avaient pas changé
//  depuis la précédente.
//
//  Trois mesures, dans cet ordre d'importance :
//
//  1. Un cache sur disque. La boîte s'affiche instantanément avec
//     ce qu'on savait d'elle, puis se met à jour si besoin. On ne
//     regarde plus jamais une liste vide.
//
//  2. Un sondage qui coûte un aller-retour. `STATUS INBOX
//     (UIDNEXT UNSEEN)` dit si quelque chose a bougé sans
//     rapatrier un seul message. Le relevé complet n'a lieu que
//     si la réponse a changé.
//
//  3. Un relevé de fond, à intervalle régulier et hors du fil
//     principal. L'utilisateur n'a plus à cliquer « Actualiser »
//     pour voir arriver son courrier.
//
//  Ce que ce fichier ne prétend pas être : du push. IMAP IDLE
//  demanderait de tenir une connexion ouverte en permanence, de
//  la rouvrir à chaque réveil de veille et de gérer son
//  expiration toutes les vingt-neuf minutes. C'est faisable, ce
//  n'est pas fait ici, et le sondage intelligent en donne
//  l'essentiel pour une fraction du risque.
// ═══════════════════════════════════════════════════════════

final class MailSync {

    static let shared = MailSync()

    /// Ce qu'on garde d'un relevé, sur disque entre deux lancements.
    struct Cached: Codable {
        var savedAt: TimeInterval = 0
        /// L'adresse du compte au moment de l'enregistrement. Changer de
        /// compte doit vider la boîte affichée : montrer le courrier du
        /// compte précédent serait une fuite, pas un cache.
        var account: String = ""
        var unread: Int = 0
        var source: String = ""
        var uidNext: String = ""
        var messages: [MailMessage] = []
    }

    private(set) var cached = Cached()
    private var loaded = false
    private var syncing = false
    private var timer: Timer?

    /// Appelé sur le fil principal quand la boîte a changé.
    var onUpdate: ((Cached) -> Void)?

    private var url: URL { budSupportDir.appendingPathComponent("inbox-cache.json") }

    private init() {}

    // ─────────────────────────────────────────────────────────
    //  Le cache
    // ─────────────────────────────────────────────────────────

    /// Rend ce qu'on sait de la boîte, tout de suite. Le fichier n'est lu
    /// qu'une fois par session : les ouvertures suivantes sont servies
    /// depuis la mémoire.
    @discardableResult
    func warmUp() -> Cached {
        guard !loaded else { return cached }
        loaded = true
        if let d = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(Cached.self, from: d) {
            // Un cache qui n'est pas celui du compte relié ne vaut rien.
            if c.account == MailRouter.activeAddress { cached = c }
        }
        return cached
    }

    private func persist() {
        let e = JSONEncoder()
        guard let d = try? e.encode(cached) else { return }
        try? d.write(to: url, options: .atomic)
    }

    /// Efface le cache. À appeler quand on change de compte.
    func forget() {
        cached = Cached()
        loaded = true
        try? FileManager.default.removeItem(at: url)
    }

    // ─────────────────────────────────────────────────────────
    //  La synchronisation
    // ─────────────────────────────────────────────────────────

    /// Met la boîte à jour hors du fil principal.
    ///
    /// `force` saute le sondage et fait le relevé complet : c'est ce que
    /// demande le bouton « Actualiser », qui doit aussi voir ce que le
    /// sondage ne détecte pas — une suppression faite ailleurs, par exemple.
    func sync(force: Bool = false, done: ((Cached, String?) -> Void)? = nil) {
        guard !syncing else { done?(cached, nil); return }
        syncing = true
        let account = MailRouter.activeAddress

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let s = self else { return }

            // Étape 1 : sonder, sauf si l'on nous demande de ne pas le faire.
            if !force, !s.cached.messages.isEmpty, s.cached.account == account,
               let (next, unseen) = MailRouter.status(),
               next == s.cached.uidNext, unseen == s.cached.unread {
                DispatchQueue.main.async {
                    s.syncing = false
                    done?(s.cached, nil)          // rien de neuf, rien à redessiner
                }
                return
            }

            // Étape 2 : le relevé complet, puisqu'il a lieu d'être.
            let snap = MailRouter.snapshot(60)
            DispatchQueue.main.async {
                s.syncing = false
                guard snap.error == nil, snap.unread >= 0 || !snap.msgs.isEmpty else {
                    done?(s.cached, snap.error)
                    return
                }
                var c = Cached()
                c.savedAt = Date().timeIntervalSince1970
                c.account = account
                c.unread = max(0, snap.unread)
                c.source = snap.source
                c.uidNext = snap.uidNext
                c.messages = snap.msgs
                s.cached = c
                s.loaded = true
                s.persist()
                done?(c, nil)
                s.onUpdate?(c)
            }
        }
    }

    /// Démarre le sondage de fond.
    ///
    /// Quatre-vingt-dix secondes : assez rapproché pour qu'un message
    /// arrive de lui-même pendant qu'on travaille, assez espacé pour que
    /// le coût reste un aller-retour par minute et demie. Le minuteur
    /// tolère un décalage, pour se grouper avec les autres réveils du
    /// système plutôt que d'en provoquer un pour lui seul.
    func startPolling() {
        timer?.invalidate()
        let t = Timer(timeInterval: 90, repeats: true) { [weak self] _ in
            guard MailRouter.gmailReady else { return }
            self?.sync()
        }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
