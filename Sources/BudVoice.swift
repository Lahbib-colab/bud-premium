import Cocoa
import Speech
import AVFoundation

// ═══════════════════════════════════════════════════════════
//  Dictée — reconnaissance vocale, sur l'appareil seulement
//
//  Le reste de BUD ne fait rien sortir de la machine : l'analyse
//  de hameçonnage est locale, la conversation est locale, les
//  jetons restent dans le trousseau. La dictée ne fera pas
//  exception.
//
//  Or `SFSpeechRecognizer` envoie l'audio aux serveurs d'Apple
//  par défaut. `requiresOnDeviceRecognition` l'en empêche, mais
//  la documentation est explicite : « The request only honors
//  this setting if supportsOnDeviceRecognition is also true. »
//  Autrement dit, poser le drapeau sans vérifier ne garantit
//  rien du tout.
//
//  Donc : si ce Mac ne sait pas reconnaître le français hors
//  ligne, BUD refuse la dictée et dit pourquoi. Pas de repli
//  silencieux sur le réseau.
//
//  Deux modes partagent le même moteur audio, et un seul à la
//  fois. On ne peut pas poser deux prises sur la même entrée :
//  armer le mot d'activation pendant une dictée, ou l'inverse,
//  ferait tomber l'application. L'un cède donc la place à
//  l'autre, et le mot d'activation se réarme tout seul après.
// ═══════════════════════════════════════════════════════════

final class BudVoice {

    static let shared = BudVoice()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr_FR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hardStop: Timer?
    private var silence: Timer?
    private var lastText = ""

    private enum Mode { case idle, dictation, wake }
    private var mode: Mode = .idle

    /// Vrai pendant une dictée demandée par le bouton micro. L'écoute du
    /// mot d'activation ne compte pas : elle n'est pas une dictée, et le
    /// bouton ne doit pas pulser en permanence.
    var listening: Bool { mode == .dictation }

    /// Vrai quand BUD guette « Hey Bud ».
    private(set) var wakeArmed = false

    /// Texte en cours de reconnaissance, à chaque mot.
    var onPartial: ((String) -> Void)?
    /// Texte retenu quand l'utilisateur s'arrête de parler.
    var onFinal: ((String) -> Void)?
    /// Une phrase à montrer : refus, autorisation manquante, panne.
    var onTrouble: ((String) -> Void)?
    /// Changement d'état, pour que le bouton suive.
    var onState: (() -> Void)?

    /// Le mot d'activation vient d'être entendu : BUD se déverrouille et
    /// attend la suite. Sert à montrer qu'on écoute avant de comprendre.
    var onWake: (() -> Void)?
    /// La phrase prononcée après le mot d'activation, une fois terminée.
    var onWakeCommand: ((String) -> Void)?

    private init() {}

    // ─────────────────────────────────────────────────────────
    //  Disponibilité
    // ─────────────────────────────────────────────────────────

    /// `nil` si la dictée est possible, sinon la raison, en clair.
    func unavailableReason() -> String? {
        guard let r = recognizer else {
            return "La reconnaissance du français n'est pas installée sur ce Mac."
        }
        guard r.supportsOnDeviceRecognition else {
            return "Ce Mac ne sait pas reconnaître la parole sans l'envoyer aux serveurs d'Apple. "
                + "BUD ne fera pas sortir votre voix de la machine, donc la dictée reste fermée. "
                + "Pour l'activer : Réglages Système → Clavier → Dictée, et téléchargez le français."
        }
        guard r.isAvailable else {
            return "La reconnaissance vocale est momentanément indisponible."
        }
        return nil
    }

    // ─────────────────────────────────────────────────────────
    //  Marche et arrêt
    // ─────────────────────────────────────────────────────────

    func toggle() { listening ? stop(final: true) : start() }

    func start() { begin(.dictation) }

