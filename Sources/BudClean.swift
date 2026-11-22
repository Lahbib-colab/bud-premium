import Cocoa

// ═══════════════════════════════════════════════════════════
//  Corbeille et résidus
//  Rien n'est supprimé sans analyse préalable ni confirmation.
// ═══════════════════════════════════════════════════════════

struct CleanTarget {
    let id: String
    let title: String
    let detail: String
    let icon: String
    /// true : le contenu part à la corbeille ; false : suppression directe
    let toTrash: Bool
    let urls: () -> [URL]
}

struct CleanResult {
    var bytes: Int64 = 0
    var files: Int = 0
}

enum Cleaner {

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Taille réelle occupée par un dossier, bornée pour rester rapide.
    static func sizeOf(_ url: URL, limit: Int = 60_000) -> CleanResult {
        var r = CleanResult()
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey],
                                    options: []) else { return r }
        var seen = 0
        for case let f as URL in e {
            seen += 1
            if seen > limit { break }
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey])
            if v?.isDirectory == true { continue }
            r.bytes += Int64(v?.totalFileAllocatedSize ?? 0)
            r.files += 1
        }
        return r
    }

    /// Les éléments de premier niveau d'un dossier (ce que l'on videra).
    static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                      options: [])) ?? []
    }

    static func targets() -> [CleanTarget] {
        let fm = FileManager.default
        let uid = getuid()
        return [
            CleanTarget(id: "trash", title: "Corbeille", detail: "Votre corbeille personnelle",
                        icon: "trash.fill", toTrash: false) {
                children(home.appendingPathComponent(".Trash"))
            },
            CleanTarget(id: "trashVol", title: "Corbeilles des volumes",
                        detail: "Fichiers supprimés restés sur les disques externes",
                        icon: "externaldrive.badge.xmark", toTrash: false) {
                var out: [URL] = []
                for v in scanVolumes() where !v.isBoot {
                    let t = v.url.appendingPathComponent(".Trashes/\(uid)")
                    if fm.fileExists(atPath: t.path) { out += children(t) }
                }
                return out
            },
            CleanTarget(id: "caches", title: "Caches applicatifs",
                        detail: "~/Bibliothèque/Caches, reconstruits automatiquement",
                        icon: "shippingbox.fill", toTrash: false) {
                children(home.appendingPathComponent("Library/Caches"))
            },
            CleanTarget(id: "logs", title: "Journaux",
                        detail: "~/Bibliothèque/Logs", icon: "doc.text.magnifyingglass", toTrash: false) {
                children(home.appendingPathComponent("Library/Logs"))
            },
            CleanTarget(id: "derived", title: "Données Xcode",
                        detail: "DerivedData et archives de compilation",
                        icon: "hammer.fill", toTrash: false) {
                children(home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
            },
            CleanTarget(id: "dsstore", title: "Fichiers .DS_Store",
                        detail: "Bureau, Documents et Téléchargements",
                        icon: "doc.badge.gearshape", toTrash: false) {
                var out: [URL] = []
                for d in ["Desktop", "Documents", "Downloads"] {
                    let root = home.appendingPathComponent(d)
                    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                                options: [.skipsPackageDescendants]) else { continue }
                    var n = 0
                    for case let f as URL in e {
                        n += 1
                        if n > 40_000 { break }
                        if f.lastPathComponent == ".DS_Store" { out.append(f) }
                    }
                }
                return out
            },
            CleanTarget(id: "oldDownloads", title: "Vieux téléchargements",
                        detail: "Fichiers de plus de 60 jours, envoyés à la corbeille",
                        icon: "clock.arrow.circlepath", toTrash: true) {
                let limit = Date().addingTimeInterval(-60 * 86400)
                return children(home.appendingPathComponent("Downloads")).filter { u in
                    let v = try? u.resourceValues(forKeys: [.contentModificationDateKey])
                    return (v?.contentModificationDate ?? Date()) < limit
                }
            }
        ]
    }

    /// Analyse en arrière-plan ; le résultat revient sur le fil principal.
    static func scan(progress: @escaping (Double, String) -> Void = { _, _ in },
                     done: @escaping ([String: CleanResult]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var out: [String: CleanResult] = [:]
            let fm = FileManager.default
            let all = targets()
            for (idx, t) in all.enumerated() {
                DispatchQueue.main.async { progress(Double(idx) / Double(all.count), t.title) }
                var r = CleanResult()
                for u in t.urls() {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                    if isDir.boolValue {
                        let s = sizeOf(u)
                        r.bytes += s.bytes
                        r.files += s.files
                    } else {
                        let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                        r.bytes += Int64(v?.totalFileAllocatedSize ?? 0)
                        r.files += 1
                    }
                }
                out[t.id] = r
            }
            DispatchQueue.main.async { progress(1, ""); done(out) }
        }
    }

    /// Exécute le nettoyage des cibles demandées.
    static func clean(ids: Set<String>,
                      progress: @escaping (Double, String, Int64) -> Void = { _, _, _ in },
                      done: @escaping (Int64, Int, Int) -> Void) {
        let selected = targets().filter { ids.contains($0.id) }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var freed: Int64 = 0
            var removed = 0
            var failed = 0
            for (idx, t) in selected.enumerated() {
                DispatchQueue.main.async { progress(Double(idx) / Double(max(1, selected.count)), t.title, freed) }
                for u in t.urls() {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                    let size: Int64
                    if isDir.boolValue { size = sizeOf(u).bytes }
                    else { size = Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                                            .totalFileAllocatedSize ?? 0) }
                    do {
                        if t.toTrash {
                            try fm.trashItem(at: u, resultingItemURL: nil)
                        } else {
                            try fm.removeItem(at: u)
                        }
                        freed += size
                        removed += 1
                    } catch {
                        failed += 1
                    }
                    if removed % 12 == 0 {
                        let snapshot = freed
                        DispatchQueue.main.async { progress(-1, t.title, snapshot) }
                    }
                }
            }
            DispatchQueue.main.async { progress(1, "", freed); done(freed, removed, failed) }
        }
    }
}

