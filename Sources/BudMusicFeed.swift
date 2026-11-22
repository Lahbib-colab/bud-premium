import Cocoa
import Foundation

// ═══════════════════════════════════════════════════════════
//  Ce que Musique annonce d'elle-même
//
//  Music.app publie une notification distribuée à chaque
//  changement : « com.apple.Music.playerInfo ». Elle porte le
//  titre, l'artiste, l'album, l'état et la durée.
//
//  Trois propriétés en font la source primaire, devant
//  AppleScript :
//
//  — elle ne demande aucune autorisation. Pas d'événement
//    Apple, donc rien à cocher dans Automatisation, et rien
//    qu'une nouvelle signature de BUD puisse invalider.
//  — elle ne coûte aucun processus. Pas d'osascript à lancer
//    toutes les quatre secondes.
//  — elle arrive quand ça change, pas quand on demande. Le
//    titre apparaît dans le notch au moment où le morceau
//    démarre, pas au sondage suivant.
//
//  Elle a une limite, honnêtement : elle ne dit rien tant que
//  rien ne change. BUD lancé pendant un morceau déjà en cours
//  ne la reçoit pas. C'est pourquoi AppleScript reste là, non
//  plus comme source unique mais comme second témoin.
//
//  Et elle ne donne pas la position de lecture. On ne
//  l'invente donc pas : elle n'est estimée que depuis un début
//  de morceau, où elle vaut zéro et où le temps écoulé suffit.
// ═══════════════════════════════════════════════════════════

struct MusicAnnounce {
    var title = ""
    var artist = ""
    var album = ""
    var playing = false
    /// Musique a dit « arrêté » : différent de « on ne sait pas ».
    var stopped = false
    var duration: Double = 0
    var trackKey = ""
    /// Quand l'annonce est arrivée, pour estimer la position.
    var at = Date()
    /// Vrai seulement si l'annonce marque un **début** de morceau. Reprendre
    /// après une pause produit la même notification sans position, et
    /// compter depuis cet instant placerait le curseur au début d'un
    /// morceau entamé. Mieux vaut ne rien afficher que se tromper.
    var fromStart = false

    var hasTrack: Bool { !title.isEmpty }
}

/// L'objet qui reçoit la notification. Le centre distribué veut une cible
/// et un sélecteur : c'est la seule forme qui accepte
/// `deliverImmediately`, et sans ce réglage le système peut retenir les
/// notifications quand l'application est occupée — ce qui est précisément
/// le moment où l'on veut la nouvelle.
final class MusicFeedListener: NSObject {
    @objc func playerInfo(_ note: Notification) {
        MusicFeed.absorb(note.userInfo)
    }
}

enum MusicFeed {
    private(set) static var last: MusicAnnounce?
    /// Prévenu sur le fil principal, à chaque annonce.
    static var onChange: (() -> Void)?

    private static var listener: MusicFeedListener?

    static func start() {
        guard listener == nil else { return }
        let l = MusicFeedListener()
        listener = l
        let c = DistributedNotificationCenter.default()
        // Les deux noms : Music sur Catalina et au-delà, iTunes avant.
        // Un système ne poste que le sien, l'autre observateur dort.
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
            c.addObserver(l, selector: #selector(MusicFeedListener.playerInfo(_:)),
                          name: Notification.Name(name), object: nil,
                          suspensionBehavior: .deliverImmediately)
        }
    }

    /// Oublie ce qu'on sait, quand Musique se ferme.
    static func forget() { last = nil }

    static func absorb(_ info: [AnyHashable: Any]?) {
        guard let info = info else { return }
        var a = MusicAnnounce()

        a.title = text(info["Name"])
        a.artist = text(info["Artist"])
        a.album = text(info["Album"])

        let state = text(info["Player State"]).lowercased()
        a.playing = state == "playing"
        a.stopped = state == "stopped"

        // « Total Time » est en millisecondes, et peut arriver en nombre
        // comme en chaîne selon la version.
        if let ms = number(info["Total Time"]), ms > 0 { a.duration = ms / 1000 }

        // L'identifiant persistant, quand il est là, distingue deux morceaux
        // de même titre. Sinon le triplet suffit — une radio n'en a pas.
        let pid = text(info["PersistentID"])
        a.trackKey = pid.isEmpty
            ? (a.title.isEmpty ? "" : "\(a.title)|\(a.artist)|\(a.album)")
            : pid

        // Un morceau arrêté n'efface pas le précédent titre : il le met en
        // pause. Mais un état « arrêté » sans titre, c'est Musique qui
        // s'en va, et là il faut vraiment oublier.
        if a.stopped && !a.hasTrack { last = nil; notify(); return }

        a.fromStart = a.playing && a.trackKey != (last?.trackKey ?? "")
        last = a
        notify()
    }

    private static func notify() {
        if Thread.isMainThread { onChange?() }
        else { DispatchQueue.main.async { onChange?() } }
    }

    /// La position estimée, et seulement quand elle est défendable.
    /// Rien d'autre que le temps écoulé depuis un début de morceau.
    static func estimatedPosition() -> Double? {
        guard let a = last, a.playing, a.fromStart, a.duration > 0 else { return nil }
        let t = Date().timeIntervalSince(a.at)
        guard t >= 0 else { return nil }
        return min(t, a.duration)
    }

    private static func text(_ v: Any?) -> String {
        guard let v = v else { return "" }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }
}
