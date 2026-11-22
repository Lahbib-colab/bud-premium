import Cocoa

// ═══════════════════════════════════════════════════════════
//  Vérification de mise à jour
//  BUD interroge un petit fichier JSON hébergé où vous voulez :
//  { "version": "14.1", "notes": "…", "url": "https://…/Installer.command" }
// ═══════════════════════════════════════════════════════════

struct UpdateInfo {
    let version: String
    let notes: String
    let url: String
}

enum BudUpdater {

    static let defaultChannel =
        "https://raw.githubusercontent.com/Lahbib-colab/bud-premium/main/version.json"

    /// Compare « 14.10 » et « 14.9 » correctement, segment par segment.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func check(_ channel: String, done: @escaping (UpdateInfo?, String?) -> Void) {
        guard let url = URL(string: channel) else {
            done(nil, "adresse de canal invalide")
            return
        }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let e = err { done(nil, e.localizedDescription); return }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    done(nil, "canal introuvable (code \(http.statusCode))")
                    return
                }
                guard let d = data,
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let v = j["version"] as? String else {
                    done(nil, "fichier de version illisible")
                    return
                }
                done(UpdateInfo(version: v,
                                notes: j["notes"] as? String ?? "",
                                url: j["url"] as? String ?? ""), nil)
            }
        }.resume()
    }
}

/// Carte « À propos » : version, signature, et vérification animée.
final class UpdateCardView: NSView {

    enum Phase { case idle, checking, upToDate, available, failed }

    private var phase: Phase = .idle
    private var spin: CGFloat = 0
    private var pop: CGFloat = 0           // rebond du résultat
    private var pulse: CGFloat = 0
    private var timer: Timer?
    private var message = "Vérifiez si une nouvelle version existe."
    private var found: UpdateInfo?
    private var actionBtn: GlassButton!
    private var channelBtn: GlassButton!

    var channel: () -> String = { BudUpdater.defaultChannel }
    var onChannelEdit: (() -> Void)?
    var onStatus: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        actionBtn = GlassButton(frame: NSRect(x: W - 232, y: H / 2 - 18, width: 118, height: 36),
                                title: "Vérifier", icon: "arrow.triangle.2.circlepath", compact: true)
        actionBtn.onClick = { [weak self] _ in self?.primaryAction() }
        channelBtn = GlassButton(frame: NSRect(x: W - 106, y: H / 2 - 18, width: 98, height: 36),
                                 title: "Canal", icon: "antenna.radiowaves.left.and.right", compact: true)
        channelBtn.onClick = { [weak self] _ in self?.onChannelEdit?() }
        [actionBtn, channelBtn].forEach { addSubview($0) }
    }

    private func startTicking() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] tm in
            guard let s = self else { tm.invalidate(); return }
            s.spin += s.phase == .checking ? 0.22 : 0
            s.pulse += 0.06
            if s.pop > 0 { s.pop = max(0, s.pop - 0.035) }
            if s.phase != .checking && s.pop == 0 {
                tm.invalidate()
                s.timer = nil
            }
            s.needsDisplay = true
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func primaryAction() {
        if phase == .available, let f = found, let u = URL(string: f.url), !f.url.isEmpty {
            NSWorkspace.shared.open(u)
            onStatus?("Téléchargement de la version \(f.version)")
            return
        }
        check()
    }

    func check(silent: Bool = false) {
        guard phase != .checking else { return }
        phase = .checking
        pop = 0
        message = "Interrogation du canal de mise à jour…"
        actionBtn.title = "Vérification"
        actionBtn.enabledFlag = false
        startTicking()
        needsDisplay = true

        BudUpdater.check(channel()) { [weak self] info, err in
            guard let s = self else { return }
            s.actionBtn.enabledFlag = true
            s.pop = 1
            s.startTicking()
            if let e = err {
                s.phase = .failed
                s.message = "Canal injoignable : \(e)"
                s.actionBtn.title = "Réessayer"
                if !silent { s.onStatus?("Mise à jour : canal injoignable") }
            } else if let i = info, BudUpdater.isNewer(i.version, than: budVersion) {
                s.phase = .available
                s.found = i
                s.message = "Version \(i.version) disponible" + (i.notes.isEmpty ? "" : " · \(i.notes)")
                s.actionBtn.title = "Télécharger"
                s.actionBtn.iconName = "arrow.down.circle.fill"
                s.actionBtn.prominent = true
                s.onStatus?("BUD \(i.version) disponible")
            } else {
                s.phase = .upToDate
                s.message = "BUD \(budVersion) est à jour."
                s.actionBtn.title = "Vérifier"
                s.actionBtn.iconName = "arrow.triangle.2.circlepath"
                s.actionBtn.prominent = false
                if !silent { s.onStatus?("BUD est à jour") }
            }
            s.needsDisplay = true
        }
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds
        let card = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        TH.fill(0.05).setFill()
        card.fill()
        TH.fill(0.08).setStroke()
        card.lineWidth = 1
        card.stroke()

        // Pastille animée à gauche
        let c = NSPoint(x: r.minX + 40, y: r.midY)
        let radius: CGFloat = 19 + (phase == .checking ? CGFloat(sin(pulse * 2)) * 1.2 : 0)
        let tint: NSColor = phase == .available ? warnColor
                          : (phase == .failed ? dangerColor : TH.accent)

        tint.withAlphaComponent(0.14 + (pop * 0.18)).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()

        if phase == .checking {
            // Arc qui tourne
            let arc = NSBezierPath()
            let start = spin * 57.3
            arc.appendArc(withCenter: c, radius: radius - 3,
                          startAngle: start, endAngle: start + 250)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            tint.setStroke()
            arc.stroke()
        } else {
            let scale = 1 + pop * 0.35
            let icon = phase == .available ? "arrow.down.circle.fill"
                     : (phase == .failed ? "exclamationmark.triangle.fill"
                        : (phase == .upToDate ? "checkmark.circle.fill" : "sparkles"))
            drawSymbol(icon, center: c, size: 20 * scale, weight: .semibold, color: tint)
        }

        // Textes
        let textW = r.width - 80 - 240
        drawString("BUD Premium \(budVersion)",
                   in: NSRect(x: r.minX + 72, y: r.midY + 3, width: textW, height: 20),
                   size: 13.5, weight: .bold, color: TH.text)
        drawString(message, in: NSRect(x: r.minX + 72, y: r.midY - 17, width: textW, height: 18),
                   size: 11, weight: .medium, color: TH.dim(0.5))
    }
}
