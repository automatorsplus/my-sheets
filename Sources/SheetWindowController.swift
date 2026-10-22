import AppKit

final class RootView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); onLayout?() }
}

final class BarView: NSView {
    var color: NSColor
    var bottomLine = true
    init(color: NSColor) { self.color = color; super.init(frame: .zero); clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) {
        color.setFill(); bounds.fill()
        if bottomLine { Palette.headerLine.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
    }
}

extension Selection {
    /// One range, with the given cell active.
    static func covering(_ r: CellRange, active: CellAddr) -> Selection {
        var s = Selection(active)
        s.ranges = [r]
        s.anchor = r.topLeft
        s.corner = CellAddr(r.r1, r.c1)
        s.kind = r.isWholeRows && !r.isWholeCols ? .rows : (r.isWholeCols && !r.isWholeRows ? .cols : .cells)
        return s
    }
}

final class SheetWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    unowned let doc: SheetDocument
    private(set) var zoom: CGFloat

    let root = RootView()
    private(set) var grid: GridView!
    private(set) var scroll: NSScrollView!
    private(set) var colHeader: HeaderView!
    private(set) var rowHeader: HeaderView!
    private(set) var corner: CornerView!
    private(set) var tabs: TabsBar!
    private var toolbar: BarView!
    private var fillButton: FillButton!
    private(set) var boldButton: NSButton!
    private(set) var italicButton: NSButton!
    let fontSizeBox = NSComboBox()
    /// Excel's font size list, which the bigger/smaller buttons step through.
    static let fontSizes: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]
    private var banner: BarView!
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private var bannerDismissed = false
    private var formulaBar: BarView!
    let nameBox = NSTextField()
    let formulaField = NSTextField()
    private let cancelButton = NSButton()
    private let enterButton = NSButton()
    private let fxLabel = NSTextField(labelWithString: "fx")
    private var rowHeaderWidth: CGFloat = 40

    var editor: CellEditor?
    private var formulaEditing = false
    private var tabStartCol: Int?
    var fillColor = RGB(hex: 0xFFFF00)
    private var usedCache: (rows: Int, cols: Int)?
    private var marqueeTimer: Timer?

    struct Clip {
        let range: CellRange
        let sheetIndex: Int
        let isCut: Bool
        let changeCount: Int
        let source: Sheet
    }

    var clip: Clip? {
        didSet {
            marqueeTimer?.invalidate()
            marqueeTimer = nil
            if clip != nil {
                marqueeTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let c = self.clip else { return }
                        self.grid.marqueePhase -= 1.5
                        let r = self.geo.rect(c.range).intersection(self.grid.bounds.insetBy(dx: -8, dy: -8))
                        self.grid.setNeedsDisplay(r.insetBy(dx: -4, dy: -4))
                    }
                }
            }
            grid?.needsDisplay = true
        }
    }

    enum SizeTarget { case some([Int]), all }
    enum HeaderState { case none, partial, full }
    enum AfterEdit { case none, enterDown, enterUp, tab, backTab, arrow(Int, Int) }

    init(document: SheetDocument) {
        doc = document
        let saved = UserDefaults.standard.double(forKey: "zoom")
        zoom = saved > 0 ? CGFloat(saved) : 1.25
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 440)
        window.appearance = NSAppearance(named: .aqua)
        // Workbooks open as tabs beside the Home tab.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = HomeWindowController.tabbingIdentifier
        super.init(window: window)
        window.contentView = root
        window.delegate = self
        build()
        window.initialFirstResponder = grid
        window.center()
        documentChanged()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.grid)
            self.scrollTo(self.sel.active)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building the window

    private func build() {
        root.onLayout = { [unowned self] in self.layoutViews() }

        toolbar = BarView(color: Palette.chrome)
        root.addSubview(toolbar)
        buildToolbar()

        banner = BarView(color: NSColor(srgbRed: 1, green: 0.95, blue: 0.78, alpha: 1))
        bannerLabel.font = .systemFont(ofSize: 14)
        bannerLabel.textColor = NSColor(white: 0.15, alpha: 1)
        banner.addSubview(bannerLabel)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide this message")!, target: self, action: #selector(dismissBanner))
        close.isBordered = false
        close.identifier = NSUserInterfaceItemIdentifier("bannerClose")
        banner.addSubview(close)
        root.addSubview(banner)

        formulaBar = BarView(color: .white)
        for f in [nameBox, formulaField] {
            f.font = .systemFont(ofSize: 15)
            f.delegate = self
            f.focusRingType = .none
            f.cell?.wraps = false
            f.cell?.isScrollable = true
            formulaBar.addSubview(f)
        }
        nameBox.alignment = .left
        nameBox.toolTip = "Name Box: type an address like B12 or A1:C5 and press Return to go there"
        formulaField.toolTip = "Formula bar: shows and edits the selected cell"
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        enterButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Enter")?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        for (b, a) in [(cancelButton, #selector(cancelButtonPressed)), (enterButton, #selector(enterButtonPressed))] {
            b.isBordered = false
            b.target = self
            b.action = a
            b.isEnabled = false
            formulaBar.addSubview(b)
        }
        fxLabel.font = NSFont(name: "Georgia-Italic", size: 17) ?? .systemFont(ofSize: 16)
        fxLabel.textColor = NSColor(white: 0.35, alpha: 1)
        formulaBar.addSubview(fxLabel)
        root.addSubview(formulaBar)

        corner = CornerView(ctl: self)
        colHeader = HeaderView(ctl: self, rows: false)
        rowHeader = HeaderView(ctl: self, rows: true)
        grid = GridView(ctl: self)
        scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.backgroundColor = .white
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        tabs = TabsBar(ctl: self)
        for v in [corner!, colHeader!, rowHeader!, scroll!, tabs!] as [NSView] { root.addSubview(v) }
        tabs.updateZoom()
        updateBanner()
    }

    private func toolButton(_ title: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        let b = NSButton(title: title, image: img ?? NSImage(), target: self, action: action)
        b.imagePosition = .imageLeading
        b.isBordered = false
        b.font = .systemFont(ofSize: 14)
        b.toolTip = tip
        b.sizeToFit()
        b.frame.size.width += 12
        return b
    }

    /// A Bold or Italic button that stays pressed while the active cell has that style.
    private func styleToggle(_ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        let b = NSButton(image: img ?? NSImage(), target: self, action: action)
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        b.frame = NSRect(x: 0, y: 0, width: 36, height: 28)
        return b
    }

    private func textButton(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.font = .systemFont(ofSize: 15, weight: .medium)
        b.toolTip = tip
        b.frame = NSRect(x: 0, y: 0, width: 40, height: 28)
        return b
    }

    private func buildToolbar() {
        let items: [NSView] = [
            toolButton("Home", "house", #selector(showHome(_:)), "All your workbooks (⇧⌘H)"),
            toolButton("Undo", "arrow.uturn.backward", #selector(undoPressed), "Undo the last change (⌘Z)"),
            toolButton("Redo", "arrow.uturn.forward", #selector(redoPressed), "Redo (⇧⌘Z)"),
            {
                fillButton = FillButton(ctl: self)
                return fillButton
            }(),
            {
                boldButton = styleToggle("bold", #selector(toggleBold(_:)), "Bold (⌘B)")
                return boldButton
            }(),
            {
                italicButton = styleToggle("italic", #selector(toggleItalic(_:)), "Italic (⌘I)")
                return italicButton
            }(),
            {
                fontSizeBox.addItems(withObjectValues: SheetWindowController.fontSizes.map { NumFmt.general($0) })
                fontSizeBox.numberOfVisibleItems = SheetWindowController.fontSizes.count
                fontSizeBox.font = .systemFont(ofSize: 14)
                fontSizeBox.frame = NSRect(x: 0, y: 0, width: 66, height: 26)
                fontSizeBox.target = self
                fontSizeBox.action = #selector(fontSizeChosen(_:))
                fontSizeBox.toolTip = "Font size"
                return fontSizeBox
            }(),
            textButton("A▲", #selector(increaseFontSize(_:)), "Bigger text (⇧⌘>)"),
            textButton("A▼", #selector(decreaseFontSize(_:)), "Smaller text (⇧⌘<)"),
            toolButton("Insert", "plus.square", #selector(showInsertMenu(_:)), "Insert rows, columns or a sheet"),
            toolButton("Delete", "minus.square", #selector(showDeleteMenu(_:)), "Delete rows, columns or a sheet"),
            toolButton("Format", "arrow.up.and.down.text.horizontal", #selector(showFormatMenu(_:)), "Row height, column width, hide and unhide"),
        ]
        var x: CGFloat = 10
        for (i, v) in items.enumerated() {
            if i == 1 || i == 3 || i == 4 || i == 9 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.frame = NSRect(x: x + 4, y: 9, width: 1, height: 26)
                toolbar.addSubview(sep)
                x += 12
            }
            v.frame.origin = NSPoint(x: x, y: (44 - v.frame.height) / 2)
            toolbar.addSubview(v)
            x += v.frame.width + 6
        }
    }

    private func layoutViews() {
        let w = root.bounds.width, h = root.bounds.height
        var top: CGFloat = 0
        toolbar.frame = NSRect(x: 0, y: top, width: w, height: 44)
        top += 44
        banner.isHidden = (doc.losses.isEmpty && doc.copiedFrom == nil) || bannerDismissed
        if !banner.isHidden {
            banner.frame = NSRect(x: 0, y: top, width: w, height: 48)
            bannerLabel.frame = NSRect(x: 14, y: 6, width: w - 60, height: 36)
            banner.subviews.first { $0.identifier?.rawValue == "bannerClose" }?.frame = NSRect(x: w - 36, y: 12, width: 24, height: 24)
            top += 48
        }
        formulaBar.frame = NSRect(x: 0, y: top, width: w, height: 38)
        nameBox.frame = NSRect(x: 8, y: 6, width: 120, height: 26)
        cancelButton.frame = NSRect(x: 136, y: 7, width: 26, height: 24)
        enterButton.frame = NSRect(x: 164, y: 7, width: 26, height: 24)
        fxLabel.frame = NSRect(x: 196, y: 8, width: 24, height: 22)
        formulaField.frame = NSRect(x: 224, y: 6, width: w - 232, height: 26)
        top += 38
        let hh = ceil(22 * zoom)
        let rw = rowHeaderWidth
        let bottom: CGFloat = 38
        corner.frame = NSRect(x: 0, y: top, width: rw, height: hh)
        colHeader.frame = NSRect(x: rw, y: top, width: max(0, w - rw), height: hh)
        rowHeader.frame = NSRect(x: 0, y: top + hh, width: rw, height: max(0, h - top - hh - bottom))
        scroll.frame = NSRect(x: rw, y: top + hh, width: max(0, w - rw), height: max(0, h - top - hh - bottom))
        tabs.frame = NSRect(x: 0, y: h - bottom, width: w, height: bottom)
        updateExtent()
    }

    func updateBanner() {
        if !doc.losses.isEmpty {
            banner.color = NSColor(srgbRed: 1, green: 0.95, blue: 0.78, alpha: 1)
            bannerLabel.stringValue = "This file has \(plainList(doc.losses)), which MySheets can't keep. "
                + "Your changes will go into a copy, so the original stays as it is."
        } else if let original = doc.copiedFrom {
            banner.color = NSColor(srgbRed: 0.87, green: 0.95, blue: 0.89, alpha: 1)
            bannerLabel.stringValue = "This is a copy, and your changes save here. The original “\(original)” hasn't changed."
            bannerDismissed = false
        }
        banner.needsDisplay = true
        layoutViews()
    }

    @objc private func dismissBanner() { bannerDismissed = true; layoutViews() }

    var bannerText: String? { banner.isHidden ? nil : bannerLabel.stringValue }

    // MARK: Home and tabs

    @objc func showHome(_ sender: Any?) { HomeWindowController.show(beside: window) }

    /// The + at the end of the tab bar opens the Home tab.
    override func newWindowForTab(_ sender: Any?) { HomeWindowController.show(beside: window) }

    // MARK: Geometry

    var sheet: Sheet { doc.workbook.sheet }

    var sel: Selection {
        get { doc.workbook.sheets[doc.workbook.active].selection }
        set { doc.workbook.sheets[doc.workbook.active].selection = newValue }
    }

    var geo: Geo {
        let s = doc.workbook.sheets[doc.workbook.active]
        return Geo(rows: s.rows, cols: s.cols, zoom: zoom)
    }

    var clipBounds: NSRect { scroll?.contentView.bounds ?? .zero }
    var headerFont: NSFont { .systemFont(ofSize: (12 * zoom * 2).rounded() / 2) }

    private var used: (rows: Int, cols: Int) {
        if let u = usedCache { return u }
        let u = sheet.usedSize()
        usedCache = u
        return u
    }

    /// The scrollable area covers the used cells plus a screen more, and grows as you scroll, as Excel's does.
    func updateExtent(including extra: CellAddr? = nil) {
        guard let scroll, let grid else { return }
        let g = geo
        let vis = scroll.contentView.bounds
        let s = sel
        let pageRows = max(10, Int(vis.height / max(1, CGFloat(g.rows.defaultSize) * zoom)))
        let pageCols = max(5, Int(vis.width / max(1, CGFloat(g.cols.defaultSize) * zoom)))
        var needRows = max(used.rows, g.row(at: vis.maxY) + 1, s.active.row + 1)
        var needCols = max(used.cols, g.col(at: vis.maxX) + 1, s.active.col + 1)
        if !(s.last.isWholeRows && s.last.isWholeCols) {
            if s.kind != .cols { needRows = max(needRows, s.corner.row + 1) }
            if s.kind != .rows { needCols = max(needCols, s.corner.col + 1) }
        }
        if let extra { needRows = max(needRows, extra.row + 1); needCols = max(needCols, extra.col + 1) }
        needRows = min(maxRows, needRows + pageRows)
        needCols = min(maxCols, needCols + pageCols)
        let size = NSSize(width: max(g.x(needCols), vis.width), height: max(g.y(needRows), vis.height))
        if grid.frame.size != size { grid.setFrameSize(size) }
    }

    private func neededRowHeaderWidth() -> CGFloat {
        let last = geo.row(at: clipBounds.maxY) + 1
        let digits = max(3, String(last).count)
        let font = NSFont.systemFont(ofSize: headerFont.pointSize, weight: .semibold)
        let w = ("0" as NSString).size(withAttributes: [.font: font]).width
        return ceil(w * CGFloat(digits) + 16 * zoom)
    }

    @objc private func scrolled(_ n: Notification) {
        updateExtent()
        let need = neededRowHeaderWidth()
        if abs(need - rowHeaderWidth) > 0.5 { rowHeaderWidth = need; layoutViews() }
        colHeader.needsDisplay = true
        rowHeader.needsDisplay = true
    }

    func redrawAll() {
        for v in [grid, colHeader, rowHeader, corner, tabs] as [NSView?] { v?.needsDisplay = true }
    }

    func documentChanged() {
        usedCache = nil
        updateExtent()
        redrawAll()
        updateFormulaBar()
        updateNameBox()
        fillButton?.update()
    }

    func focusGrid() { window?.makeFirstResponder(grid) }

    func scrollTo(_ a: CellAddr) {
        updateExtent(including: a)
        grid.scrollToVisible(geo.rect(a))
    }

    // MARK: Selection

    func selectionChanged(scrollTo a: CellAddr?) {
        if let a { scrollTo(a) } else { updateExtent() }
        grid.needsDisplay = true
        colHeader.needsDisplay = true
        rowHeader.needsDisplay = true
        corner.needsDisplay = true
        updateFormulaBar()
        updateNameBox()
    }

    func headerState(_ i: Int, rows: Bool) -> HeaderState {
        var st = HeaderState.none
        for rg in sel.ranges {
            if rows {
                guard i >= rg.r0 && i <= rg.r1 else { continue }
                if rg.isWholeRows { return .full }
            } else {
                guard i >= rg.c0 && i <= rg.c1 else { continue }
                if rg.isWholeCols { return .full }
            }
            st = .partial
        }
        return st
    }

    private var firstVisibleCol: Int { geo.col(at: clipBounds.minX) }
    private var firstVisibleRow: Int { geo.row(at: clipBounds.minY) }

    func clickCell(_ a: CellAddr, shift: Bool, cmd: Bool) {
        tabStartCol = nil
        var s = sel
        if shift { s.extend(to: a) }
        else if cmd { s.add(a, kind: .cells) }
        else { s = Selection(a) }
        sel = s
        selectionChanged(scrollTo: nil)
    }

    func dragCell(to a: CellAddr) {
        var s = sel
        s.extend(to: s.kind == .cells ? a : a)
        guard s != sel else { return }
        sel = s
        selectionChanged(scrollTo: nil)
        let r = s.last
        if !r.isSingle { showNameBox("\(r.rowCount)R × \(r.colCount)C") }
    }

    func finishDragSelect() { updateNameBox() }

    func clickHeader(_ i: Int, rows: Bool, shift: Bool, cmd: Bool) {
        tabStartCol = nil
        var s = sel
        if rows {
            if shift {
                if s.kind != .rows { s = Selection.rows(s.active.row, i, activeCol: s.active.col) }
                else { s.extend(to: CellAddr(i, s.anchor.col)) }
            } else if cmd {
                s.add(CellAddr(i, firstVisibleCol), kind: .rows)
            } else {
                s = Selection.rows(i, i, activeCol: firstVisibleCol)
            }
        } else {
            if shift {
                if s.kind != .cols { s = Selection.cols(s.active.col, i, activeRow: s.active.row) }
                else { s.extend(to: CellAddr(s.anchor.row, i)) }
            } else if cmd {
                s.add(CellAddr(firstVisibleRow, i), kind: .cols)
            } else {
                s = Selection.cols(i, i, activeRow: firstVisibleRow)
            }
        }
        sel = s
        selectionChanged(scrollTo: nil)
    }

    func dragHeader(to i: Int, rows: Bool) {
        var s = sel
        s.extend(to: rows ? CellAddr(i, s.anchor.col) : CellAddr(s.anchor.row, i))
        guard s != sel else { return }
        sel = s
        selectionChanged(scrollTo: nil)
        let r = s.last
        showNameBox(rows ? "\(r.rowCount)R × \(maxCols)C" : "\(maxRows)R × \(r.colCount)C")
    }

    func selectAll() {
        commitEditing()
        sel = Selection.all(active: sel.active)
        selectionChanged(scrollTo: nil)
    }

    func selectWholeRows() {
        let s = sel
        sel = Selection.rows(s.last.r0, s.last.r1, activeCol: s.active.col)
        sel.active = s.active
        selectionChanged(scrollTo: nil)
    }

    func selectWholeCols() {
        let s = sel
        sel = Selection.cols(s.last.c0, s.last.c1, activeRow: s.active.row)
        sel.active = s.active
        selectionChanged(scrollTo: nil)
    }

    func moveActive(_ dr: Int, _ dc: Int, extend: Bool = false, keepTab: Bool = false) {
        if !keepTab { tabStartCol = nil }
        var s = sel
        if extend {
            guard let c = sheet.step(s.corner, dr, dc) else { return }
            s.extend(to: c)
            sel = s
            selectionChanged(scrollTo: c)
        } else {
            guard let a = sheet.step(s.active, dr, dc) else { return }
            sel = Selection(a)
            selectionChanged(scrollTo: a)
        }
    }

    func jump(_ dr: Int, _ dc: Int, extend: Bool = false) {
        tabStartCol = nil
        var s = sel
        if extend {
            let c = sheet.jump(from: s.corner, dr, dc)
            s.extend(to: c)
            sel = s
            selectionChanged(scrollTo: c)
        } else {
            let a = sheet.jump(from: s.active, dr, dc)
            sel = Selection(a)
            selectionChanged(scrollTo: a)
        }
    }

    func page(down: Bool, extend: Bool) {
        tabStartCol = nil
        let g = geo
        let vis = clipBounds
        let n = max(1, g.row(at: vis.maxY) - g.row(at: vis.minY))
        var s = sel
        let from = extend ? s.corner : s.active
        let target = CellAddr(min(max(from.row + (down ? n : -n), 0), maxRows - 1), from.col)
        updateExtent(including: target)
        let dy = g.y(target.row) - g.y(from.row)
        scroll.contentView.scroll(to: NSPoint(x: vis.minX, y: max(0, vis.minY + dy)))
        scroll.reflectScrolledClipView(scroll.contentView)
        if extend { s.extend(to: target) } else { s = Selection(target) }
        sel = s
        selectionChanged(scrollTo: target)
    }

    func home() {
        var c = 0
        while c < maxCols - 1 && sheet.cols.isHidden(c) { c += 1 }
        let a = CellAddr(sel.active.row, c)
        sel = Selection(a)
        selectionChanged(scrollTo: a)
    }

    func lastCell() {
        let u = used
        let a = CellAddr(max(0, u.rows - 1), max(0, u.cols - 1))
        sel = Selection(a)
        selectionChanged(scrollTo: a)
    }

    private func cycle(in r: CellRange, from a: CellAddr, byRow: Bool, forward: Bool) -> CellAddr {
        var row = a.row, col = a.col
        if byRow {
            col += forward ? 1 : -1
            if col > r.c1 { col = r.c0; row += 1; if row > r.r1 { row = r.r0 } }
            if col < r.c0 { col = r.c1; row -= 1; if row < r.r0 { row = r.r1 } }
        } else {
            row += forward ? 1 : -1
            if row > r.r1 { row = r.r0; col += 1; if col > r.c1 { col = r.c0 } }
            if row < r.r0 { row = r.r1; col -= 1; if col < r.c0 { col = r.c1 } }
        }
        return CellAddr(row, col)
    }

    /// Return: down (Shift-Return: up). Inside a selected block it walks the block; after a run of Tabs
    /// it goes back to the column where the Tabs started, as Excel does.
    func enterKey(forward: Bool) {
        let s = sel
        if !s.isSingleCell {
            var t = s
            t.active = cycle(in: s.last, from: s.active, byRow: false, forward: forward)
            sel = t
            selectionChanged(scrollTo: t.active)
            return
        }
        if forward, let start = tabStartCol {
            let a = CellAddr(min(s.active.row + 1, maxRows - 1), start)
            tabStartCol = nil
            sel = Selection(a)
            selectionChanged(scrollTo: a)
            return
        }
        moveActive(forward ? 1 : -1, 0)
    }

    func tabKey(forward: Bool) {
        let s = sel
        if !s.isSingleCell {
            var t = s
            t.active = cycle(in: s.last, from: s.active, byRow: true, forward: forward)
            sel = t
            selectionChanged(scrollTo: t.active)
            return
        }
        if forward && tabStartCol == nil { tabStartCol = s.active.col }
        moveActive(0, forward ? 1 : -1, keepTab: true)
    }

    // MARK: Name box and formula bar

    func updateNameBox() {
        guard window?.firstResponder !== nameBox.currentEditor() || nameBox.currentEditor() == nil else { return }
        nameBox.stringValue = cellName(sel.active)
    }

    func showNameBox(_ text: String) { nameBox.stringValue = text }

    func updateFontControls() {
        guard boldButton != nil else { return }
        let st = doc.styles[sheet.styleAt(sel.active)]
        boldButton.state = st.bold ? .on : .off
        italicButton.state = st.italic ? .on : .off
        if fontSizeBox.currentEditor() == nil { fontSizeBox.stringValue = NumFmt.general(st.size) }
    }

    func updateFormulaBar() {
        updateFontControls()
        guard !formulaEditing, editor == nil else { return }
        let a = sel.active
        formulaField.stringValue = editText(sheet.cell(a), format: doc.styles[sheet.styleAt(a)].numFmt, date1904: doc.date1904)
    }

    func updateMode() {
        let mode: String
        if let ed = editor { mode = ed.mode == .enter ? "Enter" : "Edit" }
        else if formulaEditing { mode = "Edit" }
        else { mode = "Ready" }
        tabs.modeLabel.stringValue = mode
        cancelButton.isEnabled = mode != "Ready"
        enterButton.isEnabled = mode != "Ready"
    }

    private func goTo(_ text: String) {
        guard let r = parseRange(text) else {
            NSSound.beep()
            updateNameBox()
            return
        }
        sel = r.isSingle ? Selection(r.topLeft) : .covering(r, active: r.topLeft)
        selectionChanged(scrollTo: r.topLeft)
    }

    func controlTextDidBeginEditing(_ n: Notification) {
        guard (n.object as? NSTextField) === formulaField else { return }
        if editor != nil { commitEditing(refocus: false) }
        formulaEditing = true
        clip = nil
        updateMode()
    }

    func controlTextDidChange(_ n: Notification) {
        if (n.object as? NSTextField) === formulaField, formulaEditing { grid.previewText = formulaField.stringValue }
    }

    func controlTextDidEndEditing(_ n: Notification) {
        if (n.object as? NSTextField) === formulaField, formulaEditing { commitFormulaBar(then: .none, refocus: false) }
        if (n.object as? NSTextField) === nameBox { updateNameBox() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy s: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if control === formulaField {
            switch s {
            case #selector(NSResponder.insertNewline(_:)): commitFormulaBar(then: shift ? .enterUp : .enterDown); return true
            case #selector(NSResponder.insertTab(_:)): commitFormulaBar(then: .tab); return true
            case #selector(NSResponder.insertBacktab(_:)): commitFormulaBar(then: .backTab); return true
            case #selector(NSResponder.cancelOperation(_:)): cancelEditing(); return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            default: return false
            }
        }
        if control === nameBox {
            switch s {
            case #selector(NSResponder.insertNewline(_:)):
                let text = nameBox.stringValue
                focusGrid()
                goTo(text)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                focusGrid()
                updateNameBox()
                return true
            default: return false
            }
        }
        return false
    }

    private func commitFormulaBar(then after: AfterEdit, refocus: Bool = true) {
        guard formulaEditing else {
            if refocus { focusGrid() }
            advance(after)
            return
        }
        formulaEditing = false
        let text = formulaField.stringValue
        grid.previewText = nil
        applyEntry(text, at: sel.active)
        if refocus { focusGrid() }
        advance(after)
        updateMode()
        updateFormulaBar()
    }

    @objc private func cancelButtonPressed() { cancelEditing() }
    @objc private func enterButtonPressed() { commitEditing() }

    // MARK: Typing in cells

    func beginEditing(_ mode: CellEditor.Mode, with event: NSEvent? = nil) {
        guard editor == nil, !formulaEditing, let window else { return }
        let a = sel.active
        scrollTo(a)
        let st = doc.styles[sheet.styleAt(a)]
        let font = fontBook.font(st, zoom: zoom)
        let r = geo.rect(a)
        let cellRect = NSRect(x: r.minX, y: r.minY, width: max(r.width - 1, 10), height: max(r.height - 1, 10))
        let ed = CellEditor(frame: cellRect)
        ed.ctl = self
        ed.mode = mode
        ed.addr = a
        ed.cellRect = cellRect
        ed.padX = 3 * zoom
        ed.isRichText = false
        ed.allowsUndo = false
        ed.importsGraphics = false
        ed.isAutomaticQuoteSubstitutionEnabled = false
        ed.isAutomaticDashSubstitutionEnabled = false
        ed.isAutomaticTextReplacementEnabled = false
        ed.isAutomaticSpellingCorrectionEnabled = false
        ed.isContinuousSpellCheckingEnabled = false
        ed.isAutomaticLinkDetectionEnabled = false
        ed.smartInsertDeleteEnabled = false
        ed.font = font
        ed.textColor = st.color?.color ?? .black
        ed.backgroundColor = st.fill?.color ?? .white
        ed.drawsBackground = true
        ed.insertionPointColor = .black
        ed.textContainer?.lineFragmentPadding = 0
        ed.isHorizontallyResizable = true
        ed.isVerticallyResizable = true
        ed.textContainer?.widthTracksTextView = false
        ed.textContainer?.heightTracksTextView = false
        ed.textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
        ed.minSize = cellRect.size
        ed.maxSize = NSSize(width: 100_000, height: 100_000)
        let start = event != nil ? "" : editText(sheet.cell(a), format: st.numFmt, date1904: doc.date1904)
        ed.string = start
        editor = ed
        clip = nil
        grid.addSubview(ed)
        ed.fitToText()
        window.makeFirstResponder(ed)
        if let event { ed.keyDown(with: event) } else { ed.setSelectedRange(NSRange(location: (start as NSString).length, length: 0)) }
        formulaField.stringValue = ed.string
        grid.needsDisplay = true
        updateMode()
    }

    func editorTextChanged(_ s: String) { formulaField.stringValue = s }

    /// Finishes typing (in the cell or the formula bar) and keeps the result.
    func commitEditing(then after: AfterEdit = .none, refocus: Bool = true) {
        if formulaEditing { commitFormulaBar(then: after, refocus: refocus); return }
        guard let ed = editor else { return }
        let text = ed.string, a = ed.addr
        editor = nil
        ed.removeFromSuperview()
        if refocus { focusGrid() }
        applyEntry(text, at: a)
        advance(after)
        updateMode()
        updateFormulaBar()
        grid.needsDisplay = true
    }

    func commitIfStillEditing(_ ed: CellEditor) {
        guard editor === ed, window?.firstResponder !== ed else { return }
        commitEditing(refocus: false)
    }

    func cancelEditing() {
        if formulaEditing {
            formulaEditing = false
            grid.previewText = nil
            formulaField.abortEditing()
            focusGrid()
        }
        if let ed = editor {
            editor = nil
            ed.removeFromSuperview()
            focusGrid()
        }
        updateMode()
        updateFormulaBar()
        grid.needsDisplay = true
    }

    private func advance(_ after: AfterEdit) {
        switch after {
        case .none: break
        case .enterDown: enterKey(forward: true)
        case .enterUp: enterKey(forward: false)
        case .tab: tabKey(forward: true)
        case .backTab: tabKey(forward: false)
        case .arrow(let dr, let dc): moveActive(dr, dc)
        }
    }

    /// Puts typed text into a cell. Number formats only change if the cell had none (General), as in Excel.
    static func put(_ entry: Entry, at a: CellAddr, in sh: inout Sheet, styles: StyleTable) {
        switch entry {
        case .clear: sh.setValue(a, nil)
        case .formula(let f): sh.setValue(a, nil, formula: f)
        case .value(let v, let fmt):
            var st = sh.styleAt(a)
            if let fmt, styles[st].numFmt == "General" { st = styles.withNumFmt(st, fmt) }
            sh.setValue(a, v, style: st)
        }
    }

    private func applyEntry(_ text: String, at a: CellAddr) {
        let old = editText(sheet.cell(a), format: doc.styles[sheet.styleAt(a)].numFmt, date1904: doc.date1904)
        guard text != old else { return }
        let styles = doc.styles
        let entry = parseEntry(text)
        doc.edit("Typing") { wb in
            var sh = wb.sheet
            SheetWindowController.put(entry, at: a, in: &sh, styles: styles)
            fitRows([a.row], in: &sh)
            wb.sheet = sh
        }
    }

    // MARK: Sizes

    func sizeTargets(for i: Int, rows: Bool) -> SizeTarget {
        let s = sel
        if s.ranges.contains(where: { $0.isWholeRows && $0.isWholeCols }) { return .all }
        let full = s.ranges.filter { rows ? $0.isWholeRows : $0.isWholeCols }
        if full.contains(where: { rows ? (i >= $0.r0 && i <= $0.r1) : (i >= $0.c0 && i <= $0.c1) }) {
            var idx = Set<Int>()
            for rg in full { for k in (rows ? rg.r0...rg.r1 : rg.c0...rg.c1) { idx.insert(k) } }
            return .some(idx.sorted())
        }
        return .some([i])
    }

    /// Live resizing while an edge is dragged; HeaderView records the undo step when the drag ends.
    func applySize(_ size: Double, to t: SizeTarget, rows: Bool, live: Int? = nil) {
        let i = doc.workbook.active
        var ax = rows ? doc.workbook.sheets[i].rows : doc.workbook.sheets[i].cols
        switch t {
        case .all:
            ax.set(Array(ax.sizes.keys), size: nil)
            ax.set(Array(ax.hidden), hidden: false)
            ax.setDefault(max(2, size))
        case .some(let idx):
            if size < 1 { ax.set(idx, hidden: true) }
            else { ax.set(idx, hidden: false); ax.set(idx, size: size) }
        }
        if rows {
            doc.workbook.sheets[i].rows = ax
            if case .some(let idx) = t { doc.workbook.sheets[i].autoHeights.subtract(idx) } else { doc.workbook.sheets[i].autoHeights = [] }
        } else {
            doc.workbook.sheets[i].cols = ax
        }
        updateExtent()
        grid.needsDisplay = true
        colHeader.needsDisplay = true
        rowHeader.needsDisplay = true
    }

    private func fitWidth(col c: Int, _ sh: Sheet) -> Double? {
        var best: CGFloat = 0
        for (_, rc) in sh.cells {
            guard let cell = rc[c], let t = cellText(cell, doc.styles[cell.style], zoom: 1, date1904: doc.date1904) else { continue }
            let w = t.text.components(separatedBy: "\n").map { t.width($0) }.max() ?? 0
            best = max(best, w)
        }
        return best == 0 ? nil : Double(ceil(best + 10))
    }

    private func fitHeight(row r: Int, _ sh: Sheet) -> Double? {
        var best: CGFloat = 0
        if let rs = sh.rowStyles[r] {
            let f = fontBook.font(doc.styles[rs], zoom: 1)
            best = ceil(f.ascender - f.descender + f.leading) + 4
        }
        guard let rc = sh.cells[r] else { return best <= CGFloat(sh.rows.defaultSize) ? nil : Double(ceil(best)) }
        for (c, cell) in rc {
            let st = doc.styles[cell.style]
            guard let t = cellText(cell, st, zoom: 1, date1904: doc.date1904) else { continue }
            var h = CGFloat(t.text.components(separatedBy: "\n").count) * t.lineHeight + 4
            if st.wrap {
                let width = CGFloat(sh.cols.size(c)) - 6
                let s = NSAttributedString(string: t.text, attributes: t.attrs)
                h = ceil(s.boundingRect(with: NSSize(width: max(10, width), height: 1e6), options: [.usesLineFragmentOrigin]).height) + 4
            }
            best = max(best, h)
        }
        return best <= CGFloat(sh.rows.defaultSize) ? nil : Double(ceil(best))
    }

    func autofit(_ t: SizeTarget, rows: Bool) {
        commitEditing()
        let idx: [Int]
        switch t {
        case .all: idx = Array(0..<(rows ? used.rows : used.cols))
        case .some(let i): idx = i
        }
        let sh = sheet
        var groups: [Double?: [Int]] = [:]
        for k in idx { groups[rows ? fitHeight(row: k, sh) : fitWidth(col: k, sh), default: []].append(k) }
        doc.edit(rows ? "AutoFit Row Height" : "AutoFit Column Width") { wb in
            var ax = rows ? wb.sheet.rows : wb.sheet.cols
            ax.set(idx, hidden: false)
            for (size, keys) in groups { ax.set(keys, size: size) }
            if rows {
                wb.sheets[wb.active].rows = ax
                for (size, keys) in groups {
                    if size == nil { wb.sheets[wb.active].autoHeights.subtract(keys) } else { wb.sheets[wb.active].autoHeights.formUnion(keys) }
                }
            } else {
                wb.sheets[wb.active].cols = ax
            }
        }
    }

    /// Rows (or columns) the selection touches. A selection running the full length uses the used part.
    private func selectedIndices(rows: Bool) -> [Int] {
        var set = Set<Int>()
        let limit = rows ? max(used.rows, sel.active.row + 1) : max(used.cols, sel.active.col + 1)
        for rg in sel.ranges {
            let lo = rows ? rg.r0 : rg.c0
            var hi = rows ? rg.r1 : rg.c1
            if hi - lo > 100_000 { hi = max(lo, min(hi, limit - 1)) }
            for k in lo...hi { set.insert(k) }
        }
        return set.sorted()
    }

    private func ask(_ title: String, _ message: String, _ initial: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        field.font = .systemFont(ofSize: 16)
        field.stringValue = initial
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func tell(_ title: String, _ message: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    private func setSizes(_ idx: [Int], px: Double, rows: Bool, action: String) {
        doc.edit(action) { wb in
            var ax = rows ? wb.sheet.rows : wb.sheet.cols
            if px < 1 { ax.set(idx, hidden: true) } else { ax.set(idx, hidden: false); ax.set(idx, size: px) }
            if rows { wb.sheets[wb.active].rows = ax; wb.sheets[wb.active].autoHeights.subtract(idx) } else { wb.sheets[wb.active].cols = ax }
        }
    }

    @objc func rowHeightDialog(_ sender: Any?) {
        commitEditing()
        let idx = selectedIndices(rows: true)
        let sizes = Set(idx.prefix(2000).map { sheet.rows.size($0) })
        let current = sizes.count == 1 ? NumFmt.general((sizes.first! * 0.75 * 100).rounded() / 100) : ""
        guard let text = ask("Row Height", "Height in points, from 0 to 409. The normal height is 15.", current) else { return }
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v >= 0, v <= 409 else {
            tell("Row height must be a number from 0 to 409."); return
        }
        setSizes(idx, px: (v * 4 / 3 * 100).rounded() / 100, rows: true, action: "Row Height")
    }

    @objc func columnWidthDialog(_ sender: Any?) {
        commitEditing()
        let idx = selectedIndices(rows: false)
        let sizes = Set(idx.prefix(2000).map { sheet.cols.size($0) })
        let current = sizes.count == 1 ? NumFmt.general((max(0, sizes.first! - 5) / 7 * 100).rounded() / 100) : ""
        guard let text = ask("Column Width", "Width in characters, from 0 to 255. The normal width is 8.43.", current) else { return }
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v >= 0, v <= 255 else {
            tell("Column width must be a number from 0 to 255."); return
        }
        setSizes(idx, px: v == 0 ? 0 : (v * 7 + 5).rounded(), rows: false, action: "Column Width")
    }

    @objc func autofitRows(_ sender: Any?) { autofit(.some(selectedIndices(rows: true)), rows: true) }
    @objc func autofitColumns(_ sender: Any?) { autofit(.some(selectedIndices(rows: false)), rows: false) }

    @objc func hideRows(_ sender: Any?) {
        commitEditing()
        let idx = selectedIndices(rows: true)
        doc.edit("Hide Rows") { wb in wb.sheets[wb.active].rows.set(idx, hidden: true) }
    }

    @objc func hideColumns(_ sender: Any?) {
        commitEditing()
        let idx = selectedIndices(rows: false)
        doc.edit("Hide Columns") { wb in wb.sheets[wb.active].cols.set(idx, hidden: true) }
    }

    private func hiddenInSelection(rows: Bool) -> [Int] {
        let ax = rows ? sheet.rows : sheet.cols
        return ax.hidden.filter { k in sel.ranges.contains { rows ? (k >= $0.r0 && k <= $0.r1) : (k >= $0.c0 && k <= $0.c1) } }.sorted()
    }

    @objc func unhideRows(_ sender: Any?) {
        commitEditing()
        let idx = hiddenInSelection(rows: true)
        guard !idx.isEmpty else { return }
        doc.edit("Unhide Rows") { wb in wb.sheets[wb.active].rows.set(idx, hidden: false) }
    }

    @objc func unhideColumns(_ sender: Any?) {
        commitEditing()
        let idx = hiddenInSelection(rows: false)
        guard !idx.isEmpty else { return }
        doc.edit("Unhide Columns") { wb in wb.sheets[wb.active].cols.set(idx, hidden: false) }
    }

    // MARK: Moving

    func moveBlock(_ src: CellRange, by dr: Int, _ dc: Int, copy: Bool, confirm: Bool = true) {
        let dst = src.offsetBy(dr, dc)
        if confirm && sheet.hasValues(in: dst, excluding: copy ? nil : src) {
            let a = NSAlert()
            a.messageText = "There's already data here. Do you want to replace it?"
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let act = sel.active
        doc.edit(copy ? "Copy Cells" : "Move Cells") { wb in
            wb.sheets[wb.active].moveRange(src, by: dr, dc, copy: copy)
            let na = src.contains(act) ? CellAddr(act.row + dr, act.col + dc) : dst.topLeft
            wb.sheets[wb.active].selection = .covering(dst, active: na)
        }
        if !copy, let c = clip, c.range.intersects(src) { clip = nil }
    }

    func moveRows(_ a: Int, _ n: Int, to t: Int, copy: Bool) {
        let act = sel.active
        let offset = min(max(act.row - a, 0), n - 1)
        doc.edit(copy ? "Insert Copied Rows" : "Move Rows") { wb in
            let start: Int
            if copy {
                wb.sheets[wb.active].insertCopies(ofRows: a, count: n, at: t)
                start = t
            } else {
                wb.sheets[wb.active].remapRows(Sheet.moveMap(from: a, count: n, to: t))
                start = t > a ? t - n : t
            }
            wb.sheets[wb.active].selection = .covering(.rows(start, start + n - 1), active: CellAddr(start + offset, act.col))
        }
        if let c = clip, c.range.isWholeRows { clip = nil }
    }

    func moveCols(_ a: Int, _ n: Int, to t: Int, copy: Bool) {
        let act = sel.active
        let offset = min(max(act.col - a, 0), n - 1)
        doc.edit(copy ? "Insert Copied Columns" : "Move Columns") { wb in
            let start: Int
            if copy {
                wb.sheets[wb.active].insertCopies(ofCols: a, count: n, at: t)
                start = t
            } else {
                wb.sheets[wb.active].remapCols(Sheet.moveMap(from: a, count: n, to: t))
                start = t > a ? t - n : t
            }
            wb.sheets[wb.active].selection = .covering(.cols(start, start + n - 1), active: CellAddr(act.row, start + offset))
        }
        if let c = clip, c.range.isWholeCols { clip = nil }
    }

    // MARK: Insert and delete

    @objc func insertRows(_ sender: Any?) {
        commitEditing()
        let r = sel.last
        let n = r.rowCount
        guard n < maxRows else { tell("Select fewer rows to insert."); return }
        guard used.rows + n <= maxRows else { tell("Rows can't be inserted here", "That would push data off the end of the sheet."); return }
        let act = sel.active
        doc.edit(n == 1 ? "Insert Row" : "Insert Rows") { wb in
            wb.sheets[wb.active].remapRows(Sheet.insertMap(at: r.r0, count: n))
            wb.sheets[wb.active].selection = r.isWholeRows ? .covering(r, active: act) : wb.sheets[wb.active].selection
        }
    }

    @objc func insertColumns(_ sender: Any?) {
        commitEditing()
        let r = sel.last
        let n = r.colCount
        guard n < maxCols else { tell("Select fewer columns to insert."); return }
        guard used.cols + n <= maxCols else { tell("Columns can't be inserted here", "That would push data off the edge of the sheet."); return }
        doc.edit(n == 1 ? "Insert Column" : "Insert Columns") { wb in
            wb.sheets[wb.active].remapCols(Sheet.insertMap(at: r.c0, count: n))
        }
    }

    @objc func deleteRows(_ sender: Any?) {
        commitEditing()
        let r = sel.last
        guard r.rowCount < maxRows else { tell("Select the rows to delete first."); return }
        let act = sel.active
        doc.edit(r.rowCount == 1 ? "Delete Row" : "Delete Rows") { wb in
            wb.sheets[wb.active].remapRows(Sheet.deleteMap(at: r.r0, count: r.rowCount))
            wb.sheets[wb.active].selection = r.isWholeRows ? .covering(r, active: act) : Selection(CellAddr(r.r0, act.col))
        }
    }

    @objc func deleteColumns(_ sender: Any?) {
        commitEditing()
        let r = sel.last
        guard r.colCount < maxCols else { tell("Select the columns to delete first."); return }
        let act = sel.active
        doc.edit(r.colCount == 1 ? "Delete Column" : "Delete Columns") { wb in
            wb.sheets[wb.active].remapCols(Sheet.deleteMap(at: r.c0, count: r.colCount))
            wb.sheets[wb.active].selection = r.isWholeCols ? .covering(r, active: act) : Selection(CellAddr(act.row, r.c0))
        }
    }

    /// Right-click a row number after cutting rows: puts them in above it.
    @objc func insertCutCells(_ sender: Any?) {
        commitEditing()
        guard let c = clip, c.sheetIndex == doc.workbook.active else { return }
        let target = sel.last
        if c.range.isWholeRows {
            let t = target.r0
            if !c.isCut || t < c.range.r0 || t > c.range.r1 + 1 { moveRows(c.range.r0, c.range.rowCount, to: t, copy: !c.isCut) }
            if c.isCut { clip = nil }
        } else if c.range.isWholeCols {
            let t = target.c0
            if !c.isCut || t < c.range.c0 || t > c.range.c1 + 1 { moveCols(c.range.c0, c.range.colCount, to: t, copy: !c.isCut) }
            if c.isCut { clip = nil }
        } else {
            paste(sender)
        }
    }

    @objc func delete(_ sender: Any?) { clearContents(sender) }

    @objc func clearContents(_ sender: Any?) {
        commitEditing()
        let s = sel
        guard s.ranges.contains(where: { sheet.hasValues(in: $0) }) else { return }
        doc.edit("Clear") { wb in for rg in s.ranges { wb.sheets[wb.active].clearContents(in: rg) } }
    }

    // MARK: Fill colour

    @objc func fillWithColour(_ sender: Any?) { applyFill(fillColor) }
    @objc func noFill(_ sender: Any?) { applyFill(nil) }

    func applyFill(_ rgb: RGB?) {
        let styles = doc.styles
        restyleSelection(rgb == nil ? "No Fill" : "Fill Colour") { styles.withFill($0, rgb) }
        fillButton.update()
    }

    /// Gives every selected cell (and selected whole rows and columns) the format `change` makes from its own.
    private func restyleSelection(_ action: String, fitRows: Bool = false, _ change: (Int) -> Int) {
        commitEditing()
        let usedRows = used.rows
        doc.edit(action) { wb in
            var sh = wb.sheet
            func restyle(_ addrs: [CellAddr]) {
                for a in addrs {
                    var c = sh.cell(a) ?? Cell(style: sh.styleAt(a))
                    c.style = change(c.style)
                    sh.setCell(a, c)
                }
            }
            func stored(_ r: CellRange) -> [CellAddr] {
                var out: [CellAddr] = []
                sh.forEachCell(in: r) { a, _ in out.append(a) }
                return out
            }
            for rg in sh.selection.ranges {
                if rg.isWholeRows && rg.isWholeCols {
                    for c in 0..<maxCols { sh.colStyles[c] = change(sh.colStyles[c] ?? 0) }
                    for (r, s) in sh.rowStyles { sh.rowStyles[r] = change(s) }
                    restyle(stored(rg))
                } else if rg.isWholeRows {
                    let cellsBefore = stored(rg)
                    for r in rg.r0...rg.r1 { sh.rowStyles[r] = change(sh.rowStyles[r] ?? 0) }
                    restyle(cellsBefore)
                } else if rg.isWholeCols {
                    let cellsBefore = stored(rg)
                    for c in rg.c0...rg.c1 { sh.colStyles[c] = change(sh.colStyles[c] ?? 0) }
                    // Rows with their own format win over column formats, so give those crossings their own cells.
                    var crossings: [CellAddr] = []
                    for r in sh.rowStyles.keys { for c in rg.c0...rg.c1 where sh.cell(CellAddr(r, c)) == nil { crossings.append(CellAddr(r, c)) } }
                    restyle(cellsBefore + crossings)
                } else {
                    var addrs: [CellAddr] = []
                    addrs.reserveCapacity(rg.rowCount * rg.colCount)
                    for r in rg.r0...rg.r1 { for c in rg.c0...rg.c1 { addrs.append(CellAddr(r, c)) } }
                    restyle(addrs)
                }
            }
            if fitRows {
                // Rows grow to fit bigger text, and shrink back, unless they were sized by hand.
                var rows = Set<Int>()
                for rg in sh.selection.ranges {
                    let hi = rg.isWholeCols ? min(rg.r1, max(usedRows, rg.r0 + 1) - 1) : rg.r1
                    if hi - rg.r0 <= 200_000 { for r in rg.r0...max(rg.r0, hi) { rows.insert(r) } }
                }
                self.fitRows(rows, in: &sh)
            }
            wb.sheet = sh
        }
    }

    /// Sets each row that isn't sized by hand to the height its text needs.
    private func fitRows(_ rows: Set<Int>, in sh: inout Sheet) {
        var groups: [Double?: [Int]] = [:]
        for r in rows where sh.rows.customSize(r) == nil || sh.autoHeights.contains(r) {
            groups[fitHeight(row: r, sh), default: []].append(r)
        }
        for (size, keys) in groups {
            sh.rows.set(keys, size: size)
            if size == nil { sh.autoHeights.subtract(keys) } else { sh.autoHeights.formUnion(keys) }
        }
    }

    // MARK: Bold, italic and font size

    @objc func toggleBold(_ sender: Any?) {
        let on = !doc.styles[sheet.styleAt(sel.active)].bold
        let styles = doc.styles
        restyleSelection(on ? "Bold" : "Not Bold") { styles.withFont($0, bold: on) }
    }

    @objc func toggleItalic(_ sender: Any?) {
        let on = !doc.styles[sheet.styleAt(sel.active)].italic
        let styles = doc.styles
        restyleSelection(on ? "Italic" : "Not Italic") { styles.withFont($0, italic: on) }
    }

    func setFontSize(_ size: Double) {
        let styles = doc.styles
        restyleSelection("Font Size", fitRows: true) { styles.withFont($0, size: size) }
    }

    @objc func fontSizeChosen(_ sender: Any?) {
        let text = fontSizeBox.stringValue.trimmingCharacters(in: .whitespaces)
        guard let v = Double(text), v >= 1, v <= 409 else {
            NSSound.beep()
            updateFontControls()
            focusGrid()
            return
        }
        setFontSize((v * 2).rounded() / 2)
        focusGrid()
    }

    /// Each cell steps to the next size in Excel's list, as Excel's Increase Font Size does.
    @objc func increaseFontSize(_ sender: Any?) {
        let styles = doc.styles
        restyleSelection("Increase Font Size", fitRows: true) { s in
            let cur = styles[s].size
            return styles.withFont(s, size: SheetWindowController.fontSizes.first { $0 > cur } ?? cur)
        }
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        let styles = doc.styles
        restyleSelection("Decrease Font Size", fitRows: true) { s in
            let cur = styles[s].size
            return styles.withFont(s, size: SheetWindowController.fontSizes.last { $0 < cur } ?? cur)
        }
    }

    // MARK: Clipboard

    @objc func copy(_ sender: Any?) { putOnClipboard(cut: false) }
    @objc func cut(_ sender: Any?) { putOnClipboard(cut: true) }

    private func putOnClipboard(cut: Bool) {
        commitEditing()
        guard sel.ranges.count == 1 else { tell("That command can't be used on multiple selections."); return }
        let r = sel.last
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tsv(sheet, r), forType: .string)
        clip = Clip(range: r, sheetIndex: doc.workbook.active, isCut: cut, changeCount: pb.changeCount, source: sheet)
    }

    private func tsv(_ sh: Sheet, _ r: CellRange) -> String {
        let u = sh.usedSize()
        let r1 = min(r.r1, max(r.r0, u.rows - 1)), c1 = min(r.c1, max(r.c0, u.cols - 1))
        var lines: [String] = []
        for row in r.r0...r1 {
            var fields: [String] = []
            for col in r.c0...c1 {
                var s = ""
                if let cell = sh.cell(CellAddr(row, col)), let t = cellText(cell, doc.styles[cell.style], zoom: 1, date1904: doc.date1904) { s = t.text }
                if s.contains("\t") || s.contains("\n") || s.contains("\"") { s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                fields.append(s)
            }
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func parseTSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        if chars.last == "\n" { chars.removeLast() }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" && field.isEmpty {
                quoted = true
            } else if ch == "\t" {
                row.append(field); field = ""
            } else if ch == "\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(ch)
            }
            i += 1
        }
        row.append(field)
        rows.append(row)
        return rows
    }

    @objc func paste(_ sender: Any?) {
        commitEditing()
        let pb = NSPasteboard.general
        let dest = sel.last.topLeft
        if let c = clip, pb.changeCount == c.changeCount {
            let dr = dest.row - c.range.r0, dc = dest.col - c.range.c0
            if c.isCut {
                if c.sheetIndex == doc.workbook.active {
                    if dr != 0 || dc != 0 { moveBlock(c.range, by: dr, dc, copy: false, confirm: false) }
                } else {
                    pasteCells(from: c.source, c.range, to: dest) { wb in
                        if c.sheetIndex < wb.sheets.count { wb.sheets[c.sheetIndex].removeCells(in: c.range) }
                    }
                }
                clip = nil
            } else {
                pasteCells(from: c.source, c.range, to: dest)
            }
            return
        }
        if let text = pb.string(forType: .string) { pasteText(text, at: dest) }
    }

    private func pasteCells(from src: Sheet, _ r: CellRange, to dest: CellAddr, also: ((inout Workbook) -> Void)? = nil) {
        let dr = dest.row - r.r0, dc = dest.col - r.c0
        let dst = CellRange(dest.row, dest.col, min(maxRows - 1, r.r1 + dr), min(maxCols - 1, r.c1 + dc))
        doc.edit("Paste") { wb in
            var sh = wb.sheet
            sh.removeCells(in: dst)
            src.forEachCell(in: r) { a, cell in
                let b = CellAddr(a.row + dr, a.col + dc)
                if b.row < maxRows && b.col < maxCols { sh.cells[b.row, default: [:]][b.col] = cell }
            }
            if r.isWholeRows { for (row, s) in src.rowStyles where row >= r.r0 && row <= r.r1 && row + dr < maxRows { sh.rowStyles[row + dr] = s } }
            if r.isWholeCols { for (col, s) in src.colStyles where col >= r.c0 && col <= r.c1 && col + dc < maxCols { sh.colStyles[col + dc] = s } }
            sh.selection = .covering(dst, active: dest)
            wb.sheet = sh
            also?(&wb)
        }
    }

    private func pasteText(_ text: String, at dest: CellAddr) {
        let rows = parseTSV(text)
        guard !rows.isEmpty else { return }
        let styles = doc.styles
        doc.edit("Paste") { wb in
            var sh = wb.sheet
            for (i, fields) in rows.enumerated() {
                for (j, f) in fields.enumerated() {
                    let a = CellAddr(dest.row + i, dest.col + j)
                    guard a.row < maxRows, a.col < maxCols else { continue }
                    SheetWindowController.put(parseEntry(f), at: a, in: &sh, styles: styles)
                }
            }
            let r1 = min(maxRows - 1, dest.row + rows.count - 1)
            let c1 = min(maxCols - 1, dest.col + max(1, rows.map(\.count).max() ?? 1) - 1)
            let r = CellRange(dest.row, dest.col, r1, c1)
            sh.selection = r.isSingle ? Selection(dest) : .covering(r, active: dest)
            wb.sheet = sh
        }
    }

    // MARK: Sheets

    func selectSheet(_ i: Int) {
        guard i != doc.workbook.active, i >= 0, i < doc.workbook.sheets.count else { return }
        commitEditing()
        doc.workbook.active = i
        documentChanged()
        scrollTo(sel.active)
    }

    @objc func insertSheet(_ sender: Any?) {
        commitEditing()
        var n = doc.workbook.sheets.count + 1
        let names = Set(doc.workbook.sheets.map { $0.name.lowercased() })
        while names.contains("sheet\(n)") { n += 1 }
        doc.edit("Insert Sheet") { wb in
            wb.sheets.insert(Sheet(name: "Sheet\(n)"), at: wb.active + 1)
            wb.active += 1
        }
    }

    @objc func deleteSheet(_ sender: Any?) {
        commitEditing()
        guard doc.workbook.sheets.count > 1 else { tell("A workbook needs at least one sheet."); return }
        doc.edit("Delete Sheet") { wb in
            wb.sheets.remove(at: wb.active)
            wb.active = min(wb.active, wb.sheets.count - 1)
        }
    }

    @objc func renameActiveSheet(_ sender: Any?) { renameSheet(doc.workbook.active) }

    func renameSheet(_ i: Int) {
        commitEditing()
        guard let name = ask("Rename Sheet", "A sheet name can be up to 31 characters, without : \\ / ? * [ or ].", doc.workbook.sheets[i].name) else { return }
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.count > 31 || t.contains(where: { ":\\/?*[]".contains($0) }) || t.hasPrefix("'") || t.hasSuffix("'") {
            tell("That sheet name can't be used.", "Use 1 to 31 characters, without : \\ / ? * [ or ], and not starting or ending with '.")
            return
        }
        if doc.workbook.sheets.enumerated().contains(where: { $0.offset != i && $0.element.name.lowercased() == t.lowercased() }) {
            tell("Another sheet already has that name.")
            return
        }
        guard t != doc.workbook.sheets[i].name else { return }
        doc.edit("Rename Sheet") { wb in wb.sheets[i].name = t }
    }

    // MARK: Zoom

    func setZoom(_ value: CGFloat) {
        let z = min(4, max(0.1, value))
        guard abs(z - zoom) > 0.001 else { return }
        commitEditing()
        let g = geo
        let vis = clipBounds
        let topRow = g.row(at: vis.minY), leftCol = g.col(at: vis.minX)
        zoom = z
        UserDefaults.standard.set(Double(z), forKey: "zoom")
        rowHeaderWidth = neededRowHeaderWidth()
        layoutViews()
        let g2 = geo
        scroll.contentView.scroll(to: NSPoint(x: g2.x(leftCol), y: g2.y(topRow)))
        scroll.reflectScrolledClipView(scroll.contentView)
        tabs.updateZoom()
        redrawAll()
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(((zoom * 10).rounded() + 1) / 10) }
    @objc func zoomOut(_ sender: Any?) { setZoom(((zoom * 10).rounded() - 1) / 10) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    // MARK: Toolbar and menus

    @objc private func undoPressed() { commitEditing(); doc.undoManager?.undo() }
    @objc private func redoPressed() { commitEditing(); doc.undoManager?.redo() }

    private func item(_ m: NSMenu, _ title: String, _ action: Selector) {
        let i = m.addItem(withTitle: title, action: action, keyEquivalent: "")
        i.target = self
    }

    private func popUp(_ m: NSMenu, from sender: Any?) {
        guard let v = sender as? NSView else { return }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: v.isFlipped ? v.bounds.height + 4 : -4), in: v)
    }

    @objc private func showInsertMenu(_ sender: Any?) {
        let m = NSMenu()
        item(m, "Insert Rows Above", #selector(insertRows(_:)))
        item(m, "Insert Columns to the Left", #selector(insertColumns(_:)))
        if clip != nil { item(m, clip!.isCut ? "Insert Cut Cells" : "Insert Copied Cells", #selector(insertCutCells(_:))) }
        m.addItem(.separator())
        item(m, "Insert Sheet", #selector(insertSheet(_:)))
        popUp(m, from: sender)
    }

    @objc private func showDeleteMenu(_ sender: Any?) {
        let m = NSMenu()
        item(m, "Delete Rows", #selector(deleteRows(_:)))
        item(m, "Delete Columns", #selector(deleteColumns(_:)))
        item(m, "Clear Contents", #selector(clearContents(_:)))
        m.addItem(.separator())
        item(m, "Delete Sheet", #selector(deleteSheet(_:)))
        popUp(m, from: sender)
    }

    @objc private func showFormatMenu(_ sender: Any?) {
        let m = NSMenu()
        item(m, "Row Height…", #selector(rowHeightDialog(_:)))
        item(m, "AutoFit Row Height", #selector(autofitRows(_:)))
        item(m, "Column Width…", #selector(columnWidthDialog(_:)))
        item(m, "AutoFit Column Width", #selector(autofitColumns(_:)))
        m.addItem(.separator())
        item(m, "Hide Rows", #selector(hideRows(_:)))
        item(m, "Unhide Rows", #selector(unhideRows(_:)))
        item(m, "Hide Columns", #selector(hideColumns(_:)))
        item(m, "Unhide Columns", #selector(unhideColumns(_:)))
        m.addItem(.separator())
        item(m, "Rename Sheet…", #selector(renameActiveSheet(_:)))
        popUp(m, from: sender)
    }

    func cellMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Cut", #selector(cut(_:)))
        item(m, "Copy", #selector(copy(_:)))
        item(m, "Paste", #selector(paste(_:)))
        if clip != nil { item(m, clip!.isCut ? "Insert Cut Cells" : "Insert Copied Cells", #selector(insertCutCells(_:))) }
        m.addItem(.separator())
        item(m, "Insert Rows Above", #selector(insertRows(_:)))
        item(m, "Insert Columns to the Left", #selector(insertColumns(_:)))
        item(m, "Delete Rows", #selector(deleteRows(_:)))
        item(m, "Delete Columns", #selector(deleteColumns(_:)))
        m.addItem(.separator())
        item(m, "Clear Contents", #selector(clearContents(_:)))
        item(m, "Fill Colour", #selector(fillWithColour(_:)))
        item(m, "No Fill", #selector(noFill(_:)))
        item(m, "Bold", #selector(toggleBold(_:)))
        item(m, "Italic", #selector(toggleItalic(_:)))
        m.addItem(.separator())
        item(m, "Row Height…", #selector(rowHeightDialog(_:)))
        item(m, "Column Width…", #selector(columnWidthDialog(_:)))
        return m
    }

    func headerMenu(rows: Bool) -> NSMenu {
        let m = NSMenu()
        item(m, "Cut", #selector(cut(_:)))
        item(m, "Copy", #selector(copy(_:)))
        item(m, "Paste", #selector(paste(_:)))
        if let c = clip, rows ? c.range.isWholeRows : c.range.isWholeCols {
            item(m, (c.isCut ? "Insert Cut " : "Insert Copied ") + (rows ? "Rows" : "Columns"), #selector(insertCutCells(_:)))
        }
        m.addItem(.separator())
        item(m, rows ? "Insert Rows" : "Insert Columns", rows ? #selector(insertRows(_:)) : #selector(insertColumns(_:)))
        item(m, rows ? "Delete Rows" : "Delete Columns", rows ? #selector(deleteRows(_:)) : #selector(deleteColumns(_:)))
        item(m, "Clear Contents", #selector(clearContents(_:)))
        m.addItem(.separator())
        item(m, "Fill Colour", #selector(fillWithColour(_:)))
        item(m, "No Fill", #selector(noFill(_:)))
        m.addItem(.separator())
        item(m, rows ? "Row Height…" : "Column Width…", rows ? #selector(rowHeightDialog(_:)) : #selector(columnWidthDialog(_:)))
        item(m, rows ? "AutoFit Row Height" : "AutoFit Column Width", rows ? #selector(autofitRows(_:)) : #selector(autofitColumns(_:)))
        item(m, rows ? "Hide" : "Hide", rows ? #selector(hideRows(_:)) : #selector(hideColumns(_:)))
        item(m, rows ? "Unhide" : "Unhide", rows ? #selector(unhideRows(_:)) : #selector(unhideColumns(_:)))
        return m
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paste(_:))?:
            return clip != nil || NSPasteboard.general.string(forType: .string) != nil
        case #selector(insertCutCells(_:))?:
            return clip != nil && clip!.sheetIndex == doc.workbook.active
        case #selector(deleteSheet(_:))?:
            return doc.workbook.sheets.count > 1
        case #selector(unhideRows(_:))?:
            return !sheet.rows.hidden.isEmpty
        case #selector(unhideColumns(_:))?:
            return !sheet.cols.hidden.isEmpty
        case #selector(toggleBold(_:))?:
            menuItem.state = doc.styles[sheet.styleAt(sel.active)].bold ? .on : .off
            return true
        case #selector(toggleItalic(_:))?:
            menuItem.state = doc.styles[sheet.styleAt(sel.active)].italic ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        marqueeTimer?.invalidate()
        marqueeTimer = nil
        SizeTip.shared.hide()
        NotificationCenter.default.removeObserver(self)
        AppDelegate.workbookClosed()
    }
}
