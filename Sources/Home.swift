import AppKit

/// The Home tab: start a new workbook, or pick one you've saved. Workbooks open as tabs beside it.
final class HomeWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let tabbingIdentifier = "MySheets"
    private(set) static var current: HomeWindowController?

    let root = RootView()
    private let header = BarView(color: Palette.accent)
    private let titleLabel = NSTextField(labelWithString: "MySheets")
    let search = NSTextField()
    private let magnifier = NSImageView()
    private let scroll = NSScrollView()
    private let content = HomeContent()
    private(set) var newTile: Tile!
    private(set) var openTile: Tile!
    private let heading = NSTextField(labelWithString: "Your workbooks")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var entries: [Library.Entry] = []
    private(set) var cards: [WorkbookCard] = []
    private var reloadQueued = false

    /// Opens the Home tab, or brings it forward. A new Home tab goes first in `host`'s row of tabs.
    @discardableResult
    static func show(beside host: NSWindow? = nil) -> HomeWindowController {
        if let h = current, let w = h.window {
            h.reload()
            w.tabGroup?.selectedWindow = w
            w.makeKeyAndOrderFront(nil)
            return h
        }
        let h = HomeWindowController()
        current = h
        let w = h.window!
        if let host, host.isVisible, host.tabbingIdentifier == tabbingIdentifier {
            (host.tabGroup?.windows.first ?? host).addTabbedWindow(w, ordered: .below)
        }
        w.makeKeyAndOrderFront(nil)
        return h
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Home"
        window.minSize = NSSize(width: 700, height: 440)
        window.appearance = NSAppearance(named: .aqua)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = root
        window.delegate = self
        let tabTitle = NSMutableAttributedString()
        if let house = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil) {
            let a = NSTextAttachment()
            a.image = house
            tabTitle.append(NSAttributedString(attachment: a))
            tabTitle.append(NSAttributedString(string: " "))
        }
        tabTitle.append(NSAttributedString(string: "Home"))
        window.tab.attributedTitle = tabTitle
        build()
        window.center()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: Library.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        root.onLayout = { [unowned self] in self.layoutViews() }
        header.bottomLine = false
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .white
        header.addSubview(titleLabel)
        root.addSubview(header)
        search.font = .systemFont(ofSize: 16)
        search.placeholderString = "Find a workbook"
        search.bezelStyle = .roundedBezel
        search.focusRingType = .none
        search.delegate = self
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        magnifier.contentTintColor = NSColor(white: 0.35, alpha: 1)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.chrome
        scroll.documentView = content
        root.addSubview(scroll)

        newTile = Tile(title: "New workbook", symbol: "plus", filled: true) { NSDocumentController.shared.newDocument(nil) }
        openTile = Tile(title: "Open a file…", symbol: "folder", filled: false) { NSDocumentController.shared.openDocument(nil) }
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.textColor = NSColor(white: 0.15, alpha: 1)
        emptyLabel.font = .systemFont(ofSize: 17)
        emptyLabel.textColor = NSColor(white: 0.4, alpha: 1)
        for v in [newTile!, openTile!, heading, magnifier, search, emptyLabel] as [NSView] { content.addSubview(v) }
    }

    private func layoutViews() {
        let w = root.bounds.width, h = root.bounds.height
        header.frame = NSRect(x: 0, y: 0, width: w, height: 64)
        titleLabel.frame = NSRect(x: 36, y: 15, width: 300, height: 34)
        scroll.frame = NSRect(x: 0, y: 64, width: w, height: max(0, h - 64))
        layoutContent()
    }

    private func layoutContent() {
        let w = scroll.contentSize.width
        let pad: CGFloat = 36, gap: CGFloat = 24
        let size = WorkbookCard.size
        var y: CGFloat = 28
        newTile.frame = NSRect(x: pad, y: y, width: size.width, height: 96)
        openTile.frame = NSRect(x: pad + size.width + gap, y: y, width: size.width, height: 96)
        y += 96 + 36
        heading.frame = NSRect(x: pad, y: y, width: 260, height: 30)
        // The search box lines up with the right edge of the last column of cards.
        let colsWide = max(1, Int((w - 2 * pad + gap) / (size.width + gap)))
        let right = max(pad + 260 + 300, pad + CGFloat(colsWide) * (size.width + gap) - gap)
        search.frame = NSRect(x: right - 260, y: y, width: 260, height: 30)
        magnifier.frame = NSRect(x: right - 292, y: y + 3, width: 24, height: 24)
        y += 30 + 14
        emptyLabel.frame = NSRect(x: pad, y: y, width: max(0, w - 2 * pad), height: 50)
        emptyLabel.isHidden = !cards.isEmpty
        let cols = max(1, Int((w - 2 * pad + gap) / (size.width + gap)))
        for (i, c) in cards.enumerated() {
            c.frame = NSRect(x: pad + CGFloat(i % cols) * (size.width + gap), y: y + CGFloat(i / cols) * (size.height + gap),
                             width: size.width, height: size.height)
        }
        let rows = (cards.count + cols - 1) / cols
        let bottom = cards.isEmpty ? y + 50 : y + CGFloat(rows) * (size.height + gap)
        content.frame = NSRect(x: 0, y: 0, width: w, height: max(bottom + pad, scroll.contentSize.height))
    }

    /// Reads the folder and the recent list again, and redraws the cards.
    func reload() {
        entries = Library.entries()
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? entries : entries.filter { $0.name.lowercased().contains(q) }
        cards.forEach { $0.removeFromSuperview() }
        cards = shown.map { WorkbookCard(entry: $0, home: self) }
        cards.forEach { content.addSubview($0) }
        if entries.isEmpty {
            emptyLabel.stringValue = "Nothing saved yet. Click New workbook to start one."
        } else if shown.isEmpty {
            emptyLabel.stringValue = "No workbook has “\(search.stringValue)” in its name."
        }
        layoutContent()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    @objc private func libraryChanged() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadQueued = false
            if self.window?.isVisible == true { self.reload() }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { reload() }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if HomeWindowController.current === self { HomeWindowController.current = nil }
    }

    /// The + at the end of the tab bar, pressed while Home is showing, starts a new workbook.
    override func newWindowForTab(_ sender: Any?) { NSDocumentController.shared.newDocument(nil) }

    // MARK: What you can do with a workbook

    private func openDocument(_ url: URL) -> NSDocument? {
        let path = url.resolvingSymlinksInPath().path
        return NSDocumentController.shared.documents.first { $0.fileURL?.resolvingSymlinksInPath().path == path }
    }

    func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
            if let error { self?.show(error) }
        }
    }

    private func show(_ error: Error) {
        if let window { window.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) } else { NSApp.presentError(error) }
    }

    func menu(for e: Library.Entry) -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let i = m.addItem(withTitle: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = e.url
        }
        item("Open", #selector(openItem(_:)))
        item("Rename…", #selector(renameItem(_:)))
        item("Duplicate", #selector(duplicateItem(_:)))
        item("Show in Finder", #selector(showInFinder(_:)))
        m.addItem(.separator())
        item("Move to Bin…", #selector(binItem(_:)))
        return m
    }

    private func entry(_ sender: Any?) -> Library.Entry? {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return nil }
        return entries.first { $0.url == url }
    }

    @objc private func openItem(_ sender: Any?) { if let e = entry(sender) { open(e.url) } }

    @objc private func renameItem(_ sender: Any?) {
        guard let e = entry(sender) else { return }
        let a = NSAlert()
        a.messageText = "Rename “\(e.name)”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        field.font = .systemFont(ofSize: 16)
        field.stringValue = e.name
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        rename(e, to: field.stringValue)
    }

    /// Gives a workbook a new name, in the same folder. An open one keeps its window.
    @discardableResult
    func rename(_ e: Library.Entry, to raw: String, then done: (() -> Void)? = nil) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != e.name else { return false }
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            tell("A name can't contain / or :, or start with a full stop.")
            return false
        }
        let target = e.url.deletingLastPathComponent().appendingPathComponent(name + ".xlsx")
        let sameFile = target.path.lowercased() == e.url.path.lowercased()
        if FileManager.default.fileExists(atPath: target.path) && !sameFile {
            tell("There's already a workbook called “\(name)” there.", "Choose another name.")
            return false
        }
        if let doc = openDocument(e.url) {
            doc.move(to: target) { [weak self] error in
                if let error { self?.show(error) }
                self?.reload()
                done?()
            }
        } else {
            do {
                if sameFile {
                    // Only the capitals change, which the Mac's file system sees as the same name.
                    let temp = e.url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).xlsx")
                    try FileManager.default.moveItem(at: e.url, to: temp)
                    try FileManager.default.moveItem(at: temp, to: target)
                } else {
                    try FileManager.default.moveItem(at: e.url, to: target)
                }
            } catch {
                show(error)
                return false
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
            reload()
            done?()
        }
        return true
    }

    @objc private func duplicateItem(_ sender: Any?) { if let e = entry(sender) { duplicate(e) } }

    /// Copies a workbook as "Name copy", beside it. An open one is saved first, so the copy has the latest changes.
    func duplicate(_ e: Library.Entry, then done: ((URL?) -> Void)? = nil) {
        let copy = { [weak self] in
            var dir = e.url.deletingLastPathComponent()
            if !FileManager.default.isWritableFile(atPath: dir.path) {
                try? Library.makeFolder()
                dir = Library.folder
            }
            let target = Library.freeURL(in: dir, base: e.name + " copy")
            do {
                try FileManager.default.copyItem(at: e.url, to: target)
            } catch {
                self?.show(error)
                done?(nil)
                return
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
            self?.reload()
            done?(target)
        }
        if let doc = openDocument(e.url), doc.hasUnautosavedChanges {
            doc.autosave(withImplicitCancellability: false) { _ in copy() }
        } else {
            copy()
        }
    }

    @objc private func showInFinder(_ sender: Any?) {
        if let e = entry(sender) { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
    }

    @objc private func binItem(_ sender: Any?) {
        guard let e = entry(sender) else { return }
        let a = NSAlert()
        a.messageText = "Move “\(e.name)” to the Bin?"
        a.informativeText = "You can get it back from the Bin until you empty it."
        a.addButton(withTitle: "Move to Bin")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        openDocument(e.url)?.close()
        NSWorkspace.shared.recycle([e.url]) { [weak self] _, error in
            if let error { self?.show(error) }
            self?.reload()
        }
    }

    private func tell(_ title: String, _ message: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

final class HomeContent: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Pictures of workbooks

/// Small pictures of workbooks for the Home tab: the top-left corner of the sheet that was showing,
/// drawn like the grid at a fixed size, so every card looks alike. Kept until the file changes.
final class Thumbs {
    static let shared = Thumbs()
    static let size = NSSize(width: 236, height: 150)
    static let zoom: CGFloat = 0.6
    private var cache: [String: (modified: Date, image: NSImage)] = [:]
    private let queue = DispatchQueue(label: "MySheets.thumbs", qos: .userInitiated)

    func load(_ e: Library.Entry, _ done: @escaping (NSImage) -> Void) {
        if let c = cache[e.url.path], c.modified == e.modified { done(c.image); return }
        queue.async {
            guard let data = try? Data(contentsOf: e.url), let loaded = try? XLSXReader.read(data) else { return }
            DispatchQueue.main.async {
                let image = Thumbs.picture(of: loaded)
                self.cache[e.url.path] = (e.modified, image)
                done(image)
            }
        }
    }

    static func picture(of book: LoadedWorkbook) -> NSImage {
        let sheet = book.workbook.sheet, styles = book.styles, z = zoom
        // Small column letters and row numbers, as on the grid.
        let top: CGFloat = 13, left: CGFloat = 18
        let headerFont = NSFont.systemFont(ofSize: 7.5, weight: .medium)
        func spans(_ axis: Axis, upTo limit: CGFloat) -> [(i: Int, at: CGFloat, size: CGFloat)] {
            var out: [(Int, CGFloat, CGFloat)] = []
            var at: CGFloat = 0, i = 0
            while at < limit && i < 200 {
                let s = CGFloat(axis.size(i)) * z
                if s > 0 { out.append((i, at, s)) }
                at += s
                i += 1
            }
            return out
        }
        let cols = spans(sheet.cols, upTo: size.width - left).map { (i: $0.i, at: $0.at + left, size: $0.size) }
        let rows = spans(sheet.rows, upTo: size.height - top).map { (i: $0.i, at: $0.at + top, size: $0.size) }
        let drawn = NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            Palette.headerBg.setFill()
            NSRect(x: 0, y: 0, width: size.width, height: top).fill()
            NSRect(x: 0, y: 0, width: left, height: size.height).fill()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let headAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: Palette.headerText, .paragraphStyle: para]
            for c in cols { (columnName(c.i) as NSString).draw(in: NSRect(x: c.at, y: 2, width: c.size, height: top - 2), withAttributes: headAttrs) }
            for r in rows where r.size >= 8 {
                (String(r.i + 1) as NSString).draw(in: NSRect(x: 0, y: r.at + (r.size - 10) / 2, width: left, height: 10), withAttributes: headAttrs)
            }
            for r in rows {
                for c in cols {
                    if let fill = styles[sheet.styleAt(CellAddr(r.i, c.i))].fill {
                        fill.color.setFill()
                        NSRect(x: c.at, y: r.at, width: c.size, height: r.size).fill()
                    }
                }
            }
            Palette.grid.setFill()
            for c in cols { NSRect(x: c.at + c.size - 0.5, y: 0, width: 0.5, height: size.height).fill() }
            for r in rows { NSRect(x: 0, y: r.at + r.size - 0.5, width: size.width, height: 0.5).fill() }
            Palette.headerLine.setFill()
            NSRect(x: 0, y: top - 0.5, width: size.width, height: 0.5).fill()
            NSRect(x: left - 0.5, y: 0, width: 0.5, height: size.height).fill()
            for r in rows {
                for (k, c) in cols.enumerated() {
                    let a = CellAddr(r.i, c.i)
                    guard let cell = sheet.cell(a), let t = cellText(cell, styles[sheet.styleAt(a)], zoom: z, date1904: book.date1904) else { continue }
                    // Text spills into empty cells to its right, as in the grid.
                    var width = c.size
                    if t.align == .left && !t.numeric {
                        var j = k + 1
                        while j < cols.count && sheet.cell(CellAddr(r.i, cols[j].i)) == nil { width += cols[j].size; j += 1 }
                    }
                    let para = NSMutableParagraphStyle()
                    para.alignment = t.align
                    para.lineBreakMode = .byClipping
                    var attrs = t.attrs
                    attrs[.paragraphStyle] = para
                    // Sits at the bottom of its row, as Excel puts it.
                    let lines = CGFloat(t.text.components(separatedBy: "\n").count)
                    let h = min(r.size, t.lineHeight * lines)
                    let box = NSRect(x: c.at + 2 * z, y: r.at + r.size - h, width: width - 4 * z, height: h)
                    (t.text as NSString).draw(in: box, withAttributes: attrs)
                }
            }
            return true
        }
        // Drawn once now, so the workbook itself isn't kept in memory.
        guard let cg = drawn.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: 2)]) else { return drawn }
        return NSImage(cgImage: cg, size: size)
    }
}