    private func begin(_ want: Mode) {
        guard mode != want else { return }
        if let why = unavailableReason() { onTrouble?(why); return }

        // Deux autorisations distinctes, et deux refus distincts : la
        // reconnaissance vocale et le microphone sont deux réglages de
        // confidentialité séparés, qu'on peut accorder l'un sans l'autre.
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let s = self else { return }
                switch status {
                case .authorized:
                    s.askMicrophone(want)
                case .denied, .restricted:
                    s.onTrouble?("La reconnaissance vocale est refusée pour BUD. "
                        + "Réglages Système → Confidentialité et sécurité → Reconnaissance vocale.")
                case .notDetermined:
                    s.onTrouble?("Autorisation de reconnaissance vocale non accordée.")
                @unknown default:
                    s.onTrouble?("Autorisation de reconnaissance vocale indéterminée.")
                }
            }
        }
    }

    private func askMicrophone(_ want: Mode) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginListening(want)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                DispatchQueue.main.async {
                    guard let s = self else { return }
                    if ok { s.beginListening(want) }
                    else { s.onTrouble?("Sans microphone, BUD ne peut pas vous entendre.") }
                }
            }
        default:
            onTrouble?("Le microphone est refusé pour BUD. "
                + "Réglages Système → Confidentialité et sécurité → Microphone.")
        }
    }

    private func beginListening(_ want: Mode) {
        guard let recognizer = recognizer else { return }
        // Le moteur est unique : on démonte proprement avant de remonter.
        teardown()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Le drapeau qui compte. `unavailableReason()` a déjà vérifié que
        // ce Mac l'honore : sans cette vérification, le poser ne serait
        // qu'une intention.
        req.requiresOnDeviceRecognition = true
        request = req

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        // Sans entrée audio valable, `installTap` lève une exception
        // Objective-C, que Swift ne sait pas rattraper : l'application
        // s'arrêterait net. On regarde donc avant de poser la prise.
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else {
            onTrouble?("Aucune entrée audio utilisable. Vérifiez le microphone dans Réglages Système → Son.")
            request = nil
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            request = nil
            onTrouble?("Le moteur audio n'a pas démarré : \(error.localizedDescription)")
            return
        }

        lastText = ""
        wakeHeard = false
        wakeTail = ""
        mode = want
        onState?()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let s = self, s.mode != .idle else { return }
                if let r = result {
                    let text = r.bestTranscription.formattedString
                    if !text.isEmpty { s.heard(text) }
                    if r.isFinal {
                        if s.mode == .wake { s.recycleWake() } else { s.stop(final: true) }
                    }
                } else if error != nil {
                    if s.mode == .wake {
                        // En veille, une erreur est presque toujours la fin
                        // d'un flux silencieux. On se remet à écouter.
                        s.recycleWake()
                    } else {
                        // Une erreur après de la parole reconnue n'est pas un
                        // échec : c'est souvent la fin du flux. On garde le texte.
                        s.stop(final: !s.lastText.isEmpty)
                        if s.lastText.isEmpty {
                            s.onTrouble?("Je n'ai rien compris. Réessayez en parlant un peu plus fort.")
                        }
                    }
                }
            }
        }

        if want == .dictation {
            // Deux garde-fous : on ne reste pas à écouter indéfiniment, et on
            // conclut dès que la phrase est finie plutôt que d'attendre.
            hardStop?.invalidate()
            hardStop = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                self?.stop(final: true)
            }
            armSilence()
        } else {
            armWakeRecycle()
        }
    }

    private func heard(_ text: String) {
        lastText = text
        switch mode {
        case .dictation:
            onPartial?(text)
            armSilence()
        case .wake:
            absorbWake(text)
        case .idle:
            break
        }
    }

    /// Relancé à chaque mot reconnu : deux secondes sans rien de neuf, et
    /// BUD considère la phrase terminée.
    private func armSilence() {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.stop(final: true)
        }
    }

    /// Démonte le moteur sans toucher au mode : la remontée s'en charge.
    private func teardown() {
        hardStop?.invalidate(); hardStop = nil
        silence?.invalidate();  silence = nil
        wakeRecycle?.invalidate(); wakeRecycle = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    func stop(final: Bool) {
        let wasDictation = mode == .dictation
        guard mode != .idle else { return }
        teardown()
        mode = .idle
        onState?()

        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastText = ""
        if final && wasDictation && !text.isEmpty { onFinal?(text) }

        // La dictée rend la main : si la veille était armée, elle reprend.
        if wasDictation && wakeArmed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let s = self, s.wakeArmed, s.mode == .idle else { return }
                s.begin(.wake)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  Le mot d'activation
    //
    //  Écouter en permanence n'est pas gratuit, et BUD ne le fera
    //  pas dans votre dos : la veille s'arme explicitement, et
    //  l'interface le montre tant qu'elle est armée. Le micro
    //  reste ouvert, la reconnaissance tourne sur le processeur,
    //  et sur batterie cela se sent. C'est pourquoi c'est un
    //  interrupteur et non un réglage par défaut.
    //
    //  Ce qui est écouté ne quitte toujours pas la machine :
    //  même moteur sur l'appareil, même refus de repli réseau.
    //
    //  Une tâche de reconnaissance ne vit pas indéfiniment —
    //  autour d'une minute — et son texte s'accumule. On la
    //  renouvelle donc pendant un silence, jamais au milieu
    //  d'une phrase, sinon on couperait la commande en deux.
    // ═══════════════════════════════════════════════════════════

    private var wakeHeard = false
    private var wakeTail = ""
    private var wakeRecycle: Timer?
    private var wakeQuiet: Timer?
    private var wakeLastChange = Date()

    /// Les formes que la reconnaissance rend pour « Hey Bud ». Le français
    /// n'écrit pas « Hey », et « Bud » n'est pas un mot du dictionnaire :
    /// la transcription varie. On accepte donc une famille, et au-delà une
    /// petite distance d'édition.
    private static let wakeForms = [
        "hey bud", "hey bude", "he bud", "hé bud", "et bud", "eh bud",
        "ok bud", "hey buddy", "hey but", "hey boude", "hey boud"
    ]

    func armWake() {
        guard !wakeArmed else { return }
        if let why = unavailableReason() { onTrouble?(why); return }
        wakeArmed = true
        onState?()
        if mode == .idle { begin(.wake) }
    }

    func disarmWake() {
        wakeArmed = false
        if mode == .wake { stop(final: false) }
        onState?()
    }

    func toggleWake() { wakeArmed ? disarmWake() : armWake() }

    private func armWakeRecycle() {
        wakeRecycle?.invalidate()
        // Toutes les dix secondes on regarde s'il est temps de renouveler
        // la tâche : seulement si plus rien n'a bougé depuis deux secondes
        // et qu'aucune commande n'est en cours.
        wakeRecycle = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let s = self, s.mode == .wake else { return }
            guard !s.wakeHeard, Date().timeIntervalSince(s.wakeLastChange) > 2 else { return }
            s.recycleWake()
        }
    }

    /// Repart sur une tâche neuve, texte vidé.
    private func recycleWake() {
        guard wakeArmed else { stop(final: false); return }
        teardown()
        mode = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let s = self, s.wakeArmed, s.mode == .idle else { return }
            s.begin(.wake)
        }
    }

    private func absorbWake(_ text: String) {
        wakeLastChange = Date()
        let norm = BudVoice.normalize(text)

        if !wakeHeard {
            guard let after = BudVoice.afterWake(norm, raw: text) else { return }
            wakeHeard = true
            wakeTail = after
            onWake?()
        } else if let after = BudVoice.afterWake(norm, raw: text) {
            wakeTail = after
        }

        // La commande est close par un silence court : on vient de parler,
        // on n'attend pas deux secondes de plus comme pour une dictée.
        wakeQuiet?.invalidate()
        wakeQuiet = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            self?.closeWakeCommand()
        }
    }

    private func closeWakeCommand() {
        wakeQuiet?.invalidate(); wakeQuiet = nil
        let cmd = wakeTail.trimmingCharacters(in: .whitespacesAndNewlines)
        wakeHeard = false
        wakeTail = ""
        if !cmd.isEmpty { onWakeCommand?(cmd) }
        recycleWake()
    }

    // ─────────────────────────────────────────────────────────
    //  Reconnaître « Hey Bud » dans un flux
    // ─────────────────────────────────────────────────────────

    /// Minuscules, sans accents, sans ponctuation, espaces réduits à un.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: Locale(identifier: "fr_FR"))
        let kept = folded.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Rend ce qui suit le mot d'activation, ou `nil` s'il n'y est pas.
    ///
    /// Le découpage se fait sur le texte normalisé, mais la commande rendue
    /// vient du texte brut : « Réponds au mail de Free » doit garder ses
    /// accents et ses majuscules pour la suite.
    static func afterWake(_ norm: String, raw: String) -> String? {
        let words = norm.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }

        for i in 0..<(words.count - 1) {
            let pair = "\(words[i]) \(words[i + 1])"
            guard matchesWake(pair) else { continue }
            // Position du mot d'activation dans la suite normalisée : on
            // reprend le brut au même rang de mot, les deux listes ayant le
            // même nombre d'éléments à la ponctuation près.
            let rawWords = raw.split(separator: " ").map(String.init)
            let start = i + 2
            guard start < rawWords.count else { return "" }
            return rawWords[start...].joined(separator: " ")
        }
        return nil
    }

    private static func matchesWake(_ pair: String) -> Bool {
        if wakeForms.contains(pair) { return true }
        // Une faute de reconnaissance près : « hey bad », « ey bud ».
        for f in wakeForms where abs(f.count - pair.count) <= 2 {
            if editDistance(f, pair) <= 1 { return true }
        }
        return false
    }

    /// Distance de Levenshtein, deux lignes de tampon.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[y.count]
    }
}

