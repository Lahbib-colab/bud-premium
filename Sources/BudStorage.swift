import Cocoa

// ═══════════════════════════════════════════════════════════
//  Stockage interne et externe
// ═══════════════════════════════════════════════════════════

struct VolumeInfo {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isBoot: Bool

    var used: Int64 { max(0, total - free) }
    var usedRatio: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var freePercent: Int { total > 0 ? Int((Double(free) / Double(total)) * 100.0) : 0 }
    var icon: String {
        if isBoot { return "internaldrive.fill" }
        if isRemovable { return "externaldrive.fill" }
        return isInternal ? "internaldrive" : "externaldrive.connected.to.line.below"
    }
    var tag: String {
        if isBoot { return "Démarrage" }
        if isRemovable { return "Externe" }
        return isInternal ? "Interne" : "Réseau"
    }
}

func scanVolumes() -> [VolumeInfo] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                  .volumeAvailableCapacityForImportantUsageKey,
                                  .volumeAvailableCapacityKey,
                                  .volumeIsRemovableKey, .volumeIsEjectableKey,
                                  .volumeIsInternalKey, .volumeIsBrowsableKey]
    let fm = FileManager.default
    guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                          options: [.skipHiddenVolumes]) else { return [] }
    var out: [VolumeInfo] = []
    for u in urls {
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
        guard v.volumeIsBrowsable ?? true else { continue }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        guard total > 0 else { continue }
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        let removable = (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)
        out.append(VolumeInfo(url: u,
                              name: v.volumeName ?? u.lastPathComponent,
                              total: total,
                              free: max(0, free),
                              isInternal: (v.volumeIsInternal ?? false) && !removable,
                              isRemovable: removable,
                              isBoot: u.path == "/"))
    }
    return out.sorted { a, b in
        if a.isBoot != b.isBoot { return a.isBoot }
        if a.isInternal != b.isInternal { return a.isInternal }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

func bootVolume() -> VolumeInfo? {
    let v = scanVolumes()
    return v.first { $0.isBoot } ?? v.first
}

final class StoragePanelView: NSView {

    private let hero: HeroHeader
    private let ring = GaugeRing(frame: .zero)
    private var tileFree: StatTile!, tileUsed: StatTile!, tileTotal: StatTile!, tileCount: StatTile!
    private var vitalCpu: NSTextField!, vitalMem: NSTextField!, vitalUp: NSTextField!
    private let scroll = NSScrollView(frame: .zero)
    private let listHost = NSView(frame: .zero)
    private var rowViews: [NSView] = []

    var onEject: ((String) -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Stockage", subtitle: "Vos disques internes et externes, en un coup d'œil.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        addSubview(hero)

        ring.frame = NSRect(x: W - 116, y: H - 86, width: 80, height: 80)
        addSubview(ring)

        let gap: CGFloat = 12
        let tw = (W - gap * 3) / 4
        let ty = H - 184
        tileFree  = StatTile(frame: NSRect(x: 0, y: ty, width: tw, height: 78), caption: "Libre")
        tileUsed  = StatTile(frame: NSRect(x: tw + gap, y: ty, width: tw, height: 78), caption: "Occupé")
        tileTotal = StatTile(frame: NSRect(x: (tw + gap) * 2, y: ty, width: tw, height: 78), caption: "Capacité")
        tileCount = StatTile(frame: NSRect(x: (tw + gap) * 3, y: ty, width: tw, height: 78), caption: "Volumes")
        [tileFree, tileUsed, tileTotal, tileCount].forEach { addSubview($0) }

        mkSection(self, H - 208, W, "Volumes")

        scroll.frame = NSRect(x: 0, y: 96, width: W, height: H - 312)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = listHost
        addSubview(scroll)

        // Constantes du Mac
        let cw = (W - 24) / 3
        vitalCpu = mkStatRow(self, 52, 0, cw, "cpu", "CPU")
        vitalMem = mkStatRow(self, 52, cw + 12, cw, "memorychip", "RAM")
        vitalUp  = mkStatRow(self, 52, (cw + 12) * 2, cw, "clock.arrow.circlepath", "Veille")

        let b1 = GlassButton(frame: NSRect(x: 0, y: 0, width: cw, height: 40),
                             title: "Actualiser", icon: "arrow.clockwise")
        b1.onClick = { [weak self] _ in self?.refresh(animated: true) }
        let b2 = GlassButton(frame: NSRect(x: cw + 12, y: 0, width: cw, height: 40),
                             title: "Volumes", icon: "folder.fill")
        b2.onClick = { _ in NSWorkspace.shared.open(URL(fileURLWithPath: "/Volumes")) }
        let b3 = GlassButton(frame: NSRect(x: (cw + 12) * 2, y: 0, width: cw, height: 40),
                             title: "Tout éjecter", icon: "eject.fill")
        b3.onClick = { [weak self] _ in
            guard let s = self else { return }
            s.onEject?(s.ejectAll())
        }
        [b1, b2, b3].forEach { addSubview($0) }
    }

    func stepRing() { ring.step() }

    func refresh(animated: Bool = false) {
        let vols = scanVolumes()

        if let boot = vols.first(where: { $0.isBoot }) ?? vols.first {
            let pct = Int((boot.usedRatio * 100).rounded())
            ring.set(pct, caption: "occupé", animated: animated)
            tileFree.set(formatBytes(boot.free), hint: "\(boot.freePercent) % encore libres")
            tileUsed.set(formatBytes(boot.used), hint: "\(pct) % du disque")
            tileTotal.set(formatBytes(boot.total), hint: "disque de démarrage")
            hero.set(subtitle: "\(boot.name) · \(formatBytes(boot.free)) encore disponibles",
                     trailing: boot.freePercent <= 10 ? "Disque saturé" : "")
        }
        let ext = vols.filter { !$0.isBoot }.count
        tileCount.set("\(vols.count)", hint: ext == 0 ? "aucun volume externe" : "\(ext) en plus du démarrage")

        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        ThemeRegistry.shared.prune()

        let rowH: CGFloat = 64
        let W = scroll.bounds.width - 6
        let totalH = max(scroll.bounds.height, CGFloat(vols.count) * rowH)
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: totalH)

        for (i, v) in vols.enumerated() {
            let y = totalH - CGFloat(i + 1) * rowH + 6
            let row = mkCard(listHost, NSRect(x: 0, y: y, width: W, height: rowH - 10), radius: 12)
            rowViews.append(row)
            let rh = row.bounds.height           // 54

            // Colonne droite : pourcentage puis bouton, largeurs mesurées
            let pctTxt = "\(Int((v.usedRatio * 100).rounded())) %"
            let pctW = textWidth(pctTxt, size: 14, weight: .bold, mono: true) + 10
            let ejectable = v.isRemovable || (!v.isInternal && !v.isBoot)
            let btnTitle = ejectable ? "Éjecter" : "Ouvrir"
            let btnW = max(74, textWidth(btnTitle, size: 11.5, weight: .semibold) + 26)
            let rightEdge = W - 12 - btnW - 10 - pctW

            // Ligne 1 : icône, nom, étiquette de type
            let iv = mkIcon(row, v.icon, x: 13, y: rh - 22, size: 15, alpha: 0.6)
            if v.isRemovable { iv.contentTintColor = TH.accent }

            let tagW = textWidth(v.tag, size: 9.5, weight: .semibold) + 16
            let nameMax = rightEdge - 38 - tagW - 14
            var name = v.name
            if textWidth(name, size: 12.5, weight: .semibold) > nameMax {
                while name.count > 4 && textWidth(name + "…", size: 12.5, weight: .semibold) > nameMax {
                    name.removeLast()
                }
                name += "…"
            }
            let nameW = textWidth(name, size: 12.5, weight: .semibold) + 10
            row.addSubview(mkLabel(name, NSRect(x: 37, y: rh - 22, width: nameW, height: 18), 12.5, .semibold))

            let tagRect = NSRect(x: 37 + nameW + 4, y: rh - 21, width: tagW, height: 16)
            let tagView = mkCard(row, tagRect, radius: 8, alpha: 0.09)
            tagView.addSubview(mkLabel(v.tag, NSRect(x: 0, y: 0, width: tagW, height: 14),
                                       9.5, .semibold, alpha: 0.55, .center))

            // Ligne 2 : barre puis volumétrie, bien séparées du nom
            let bar = ProgressBar(frame: NSRect(x: 37, y: 23, width: rightEdge - 45, height: 5))
            bar.value = CGFloat(v.usedRatio)
            bar.tint = v.freePercent <= 10 ? dangerColor : (v.freePercent <= 20 ? warnColor : nil)
            row.addSubview(bar)

            let detail = "\(formatBytes(v.free)) libres sur \(formatBytes(v.total))"
            row.addSubview(mkLabel(detail, NSRect(x: 37, y: 3, width: rightEdge - 45, height: 15),
                                   10.5, .regular, alpha: 0.5))

            row.addSubview(mkLabel(pctTxt, NSRect(x: rightEdge, y: rh / 2 - 9, width: pctW, height: 19),
                                   14, .bold, alpha: 1, .right, mono: true))

            let action = GlassButton(frame: NSRect(x: W - 12 - btnW, y: rh / 2 - 16, width: btnW, height: 32),
                                     title: btnTitle, compact: true)
            let url = v.url
            if ejectable {
                action.onClick = { [weak self] _ in self?.eject(url) }
            } else {
                action.onClick = { _ in NSWorkspace.shared.open(url) }
            }
            row.addSubview(action)
        }

        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        vitalCpu.stringValue = String(format: "%.2f", l[0])
        let m = memoryStats()
        vitalMem.stringValue = m.total > 0 ? String(format: "%.1f Go", m.used / 1_073_741_824) : "—"
        vitalUp.stringValue = formatUptime(ProcessInfo.processInfo.systemUptime)
    }

    /// Éjecte tous les volumes amovibles ou réseau. Renvoie un compte rendu.
    @discardableResult
    func ejectAll() -> String {
        let candidates = scanVolumes().filter { !$0.isBoot && ($0.isRemovable || !$0.isInternal) }
        guard !candidates.isEmpty else { return "Aucun disque externe monté." }
        var done: [String] = []
        var failed: [String] = []
        for v in candidates {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
                done.append(v.name)
            } catch {
                failed.append(v.name)
            }
        }
        refresh()
        if done.isEmpty { return "Éjection refusée : \(failed.joined(separator: ", ")) est encore utilisé." }
        var msg = "Éjecté : \(done.joined(separator: ", "))"
        if !failed.isEmpty { msg += " · encore occupé : \(failed.joined(separator: ", "))" }
        return msg
    }

    private func eject(_ url: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            onEject?("\(url.lastPathComponent) éjecté proprement")
        } catch {
            onEject?("Impossible d'éjecter \(url.lastPathComponent)")
        }
        refresh()
    }
}
