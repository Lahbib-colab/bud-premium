import Cocoa

// ═══════════════════════════════════════════════════════════
//  Rappels et alarmes
//  Stockage local : reminders.json. L'alarme sonne dans le notch,
//  avec report ou validation, même si aucune autre app n'est ouverte.
// ═══════════════════════════════════════════════════════════

struct Reminder: Codable {
    var id: String
    var title: String
    var fireAt: TimeInterval
    var repeatMode: Int        // 0 aucun · 1 chaque jour · 2 chaque semaine
    var done: Bool

    var date: Date { Date(timeIntervalSince1970: fireAt) }
    var repeatLabel: String {
        switch repeatMode {
        case 1: return "chaque jour"
        case 2: return "chaque semaine"
        default: return "une fois"
        }
    }
    var whenLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        if Calendar.current.isDateInToday(date) { f.dateFormat = "'aujourd''hui à' HH'h'mm" }
        else if Calendar.current.isDateInTomorrow(date) { f.dateFormat = "'demain à' HH'h'mm" }
        else { f.dateFormat = "EEEE d MMMM 'à' HH'h'mm" }
        return f.string(from: date)
    }
}

final class ReminderStore {
    static let shared = ReminderStore()
    private let url = budSupportDir.appendingPathComponent("reminders.json")
    private(set) var items: [Reminder] = []

    init() { load() }

    func load() {
        if let d = try? Data(contentsOf: url),
           let r = try? JSONDecoder().decode([Reminder].self, from: d) { items = r }
        sort()
    }
    private func sort() { items.sort { $0.fireAt < $1.fireAt } }

    func save() {
        sort()
        let e = JSONEncoder()
        e.outputFormatting = .prettyPrinted
        if let d = try? e.encode(items) { try? d.write(to: url, options: .atomic) }
    }

    @discardableResult
    func add(title: String, at date: Date, repeatMode: Int = 0) -> Reminder {
        let r = Reminder(id: UUID().uuidString, title: title,
                         fireAt: date.timeIntervalSince1970, repeatMode: repeatMode, done: false)
        items.append(r)
        save()
        return r
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func complete(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].repeatMode == 0 {
            items.remove(at: i)
        } else {
            let step: TimeInterval = items[i].repeatMode == 1 ? 86400 : 604800
            var next = items[i].fireAt
            while next <= Date().timeIntervalSince1970 { next += step }
            items[i].fireAt = next
            items[i].done = false
        }
        save()
    }

    func snooze(id: String, minutes: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].fireAt = Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970
        items[i].done = false
        save()
    }

    /// Le premier rappel dont l'heure est passée.
    func due() -> Reminder? {
        let now = Date().timeIntervalSince1970
        return items.first { !$0.done && $0.fireAt <= now }
    }

    func next() -> Reminder? {
        let now = Date().timeIntervalSince1970
        return items.first { $0.fireAt > now }
    }
}

/// Analyse une formulation française : « dans 20 minutes », « à 18h30 », « demain à 9h ».
enum ReminderParser {
    static func parse(_ raw: String) -> (title: String, date: Date)? {
        let lower = raw.lowercased()
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        var when: Date?
        var cut: String?

        if let r = lower.range(of: #"dans\s+(\d+)\s*(min|minute|minutes|h|heure|heures)"#,
                               options: .regularExpression) {
            let frag = String(lower[r])
            let n = Int(frag.filter { $0.isNumber }) ?? 0
            let isHour = frag.contains("h") && !frag.contains("min")
            when = Date().addingTimeInterval(Double(n) * (isHour ? 3600 : 60))
            cut = frag
        } else if let r = lower.range(of: #"(\d{1,2})\s*(h|:)\s*(\d{2})?"#, options: .regularExpression) {
            let frag = String(lower[r])
            let nums = frag.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let hour = nums.first, hour < 24 else { return nil }
            let minute = nums.count > 1 ? min(59, nums[1]) : 0
            var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            c.hour = hour
            c.minute = minute
            var d = Calendar.current.date(from: c) ?? Date()
            if lower.contains("demain") { d = d.addingTimeInterval(86400) }
            else if d < Date() { d = d.addingTimeInterval(86400) }
            when = d
            cut = frag
        } else if lower.contains("demain") {
            var c = Calendar.current.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86400))
            c.hour = 9
            c.minute = 0
            when = Calendar.current.date(from: c)
            cut = "demain"
        }

        guard let date = when else { return nil }

        // Titre : on retire les mots de commande et l'expression temporelle
        var title = raw
        for m in ["rappelle-moi de", "rappelle moi de", "rappelle-moi", "rappelle moi",
                  "rappel :", "rappel:", "n'oublie pas de", "pense à", "pense a"] {
            if let r = title.lowercased().range(of: m) {
                title = String(title[r.upperBound...])
                break
            }
        }
        if let c = cut, let r = title.lowercased().range(of: c) {
            title.removeSubrange(r)
        }
        for w in [" demain", "demain ", " à ", " a "] {
            title = title.replacingOccurrences(of: w, with: " ")
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Rappel" }
        return (title, date)
    }
}

final class RemindersPanelView: NSView {
    private let hero: HeroHeader
    private var nextTile: StatTile!, countTile: StatTile!
    private let scroll = NSScrollView(frame: .zero)
    private let listHost = NSView(frame: .zero)
    private var rows: [NSView] = []
    private var quickField: NSTextField!

