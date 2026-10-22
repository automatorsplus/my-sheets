import AppKit

// MARK: - Cursors, drawn to look like Excel's

enum Cursors {
    private static func make(_ size: CGFloat, hot: NSPoint, _ draw: @escaping () -> Void) -> NSCursor {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in draw(); return true }
        return NSCursor(image: img, hotSpot: hot)
    }

    private static func outlined(_ path: NSBezierPath, fill: NSColor = .black, stroke: NSColor = .white, width: CGFloat = 2) {
        path.lineJoinStyle = .miter
        path.lineWidth = width
        stroke.setStroke(); path.stroke()
        fill.setFill(); path.fill()
    }

    /// The chunky white plus Excel shows over cells.
    static let cell: NSCursor = make(22, hot: NSPoint(x: 11, y: 11)) {
        let c: CGFloat = 11, a: CGFloat = 3, l: CGFloat = 9
        let p = NSBezierPath()
        let pts: [(CGFloat, CGFloat)] = [(c - a, c - l), (c + a, c - l), (c + a, c - a), (c + l, c - a), (c + l, c + a), (c + a, c + a),
                                         (c + a, c + l), (c - a, c + l), (c - a, c + a), (c - l, c + a), (c - l, c - a), (c - a, c - a)]
        p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
        p.close()
        p.lineWidth = 1
        NSColor.white.setFill(); p.fill()
        NSColor.black.setStroke(); p.stroke()
    }

    private static func splitArrow(vertical: Bool, double: Bool) -> NSCursor {
        make(24, hot: NSPoint(x: 12, y: 12)) {
            let t = NSAffineTransform()
            if vertical {
                t.translateX(by: 12, yBy: 12); t.rotate(byDegrees: 90); t.translateX(by: -12, yBy: -12)
                t.concat()
            }
            let bar = NSBezierPath()
            if double {
                bar.appendRect(NSRect(x: 9.5, y: 4, width: 1.5, height: 16))
                bar.appendRect(NSRect(x: 13, y: 4, width: 1.5, height: 16))
            } else {
                bar.appendRect(NSRect(x: 11, y: 4, width: 2, height: 16))
            }
            let arrows = NSBezierPath()
            // Left arrow
            arrows.move(to: NSPoint(x: 1, y: 12)); arrows.line(to: NSPoint(x: 6, y: 7)); arrows.line(to: NSPoint(x: 6, y: 10.5))
            arrows.line(to: NSPoint(x: 9, y: 10.5)); arrows.line(to: NSPoint(x: 9, y: 13.5)); arrows.line(to: NSPoint(x: 6, y: 13.5))
            arrows.line(to: NSPoint(x: 6, y: 17)); arrows.close()
            // Right arrow
            arrows.move(to: NSPoint(x: 23, y: 12)); arrows.line(to: NSPoint(x: 18, y: 7)); arrows.line(to: NSPoint(x: 18, y: 10.5))
            arrows.line(to: NSPoint(x: 15, y: 10.5)); arrows.line(to: NSPoint(x: 15, y: 13.5)); arrows.line(to: NSPoint(x: 18, y: 13.5))
            arrows.line(to: NSPoint(x: 18, y: 17)); arrows.close()
            arrows.append(bar)
            outlined(arrows)
        }
    }

    static let colResize = splitArrow(vertical: false, double: false)
    static let rowResize = splitArrow(vertical: true, double: false)
    static let colUnhide = splitArrow(vertical: false, double: true)
    static let rowUnhide = splitArrow(vertical: true, double: true)

    /// Four-way arrow, for dragging a selection to move it.
    static let move: NSCursor = make(24, hot: NSPoint(x: 12, y: 12)) {
        let p = NSBezierPath()
        let c: CGFloat = 12
        func head(_ dx: CGFloat, _ dy: CGFloat) {
            let tip = NSPoint(x: c + dx * 11, y: c + dy * 11)
            let base = NSPoint(x: c + dx * 6, y: c + dy * 6)
            p.move(to: tip)
            p.line(to: NSPoint(x: base.x + dy * 4, y: base.y + dx * 4))
            p.line(to: NSPoint(x: base.x - dy * 4, y: base.y - dx * 4))
            p.close()
        }
        head(1, 0); head(-1, 0); head(0, 1); head(0, -1)
        p.appendRect(NSRect(x: c - 7, y: c - 1, width: 14, height: 2))
        p.appendRect(NSRect(x: c - 1, y: c - 7, width: 2, height: 14))
        outlined(p)
    }

    private static func selectArrow(down: Bool) -> NSCursor {
        make(16, hot: NSPoint(x: 8, y: 8)) {
            let t = NSAffineTransform()
            if !down { t.translateX(by: 8, yBy: 8); t.rotate(byDegrees: -90); t.translateX(by: -8, yBy: -8); t.concat() }
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 6, y: 1)); p.line(to: NSPoint(x: 10, y: 1)); p.line(to: NSPoint(x: 10, y: 8))
            p.line(to: NSPoint(x: 14, y: 8)); p.line(to: NSPoint(x: 8, y: 15)); p.line(to: NSPoint(x: 2, y: 8))
            p.line(to: NSPoint(x: 6, y: 8)); p.close()
            outlined(p, width: 1.5)
        }
    }

    static let colSelect = selectArrow(down: true)
    static let rowSelect = selectArrow(down: false)
}

