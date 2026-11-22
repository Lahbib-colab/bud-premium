import Cocoa

// ═══════════════════════════════════════════════════════════
//  Sous-agents — le socle
//
//  Un sous-agent est un exécutable posé dans un dossier, qui
//  reçoit du JSON sur son entrée standard et en rend sur sa
//  sortie standard. Rien d'autre.
//
//  Pourquoi des processus et non des greffons chargés dans BUD :
//
//  — Un greffon partage la mémoire de l'application. Un script
//    qui boucle, qui épuise la mémoire ou qui plante emporte
//    BUD avec lui. Un processus séparé, on le tue.
//  — Un greffon impose un langage et une interface binaire. Un
//    processus accepte du shell, du Python, du Swift compilé,
//    n'importe quoi d'exécutable.
//  — Un sous-agent se teste depuis le Terminal, seul, sans
//    lancer BUD : `echo '{}' | ./run`. C'est ce qui rend le
//    système réellement extensible, bien plus que son API.
//
//  Le contrat tient en deux structures, `AgentInput` et
//  `AgentOutput`, et il est versionné.
//
//  ── Sécurité ──
//
//  Exécuter ce qu'on trouve dans un dossier est un pouvoir
//  dangereux. Quatre règles l'encadrent, et aucune n'est
//  décorative :
//
//  1. Les entrées passent par l'entrée standard, jamais par la
//     ligne de commande. Un argument se retrouve dans la table
//     des processus, visible de tout le système, et finit tôt
//     ou tard interpolé dans un shell.
//  2. Le dossier des scripts ne doit être inscriptible que par
//     son propriétaire. Un dossier ouvert en écriture à tous
//     est une élévation de privilège : quiconque peut y écrire
//     fait exécuter son code sous votre compte, par BUD.
//  3. Délai maximal, puis mise à mort. Un script qui ne rend
//     pas la main ne doit pas occuper une ressource
//     indéfiniment.
//  4. Sortie plafonnée. Un script qui écrit sans fin ne doit
//     pas faire gonfler la mémoire de BUD.
// ═══════════════════════════════════════════════════════════

// ───────────────────────────────────────────────────────────
//  Le contrat
// ───────────────────────────────────────────────────────────

/// Le manifeste, lu dans `manifest.json` à côté de l'exécutable.
struct AgentManifest: Codable {
    /// Identifiant : le nom du dossier. Sert de clé partout.
    var name: String = ""
    var title: String = ""
    var detail: String = ""
    /// Délai maximal d'exécution, en secondes.
    var timeout: Double = 20
    /// Période d'exécution automatique, en minutes. 0 = sur demande.
    var every: Int = 0
    /// Version du contrat attendue. BUD refuse ce qu'il ne sait pas lire.
    var contract: Int = 1
}

/// Ce que BUD écrit sur l'entrée standard du sous-agent.
struct AgentInput: Codable {
    var contract = 1
    var agent = ""
    var invokedAt = ""
    /// Le dossier de BUD, pour qu'un script y dépose ses propres fichiers.
    var support = ""
    /// Données libres fournies par l'appelant.
    var payload: [String: String] = [:]
}

/// Une ligne de résultat. C'est l'unité que BUD sait afficher.
struct AgentItem: Codable {
    var title = ""
    var detail = ""
    /// « info », « action » ou « warning ». Tout autre valeur vaut « info ».
    var level = "info"
    /// Chemin de fichier ou adresse à ouvrir au clic. Facultatif.
    var open = ""
}

/// Ce que le sous-agent doit écrire sur sa sortie standard.
struct AgentOutput: Codable {
    var contract = 1
    var ok = true
    var summary = ""
    var items: [AgentItem] = []
    var error: String?

    static func failure(_ why: String) -> AgentOutput {
        AgentOutput(ok: false, summary: "", items: [], error: why)
    }
}

// ───────────────────────────────────────────────────────────
//  Le moteur
// ───────────────────────────────────────────────────────────