// ═══════════════════════════════════════════════════════════
//  Le bouton de dictée
//
//  Un micro qui pulse pendant l'écoute, et trois anneaux qui
//  s'écartent : il faut voir d'un coup d'œil que le Mac écoute.
// ═══════════════════════════════════════════════════════════

final class MicButton: NSView {
    var listening = false { didSet { listening ? startPulse() : stopPulse(); needsDisplay = true } }
    var onClick: (() -> Void)?

    private var t: CGFloat = 0
    private var anim: Timer?
    private var hover = false
    private var track: NSTrackingArea?

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    deinit { anim?.invalidate() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = track { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        track = a
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { onClick?() }

    private func startPulse() {
        anim?.invalidate()
        anim = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            s.t += 0.055
            s.needsDisplay = true
        }
    }
    private func stopPulse() { anim?.invalidate(); anim = nil; t = 0 }

    override func draw(_ dirty: NSRect) {
        let b = bounds
        let c = NSPoint(x: b.midX, y: b.midY)
        let col = listening ? dangerColor : (hover ? TH.text : TH.dim(0.55))

        if listening {
            // Trois anneaux décalés d'un tiers de cycle, qui grandissent
            // en s'effaçant : l'onde qui part du micro.
            for k in 0..<3 {
                let ph = (t + CGFloat(k) / 3).truncatingRemainder(dividingBy: 1)
                let rad = 9 + ph * 11
                let a = (1 - ph) * 0.34
                col.withAlphaComponent(a).setStroke()
                let p = NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad,
                                                    width: rad * 2, height: rad * 2))
                p.lineWidth = 1.4
                p.stroke()
            }
        }

        let disc = NSRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26)
        TH.fill(listening ? 0.16 : (hover ? 0.12 : 0.07)).setFill()
        NSBezierPath(ovalIn: disc).fill()
        drawSymbol(listening ? "waveform" : "mic.fill", center: c, size: 13,
                   weight: .semibold, color: col)
    }
}