/// Ligne de nettoyage : case à cocher, intitulé, volume récupérable.
final class CleanRow: NSView {
    let targetID: String
    private let title: String
    private let detail: String
    private let iconName: String
    var checked = true { didSet { needsDisplay = true } }
    var sizeText = "—" { didSet { needsDisplay = true } }
    var empty = false { didSet { needsDisplay = true } }
    var onToggle: ((String) -> Void)?
    private var hover = false

    init(frame: NSRect, target: CleanTarget) {
        targetID = target.id
        title = target.title
        detail = target.detail
        iconName = target.icon
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        guard !empty, bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        onToggle?(targetID)
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let card = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        TH.fill(empty ? 0.03 : (hover ? 0.09 : 0.05)).setFill()
        card.fill()
        TH.fill(0.07).setStroke()
        card.lineWidth = 1
        card.stroke()

        // Case à cocher
        let box = NSRect(x: r.minX + 14, y: r.midY - 9, width: 18, height: 18)
        let bp = NSBezierPath(roundedRect: box, xRadius: 5.5, yRadius: 5.5)
        if checked && !empty {
            TH.accent.setFill()
            bp.fill()
            drawSymbol("checkmark", center: NSPoint(x: box.midX, y: box.midY), size: 10,
                       weight: .bold, color: TH.onAccent)
        } else {
            TH.fill(0.10).setFill()
            bp.fill()
            TH.fill(0.14).setStroke()
            bp.lineWidth = 1
            bp.stroke()
        }

        drawSymbol(iconName, center: NSPoint(x: r.minX + 52, y: r.midY), size: 13.5, weight: .semibold,
                   color: empty ? TH.dim(0.25) : (checked ? TH.accent : TH.dim(0.45)))

        let sizeW = textWidth(sizeText, size: 13, weight: .bold, mono: true) + 10
        let textMax = r.width - 72 - sizeW - 16
        drawString(title, in: NSRect(x: r.minX + 72, y: r.midY + 1, width: textMax, height: 17),
                   size: 12.5, weight: .semibold, color: empty ? TH.dim(0.35) : TH.text)
        drawString(detail, in: NSRect(x: r.minX + 72, y: r.midY - 15, width: textMax, height: 15),
                   size: 10.5, weight: .regular, color: TH.dim(0.42))

        drawString(empty ? "rien" : sizeText,
                   in: NSRect(x: r.maxX - sizeW - 14, y: r.midY - 9, width: sizeW, height: 19),
                   size: 13, weight: .bold, color: empty ? TH.dim(0.3) : TH.text, align: .right, mono: true)
    }
}

