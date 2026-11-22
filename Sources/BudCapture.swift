import Foundation
import AppKit

// ═══════════════════════════════════════════════════════════
//  Capture d'écran
//
//  BUD n'écrit pas son propre code de capture : il appelle
//  /usr/sbin/screencapture, l'outil du système, qui sait déjà
//  gérer les écrans multiples, les densités Retina, l'espace
//  colorimétrique et la sélection de fenêtre.
//
//  Autorisation : depuis macOS 10.15, capturer l'écran exige
//  l'« Enregistrement de l'écran » dans Confidentialité et
//  sécurité. Sans elle, l'image sort vide ou noire — BUD le
//  détecte à la taille du fichier et le dit, plutôt que de
//  laisser une capture inutilisable sur le Bureau.
// ═══════════════════════════════════════════════════════════

enum CaptureMode: Int {
    case screen = 0, window = 1, selection = 2

    var label: String {
        switch self {
        case .screen: return "Tout l'écran"
        case .window: return "Une fenêtre"
        case .selection: return "Sélection"
        }
    }
    var icon: String {
        switch self {
        case .screen: return "rectangle.inset.filled"
        case .window: return "macwindow"
        case .selection: return "selection.pin.in.out"
        }
    }
    /// Arguments de screencapture. `-x` coupe le son de l'obturateur.
    var flags: [String] {
        switch self {
        case .screen: return ["-x"]
        case .window: return ["-x", "-i", "-w"]   // interactif, fenêtres seules
        case .selection: return ["-x", "-i"]      // réticule ; espace bascule en mode fenêtre
        }
    }
    /// Les modes interactifs attendent l'utilisateur : inutile de
    /// temporiser pour laisser le notch se replier.
    var interactive: Bool { self != .screen }
}

enum CaptureTarget: Int {
    case desktop = 0, clipboard = 1
}

struct CaptureResult {
    var url: URL?
    var message: String
    var ok: Bool
}

enum ScreenCapture {

    /// Nom à la manière du système, lisible et trié par date.
    static func filename() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        return "Capture BUD \(df.string(from: Date())).png"
    }

    static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    /// Lance la capture hors du fil principal : les modes interactifs
    /// bloquent jusqu'à ce que l'utilisateur ait cliqué, et l'interface
    /// de BUD ne doit pas geler pendant ce temps.
    static func run(_ mode: CaptureMode, to target: CaptureTarget,
                    completion: @escaping (CaptureResult) -> Void) {
        let delay: TimeInterval = mode.interactive ? 0.15 : 0.45
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            let r = capture(mode, target)
            DispatchQueue.main.async { completion(r) }
        }
    }

    private static func capture(_ mode: CaptureMode, _ target: CaptureTarget) -> CaptureResult {
        let tool = "/usr/sbin/screencapture"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            return CaptureResult(url: nil, message: "screencapture est introuvable sur ce système.", ok: false)
        }

        var args = mode.flags
        var dest: URL?

        switch target {
        case .clipboard:
            args.append("-c")
        case .desktop:
            let u = desktop.appendingPathComponent(filename())
            dest = u
            args.append(u.path)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch {
            return CaptureResult(url: nil, message: "Capture impossible à lancer.", ok: false)
        }
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        p.waitUntilExit()

        // Un mode interactif annulé par Échap sort non nul sans rien écrire :
        // ce n'est pas une panne, inutile d'alarmer.
        if p.terminationStatus != 0 {
            if mode.interactive, dest == nil || !FileManager.default.fileExists(atPath: dest!.path) {
                return CaptureResult(url: nil, message: "Capture annulée.", ok: false)
            }
            let detail = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            return CaptureResult(url: nil,
                                 message: detail.isEmpty ? "Capture refusée par le système." : detail,
                                 ok: false)
        }

        if target == .clipboard {
            return CaptureResult(url: nil, message: "Capture copiée dans le presse-papiers.", ok: true)
        }

        guard let u = dest, FileManager.default.fileExists(atPath: u.path) else {
            return CaptureResult(url: nil, message: "Capture annulée.", ok: false)
        }

        // Une image quasi vide trahit l'autorisation manquante : le système
        // rend alors un cadre noir ou le seul fond d'écran.
        let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
        let size = (attrs?[.size] as? Int) ?? 0
        if size < 4096 {
            return CaptureResult(url: u,
                                 message: "Capture quasi vide : autorisez BUD dans Réglages Système → "
                                        + "Confidentialité et sécurité → Enregistrement de l'écran, puis relancez BUD.",
                                 ok: false)
        }

        return CaptureResult(url: u, message: "Enregistrée sur le Bureau : \(u.lastPathComponent)", ok: true)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
