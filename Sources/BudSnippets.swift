import Cocoa
import Carbon.HIToolbox

// ═══════════════════════════════════════════════════════════
//  Dictée rapide, snippets et notes éclair
//  Persistance : snippets.json + quicknotes.md dans Application Support
// ═══════════════════════════════════════════════════════════

struct Snippet: Codable {
    var title: String
    var body: String
}

final class SnippetStore {
    static let shared = SnippetStore()
    private let url = budSupportDir.appendingPathComponent("snippets.json")
    private(set) var items: [Snippet] = []

    init() { load() }

    func load() {
        if let d = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode([Snippet].self, from: d) {
            items = s
        } else {
            items = [
                Snippet(title: "Signature", body: "Bien à toi,\nLahbib"),
                Snippet(title: "Disponibilités", body: "Je suis disponible cette semaine, dis-moi ce qui t'arrange."),
                Snippet(title: "Relance douce", body: "Petit rappel au sujet de ma demande précédente, merci d'avance.")
            ]
            save()
        }
    }

    func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? e.encode(items) { try? d.write(to: url, options: .atomic) }
    }

    func add(_ s: Snippet) { items.insert(s, at: 0); save() }
    func remove(at i: Int) { guard items.indices.contains(i) else { return }; items.remove(at: i); save() }
    func update(_ i: Int, _ s: Snippet) { guard items.indices.contains(i) else { return }; items[i] = s; save() }
}

/// Journal des captures rapides, en Markdown lisible hors de l'app.
final class QuickNotesStore {
    static let shared = QuickNotesStore()
    let url = budSupportDir.appendingPathComponent("quicknotes.md")

    func append(_ text: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let entry = "\n- **\(f.string(from: Date()))** — \(text.replacingOccurrences(of: "\n", with: "  \n  "))\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(entry.data(using: .utf8)!)
            try? h.close()
        } else {
            let header = "# Notes rapides BUD\n"
            try? (header + entry).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func recent(_ n: Int) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- **") }
            .suffix(n).reversed()
            .map { $0.replacingOccurrences(of: "- **", with: "").replacingOccurrences(of: "** — ", with: " · ") }
    }
}

// ── Collage dans l'app active (nécessite l'accès Accessibilité) ──

func accessibilityGranted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

@discardableResult
func pasteIntoFrontApp() -> Bool {
    guard accessibilityGranted(prompt: false) else { return false }
    guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
    let v = CGKeyCode(kVK_ANSI_V)
    let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    return true
}