final class CleanupPanelView: NSView {
    private let hero: HeroHeader
    private var rows: [CleanRow] = []
    private var totalTile: StatTile!
    private var statusLabel: NSTextField!
    private var cleanBtn: GlassButton!
    private var sizes: [String: CleanResult] = [:]
    private var sweep: SweepView!
    private var sweepTimer: Timer?
    private var selection = Set<String>(["trash", "trashVol", "caches", "logs"])
    private var busy = false

    var onStatus: ((String) -> Void)?
    var onCleaned: (() -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Nettoyage", subtitle: "Corbeille, caches et résidus récupérables.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height

        totalTile = StatTile(frame: NSRect(x: W - 190, y: H - 86, width: 180, height: 78),
                             caption: "Récupérable", hint: "lancez une analyse")
        addSubview(totalTile)

        sweep = SweepView(frame: NSRect(x: 0, y: H - 182, width: W, height: 62))
        sweep.isHidden = true
        addSubview(sweep)

        mkSection(self, H - 116, W, "Éléments")

        let targets = Cleaner.targets()
        for (i, t) in targets.enumerated() {
            let row = CleanRow(frame: NSRect(x: 0, y: H - 164 - CGFloat(i) * 50, width: W, height: 46), target: t)
            row.checked = selection.contains(t.id)
            row.onToggle = { [weak self] id in self?.toggle(id) }
            addSubview(row)
            rows.append(row)
        }

        statusLabel = mkLabel("Analysez pour connaître l'espace récupérable.",
                              NSRect(x: 0, y: 56, width: W, height: 18), 11, .regular, alpha: 0.45, .center)
        addSubview(statusLabel)

        let bw = (W - 12) / 2
        let scanBtn = GlassButton(frame: NSRect(x: 0, y: 0, width: bw, height: 46),
                                  title: "Analyser", icon: "magnifyingglass")
        scanBtn.onClick = { [weak self] _ in self?.scan() }
        cleanBtn = GlassButton(frame: NSRect(x: bw + 12, y: 0, width: bw, height: 46),
                               title: "Nettoyer", icon: "sparkles", prominent: true)
        cleanBtn.enabledFlag = false
        cleanBtn.onClick = { [weak self] _ in self?.confirmClean() }
        [scanBtn, cleanBtn].forEach { addSubview($0) }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        for r in rows where r.targetID == id { r.checked = selection.contains(id) }
        updateTotal()
    }

    private func updateTotal() {
        var total: Int64 = 0
        for id in selection { total += sizes[id]?.bytes ?? 0 }
        totalTile.set(sizes.isEmpty ? "—" : formatBytes(total),
                      hint: sizes.isEmpty ? "lancez une analyse" : "sur les éléments cochés")
        cleanBtn.enabledFlag = !busy && total > 0
        hero.set(trailing: total > 0 ? formatBytes(total) : "")
    }

