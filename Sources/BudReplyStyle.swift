import Foundation

// ═══════════════════════════════════════════════════════════
//  Apprendre vos tournures
//
//  Il faut être précis sur ce que fait ce fichier, parce qu'il
//  serait facile de laisser croire qu'il écrit à votre place.
//
//  Il ne génère pas de langue. Il lit vos messages déjà
//  envoyés, en extrait les phrases que vous écrivez vraiment,
//  les classe par fonction — attaquer, demander, remercier,
//  conclure — et les ressort par fréquence. Une réponse
//  proposée est donc un assemblage de vos phrases, pas une
//  imitation de votre style par un modèle.
//
//  C'est moins impressionnant et beaucoup plus fiable : une
//  phrase que vous avez écrite trente fois vous ressemble par
//  construction, et aucun calcul ne peut la rendre maladroite.
//
//  Tout est local. Les corps envoyés sont lus par la connexion
//  IMAP que BUD a déjà, résumés en quelques dizaines de lignes
//  de statistiques, et les corps eux-mêmes ne sont pas gardés.
//  Le profil vit dans `style.json`, hors du dépôt.
// ═══════════════════════════════════════════════════════════

struct ReplyStyle: Codable {

    enum Role: String, Codable, CaseIterable {
        case lead      // la phrase qui ouvre le corps
        case ask       // une demande
        case thanks    // un remerciement
        case waiting   // « dans l'attente de votre retour »
        case close     // la dernière phrase avant la signature
    }

    struct Phrase: Codable {
        var text: String
        var count: Int
        var role: Role
    }

    /// Combien de messages envoyés ont été lus pour bâtir ce profil.
    var sampled = 0
    var updatedAt = ""
    /// Vous vouvoyez ou vous tutoyez. Relevé, pas supposé.
    var formal = true
    /// Longueur moyenne de vos corps, en mots. Sert à choisir entre une
    /// réponse de trois lignes et une réponse de dix.
    var bodyWords = 45
    var phrases: [Phrase] = []

    /// Vos phrases pour une fonction donnée, la plus fréquente d'abord.
    func best(_ role: Role, _ rank: Int = 0) -> String? {
        let p = phrases.filter { $0.role == role }.sorted { $0.count > $1.count }
        guard rank < p.count else { return nil }
        return p[rank].text
    }

    var isEmpty: Bool { sampled == 0 }
}

// ═══════════════════════════════════════════════════════════
//  Le classement des phrases
// ═══════════════════════════════════════════════════════════

enum StyleLearner {

    private static let file = budSupportDir.appendingPathComponent("style.json")

    static func load() -> ReplyStyle {
        guard let d = try? Data(contentsOf: file),
              let s = try? JSONDecoder().decode(ReplyStyle.self, from: d) else {
            return ReplyStyle()
        }
        return s
    }

