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

    private(set) var listening = false

    /// Texte en cours de reconnaissance, à chaque mot.
    var onPartial: ((String) -> Void)?
    /// Texte retenu quand l'utilisateur s'arrête de parler.
    var onFinal: ((String) -> Void)?
    /// Une phrase à montrer : refus, autorisation manquante, panne.
    var onTrouble: ((String) -> Void)?
    /// Changement d'état, pour que le bouton suive.
    var onState: (() -> Void)?

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

    func start() {
        guard !listening else { return }
        if let why = unavailableReason() { onTrouble?(why); return }

        // Deux autorisations distinctes, et deux refus distincts : la
        // reconnaissance vocale et le microphone sont deux réglages de
        // confidentialité séparés, qu'on peut accorder l'un sans l'autre.
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let s = self else { return }
                switch status {
                case .authorized:
                    s.askMicrophone()
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

    private func askMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginListening()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
                DispatchQueue.main.async {
                    guard let s = self else { return }
                    if ok { s.beginListening() }
                    else { s.onTrouble?("Sans microphone, BUD ne peut pas vous entendre.") }
                }
            }
        default:
            onTrouble?("Le microphone est refusé pour BUD. "
                + "Réglages Système → Confidentialité et sécurité → Microphone.")
        }
    }

    private func beginListening() {
        guard !listening, let recognizer = recognizer else { return }

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
        listening = true
        onState?()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let s = self, s.listening else { return }
                if let r = result {
                    let text = r.bestTranscription.formattedString
                    if !text.isEmpty {
                        s.lastText = text
                        s.onPartial?(text)
                        s.armSilence()
                    }
                    if r.isFinal { s.stop(final: true) }
                } else if error != nil {
                    // Une erreur après de la parole reconnue n'est pas un
                    // échec : c'est souvent la fin du flux. On garde le texte.
                    s.stop(final: !s.lastText.isEmpty)
                    if s.lastText.isEmpty {
                        s.onTrouble?("Je n'ai rien compris. Réessayez en parlant un peu plus fort.")
                    }
                }
            }
        }

        // Deux garde-fous : on ne reste pas à écouter indéfiniment, et on
        // conclut dès que la phrase est finie plutôt que d'attendre.
        hardStop?.invalidate()
        hardStop = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            self?.stop(final: true)
        }
        armSilence()
    }

    /// Relancé à chaque mot reconnu : deux secondes sans rien de neuf, et
    /// BUD considère la phrase terminée.
    private func armSilence() {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.stop(final: true)
        }
    }

    func stop(final: Bool) {
        hardStop?.invalidate(); hardStop = nil
        silence?.invalidate();  silence = nil
        guard listening else { return }
        listening = false

        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onState?()

        let text = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastText = ""
        if final && !text.isEmpty { onFinal?(text) }
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
