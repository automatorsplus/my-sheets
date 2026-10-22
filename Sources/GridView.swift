import AppKit

enum Palette {
    static let accent = NSColor(srgbRed: 16 / 255, green: 124 / 255, blue: 65 / 255, alpha: 1)
    static let grid = NSColor(white: 0.85, alpha: 1)
    static let headerBg = NSColor(white: 0.965, alpha: 1)
    static let headerLine = NSColor(white: 0.8, alpha: 1)
    static let headerText = NSColor(white: 0.3, alpha: 1)
    static let headerSelBg = NSColor(white: 0.87, alpha: 1)
    static let headerFullBg = NSColor(srgbRed: 0.78, green: 0.9, blue: 0.82, alpha: 1)
    static let headerSelText = NSColor(srgbRed: 0.04, green: 0.4, blue: 0.2, alpha: 1)
    static let shade = NSColor(srgbRed: 0.15, green: 0.2, blue: 0.17, alpha: 0.15)
    static let chrome = NSColor(white: 0.95, alpha: 1)
}

/// File font sizes are Calibri points; the system font at 13/11 of that looks about the same size.
let fontScale: CGFloat = 13.0 / 11.0

final class FontBook {
    private var cache: [String: NSFont] = [:]

    func font(_ st: CellStyle, zoom: CGFloat) -> NSFont {
        let size = max(4, (CGFloat(st.size) * fontScale * zoom * 2).rounded() / 2)
        let key = "\(size)|\(st.bold)|\(st.italic)"
        if let f = cache[key] { return f }
        var f = NSFont.systemFont(ofSize: size, weight: st.bold ? .bold : .regular)
        if st.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        cache[key] = f
        return f
    }
}

let fontBook = FontBook()

/// What a cell shows and how.
struct CellText {
    var text: String
    var font: NSFont
    var color: NSColor
    var align: NSTextAlignment
    /// Numbers show #### when they don't fit, instead of spilling into the next cell.
    var numeric: Bool
    var underline = false
    var strike = false

    var attrs: [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: attrs).width) }
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
}

func cellText(_ cell: Cell, _ st: CellStyle, zoom: CGFloat, date1904: Bool) -> CellText? {
    var text: String
    var align = NSTextAlignment.left
    var numeric = false
    var fmtColor: RGB? = nil
    var uncalculated = false
    switch cell.value {
    case nil:
        guard let f = cell.formula else { return nil }
        text = "=" + f
        uncalculated = true
    case .text(let s): text = s
    case .number(let v):
        let r = NumFmt.format(v, st.numFmt, date1904: date1904)
        text = r.text; fmtColor = r.color; align = .right; numeric = true
    case .bool(let b): text = b ? "TRUE" : "FALSE"; align = .center
    case .error(let e): text = e; align = .center
    }
    if text.isEmpty { return nil }
    switch st.hAlign {
    case "left"?: align = .left
    case "center"?, "centerContinuous"?: align = .center
    case "right"?: align = .right
    case "fill"?, "justify"?, "distributed"?: align = .left
    default: break
    }
    let color = uncalculated ? NSColor(white: 0.5, alpha: 1) : ((fmtColor ?? st.color)?.color ?? .black)
    return CellText(text: text, font: fontBook.font(st, zoom: zoom), color: color, align: align,
                    numeric: numeric, underline: st.underline, strike: st.strike)
}

/// Fills a frame of the given thickness just inside r, in the current fill colour.
func frameRect(_ r: NSRect, _ w: CGFloat) {
    NSRect(x: r.minX, y: r.minY, width: r.width, height: w).fill()
    NSRect(x: r.minX, y: r.maxY - w, width: r.width, height: w).fill()
    NSRect(x: r.minX, y: r.minY, width: w, height: r.height).fill()
    NSRect(x: r.maxX - w, y: r.minY, width: w, height: r.height).fill()
}

/// Positions on screen (points) for a sheet at a zoom.
struct Geo {
    let rows: Axis
    let cols: Axis
    let zoom: CGFloat