    static func save(_ s: ReplyStyle) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: file, options: .atomic)
    }

    // ─────────────────────────────────────────────────────────
    //  Nettoyer un corps envoyé
    //
    //  Un message envoyé contient presque toujours le message
    //  d'origine en dessous. Le garder apprendrait les phrases
    //  des autres, ce qui est exactement le contraire du but.
    // ─────────────────────────────────────────────────────────

    /// Les marqueurs de citation, dans les formes que produisent les
    /// clients courants en français et en anglais.
    private static let quoteCues = [
        "le ", "on ",                     // « Le 12 mars 2026 à 09:14, X a écrit : »
        "-----message d'origine",
        "-----original message",
        "de :", "from:", "envoyé :", "sent:",
        "début du message transféré",
        "begin forwarded message"
    ]

    private static let closers = ["cordialement", "bien à vous", "salutations",
                                  "respectueusement", "bonne journée", "bonne réception",
                                  "à bientôt", "sincères salutations"]

    /// Retire la salutation et la signature.
    ///
    /// Sans cela, « Bonjour, » se recollait à la phrase suivante — il n'a
    /// pas de ponctuation finale — et le répertoire retenait « Bonjour, Je
    /// fais suite à votre message. » au lieu de la phrase seule. Trois
    /// variantes de salutation donnaient alors trois phrases différentes,
    /// et aucune n'atteignait le seuil d'habitude.
    static func stripCivility(_ input: [String]) -> [String] {
        var lines = input
        while let first = lines.first {
            let t = first.trimmingCharacters(in: .whitespaces)
            let short = t.split(separator: " ").count <= 6
            let isGreeting = short && greetingCues.contains { t.lowercased().hasPrefix($0) }
            if t.isEmpty || isGreeting { lines.removeFirst() } else { break }
        }
        // À partir de la formule de clôture, plus rien n'est rédigé : ni la
        // formule, ni le nom qui la suit, ni la signature complète.
        for (i, l) in lines.enumerated() {
            let low = l.trimmingCharacters(in: .whitespaces).lowercased()
            if closers.contains(where: { low.hasPrefix($0) }) {
                lines = Array(lines[0..<i])
                break
            }
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines
    }

    static func ownText(in body: String) -> String {
        var kept: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { break }
            let low = line.lowercased()
            // « Le … a écrit : » n'est une citation que si la ligne le dit
            // en entier : une phrase qui commence par « Le » ne l'est pas.
            if low.hasSuffix("a écrit :") || low.hasSuffix("a écrit:")
                || low.hasSuffix("wrote:") { break }
            if quoteCues.contains(where: { low.hasPrefix($0) && low.contains("@") }) { break }
            if low.hasPrefix("-----") { break }
            // Une signature coupe aussi : ce qui suit n'est pas rédigé.
            if line == "--" || line == "-- " { break }
            kept.append(raw)
        }
        return stripCivility(kept).joined(separator: "\n")
    }

    /// Découpe en phrases. Le point d'une abréviation ne doit pas couper :
    /// on exige donc une majuscule ou une fin de texte après le point.
    static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text.replacingOccurrences(of: "\n", with: " "))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            cur.append(c)
            if c == "." || c == "!" || c == "?" {
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                let atEnd = j >= chars.count
                let nextIsUpper = !atEnd && (chars[j].isUppercase || chars[j].isNumber)
                if atEnd || nextIsUpper {
                    let s = cur.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { out.append(s) }
                    cur = ""
                }
            }
            i += 1
        }
        let s = cur.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { out.append(s) }
        return out
    }

    private static let askCues = ["pourriez-vous", "pouvez-vous", "serait-il possible",
                                  "je souhaiterais", "j'aimerais", "auriez-vous",
                                  "je vous prie de", "merci de bien vouloir"]
    private static let thanksCues = ["merci", "je vous remercie", "remerciements"]
    private static let waitCues = ["dans l'attente", "je reste", "je demeure",
                                   "n'hésitez pas", "je me tiens", "à votre disposition"]
    private static let greetingCues = ["bonjour", "bonsoir", "madame", "monsieur", "cher",
                                       "chère", "cordialement", "salutations", "bien à vous",
                                       "respectueusement"]

    /// Les salutations et les signatures ne s'apprennent pas : elles sont
    /// imposées par ailleurs, et les compter encombrerait le répertoire
    /// sans rien apporter.
    private static func isCivility(_ low: String) -> Bool {
        let words = low.split(separator: " ").count
        guard words <= 6 else { return false }
        return greetingCues.contains { low.hasPrefix($0) }
    }

    static func role(of sentence: String, isFirst: Bool, isLast: Bool) -> ReplyStyle.Role? {
        let low = sentence.lowercased()
        if isCivility(low) { return nil }
        // Une phrase trop courte ou trop longue n'est pas réutilisable :
        // en dessous de trois mots elle ne dit rien, au-delà de quarante
        // elle est trop liée à son contexte pour resservir.
        let words = sentence.split(separator: " ").count
        guard words >= 3, words <= 40 else { return nil }

        if waitCues.contains(where: { low.contains($0) }) { return .waiting }
        if askCues.contains(where: { low.contains($0) }) { return .ask }
        if thanksCues.contains(where: { low.contains($0) }) { return .thanks }
        if isFirst { return .lead }
        if isLast { return .close }
        return nil
    }

    /// Construit le profil depuis une liste de corps envoyés.
    ///
    /// Fonction pure : pas de réseau, pas de fichier. C'est ce qui permet
    /// de la rejouer sur des exemples et de vérifier son verdict.
    static func profile(from bodies: [String]) -> ReplyStyle {
        var s = ReplyStyle()
        var counts: [String: (count: Int, role: ReplyStyle.Role)] = [:]
        var totalWords = 0
        var bodiesKept = 0
        var tu = 0, vous = 0

        for body in bodies {
            let own = ownText(in: body)
            let sents = sentences(in: own).filter { !$0.isEmpty }
            guard !sents.isEmpty else { continue }
            bodiesKept += 1
            totalWords += own.split(separator: " ").count

            let low = own.lowercased()
            // Le vouvoiement se compte sur des formes sans ambiguïté :
            // « tu » isolé, « vous » isolé. « votre » appartient aux deux
            // registres dans une formule de politesse.
            for w in low.split(whereSeparator: { !$0.isLetter }) {
                if w == "tu" || w == "toi" || w == "ton" || w == "ta" { tu += 1 }
                if w == "vous" || w == "votre" || w == "vos" { vous += 1 }
            }

            for (i, sent) in sents.enumerated() {
                guard let r = role(of: sent, isFirst: i == 0, isLast: i == sents.count - 1)
                else { continue }
                let key = canonical(sent)
                if let old = counts[key] { counts[key] = (old.count + 1, old.role) }
                else { counts[key] = (1, r) }
            }
        }

        s.sampled = bodiesKept
        s.formal = vous >= tu
        s.bodyWords = bodiesKept > 0 ? max(12, totalWords / bodiesKept) : 45
        s.updatedAt = shortDateString()

        // On garde les trois meilleures par fonction : au-delà, ce sont
        // des phrases vues une seule fois, qui ne disent rien d'une
        // habitude.
        var kept: [ReplyStyle.Phrase] = []
        for r in ReplyStyle.Role.allCases {
            let pool = counts.filter { $0.value.role == r }
                .map { ReplyStyle.Phrase(text: $0.key, count: $0.value.count, role: r) }
                .sorted { ($0.count, $1.text.count) > ($1.count, $0.text.count) }
            kept.append(contentsOf: pool.prefix(3))
        }
        s.phrases = kept
        return s
    }

    /// Verse une réponse que vous venez d'envoyer au profil.
    ///
    /// Le profil complet se refait depuis le serveur, mais attendre ce
    /// relevé-là voudrait dire qu'une tournure adoptée aujourd'hui ne
    /// compte que demain. Un message envoyé est un exemple immédiat.
    static func absorbOne(_ body: String) {
        var s = load()
        let own = ownText(in: body)
        let sents = sentences(in: own).filter { !$0.isEmpty }
        guard !sents.isEmpty else { return }

        for (i, sent) in sents.enumerated() {
            guard let r = role(of: sent, isFirst: i == 0, isLast: i == sents.count - 1)
            else { continue }
            let key = canonical(sent)
            if let idx = s.phrases.firstIndex(where: { $0.text == key && $0.role == r }) {
                s.phrases[idx].count += 1
            } else {
                s.phrases.append(ReplyStyle.Phrase(text: key, count: 1, role: r))
            }
        }

        // Le même plafond qu'au relevé complet : trois par fonction. Sans
        // lui, le fichier grossirait d'une phrase à chaque envoi, et les
        // phrases vues une fois noieraient les habitudes.
        var kept: [ReplyStyle.Phrase] = []
        for r in ReplyStyle.Role.allCases {
            let pool = s.phrases.filter { $0.role == r }.sorted { $0.count > $1.count }
            kept.append(contentsOf: pool.prefix(3))
        }
        s.phrases = kept
        s.sampled += 1
        s.updatedAt = shortDateString()
        save(s)
    }

    /// Relit le dossier des envois et refait le profil. Hors fil principal :
    /// quarante corps à rapatrier prennent plusieurs secondes.
    static func relearn(_ done: @escaping (ReplyStyle) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let bodies = MailRouter.sentBodies()
            let s = bodies.isEmpty ? load() : profile(from: bodies)
            if !bodies.isEmpty { save(s) }
            DispatchQueue.main.async { done(s) }
        }
    }

    /// Deux phrases identiques à un espace ou une majuscule près sont la
    /// même phrase : sans cela, chaque variante compterait pour une et
    /// aucune n'atteindrait le seuil d'habitude.
    static func canonical(_ s: String) -> String {
        let collapsed = s.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// ═══════════════════════════════════════════════════════════
//  Ce que le message reçu demande
//
//  Même détection que le sous-agent `mail-actions`, et pour la
//  même raison : les en-têtes et les tournures explicites, pas
//  les mots-clés d'un objet, qu'un expéditeur choisit.
// ═══════════════════════════════════════════════════════════

enum MailAsk: String {
    case payment       // une facture, une échéance de paiement
    case confirm       // une confirmation attendue
    case question      // une question posée
    case appointment   // un rendez-vous à fixer ou à confirmer
    case document      // une pièce demandée
    case plain         // rien de précis : un accusé de réception suffit

    var label: String {
        switch self {
        case .payment:     return "Facture ou paiement"
        case .confirm:     return "Confirmation attendue"
        case .question:    return "Question posée"
        case .appointment: return "Rendez-vous"
        case .document:    return "Pièce demandée"
        case .plain:       return "Accusé de réception"
        }
    }
}

enum MailReader {

    /// Ce que le message attend de vous.
    ///
    /// L'ordre des tests est l'ordre des conséquences : une facture se
    /// traite avant une question, parce que s'y tromper coûte plus cher.
    static func ask(subject: String, body: String) -> MailAsk {
        let t = fold(subject + " " + body)

        if contains(t, ["facture", "echeance", "reglement", "prelevement", "impaye",
                        "montant du", "a payer", "paiement"]) { return .payment }
        if contains(t, ["rendez vous", "rdv", "creneau", "disponibilite",
                        "vous recevoir", "entretien"]) { return .appointment }
        if contains(t, ["merci de confirmer", "veuillez confirmer", "confirmez",
                        "accuser reception", "votre accord", "valider"]) { return .confirm }
        if contains(t, ["piece jointe manquante", "nous transmettre", "merci de nous envoyer",
                        "justificatif", "attestation", "merci de fournir"]) { return .document }
        if contains(t, ["pourriez vous", "pouvez vous", "quelle est", "quel est",
                        "comment", "serait il possible", "?"]) { return .question }
        return .plain
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    /// Minuscules, sans accents, espaces réduits — mais le point
    /// d'interrogation reste : c'est lui qui signale une question, et la
    /// normalisation générale de la voix l'effacerait.
    static func fold(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: Locale(identifier: "fr_FR"))
        let kept = folded.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "?") ? ch : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}

// ═══════════════════════════════════════════════════════════
//  La rédaction
//
//  Deux règles imposées, qui ne se discutent pas : l'ouverture
//  est « Bonjour, Monsieur ou Madame, » et la clôture
//  « Cordialement, merci. ». Elles encadrent le corps, et le
//  corps seul est touché par le style appris.
// ═══════════════════════════════════════════════════════════

enum ReplyWriter {

    static let opening = "Bonjour, Monsieur ou Madame,"
    static let closing = "Cordialement, merci."
    /// L'endroit où BUD ne peut pas écrire à votre place. Le tiroir le
    /// sélectionne à l'ouverture : il suffit de taper par-dessus.
    static let placeholder = "(votre réponse ici)"

    struct Draft {
        var label: String        // le nom du bouton qui le choisit
        var text: String
    }

    /// Trois propositions pour un même message : l'une accuse réception,
    /// l'une répond sur le fond, l'une demande un délai. On ne devine pas
    /// laquelle vous voulez — vous choisissez.
    static func drafts(for m: MailMessage, body: String, style: ReplyStyle) -> [Draft] {
        let ask = MailReader.ask(subject: m.subject, body: body)
        let who = MailGuard.displayName(in: m.sender)
        let about = subjectPhrase(m.subject)

        var out: [Draft] = []
        out.append(Draft(label: "Accusé de réception",
                         text: assemble(core: acknowledge(ask, about: about), style: style)))
        out.append(Draft(label: "Réponse sur le fond",
                         text: assemble(core: substantive(ask, about: about, who: who,
                                                          style: style),
                                        style: style)))
        out.append(Draft(label: "Demande de délai",
                         text: assemble(core: delay(ask, about: about), style: style)))
        return out
    }

    /// Le corps, encadré par l'ouverture et la clôture imposées, et
    /// terminé par une de vos phrases d'attente quand BUD en connaît une.
    static func assemble(core: [String], style: ReplyStyle) -> String {
        var lines = [opening, ""]
        lines.append(contentsOf: core)

        // Votre tournure d'attente, si elle a été relevée. Sinon rien :
        // mieux vaut une réponse courte qu'une phrase qui n'est pas la
        // vôtre ajoutée pour faire nombre.
        if let w = style.best(.waiting) {
            lines.append("")
            lines.append(w)
        }
        lines.append("")
        lines.append(closing)
        return lines.joined(separator: "\n")
    }

    /// L'objet transformé en complément utilisable dans une phrase.
    /// « Re: Facture novembre » devient « votre message au sujet de
    /// « Facture novembre » ».
    static func subjectPhrase(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        // Les préfixes de réponse et de transfert s'empilent : on les
        // retire tous, pas seulement le premier.
        var cut = true
        while cut {
            cut = false
            for p in ["re :", "re:", "ref :", "ref:", "rép :", "rep:", "tr :", "tr:",
                      "fwd :", "fwd:", "fw :", "fw:"] {
                if s.lowercased().hasPrefix(p) {
                    s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                    cut = true
                }
            }
        }
        return s.isEmpty ? "votre message" : "votre message au sujet de « \(s) »"
    }

    private static func acknowledge(_ ask: MailAsk, about: String) -> [String] {
        switch ask {
        case .payment:
            return ["J'ai bien reçu \(about) et j'en prends connaissance.",
                    "Je reviens vers vous dès que j'ai procédé aux vérifications nécessaires."]
        case .appointment:
            return ["J'ai bien reçu \(about).",
                    "Je vous confirme ma disponibilité et reste à votre écoute pour arrêter un créneau."]
        case .confirm:
            return ["J'ai bien reçu \(about) et je vous en confirme la bonne réception."]
        case .document:
            return ["J'ai bien reçu \(about).",
                    "Je vous fais parvenir les éléments demandés dans les meilleurs délais."]
        case .question, .plain:
            return ["J'ai bien reçu \(about) et je vous en remercie.",
                    "Je reviens vers vous rapidement."]
        }
    }

    /// Votre phrase d'attaque, quand BUD en connaît une, avec l'objet du
    /// message greffé dedans.
    ///
    /// C'est là que l'apprentissage sert vraiment. Si vous écrivez
    /// systématiquement « Je fais suite à votre message. », la réponse
    /// proposée commence par cette phrase-là — la vôtre — et non par une
    /// formule que BUD aurait choisie. L'objet s'y glisse à la place de
    /// « votre message », ce qui donne « Je fais suite à votre message au
    /// sujet de « Facture novembre ». »
    static func lead(_ style: ReplyStyle, about: String) -> String {
        guard let own = style.best(.lead) else { return "Je fais suite à \(about)." }
        guard about != "votre message",
              let r = own.range(of: "votre message") else { return own }
        return own.replacingCharacters(in: r, with: about)
    }

    private static func substantive(_ ask: MailAsk, about: String, who: String,
                                    style: ReplyStyle) -> [String] {
        let party = who.isEmpty ? "" : " auprès de \(who)"
        let opener = lead(style, about: about)
        switch ask {
        case .payment:
            return [opener,
                    "Après vérification, le règlement sera effectué dans les délais indiqués.",
                    "Si un élément manque à mon dossier\(party), merci de me le préciser."]
        case .appointment:
            return [opener,
                    "Le créneau proposé me convient. À défaut, je suis disponible en fin de journée."]
        case .confirm:
            return [opener,
                    "Je vous confirme mon accord sur les éléments que vous m'avez transmis."]
        case .document:
            return [opener,
                    "Vous trouverez les pièces demandées en réponse à ce message."]
        case .question:
            return [opener,
                    "Voici les éléments de réponse :",
                    placeholder]
        case .plain:
            return [opener,
                    placeholder]
        }
    }

    private static func delay(_ ask: MailAsk, about: String) -> [String] {
        let what: String
        switch ask {
        case .payment:   what = "le règlement"
        case .document:  what = "la transmission des pièces"
        case .confirm:   what = "ma confirmation"
        default:         what = "ma réponse complète"
        }
        return ["J'ai bien reçu \(about).",
                "Pourriez-vous m'accorder un délai supplémentaire pour \(what) ?",
                "Je reviens vers vous au plus tard la semaine prochaine."]
    }
}