    var onStatus: ((String) -> Void)?
    var onChanged: (() -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Rappels", subtitle: "Une alarme dans le notch, même app fermée.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height

        nextTile = StatTile(frame: NSRect(x: W - 330, y: H - 86, width: 190, height: 78),
                            caption: "Prochain", hint: "—")
        countTile = StatTile(frame: NSRect(x: W - 130, y: H - 86, width: 120, height: 78),
                             caption: "En attente", hint: "rappels actifs")
        [nextTile, countTile].forEach { addSubview($0) }

        mkSection(self, H - 116, W, "Ajouter")
        quickField = NSTextField(frame: NSRect(x: 0, y: H - 156, width: W - 230, height: 34))
        quickField.placeholderString = "Sortir les poubelles à 19h30 · dans 20 minutes · demain"
        quickField.font = NSFont.systemFont(ofSize: 12.5)
        quickField.target = self
        quickField.action = #selector(addFromField)
        addSubview(quickField)

        let bAdd = GlassButton(frame: NSRect(x: W - 222, y: H - 158, width: 106, height: 38),
                               title: "Ajouter", icon: "plus", prominent: true)
        bAdd.onClick = { [weak self] _ in self?.addFromField() }
        let bIn15 = GlassButton(frame: NSRect(x: W - 108, y: H - 158, width: 108, height: 38),
                                title: "Dans 15 min", icon: "clock", compact: true)
        bIn15.onClick = { [weak self] _ in
            guard let s = self else { return }
            let t = s.quickField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            s.create(title: t.isEmpty ? "Rappel" : t, date: Date().addingTimeInterval(900), repeatMode: 0)
        }
        [bAdd, bIn15].forEach { addSubview($0) }

        mkSection(self, H - 184, W, "À venir")
        scroll.frame = NSRect(x: 0, y: 56, width: W, height: H - 250)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        addSubview(mkLabel("Écrivez l'heure dans la phrase : BUD la comprend et garde le reste comme titre.",
                           NSRect(x: 0, y: 12, width: W, height: 16), 11, .regular, alpha: 0.33, .center))
    }

    @objc private func addFromField() {
        let raw = quickField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if let p = ReminderParser.parse(raw) {
            create(title: p.title, date: p.date, repeatMode: 0)
        } else {
            create(title: raw, date: Date().addingTimeInterval(3600), repeatMode: 0)
            onStatus?("Heure non comprise : rappel posé dans une heure.")
        }
    }

    private func create(title: String, date: Date, repeatMode: Int) {
        let r = ReminderStore.shared.add(title: title, at: date, repeatMode: repeatMode)
        quickField.stringValue = ""
        refresh()
        onChanged?()
        onStatus?("Rappel « \(r.title) » \(r.whenLabel)")
    }

    func refresh() {
        let items = ReminderStore.shared.items
        countTile.set("\(items.count)", hint: items.isEmpty ? "aucun rappel" : "rappels actifs")
        if let n = ReminderStore.shared.next() {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = "HH'h'mm"
            nextTile.set(f.string(from: n.date), hint: n.title)
            hero.set(subtitle: "Prochain : \(n.title), \(n.whenLabel).", trailing: "\(items.count)")
        } else {
            nextTile.set("—", hint: "rien de prévu")
            hero.set(subtitle: "Aucun rappel programmé.", trailing: "")
        }

        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        ThemeRegistry.shared.prune()

        let W = scroll.bounds.width - 6
        let rowH: CGFloat = 56
        let totalH = max(scroll.bounds.height, CGFloat(items.count) * rowH)
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: totalH)

        let now = Date().timeIntervalSince1970
        for (i, r) in items.enumerated() {
            let y = totalH - CGFloat(i + 1) * rowH + 6
            let row = mkCard(listHost, NSRect(x: 0, y: y, width: W, height: rowH - 10), radius: 12)
            rows.append(row)
            let rh = row.bounds.height
            let late = r.fireAt <= now

            let iv = mkIcon(row, late ? "bell.badge.fill" : "bell.fill", x: 14, y: rh / 2 - 8, size: 14, alpha: 0.55)
            if late { iv.contentTintColor = warnColor }

            row.addSubview(mkFitLabel(r.title, x: 40, y: rh - 28, 12.5, .semibold))
            row.addSubview(mkFitLabel("\(r.whenLabel) · \(r.repeatLabel)", x: 40, y: 8, 10.5, .regular, alpha: 0.45))

            let bDone = GlassButton(frame: NSRect(x: W - 176, y: rh / 2 - 16, width: 82, height: 32),
                                    title: "Terminé", compact: true)
            bDone.onClick = { [weak self] _ in
                ReminderStore.shared.complete(id: r.id)
                self?.refresh()
                self?.onChanged?()
            }
            let bDel = GlassButton(frame: NSRect(x: W - 88, y: rh / 2 - 16, width: 80, height: 32),
                                   title: "Supprimer", compact: true)
            bDel.destructive = true
            bDel.onClick = { [weak self] _ in
                ReminderStore.shared.remove(id: r.id)
                self?.refresh()
                self?.onChanged?()
            }
            [bDone, bDel].forEach { row.addSubview($0) }
        }
    }
}