/// Tente de déclencher la dictée système (raccourci « appuyer deux fois sur Fn »).
@discardableResult
func triggerSystemDictation() -> Bool {
    guard accessibilityGranted(prompt: true) else { return false }
    guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
    let fn = CGKeyCode(kVK_Function)
    for _ in 0..<2 {
        CGEvent(keyboardEventSource: src, virtualKey: fn, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: fn, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    return true
}

// ── Fenêtre de capture rapide ──

final class CaptureWindow: NSPanel, NSTextViewDelegate {
    private var textView: NSTextView!
    private var hintLabel: NSTextField!
    var onSubmit: ((String, CaptureTarget) -> Void)?

    enum CaptureTarget { case clipboard, note, snippet }

    init() {
        let size = NSSize(width: 520, height: 196)
        let sf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let origin = NSPoint(x: sf.midX - size.width / 2, y: sf.midY - size.height / 2 + 80)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        build(size)
    }

    override var canBecomeKey: Bool { true }

    private func build(_ size: NSSize) {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        contentView = host

        let blur = NSVisualEffectView(frame: host.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.masksToBounds = true
        host.addSubview(blur)

        let bg = NSView(frame: host.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.backgroundColor = TH.base.withAlphaComponent(TH.glass == 0 ? 1 : 0.55).cgColor
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = TH.fill(0.12).cgColor
        host.addSubview(bg)

        host.addSubview(mkLabel("Capture rapide", NSRect(x: 22, y: size.height - 36, width: 300, height: 20), 14, .bold))
        hintLabel = mkLabel("⏎ copier · ⇧⏎ note · Échap fermer",
                            NSRect(x: size.width - 262, y: size.height - 34, width: 240, height: 16),
                            10.5, .medium, alpha: 0.4, .right)
        host.addSubview(hintLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 60, width: size.width - 40, height: size.height - 108))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true

        let big: CGFloat = 1_000_000
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width - 40, height: size.height - 108))
        tv.minSize = NSSize(width: 0, height: size.height - 108)
        tv.maxSize = NSSize(width: big, height: big)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: size.width - 40, height: big)
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = true
        tv.backgroundColor = TH.fill(0.07)
        tv.textColor = TH.text
        tv.insertionPointColor = TH.text
        tv.font = NSFont.systemFont(ofSize: 14)
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.delegate = self
        scroll.documentView = tv
        textView = tv
        host.addSubview(scroll)

        let bw = (size.width - 52) / 4
        let b1 = GlassButton(frame: NSRect(x: 20, y: 16, width: bw, height: 34),
                             title: "Copier", icon: "doc.on.doc.fill", prominent: true, compact: true)
        b1.onClick = { [weak self] _ in self?.submit(.clipboard) }
        let b2 = GlassButton(frame: NSRect(x: 24 + bw, y: 16, width: bw, height: 34),
                             title: "Note", icon: "note.text", compact: true)
        b2.onClick = { [weak self] _ in self?.submit(.note) }
        let b3 = GlassButton(frame: NSRect(x: 28 + bw * 2, y: 16, width: bw, height: 34),
                             title: "Snippet", icon: "text.badge.plus", compact: true)
        b3.onClick = { [weak self] _ in self?.submit(.snippet) }
        let b4 = GlassButton(frame: NSRect(x: 32 + bw * 3, y: 16, width: bw, height: 34),
                             title: "Dicter", icon: "mic.fill", compact: true)
        b4.onClick = { [weak self] _ in self?.dictate() }
        [b1, b2, b3, b4].forEach { host.addSubview($0) }
    }

    func present() {
        textView.string = ""
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(textView)
    }

    private func dictate() {
        makeFirstResponder(textView)
        if !triggerSystemDictation() {
            hintLabel.stringValue = "Autorise BUD dans Confidentialité → Accessibilité"
        } else {
            hintLabel.stringValue = "Parle… (ou appuie deux fois sur Fn)"
        }
    }

    private func submit(_ target: CaptureTarget) {
        let t = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        orderOut(nil)
        guard !t.isEmpty else { return }
        onSubmit?(t, target)
    }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            submit(NSEvent.modifierFlags.contains(.shift) ? .note : .clipboard)
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            orderOut(nil)
            return true
        }
        return false
    }
}

/// Panneau Dictée & snippets.
final class SnippetsPanelView: NSView {
    private let hero: HeroHeader
    private var rows: [NSView] = []
    private let listHost = NSView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var statusLabel: NSTextField!

    var onStatus: ((String) -> Void)?
    var onCapture: (() -> Void)?

    override init(frame: NSRect) {
        hero = HeroHeader(frame: NSRect(x: 0, y: frame.height - 92, width: frame.width, height: 92),
                          title: "Dictée & snippets",
                          subtitle: "⌘⌥D ouvre la capture, où que vous soyez.")
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let W = bounds.width, H = bounds.height
        addSubview(hero)

        let bCap = GlassButton(frame: NSRect(x: 0, y: H - 148, width: W * 0.54 - 6, height: 44),
                               title: "Capture rapide  ⌘⌥D", icon: "mic.fill", prominent: true)
        bCap.onClick = { [weak self] _ in self?.onCapture?() }
        let bNew = GlassButton(frame: NSRect(x: W * 0.54 + 6, y: H - 148, width: W * 0.46 - 6, height: 44),
                               title: "Nouveau snippet", icon: "plus")
        bNew.onClick = { [weak self] _ in self?.editSnippet(nil) }
        [bCap, bNew].forEach { addSubview($0) }

        mkSection(self, H - 174, W, "Snippets enregistrés")

        scroll.frame = NSRect(x: 0, y: 44, width: W, height: H - 226)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = listHost
        addSubview(scroll)

        statusLabel = mkLabel("Un clic copie le snippet dans le presse-papiers.",
                              NSRect(x: 0, y: 8, width: W, height: 18), 11, .regular, alpha: 0.4, .center)
        addSubview(statusLabel)
    }