/// Draws a workbook's picture, or a grid symbol until it's ready.
final class ThumbView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        if let image {
            image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
        } else if let sym = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 44, weight: .light).applying(.init(paletteColors: [Palette.headerFullBg]))) {
            sym.draw(in: NSRect(x: bounds.midX - sym.size.width / 2, y: bounds.midY - sym.size.height / 2,
                                width: sym.size.width, height: sym.size.height))
        }
        Palette.headerLine.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Cards

/// One saved workbook on the Home tab: its picture, name and when it was last changed. Click to open it.
final class WorkbookCard: NSView {
    static let size = NSSize(width: 236, height: 238)
    let entry: Library.Entry
    unowned let home: HomeWindowController
    private let thumb = ThumbView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let placeLabel = NSTextField(labelWithString: "")
    private let more = NSButton()
    private var hover = false { didSet { updateBorder() } }
    var hasPicture: Bool { thumb.image != nil }

    init(entry: Library.Entry, home: HomeWindowController) {
        self.entry = entry
        self.home = home
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        clipsToBounds = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.cgColor
        updateBorder()

        let w = Self.size.width
        thumb.frame = NSRect(x: 0, y: 0, width: w, height: 150)
        nameLabel.stringValue = entry.name
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.textColor = NSColor(white: 0.1, alpha: 1)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 14, y: 160, width: w - 28, height: 24)
        dateLabel.stringValue = Library.when(entry.modified)
        dateLabel.font = .systemFont(ofSize: 14)
        dateLabel.textColor = NSColor(white: 0.38, alpha: 1)
        dateLabel.frame = NSRect(x: 14, y: 186, width: w - 60, height: 20)
        // Which folder it's in, after a small folder symbol.
        let place = NSMutableAttributedString()
        if let folderSymbol = NSImage(systemSymbolName: "folder", accessibilityDescription: "In folder") {
            let a = NSTextAttachment()
            a.image = folderSymbol
            place.append(NSAttributedString(attachment: a))
            place.append(NSAttributedString(string: " "))
        }
        place.append(NSAttributedString(string: FileManager.default.displayName(atPath: entry.url.deletingLastPathComponent().path)))
        place.addAttributes([.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.45, alpha: 1)],
                            range: NSRange(location: 0, length: place.length))
        placeLabel.attributedStringValue = place
        placeLabel.font = .systemFont(ofSize: 13)
        placeLabel.textColor = NSColor(white: 0.45, alpha: 1)
        placeLabel.lineBreakMode = .byTruncatingMiddle
        placeLabel.frame = NSRect(x: 14, y: 208, width: w - 60, height: 18)
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        more.isBordered = false
        more.contentTintColor = NSColor(white: 0.35, alpha: 1)
        more.target = self
        more.action = #selector(showMore)
        more.toolTip = "Rename, duplicate, show in Finder or move to the Bin"
        more.frame = NSRect(x: w - 44, y: 190, width: 32, height: 32)
        for v in [thumb, nameLabel, dateLabel, placeLabel, more] as [NSView] { addSubview(v) }
        toolTip = entry.url.path
        Thumbs.shared.load(entry) { [weak self] img in self?.thumb.image = img }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks anywhere on the card, except its ⋯ button, are the card's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === more ? more : self
    }

    private func updateBorder() {
        layer?.borderWidth = hover ? 2.5 : 1
        layer?.borderColor = (hover ? Palette.accent : Palette.headerLine).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { home.open(entry.url) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { home.menu(for: entry) }

    @objc private func showMore() {
        home.menu(for: entry).popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { entry.name }
    override func accessibilityPerformPress() -> Bool { home.open(entry.url); return true }
}

/// A big button on the Home tab: New workbook (filled green) or Open a file.
final class Tile: NSView {
    let title: String
    let symbol: String
    let filled: Bool
    let action: () -> Void
    private var hover = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, filled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.filled = filled
        self.action = action
        super.init(frame: .zero)
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirty: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        let ink: NSColor
        if filled {
            (hover ? Palette.accent.blended(withFraction: 0.15, of: .black)! : Palette.accent).setFill()
            shape.fill()
            ink = .white
        } else {
            (hover ? NSColor(srgbRed: 0.93, green: 0.97, blue: 0.94, alpha: 1) : .white).setFill()
            shape.fill()
            (hover ? Palette.accent : Palette.headerLine).setStroke()
            shape.lineWidth = hover ? 2.5 : 1
            shape.stroke()
            ink = NSColor(white: 0.12, alpha: 1)
        }
        let symColor = filled ? NSColor.white : Palette.accent
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .semibold).applying(.init(paletteColors: [symColor]))) {
            img.draw(in: NSRect(x: 22, y: (bounds.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: ink]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 72, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