    func x(_ c: Int) -> CGFloat { (CGFloat(cols.offset(c)) * zoom).rounded() }
    func y(_ r: Int) -> CGFloat { (CGFloat(rows.offset(r)) * zoom).rounded() }
    func col(at v: CGFloat) -> Int { cols.index(at: Double(max(0, v) / zoom)) }
    func row(at v: CGFloat) -> Int { rows.index(at: Double(max(0, v) / zoom)) }
    func addr(at p: NSPoint) -> CellAddr { CellAddr(row(at: p.y), col(at: p.x)) }

    func rect(_ a: CellAddr) -> NSRect {
        let x0 = x(a.col), y0 = y(a.row)
        return NSRect(x: x0, y: y0, width: x(a.col + 1) - x0, height: y(a.row + 1) - y0)
    }

    func rect(_ r: CellRange) -> NSRect {
        let x0 = x(r.c0), y0 = y(r.r0)
        return NSRect(x: x0, y: y0, width: x(r.c1 + 1) - x0, height: y(r.r1 + 1) - y0)
    }
}

final class GridView: NSView {
    unowned let ctl: SheetWindowController

    /// Text being typed in the formula bar, shown live in the active cell.
    var previewText: String? { didSet { needsDisplay = true } }

    enum Feedback { case outline(CellRange), insertRows(Int), insertCols(Int) }
    var feedback: Feedback? { didSet { needsDisplay = true } }
    /// A see-through copy of rows or columns being dragged by their numbers or letters, in grid coordinates.
    var ghost: NSRect? { didSet { needsDisplay = true } }
    var marqueePhase: CGFloat = 0

    private enum MovePlan: Equatable { case nothing, insertRows(Int), insertCols(Int), shift(Int, Int, copy: Bool) }
    private enum Drag { case none, select, move(start: CellAddr, src: CellRange) }
    private var drag = Drag.none
    private var plan = MovePlan.nothing
    private var lastDrag: NSEvent?
    private var shiftClickAt: CellAddr?
    private var tracking: NSTrackingArea?