// MARK: - The "Width: 8.43 (64 pixels)" label while dragging an edge

final class SizeTip {
    static let shared = SizeTip()
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 28), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.backgroundColor = NSColor(white: 1, alpha: 1)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .black
        panel.contentView = label
    }

    func show(_ text: String, at screenPoint: NSPoint) {
        label.stringValue = "  " + text + "  "
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 4, height: label.frame.height + 8)
        label.frame = NSRect(x: 2, y: 4, width: label.frame.width, height: label.frame.height)
        panel.setFrame(NSRect(x: screenPoint.x, y: screenPoint.y, width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() { panel.orderOut(nil) }
}

// MARK: - Sheet tabs and zoom

final class TabsBar: NSView {
    unowned let ctl: SheetWindowController
    private var tabRects: [NSRect] = []
    private var addRect = NSRect.zero
    let zoomSlider = NSSlider(value: 100, minValue: 10, maxValue: 400, target: nil, action: nil)
    let zoomLabel = NSTextField(labelWithString: "100%")
    let modeLabel = NSTextField(labelWithString: "Ready")
    private let minus = NSButton(title: "−", target: nil, action: nil)
    private let plus = NSButton(title: "+", target: nil, action: nil)
    private let font = NSFont.systemFont(ofSize: 14)
    private let boldFont = NSFont.systemFont(ofSize: 14, weight: .semibold)

    init(ctl: SheetWindowController) {
        self.ctl = ctl
        super.init(frame: .zero)
        clipsToBounds = true
        for b in [minus, plus] {
            b.bezelStyle = .inline
            b.isBordered = false
            b.font = .systemFont(ofSize: 20, weight: .medium)
            b.target = self
            addSubview(b)
        }
        minus.action = #selector(zoomOut)
        plus.action = #selector(zoomIn)
        zoomSlider.target = self
        zoomSlider.action = #selector(sliderMoved)
        zoomSlider.controlSize = .small
        addSubview(zoomSlider)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        zoomLabel.alignment = .right
        addSubview(zoomLabel)
        modeLabel.font = .systemFont(ofSize: 13)
        modeLabel.textColor = .secondaryLabelColor
        addSubview(modeLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let h = bounds.height
        zoomLabel.frame = NSRect(x: bounds.width - 58, y: (h - 18) / 2, width: 50, height: 18)
        plus.frame = NSRect(x: bounds.width - 86, y: (h - 26) / 2, width: 26, height: 26)
        zoomSlider.frame = NSRect(x: bounds.width - 216, y: (h - 20) / 2, width: 128, height: 20)
        minus.frame = NSRect(x: bounds.width - 244, y: (h - 26) / 2, width: 26, height: 26)
        modeLabel.frame = NSRect(x: bounds.width - 320, y: (h - 18) / 2, width: 70, height: 18)
    }

    func updateZoom() {
        zoomSlider.doubleValue = Double(ctl.zoom * 100)
        zoomLabel.stringValue = "\(Int((ctl.zoom * 100).rounded()))%"
    }

    @objc private func zoomOut() { ctl.setZoom(((ctl.zoom * 10).rounded() - 1) / 10) }
    @objc private func zoomIn() { ctl.setZoom(((ctl.zoom * 10).rounded() + 1) / 10) }
    @objc private func sliderMoved() { ctl.setZoom(CGFloat(zoomSlider.doubleValue / 100)) }

    override func draw(_ dirty: NSRect) {
        Palette.chrome.setFill(); bounds.fill()
        Palette.headerLine.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let book = ctl.doc.workbook
        var x: CGFloat = 12
        tabRects = []
        let limit = bounds.width - 330
        for (i, s) in book.sheets.enumerated() {
            let active = i == book.active
            let attrs: [NSAttributedString.Key: Any] = [.font: active ? boldFont : font,
                                                        .foregroundColor: active ? Palette.accent : NSColor(white: 0.25, alpha: 1)]
            let w = ceil((s.name as NSString).size(withAttributes: attrs).width) + 28
            let r = NSRect(x: x, y: 1, width: w, height: bounds.height - 1)
            tabRects.append(r)
            if r.minX < limit {
                if active {
                    NSColor.white.setFill(); r.fill()
                    Palette.accent.setFill()
                    NSRect(x: r.minX + 8, y: r.maxY - 4, width: r.width - 16, height: 3).fill()
                }
                Palette.headerLine.setFill()
                NSRect(x: r.maxX, y: 7, width: 1, height: bounds.height - 14).fill()
                let size = (s.name as NSString).size(withAttributes: attrs)
                (s.name as NSString).draw(at: NSPoint(x: r.minX + 14, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            }
            x += w + 1
        }
        addRect = NSRect(x: x + 6, y: (bounds.height - 24) / 2, width: 24, height: 24)
        if addRect.maxX < limit {
            let circle = NSBezierPath(ovalIn: addRect.insetBy(dx: 1, dy: 1))
            NSColor(white: 0.35, alpha: 1).setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
            let plusPath = NSBezierPath()
            plusPath.move(to: NSPoint(x: addRect.midX - 6, y: addRect.midY)); plusPath.line(to: NSPoint(x: addRect.midX + 6, y: addRect.midY))
            plusPath.move(to: NSPoint(x: addRect.midX, y: addRect.midY - 6)); plusPath.line(to: NSPoint(x: addRect.midX, y: addRect.midY + 6))
            plusPath.lineWidth = 1.6
            plusPath.stroke()
        }
    }

    private func tab(at p: NSPoint) -> Int? { tabRects.firstIndex { $0.contains(p) } }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if addRect.contains(p) { ctl.insertSheet(nil); return }
        guard let i = tab(at: p) else { return }
        ctl.selectSheet(i)
        if e.clickCount == 2 { ctl.renameSheet(i) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = tab(at: convert(event.locationInWindow, from: nil)) else { return nil }
        ctl.selectSheet(i)
        let m = NSMenu()
        m.addItem(withTitle: "Insert Sheet", action: #selector(SheetWindowController.insertSheet(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Rename…", action: #selector(SheetWindowController.renameActiveSheet(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Delete Sheet", action: #selector(SheetWindowController.deleteSheet(_:)), keyEquivalent: "")
        for item in m.items { item.target = ctl }
        return m
    }
}

// MARK: - Fill colour

/// Excel's Fill Color palette: theme colours with their lighter and darker shades, then the standard colours.
final class PaletteView: NSView {
    var onPick: ((RGB?) -> Void)?
    private let swatch: CGFloat = 24
    private let gap: CGFloat = 4
    private var cells: [(NSRect, RGB?)] = []

    static let themeBase: [UInt32] = [0xFFFFFF, 0x000000, 0xE7E6E6, 0x44546A, 0x4472C4, 0xED7D31, 0xA5A5A5, 0xFFC000, 0x5B9BD5, 0x70AD47]
    static let standard: [UInt32] = [0xC00000, 0xFF0000, 0xFFC000, 0xFFFF00, 0x92D050, 0x00B050, 0x00B0F0, 0x0070C0, 0x002060, 0x7030A0]

    static func shades(_ i: Int) -> [Double] {
        switch i {
        case 0: return [-0.05, -0.15, -0.25, -0.35, -0.5]
        case 1: return [0.5, 0.35, 0.25, 0.15, 0.05]
        case 2: return [-0.1, -0.25, -0.5, -0.75, -0.9]
        default: return [0.8, 0.6, 0.4, -0.25, -0.5]
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 10 * 24 + 9 * 4 + 24, height: 330))
        clipsToBounds = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let inset: CGFloat = 12
        var y: CGFloat = 66
        cells.append((NSRect(x: inset, y: 8, width: bounds.width - 2 * inset, height: 26), nil))
        for (i, base) in PaletteView.themeBase.enumerated() {
            let x = inset + CGFloat(i) * (swatch + gap)
            let b = RGB(hex: base)
            cells.append((NSRect(x: x, y: y, width: swatch, height: swatch), b))
            for (k, t) in PaletteView.shades(i).enumerated() {
                cells.append((NSRect(x: x, y: y + swatch + 6 + CGFloat(k) * (swatch + 2), width: swatch, height: swatch), b.tinted(t)))
            }
        }
        y += swatch + 6 + 5 * (swatch + 2) + 34
        for (i, c) in PaletteView.standard.enumerated() {
            cells.append((NSRect(x: inset + CGFloat(i) * (swatch + gap), y: y, width: swatch, height: swatch), RGB(hex: c)))
        }
        setFrameSize(NSSize(width: bounds.width, height: y + swatch + 14))
    }

    override func draw(_ dirty: NSRect) {
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        ("Theme Colours" as NSString).draw(at: NSPoint(x: 12, y: 44), withAttributes: label)
        for (r, c) in cells {
            if let c {
                c.color.setFill(); r.fill()
                NSColor(white: 0.6, alpha: 1).setStroke()
                NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            } else {
                NSColor(white: 0.93, alpha: 1).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
                let t: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
                let s = ("No Fill" as NSString).size(withAttributes: t)
                ("No Fill" as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: t)
            }
        }
        if let first = cells.last {
            ("Standard Colours" as NSString).draw(at: NSPoint(x: 12, y: first.0.minY - 20), withAttributes: label)
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let hit = cells.first(where: { $0.0.contains(p) }) { onPick?(hit.1) }
    }
}

/// The paint-bucket button: click to apply the last colour, click the arrow for the palette.
final class FillButton: NSView {
    unowned let ctl: SheetWindowController
    private let main = NSButton()
    private let arrow = NSButton()
    private let bar = NSView()
    private var popover: NSPopover?

    init(ctl: SheetWindowController) {
        self.ctl = ctl
        super.init(frame: NSRect(x: 0, y: 0, width: 92, height: 34))
        main.image = NSImage(systemSymbolName: "paintbrush.pointed.fill", accessibilityDescription: "Fill Colour")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        main.title = "Fill"
        main.imagePosition = .imageLeading
        main.font = .systemFont(ofSize: 14)
        main.bezelStyle = .texturedRounded
        main.isBordered = false
        main.target = self
        main.action = #selector(apply)
        main.toolTip = "Fill colour: highlight the selected cells"
        arrow.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Fill colours")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        arrow.isBordered = false
        arrow.target = self
        arrow.action = #selector(showPalette)
        arrow.toolTip = "Choose a fill colour"
        bar.wantsLayer = true
        addSubview(main); addSubview(arrow); addSubview(bar)
        main.frame = NSRect(x: 0, y: 4, width: 66, height: 24)
        arrow.frame = NSRect(x: 66, y: 4, width: 24, height: 24)
        bar.frame = NSRect(x: 6, y: 1, width: 56, height: 5)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update() { bar.layer?.backgroundColor = ctl.fillColor.color.cgColor }

    @objc private func apply() { ctl.applyFill(ctl.fillColor) }

    @objc private func showPalette() {
        let pv = PaletteView(frame: .zero)
        let vc = NSViewController()
        vc.view = pv
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pv.onPick = { [weak self, weak pop] c in
            pop?.close()
            guard let self else { return }
            if let c { self.ctl.fillColor = c; self.update() }
            self.ctl.applyFill(c)
        }
        pop.show(relativeTo: arrow.bounds, of: arrow, preferredEdge: .maxY)
        popover = pop
    }
}