    private func startSweep(_ caption: String) {
        sweep.reset()
        sweep.caption = caption
        sweep.freedText = ""
        sweep.progress = 0
        sweep.isHidden = false
        rows.forEach { $0.alphaValue = 0.35 }
        sweepTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.sweep.step() }
        RunLoop.main.add(t, forMode: .common)
        sweepTimer = t
    }

    private func endSweep(_ freed: String, celebrate: Bool) {
        sweep.freedText = freed
        if celebrate {
            sweep.celebrate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.hideSweep() }
        } else {
            hideSweep()
        }
    }

    private func hideSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        rows.forEach { $0.alphaValue = 1 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            sweep.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.sweep.isHidden = true
            self?.sweep.alphaValue = 1
        })
    }

    func scan() {
        guard !busy else { return }
        busy = true
        statusLabel.stringValue = "Analyse en cours…"
        cleanBtn.enabledFlag = false
        startSweep("Analyse…")
        Cleaner.scan(progress: { [weak self] p, name in
            self?.sweep.progress = CGFloat(p)
            self?.sweep.caption = name.isEmpty ? "Analyse…" : "Analyse · \(name)"
        }) { [weak self] res in
            guard let s = self else { return }
            s.sizes = res
            for r in s.rows {
                let v = res[r.targetID] ?? CleanResult()
                r.sizeText = formatBytes(v.bytes)
                r.empty = (v.bytes == 0)
                if v.bytes == 0 { s.selection.remove(r.targetID) }
                r.checked = s.selection.contains(r.targetID)
            }
            s.busy = false
            s.statusLabel.stringValue = "Analyse terminée. Décochez ce que vous voulez garder."
            s.updateTotal()
            var total: Int64 = 0
            for id in s.selection { total += res[id]?.bytes ?? 0 }
            s.endSweep(total > 0 ? "\(formatBytes(total)) récupérables" : "rien à libérer", celebrate: false)
        }
    }

    private func confirmClean() {
        var total: Int64 = 0
        var lines: [String] = []
        for t in Cleaner.targets() where selection.contains(t.id) {
            let b = sizes[t.id]?.bytes ?? 0
            guard b > 0 else { continue }
            total += b
            lines.append("• \(t.title) — \(formatBytes(b))")
        }
        guard total > 0 else { return }

        let a = NSAlert()
        a.messageText = "Libérer \(formatBytes(total)) ?"
        a.informativeText = lines.joined(separator: "\n")
            + "\n\nLa corbeille et les caches sont supprimés définitivement ; les vieux téléchargements partent à la corbeille."
        a.addButton(withTitle: "Nettoyer")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        busy = true
        cleanBtn.enabledFlag = false
        statusLabel.stringValue = "Nettoyage en cours…"
        startSweep("Nettoyage…")
        Cleaner.clean(ids: selection, progress: { [weak self] p, name, freed in
            guard let s = self else { return }
            if p >= 0 { s.sweep.progress = CGFloat(p) }
            if !name.isEmpty { s.sweep.caption = "Nettoyage · \(name)" }
            s.sweep.freedText = "\(formatBytes(freed)) libérés"
        }) { [weak self] freed, removed, failed in
            guard let s = self else { return }
            s.busy = false
            let msg = "\(formatBytes(freed)) libérés · \(removed) éléments"
                + (failed > 0 ? " · \(failed) protégés par le système" : "")
            s.statusLabel.stringValue = msg
            s.onStatus?(msg)
            s.onCleaned?()
            s.endSweep("\(formatBytes(freed)) libérés", celebrate: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.scan() }
        }
    }

    /// Vidage immédiat de la seule corbeille, utilisable depuis le chat.
    func emptyTrashOnly(_ done: @escaping (String) -> Void) {
        Cleaner.clean(ids: ["trash", "trashVol"]) { freed, removed, failed in
            done("\(formatBytes(freed)) libérés · \(removed) éléments"
                 + (failed > 0 ? " · \(failed) ignorés" : ""))
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  Animation de nettoyage
//  Des poussières sont aspirées vers la corbeille pendant que
//  BUD balaie ; le compteur d'octets libérés grimpe en direct.
// ═══════════════════════════════════════════════════════════

private struct Mote {
    var x: CGFloat, y: CGFloat
    var vx: CGFloat, vy: CGFloat
    var size: CGFloat
    var life: CGFloat
    var spin: CGFloat
}

final class SweepView: NSView {
    private var motes: [Mote] = []
    private var t: CGFloat = 0
    private var shimmer: CGFloat = 0
    private var burst: CGFloat = 0

    var progress: CGFloat = 0          // < 0 : indéterminé
    var caption = ""
    var freedText = ""
    var finished = false

    func reset() {
        motes.removeAll()
        t = 0
        burst = 0
        finished = false
    }

    func celebrate() {
        finished = true
        burst = 1
        for _ in 0..<26 {
            let a = CGFloat.random(in: 0...(.pi * 2))
            let sp = CGFloat.random(in: 1.4...4.2)
            motes.append(Mote(x: bounds.width * 0.5, y: bounds.height * 0.5,
                              vx: cos(a) * sp, vy: sin(a) * sp,
                              size: CGFloat.random(in: 1.6...3.4),
                              life: CGFloat.random(in: 0.7...1.0),
                              spin: CGFloat.random(in: -0.2...0.2)))
        }
    }

    func step() {
        t += 0.05
        shimmer += 0.028
        if shimmer > 1.6 { shimmer = -0.4 }
        if burst > 0 { burst = max(0, burst - 0.015) }

        let sink = NSPoint(x: bounds.width - 54, y: bounds.height / 2)

        if !finished && motes.count < 34 && Int(t * 20) % 2 == 0 {
            motes.append(Mote(x: CGFloat.random(in: 40...(bounds.width * 0.55)),
                              y: CGFloat.random(in: 12...(bounds.height - 12)),
                              vx: 0, vy: 0,
                              size: CGFloat.random(in: 1.4...3.2),
                              life: 1,
                              spin: CGFloat.random(in: -0.3...0.3)))
        }

        for i in motes.indices.reversed() {
            if finished {
                motes[i].x += motes[i].vx
                motes[i].y += motes[i].vy
                motes[i].vy -= 0.06
                motes[i].life -= 0.022
            } else {
                let dx = sink.x - motes[i].x, dy = sink.y - motes[i].y
                let d = max(6, sqrt(dx * dx + dy * dy))
                motes[i].vx += dx / d * 0.42
                motes[i].vy += dy / d * 0.42 + sin(t * 2 + motes[i].spin * 10) * 0.08
                motes[i].vx *= 0.90
                motes[i].vy *= 0.90
                motes[i].x += motes[i].vx
                motes[i].y += motes[i].vy
                if d < 14 { motes[i].life -= 0.14 }
            }
            if motes[i].life <= 0 { motes.remove(at: i) }
        }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let card = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        TH.fill(0.06).setFill()
        card.fill()
        TH.accent.withAlphaComponent(0.22).setStroke()
        card.lineWidth = 1
        card.stroke()

        // Reflet qui balaie la carte pendant le travail
        if !finished {
            NSGraphicsContext.current?.saveGraphicsState()
            card.addClip()
            let gx = r.minX + shimmer * r.width
            if let g = NSGradient(colors: [TH.accent.withAlphaComponent(0),
                                           TH.accent.withAlphaComponent(0.10),
                                           TH.accent.withAlphaComponent(0)]) {
                g.draw(in: NSRect(x: gx - 90, y: r.minY, width: 180, height: r.height), angle: 0)
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Poussières
        for m in motes {
            let a = max(0, min(1, m.life))
            (finished ? TH.accent : TH.dim(0.8)).withAlphaComponent(a * (finished ? 0.9 : 0.5)).setFill()
            NSBezierPath(ovalIn: NSRect(x: m.x - m.size, y: m.y - m.size,
                                        width: m.size * 2, height: m.size * 2)).fill()
        }

        // Balai de BUD, à gauche
        let bx = r.minX + 34 + sin(t * 3) * 5
        let by = r.midY + cos(t * 6) * 2
        drawSymbol(finished ? "sparkles" : "wind", center: NSPoint(x: bx, y: by),
                   size: 22, weight: .semibold, color: TH.accent)

        // Corbeille cible, à droite
        let sink = NSPoint(x: r.width - 54, y: r.midY)
        let pulse = finished ? 0 : CGFloat(abs(sin(t * 4))) * 2
        TH.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(ovalIn: NSRect(x: sink.x - 20 - pulse, y: sink.y - 20 - pulse,
                                    width: 40 + pulse * 2, height: 40 + pulse * 2)).fill()
        drawSymbol(finished ? "checkmark.circle.fill" : "trash.fill",
                   center: sink, size: 20, weight: .semibold,
                   color: finished ? TH.accent : TH.dim(0.75))

        // Texte et progression
        let textX = r.minX + 66
        let textW = r.width - 66 - 90
        drawString(finished ? "Nettoyage terminé" : (caption.isEmpty ? "Analyse…" : caption),
                   in: NSRect(x: textX, y: r.midY + 4, width: textW, height: 20),
                   size: 13, weight: .bold, color: TH.text)
        drawString(freedText, in: NSRect(x: textX, y: r.midY - 16, width: textW, height: 18),
                   size: 11.5, weight: .medium, color: TH.dim(0.55), mono: true)

        if !finished {
            let track = NSRect(x: textX, y: r.minY + 10, width: textW, height: 4)
            TH.fill(0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            TH.accent.setFill()
            if progress >= 0 {
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                                 width: max(4, track.width * progress), height: 4),
                             xRadius: 2, yRadius: 2).fill()
            } else {
                // Indéterminé : une navette va et vient
                let w = track.width * 0.3
                let x = track.minX + (track.width - w) * (0.5 + 0.5 * sin(t * 1.6))
                NSBezierPath(roundedRect: NSRect(x: x, y: track.minY, width: w, height: 4),
                             xRadius: 2, yRadius: 2).fill()
            }
        }
    }
}