    init(ctl: SheetWindowController) {
        self.ctl = ctl
        super.init(frame: NSRect(x: 0, y: 0, width: 2000, height: 2000))
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // A click goes straight to the cell even when the window was in the background.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        let sh = ctl.sheet
        let z = ctl.zoom
        let g = Geo(rows: sh.rows, cols: sh.cols, zoom: z)
        let styles = ctl.doc.styles
        let date1904 = ctl.doc.date1904
        NSColor.white.setFill()
        dirty.fill()

        let r0 = g.row(at: dirty.minY), r1 = g.row(at: dirty.maxY)
        let c0 = g.col(at: dirty.minX), c1 = g.col(at: dirty.maxX)
        let rowY: [(Int, CGFloat, CGFloat)] = (r0...r1).filter { !sh.rows.isHidden($0) }.map { ($0, g.y($0), g.y($0 + 1)) }
        let colX: [(Int, CGFloat, CGFloat)] = (c0...c1).filter { !sh.cols.isHidden($0) }.map { ($0, g.x($0), g.x($0 + 1)) }

        // Gridlines: each cell's right and bottom edge.
        Palette.grid.setFill()
        for (_, _, x1) in colX { NSRect(x: x1 - 1, y: dirty.minY, width: 1, height: dirty.height).fill() }
        for (_, _, y1) in rowY { NSRect(x: dirty.minX, y: y1 - 1, width: dirty.width, height: 1).fill() }

        // Fills cover the gridlines around a cell, as in Excel. Borders are drawn later, on top.
        let baseHasLook = styles[0].fill != nil || styles[0].hasBorders
        var bordered: [(NSRect, CellStyle)] = []
        for (r, y0, y1) in rowY {
            let rc = sh.cells[r]
            let rowStyle = sh.rowStyles[r]
            if rc == nil && rowStyle == nil && sh.colStyles.isEmpty && !baseHasLook { continue }
            for (c, x0, x1) in colX {
                let s = rc?[c]?.style ?? rowStyle ?? sh.colStyles[c] ?? 0
                if s == 0 && !baseHasLook { continue }
                let st = styles[s]
                let full = NSRect(x: x0 - 1, y: y0 - 1, width: x1 - x0 + 1, height: y1 - y0 + 1)
                if let f = st.fill { f.color.setFill(); full.fill() }
                if st.hasBorders { bordered.append((full, st)) }
            }
        }

        // Cell text, working out where text spills into empty neighbours.
        struct Run { let rect: NSRect; let clip: NSRect; var t: CellText; let st: CellStyle }
        var runs: [Run] = []
        let pad = 3 * z
        let active = ctl.sel.active
        let editing = ctl.editor?.addr
        for (r, y0, y1) in rowY {
            var rowCells: [(Int, Cell)] = []
            let lo = max(0, c0 - 64), hi = min(maxCols - 1, c1 + 64)
            if let rc = sh.cells[r] {
                if rc.count <= 200 { for (c, cell) in rc where c >= lo && c <= hi { rowCells.append((c, cell)) } }
                else { for c in lo...hi { if let cell = rc[c] { rowCells.append((c, cell)) } } }
            }
            var previewCol: Int? = nil
            if let p = previewText, active.row == r, active.col >= lo, active.col <= hi {
                rowCells.removeAll { $0.0 == active.col }
                rowCells.append((active.col, Cell(value: .text(p), style: sh.styleAt(active))))
                previewCol = active.col
            }
            func empty(_ c: Int) -> Bool { c != previewCol && !sh.hasValue(CellAddr(r, c)) }
            for (c, cell) in rowCells.sorted(by: { $0.0 < $1.0 }) {
                if CellAddr(r, c) == editing || sh.cols.isHidden(c) { continue }
                let st = styles[cell.style]
                guard var t = cellText(cell, st, zoom: z, date1904: date1904) else { continue }
                if c == previewCol { t.align = .left; t.numeric = false }
                let x0 = g.x(c), x1 = g.x(c + 1)
                let rect = NSRect(x: x0, y: y0, width: x1 - x0 - 1, height: y1 - y0 - 1)
                var clip = rect
                let width = t.text.split(separator: "\n", omittingEmptySubsequences: false).map { t.width(String($0)) }.max() ?? 0
                if width + 2 * pad > rect.width && !st.wrap {
                    if t.numeric {
                        let hash = t.width("#")
                        let n = max(0, Int((rect.width - 2 * pad) / max(1, hash)))
                        t.text = String(repeating: "#", count: n)
                        t.align = .center
                    } else {
                        var left = c, right = c
                        let need = width + 2 * pad
                        func span() -> CGFloat { g.x(right + 1) - g.x(left) }
                        var steps = 0
                        while span() < need && steps < 256 {
                            steps += 1
                            var grew = false
                            if t.align != .left, left > 0, empty(left - 1) { left -= 1; grew = true }
                            if span() < need, t.align != .right, right < maxCols - 1, empty(right + 1) { right += 1; grew = true }
                            if !grew { break }
                        }
                        clip = NSRect(x: g.x(left), y: y0, width: g.x(right + 1) - g.x(left) - 1, height: y1 - y0 - 1)
                        // Hide the gridlines the text runs across.
                        for k in left..<right where !sh.cols.isHidden(k) {
                            let fill = styles[sh.styleAt(CellAddr(r, k))].fill?.color ?? .white
                            fill.setFill()
                            NSRect(x: g.x(k + 1) - 1, y: y0, width: 1, height: y1 - y0 - 1).fill()
                        }
                    }
                }
                runs.append(Run(rect: rect, clip: clip, t: t, st: st))
            }
        }

        for (rect, st) in bordered { drawBorders(st, rect) }

        for run in runs where run.clip.intersects(dirty) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: run.clip).addClip()
            drawText(run.t, run.st, in: run.rect, pad: pad, zoom: z)
            NSGraphicsContext.restoreGraphicsState()
        }

        drawSelection(g, dirty)
    }

    private func drawText(_ t: CellText, _ st: CellStyle, in rect: NSRect, pad: CGFloat, zoom z: CGFloat) {
        if st.wrap {
            let para = NSMutableParagraphStyle()
            para.alignment = t.align
            var attrs = t.attrs
            attrs[.paragraphStyle] = para
            let s = NSAttributedString(string: t.text, attributes: attrs)
            let box = rect.insetBy(dx: pad, dy: 1)
            let h = ceil(s.boundingRect(with: NSSize(width: box.width, height: 1e6), options: [.usesLineFragmentOrigin]).height)
            var y = box.maxY - h
            if st.vAlign == "top" { y = box.minY } else if st.vAlign == "center" { y = box.midY - h / 2 }
            s.draw(with: NSRect(x: box.minX, y: y, width: box.width, height: h), options: [.usesLineFragmentOrigin])
            return
        }
        let lines = t.text.components(separatedBy: "\n")
        let lh = t.lineHeight
        let total = lh * CGFloat(lines.count)
        var top = rect.maxY - total - 1 * z
        if st.vAlign == "top" { top = rect.minY + 1 } else if st.vAlign == "center" { top = rect.midY - total / 2 }
        for (k, line) in lines.enumerated() {
            let w = t.width(line)
            let x: CGFloat
            switch t.align {
            case .right: x = rect.maxX - pad - w
            case .center: x = rect.midX - w / 2
            default: x = rect.minX + pad
            }
            (line as NSString).draw(at: NSPoint(x: x, y: top + CGFloat(k) * lh), withAttributes: t.attrs)
        }
    }

    private func drawBorders(_ st: CellStyle, _ r: NSRect) {
        func line(_ e: Edge?, _ from: NSPoint, _ to: NSPoint) {
            guard let e else { return }
            let path = NSBezierPath()
            path.move(to: from); path.line(to: to)
            switch e.style {
            case "medium", "mediumDashed", "mediumDashDot", "mediumDashDotDot", "slantDashDot": path.lineWidth = 2
            case "thick", "double": path.lineWidth = 3
            default: path.lineWidth = 1
            }
            if e.style.lowercased().contains("dash") { path.setLineDash([4, 2], count: 2, phase: 0) }
            if e.style == "dotted" || e.style == "hair" { path.setLineDash([1, 1], count: 2, phase: 0) }
            e.color.color.setStroke()
            path.stroke()
        }
        let x0 = r.minX + 0.5, x1 = r.maxX - 0.5, y0 = r.minY + 0.5, y1 = r.maxY - 0.5
        line(st.top, NSPoint(x: x0, y: y0), NSPoint(x: x1, y: y0))
        line(st.bottom, NSPoint(x: x0, y: y1), NSPoint(x: x1, y: y1))
        line(st.left, NSPoint(x: x0, y: y0), NSPoint(x: x0, y: y1))
        line(st.right, NSPoint(x: x1, y: y0), NSPoint(x: x1, y: y1))
    }

    private func drawSelection(_ g: Geo, _ dirty: NSRect) {
        let s = ctl.sel
        let limit = bounds.insetBy(dx: -8, dy: -8)
        let activeRect = g.rect(s.active)
        for rg in s.ranges {
            let rr = g.rect(rg).intersection(limit)
            guard rr.intersects(dirty) else { continue }
            let path = NSBezierPath(rect: rr)
            if rg.contains(s.active) {
                path.append(NSBezierPath(rect: activeRect.insetBy(dx: 0, dy: 0)))
                path.windingRule = .evenOdd
            }
            Palette.shade.setFill()
            path.fill()
        }
        if s.ranges.count == 1 {
            let br = g.rect(s.last).intersection(limit)
            Palette.accent.setFill()
            frameRect(NSRect(x: br.minX - 1, y: br.minY - 1, width: br.width + 1, height: br.height + 1), 2)
        } else {
            NSColor(white: 0.25, alpha: 1).setFill()
            frameRect(NSRect(x: activeRect.minX - 1, y: activeRect.minY - 1, width: activeRect.width + 1, height: activeRect.height + 1), 1)
        }

        if let c = ctl.clip, c.sheetIndex == ctl.doc.workbook.active {
            let mr = g.rect(c.range).intersection(limit)
            let rect = NSRect(x: mr.minX - 0.5, y: mr.minY - 0.5, width: mr.width, height: mr.height)
            let under = NSBezierPath(rect: rect)
            under.lineWidth = 2
            NSColor.white.setStroke(); under.stroke()
            let ants = NSBezierPath(rect: rect)
            ants.lineWidth = 2
            ants.setLineDash([5, 4], count: 2, phase: marqueePhase)
            Palette.accent.setStroke(); ants.stroke()
        }

        switch feedback {
        case .outline(let rg)?:
            let fr = g.rect(rg).intersection(limit)
            NSColor(white: 0.4, alpha: 0.9).setFill()
            frameRect(NSRect(x: fr.minX - 1, y: fr.minY - 1, width: fr.width + 1, height: fr.height + 1), 3)
        case .insertRows(let t)?:
            let y = g.y(t) - 1
            let v = visibleRect
            Palette.accent.setFill()
            NSRect(x: v.minX, y: y - 1.5, width: v.width, height: 3).fill()
            NSRect(x: v.minX, y: y - 7, width: 3, height: 14).fill()
        case .insertCols(let t)?:
            let x = g.x(t) - 1
            let v = visibleRect
            Palette.accent.setFill()
            NSRect(x: x - 1.5, y: v.minY, width: 3, height: v.height).fill()
            NSRect(x: x - 7, y: v.minY, width: 14, height: 3).fill()
        case nil: break
        }

        if let ghost {
            NSColor(white: 0.25, alpha: 0.13).setFill()
            ghost.fill(using: .sourceOver)
            Palette.accent.withAlphaComponent(0.8).setFill()
            frameRect(ghost, 1.5)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let ed = ctl.editor, ed.frame.contains(p) { NSCursor.iBeam.set(); return }
        (onSelectionEdge(p) ? Cursors.move : Cursors.cell).set()
    }

    /// True on the outline of the selection, where dragging moves the cells.
    func onSelectionEdge(_ p: NSPoint) -> Bool {
        let s = ctl.sel
        guard s.ranges.count == 1, !(s.last.isWholeRows && s.last.isWholeCols) else { return false }
        let r = ctl.geo.rect(s.last)
        let band: CGFloat = 4
        return r.insetBy(dx: -band, dy: -band).contains(p) && !r.insetBy(dx: band, dy: band).contains(p)
    }

    private func clampedAddr(_ p: NSPoint) -> CellAddr {
        let q = NSPoint(x: min(max(p.x, 0), bounds.maxX - 1), y: min(max(p.y, 0), bounds.maxY - 1))
        return ctl.geo.addr(at: q)
    }

    override func mouseDown(with e: NSEvent) {
        ctl.commitEditing()
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        let a = clampedAddr(p)
        let f = e.modifierFlags
        if e.clickCount == 1, !f.contains(.command), onSelectionEdge(p) {
            shiftClickAt = f.contains(.shift) ? a : nil
            let src = ctl.sel.last
            let start = CellAddr(min(max(a.row, src.r0), src.r1), min(max(a.col, src.c0), src.c1))
            drag = .move(start: start, src: src)
            plan = .nothing
            return
        }
        if e.clickCount >= 2 {
            ctl.clickCell(a, shift: false, cmd: false)
            ctl.beginEditing(.edit)
            drag = .none
            return
        }
        ctl.clickCell(a, shift: f.contains(.shift), cmd: f.contains(.command))
        drag = .select
    }

    override func mouseDragged(with e: NSEvent) {
        lastDrag = e
        autoscroll(with: e)
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .select: ctl.dragCell(to: clampedAddr(p))
        case .move(let start, let src): updateMove(start, src, p, e.modifierFlags)
        case .none: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        let d = drag
        drag = .none
        lastDrag = nil
        switch d {
        case .select: ctl.finishDragSelect()
        case .move(_, let src):
            let p = plan
            feedback = nil
            plan = .nothing
            ctl.updateNameBox()
            switch p {
            case .insertRows(let t): ctl.moveRows(src.r0, src.rowCount, to: t, copy: e.modifierFlags.contains(.option))
            case .insertCols(let t): ctl.moveCols(src.c0, src.colCount, to: t, copy: e.modifierFlags.contains(.option))
            case .shift(let dr, let dc, let copy): ctl.moveBlock(src, by: dr, dc, copy: copy)
            case .nothing:
                if let a = shiftClickAt { ctl.clickCell(a, shift: true, cmd: false) }
            }
            shiftClickAt = nil
        case .none: break
        }
    }

    override func flagsChanged(with e: NSEvent) {
        if case .move(let start, let src) = drag, let last = lastDrag {
            updateMove(start, src, convert(last.locationInWindow, from: nil), e.modifierFlags)
        }
        super.flagsChanged(with: e)
    }

    private func updateMove(_ start: CellAddr, _ src: CellRange, _ p: NSPoint, _ flags: NSEvent.ModifierFlags) {
        let g = ctl.geo
        var next = MovePlan.nothing
        if flags.contains(.shift) && (src.isWholeRows != src.isWholeCols) {
            // Shift-drag slots whole rows or columns in between others, shown by Excel's insert line.
            if src.isWholeRows {
                let r = g.row(at: p.y)
                let t = p.y < (g.y(r) + g.y(r + 1)) / 2 ? r : r + 1
                if t < src.r0 || t > src.r1 + 1 { next = .insertRows(t) }
            } else {
                let c = g.col(at: p.x)
                let t = p.x < (g.x(c) + g.x(c + 1)) / 2 ? c : c + 1
                if t < src.c0 || t > src.c1 + 1 { next = .insertCols(t) }
            }
        } else {
            let a = clampedAddr(p)
            var dr = a.row - start.row, dc = a.col - start.col
            if src.isWholeRows { dc = 0 }
            if src.isWholeCols { dr = 0 }
            dr = min(max(dr, -src.r0), maxRows - 1 - src.r1)
            dc = min(max(dc, -src.c0), maxCols - 1 - src.c1)
            if dr != 0 || dc != 0 { next = .shift(dr, dc, copy: flags.contains(.option)) }
        }
        plan = next
        switch next {
        case .insertRows(let t):
            feedback = .insertRows(t)
            ctl.showNameBox("Row \(t + 1)")
        case .insertCols(let t):
            feedback = .insertCols(t)
            ctl.showNameBox("Column \(columnName(t))")
        case .shift(let dr, let dc, _):
            let dst = src.offsetBy(dr, dc)
            feedback = .outline(dst)
            ctl.showNameBox(rangeName(dst))
        case .nothing:
            feedback = nil
            ctl.updateNameBox()
        }
        (flags.contains(.option) ? NSCursor.dragCopy : Cursors.move).set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        ctl.commitEditing()
        let a = clampedAddr(convert(event.locationInWindow, from: nil))
        if !ctl.sel.ranges.contains(where: { $0.contains(a) }) { ctl.clickCell(a, shift: false, cmd: false) }
        return ctl.cellMenu()
    }

    override func magnify(with event: NSEvent) { ctl.setZoom(ctl.zoom * (1 + event.magnification)) }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        let f = e.modifierFlags.intersection([.shift, .control, .option, .command])
        if e.keyCode == 120 && f.isEmpty { ctl.beginEditing(.edit); return }          // F2
        if e.keyCode == 32 && f == .control { ctl.beginEditing(.edit); return }       // Ctrl-U, Excel for Mac's edit key
        if e.keyCode == 49 && f == .shift { ctl.selectWholeRows(); return }           // Shift-Space
        if e.keyCode == 49 && f == .control { ctl.selectWholeCols(); return }         // Ctrl-Space
        if !f.contains(.command), !f.contains(.control), let ch = e.characters, isPrintable(ch) {
            ctl.beginEditing(.enter, with: e)
            return
        }
        interpretKeyEvents([e])
    }

    private func isPrintable(_ s: String) -> Bool {
        guard let u = s.unicodeScalars.first else { return false }
        if u.value < 0x20 || u.value == 0x7F { return false }
        if u.value >= 0xF700 && u.value <= 0xF8FF { return false }
        return true
    }

    private var shiftHeld: Bool { NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false }

    override func moveUp(_ sender: Any?) { ctl.moveActive(-1, 0) }
    override func moveDown(_ sender: Any?) { ctl.moveActive(1, 0) }
    override func moveLeft(_ sender: Any?) { ctl.moveActive(0, -1) }
    override func moveRight(_ sender: Any?) { ctl.moveActive(0, 1) }
    override func moveUpAndModifySelection(_ sender: Any?) { ctl.moveActive(-1, 0, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { ctl.moveActive(1, 0, extend: true) }
    override func moveLeftAndModifySelection(_ sender: Any?) { ctl.moveActive(0, -1, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { ctl.moveActive(0, 1, extend: true) }

    // Cmd-arrows jump to the edge of the data, as Ctrl-arrows do in Excel for Windows.
    override func moveToBeginningOfDocument(_ sender: Any?) { ctl.jump(-1, 0) }
    override func moveToEndOfDocument(_ sender: Any?) { ctl.jump(1, 0) }
    override func moveToBeginningOfLine(_ sender: Any?) { ctl.jump(0, -1) }
    override func moveToEndOfLine(_ sender: Any?) { ctl.jump(0, 1) }
    override func moveToLeftEndOfLine(_ sender: Any?) { ctl.jump(0, -1) }
    override func moveToRightEndOfLine(_ sender: Any?) { ctl.jump(0, 1) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { ctl.jump(-1, 0, extend: true) }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { ctl.jump(1, 0, extend: true) }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { ctl.jump(0, -1, extend: true) }
    override func moveToEndOfLineAndModifySelection(_ sender: Any?) { ctl.jump(0, 1, extend: true) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { ctl.jump(0, -1, extend: true) }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { ctl.jump(0, 1, extend: true) }

    override func scrollPageUp(_ sender: Any?) { ctl.page(down: false, extend: false) }
    override func scrollPageDown(_ sender: Any?) { ctl.page(down: true, extend: false) }
    override func pageUp(_ sender: Any?) { ctl.page(down: false, extend: false) }
    override func pageDown(_ sender: Any?) { ctl.page(down: true, extend: false) }
    override func pageUpAndModifySelection(_ sender: Any?) { ctl.page(down: false, extend: true) }
    override func pageDownAndModifySelection(_ sender: Any?) { ctl.page(down: true, extend: true) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { ctl.home() }
    override func scrollToEndOfDocument(_ sender: Any?) { ctl.lastCell() }

    override func insertNewline(_ sender: Any?) { ctl.enterKey(forward: !shiftHeld) }
    override func insertTab(_ sender: Any?) { ctl.tabKey(forward: true) }
    override func insertBacktab(_ sender: Any?) { ctl.tabKey(forward: false) }
    override func deleteBackward(_ sender: Any?) { ctl.clearContents(nil) }
    override func deleteForward(_ sender: Any?) { ctl.clearContents(nil) }
    override func cancelOperation(_ sender: Any?) { ctl.clip = nil }
    override func selectAll(_ sender: Any?) { ctl.selectAll() }
}