    func setStatus(_ s: String) { statusLabel.stringValue = s }

    func refresh() {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        ThemeRegistry.shared.prune()

        let items = SnippetStore.shared.items
        hero.set(trailing: items.isEmpty ? "" : "\(items.count) snippets")

        let W = scroll.bounds.width - 6
        let rowH: CGFloat = 62
        let totalH = max(scroll.bounds.height, CGFloat(items.count) * rowH)
        listHost.frame = NSRect(x: 0, y: 0, width: W, height: totalH)

        for (i, s) in items.enumerated() {
            let y = totalH - CGFloat(i + 1) * rowH + 6
            let row = mkCard(listHost, NSRect(x: 0, y: y, width: W, height: rowH - 10), radius: 12)
            rows.append(row)
            let rh = row.bounds.height

            mkIcon(row, "text.quote", x: 14, y: rh - 28, size: 13, alpha: 0.55)
            row.addSubview(mkFitLabel(s.title, x: 38, y: rh - 28, 12.5, .semibold))

            let preview = s.body.replacingOccurrences(of: "\n", with: " · ")
            let prev = mkLabel(String(preview.prefix(90)), NSRect(x: 38, y: 8, width: W - 200, height: 15),
                               10.5, .regular, alpha: 0.42)
            row.addSubview(prev)

            let copy = GlassButton(frame: NSRect(x: W - 190, y: 10, width: 76, height: 32),
                                   title: "Copier", compact: true)
            copy.idx = i
            copy.onClick = { [weak self] b in self?.copySnippet(b.idx) }
            let edit = GlassButton(frame: NSRect(x: W - 108, y: 10, width: 54, height: 32),
                                   title: "", icon: "pencil", compact: true)
            edit.idx = i
            edit.onClick = { [weak self] b in self?.editSnippet(b.idx) }
            let del = GlassButton(frame: NSRect(x: W - 48, y: 10, width: 44, height: 32),
                                  title: "", icon: "trash", compact: true)
            del.destructive = true
            del.idx = i
            del.onClick = { [weak self] b in
                SnippetStore.shared.remove(at: b.idx)
                self?.refresh()
            }
            [copy, edit, del].forEach { row.addSubview($0) }
        }
    }

    private func copySnippet(_ i: Int) {
        guard SnippetStore.shared.items.indices.contains(i) else { return }
        let s = SnippetStore.shared.items[i]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.body, forType: .string)
        onStatus?("« \(s.title) » copié dans le presse-papiers")
    }

    private func editSnippet(_ i: Int?) {
        let existing = i.flatMap { SnippetStore.shared.items.indices.contains($0) ? SnippetStore.shared.items[$0] : nil }
        let a = NSAlert()
        a.messageText = existing == nil ? "Nouveau snippet" : "Modifier le snippet"
        a.informativeText = "Un titre court, puis le contenu à coller."
        a.addButton(withTitle: "Enregistrer")
        a.addButton(withTitle: "Annuler")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        let titleField = NSTextField(frame: NSRect(x: 0, y: 110, width: 380, height: 24))
        titleField.placeholderString = "Titre"
        titleField.stringValue = existing?.title ?? ""
        container.addSubview(titleField)

        let sc = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 100))
        sc.hasVerticalScroller = true
        sc.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 100))
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 12.5)
        tv.string = existing?.body ?? ""
        sc.documentView = tv
        container.addSubview(sc)
        a.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = tv.string
        guard !title.isEmpty || !body.isEmpty else { return }
        let s = Snippet(title: title.isEmpty ? String(body.prefix(24)) : title, body: body)
        if let idx = i { SnippetStore.shared.update(idx, s) } else { SnippetStore.shared.add(s) }
        refresh()
    }
}
