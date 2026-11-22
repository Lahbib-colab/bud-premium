import Cocoa
import CoreAudio
import AudioToolbox

// ═══════════════════════════════════════════════════════════
//  Volume du Mac — en direct
//
//  Ce que remplace ce fichier : le volume passait par
//  `osascript -e "set volume output volume N"`, et se relisait
//  par un sondage toutes les secondes.
//
//  Deux latences s'additionnaient. Lancer `osascript` demande de
//  créer un processus, de charger AppleScript et d'envoyer un
//  événement Apple — une bonne centaine de millisecondes, à
//  chaque mouvement du curseur. Et comme la relecture était un
//  sondage, un changement fait ailleurs — les touches du
//  clavier, le centre de contrôle — mettait jusqu'à une seconde
//  à remonter dans BUD.
//
//  CoreAudio supprime les deux. Lire et écrire le volume y est
//  un appel direct au pilote, sans processus ni événement. Et le
//  système prévient par un écouteur de propriété dès que le
//  volume change, quelle qu'en soit l'origine : plus de sondage,
//  et le curseur de BUD suit les touches du clavier à l'instant.
//
//  Toutes les valeurs sont vérifiées. Un périphérique de sortie
//  n'expose pas toujours un volume réglable — une sortie
//  numérique optique, un agrégat — et dans ce cas BUD le dit au
//  lieu d'afficher un curseur qui ne fait rien.
// ═══════════════════════════════════════════════════════════

enum SystemAudio {

    /// Appelé sur le fil principal quand le volume ou la coupure change,
    /// quelle que soit l'application à l'origine du changement.
    static var onChange: (() -> Void)?

    private static var listeningOn: AudioDeviceID = 0
    private static var installed = false

    // ─────────────────────────────────────────────────────────
    //  Le périphérique de sortie
    // ─────────────────────────────────────────────────────────

    private static var systemAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        // 0 est l'élément principal. On écrit le nombre plutôt que la
        // constante : elle s'est appelée `…ElementMaster` jusqu'à macOS 12
        // puis `…ElementMain`, et le nom choisi déciderait du SDK qui
        // accepte de compiler.
        mElement: 0)

    static func defaultOutput() -> AudioDeviceID? {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &systemAddress, 0, nil, &size, &dev)
        return (st == noErr && dev != 0) ? dev : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ element: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    // ─────────────────────────────────────────────────────────
    //  Lire
    // ─────────────────────────────────────────────────────────

    /// Volume de sortie, 0 à 1. `nil` si ce périphérique n'en a pas.
    static func volume() -> Float? {
        guard let dev = defaultOutput() else { return nil }

        // L'élément principal d'abord. Beaucoup de périphériques ne
        // l'exposent pas et ne connaissent que leurs canaux : on fait
        // alors la moyenne de la gauche et de la droite, ce que fait
        // aussi le réglage du système.
        if let v = scalar(dev, element: 0) { return v }
        let l = scalar(dev, element: 1), r = scalar(dev, element: 2)
        switch (l, r) {
        case let (.some(a), .some(b)): return (a + b) / 2
        case let (.some(a), .none):    return a
        case let (.none, .some(b)):    return b
        default:                       return nil
        }
    }

    private static func scalar(_ dev: AudioDeviceID, element: UInt32) -> Float? {
        var addr = address(kAudioDevicePropertyVolumeScalar, element)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v)
        return st == noErr ? Float(v) : nil
    }

    static func muted() -> Bool? {
        guard let dev = defaultOutput() else { return nil }
        var addr = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m)
        return st == noErr ? (m != 0) : nil
    }

    // ─────────────────────────────────────────────────────────
    //  Écrire
    // ─────────────────────────────────────────────────────────

    /// Règle le volume. Rend `false` si le périphérique refuse, auquel cas
    /// l'appelant retombe sur AppleScript plutôt que de ne rien faire.
    @discardableResult
    static func setVolume(_ v: Float) -> Bool {
        guard let dev = defaultOutput() else { return false }
        let clamped = max(0, min(1, v))
        if write(dev, element: 0, clamped) { return true }
        // Sans élément principal, on règle chaque canal.
        let a = write(dev, element: 1, clamped)
        let b = write(dev, element: 2, clamped)
        return a || b
    }

    private static func write(_ dev: AudioDeviceID, element: UInt32, _ v: Float) -> Bool {
        var addr = address(kAudioDevicePropertyVolumeScalar, element)
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var value = Float32(v)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &value) == noErr
    }

    @discardableResult
    static func setMuted(_ m: Bool) -> Bool {
        guard let dev = defaultOutput() else { return false }
        var addr = address(kAudioDevicePropertyMute)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
              settable.boolValue else { return false }
        var value = UInt32(m ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &value) == noErr
    }

    // ─────────────────────────────────────────────────────────
    //  Observer
    // ─────────────────────────────────────────────────────────

    /// Installe les écouteurs. À appeler une fois au démarrage.
    ///
    /// Trois propriétés sont surveillées : le volume, la coupure, et le
    /// périphérique de sortie par défaut. Cette troisième est celle qu'on
    /// oublie : brancher un casque change de périphérique, et un écouteur
    /// resté attaché à l'ancien ne dirait plus rien.
    static func startObserving() {
        guard !installed else { return }
        installed = true

        var sys = systemAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &sys, DispatchQueue.main) { _, _ in
                attachToCurrentDevice()
                onChange?()
            }
        attachToCurrentDevice()
    }

    private static func attachToCurrentDevice() {
        guard let dev = defaultOutput() else { return }
        guard dev != listeningOn else { return }

        if listeningOn != 0 {
            for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                for el in UInt32(0)...2 {
                    var a = address(sel, el)
                    AudioObjectRemovePropertyListenerBlock(listeningOn, &a,
                                                           DispatchQueue.main, deviceListener)
                }
            }
        }

        listeningOn = dev
        for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            for el in UInt32(0)...2 {
                var a = address(sel, el)
                guard AudioObjectHasProperty(dev, &a) else { continue }
                AudioObjectAddPropertyListenerBlock(dev, &a, DispatchQueue.main, deviceListener)
            }
        }
    }

    /// Le même bloc pour tous les écouteurs : il faut la même référence
    /// pour pouvoir les retirer, et deux fermetures écrites à l'identique
    /// ne sont pas la même référence.
    private static let deviceListener: AudioObjectPropertyListenerBlock = { _, _ in
        onChange?()
    }
}