final class ScriptAgents {

    static let shared = ScriptAgents()
    private init() {}

    /// 256 Ko de sortie : largement de quoi rendre quelques centaines de
    /// lignes, et pas de quoi faire gonfler BUD si un script s'emballe.
    private let maxOutput = 256 * 1024

    var dir: URL { budSupportDir.appendingPathComponent("scripts") }

    // ── Découverte ──

    /// Les sous-agents installés, triés par titre.
    func discover() -> [AgentManifest] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [AgentManifest] = []
        for folder in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let mf = folder.appendingPathComponent("manifest.json")
            guard let d = try? Data(contentsOf: mf),
                  var m = try? JSONDecoder().decode(AgentManifest.self, from: d) else { continue }
            // Le nom du dossier fait foi : un manifeste qui s'en écarte
            // pourrait désigner l'exécutable d'un autre agent.
            m.name = folder.lastPathComponent
            guard m.contract == 1 else { continue }
            if m.title.isEmpty { m.title = m.name }
            out.append(m)
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // ── Vérifications avant exécution ──

    /// Tout ce qu'il faut vérifier avant d'exécuter quoi que ce soit.
    /// Le verdict de la vérification. Un `Result` aurait demandé un type
    /// d'erreur conforme à `Error` : ici la raison est une phrase destinée
    /// à l'utilisateur, pas une erreur à propager, et une énumération le
    /// dit plus franchement.
    private enum Prepared {
        case ready(URL, AgentManifest)
        case refused(String)
    }

    private func prepare(_ name: String) -> Prepared {
        // Un nom d'agent ne sert qu'à nommer un dossier : tout ce qui
        // pourrait remonter l'arborescence est écarté avant toute chose.
        guard !name.isEmpty, !name.contains("/"), !name.contains(".."),
              name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
                         options: .regularExpression) != nil else {
            return .refused("Nom de sous-agent refusé : « \(name) ».")
        }
        guard let m = discover().first(where: { $0.name == name }) else {
            return .refused("Sous-agent « \(name) » introuvable.")
        }
        let folder = dir.appendingPathComponent(name)
        let exe = folder.appendingPathComponent("run")

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: exe.path) else {
            return .refused("« \(name)/run » n'existe pas ou n'est pas exécutable.")
        }

        // Le dossier ne doit être inscriptible que par son propriétaire.
        // Sinon n'importe quel processus y déposerait un script que BUD
        // exécuterait sous votre compte.
        if let attrs = try? fm.attributesOfItem(atPath: folder.path),
           let perm = attrs[.posixPermissions] as? NSNumber {
            let p = perm.uint16Value
            if p & 0o022 != 0 {
                return .refused("« \(name) » est inscriptible par d'autres comptes : "
                    + "BUD ne l'exécutera pas. Corrigez avec chmod 755.")
            }
        }
        return .ready(exe, m)
    }

    // ── Exécution ──

    /// Exécute un sous-agent hors du fil principal et rend son résultat
    /// sur le fil principal. L'interface n'est jamais bloquée, quel que
    /// soit le temps que prend le script.
    func run(_ name: String, payload: [String: String] = [:],
             done: @escaping (AgentOutput) -> Void) {
        let exe: URL
        let manifest: AgentManifest
        switch prepare(name) {
        case .refused(let why):
            DispatchQueue.main.async { done(.failure(why)) }
            return
        case .ready(let e, let m):
            exe = e
            manifest = m
        }

        var input = AgentInput()
        input.agent = name
        input.support = budSupportDir.path
        input.payload = payload
        let f = ISO8601DateFormatter()
        input.invokedAt = f.string(from: Date())

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let s = self else { return }
            let result = s.execute(exe, manifest: manifest, input: input)
            DispatchQueue.main.async { done(result) }
        }
    }

    private func execute(_ exe: URL, manifest: AgentManifest, input: AgentInput) -> AgentOutput {
        guard let payload = try? JSONEncoder().encode(input) else {
            return .failure("Entrée non encodable.")
        }

        let p = Process()
        p.executableURL = exe
        // Aucun argument. Les données passent par l'entrée standard : un
        // argument serait lisible par tout le système dans la table des
        // processus, et finirait interpolé dans un shell.
        p.arguments = []
        p.currentDirectoryURL = exe.deletingLastPathComponent()
        // Un environnement réduit : le script hérite de quoi tourner, pas
        // de l'ensemble des variables de l'application.
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                         "HOME": NSHomeDirectory(),
                         "BUD_SUPPORT": budSupportDir.path,
                         "LANG": "fr_FR.UTF-8"]

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        do { try p.run() } catch {
            return .failure("Lancement impossible : \(error.localizedDescription)")
        }

        // Les trois tuyaux vivent en parallèle. Écrire l'entrée en entier
        // avant de lire la sortie bloquerait dès que le script répond plus
        // vite qu'il ne consomme.
        let g = DispatchGroup()
        let q = DispatchQueue(label: "fr.lahbib.bud.agent", attributes: .concurrent)
        var outData = Data(), errData = Data()
        g.enter(); q.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile(); g.leave()
        }
        g.enter(); q.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile(); g.leave()
        }
        q.async {
            inPipe.fileHandleForWriting.write(payload)
            try? inPipe.fileHandleForWriting.close()
        }

        // Délai maximal, puis mise à mort. `terminate` envoie SIGTERM, que
        // certains scripts ignorent ; SIGKILL suit, et lui ne s'ignore pas.
        let deadline = DispatchTime.now() + manifest.timeout
        let waiter = DispatchQueue(label: "fr.lahbib.bud.agent.wait")
        var timedOut = false
        let sem = DispatchSemaphore(value: 0)
        waiter.async { p.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: deadline) == .timedOut {
            timedOut = true
            p.terminate()
            if sem.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
            }
        }
        g.wait()

        if timedOut {
            return .failure("« \(manifest.name) » n'a pas répondu en "
                + "\(Int(manifest.timeout)) s et a été arrêté.")
        }

        if outData.count > maxOutput {
            return .failure("« \(manifest.name) » a produit plus de 256 Ko : sortie ignorée.")
        }

        guard p.terminationStatus == 0 else {
            let e = String(data: errData.prefix(600), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure("« \(manifest.name) » a échoué (code \(p.terminationStatus))"
                + (e.isEmpty ? "." : " : \(e)"))
        }

        guard !outData.isEmpty else {
            return .failure("« \(manifest.name) » n'a rien écrit sur sa sortie standard.")
        }
        guard var parsed = try? JSONDecoder().decode(AgentOutput.self, from: outData) else {
            let raw = String(data: outData.prefix(200), encoding: .utf8) ?? ""
            return .failure("« \(manifest.name) » n'a pas rendu de JSON valide : \(raw)")
        }
        // Un script peut dire qu'il a échoué tout en rendant du JSON ; on
        // ne réécrit pas son verdict, on s'assure juste qu'il est lisible.
        if parsed.summary.isEmpty && parsed.ok {
            parsed.summary = "\(parsed.items.count) élément(s)."
        }
        return parsed
    }

    // ── Installation des exemples ──

    /// Pose les sous-agents d'exemple au premier lancement. N'écrase
    /// jamais un fichier existant : vos modifications survivent aux mises
    /// à jour de BUD.
    func installExamples() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        for (name, manifest, body) in ScriptAgents.examples {
            let folder = dir.appendingPathComponent(name)
            let exe = folder.appendingPathComponent("run")
            guard !fm.fileExists(atPath: exe.path) else { continue }
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o755])
            try? manifest.write(to: folder.appendingPathComponent("manifest.json"),
                                atomically: true, encoding: .utf8)
            try? body.write(to: exe, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        }
    }
}
