import AppKit

/// The column letters (isRows false) or row numbers (isRows true): click and drag to select,
/// drag an edge to resize, double-click an edge to fit the contents. Pressing on rows (or columns)
/// that are already selected and dragging moves them, the way Google Sheets does.
final class HeaderView: NSView {
    unowned let ctl: SheetWindowController
    let isRows: Bool

    private struct Resize { let target: Int; let targets: SheetWindowController.SizeTarget; let start: CGFloat; let before: Workbook }
    private var resize: Resize?
    private var selecting = false

    /// Picking up selected rows by their numbers. Nothing moves until the pointer has travelled a little,
    /// so a plain click still selects just the row clicked.
    private struct Grab { let src: CellRange; let clicked: Int; let startV: CGFloat; let grabOffset: CGFloat; var moving = false; var target: Int? }
    private var grab: Grab?
    /// Where the see-through copy of the grabbed rows is drawn, in this view's coordinates.
    private var ghost: NSRect?
    private var tracking: NSTrackingArea?

    init(ctl: SheetWindowController, rows: Bool) {
        self.ctl = ctl
        isRows = rows
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    // A click goes straight to the cell even when the window was in the background.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scrollOffset: CGFloat { isRows ? ctl.clipBounds.origin.y : ctl.clipBounds.origin.x }
    private func along(_ p: NSPoint) -> CGFloat { (isRows ? p.y : p.x) + scrollOffset }
    private func axis(_ s: Sheet) -> Axis { isRows ? s.rows : s.cols }
    private func pos(_ g: Geo, _ i: Int) -> CGFloat { isRows ? g.y(i) : g.x(i) }
    private func index(_ g: Geo, _ v: CGFloat) -> Int { isRows ? g.row(at: v) : g.col(at: v) }
    private var count: Int { isRows ? maxRows : maxCols }

    override func draw(_ dirty: NSRect) {
        let sh = ctl.sheet
        let g = ctl.geo
        let ax = axis(sh)
        let off = scrollOffset
        Palette.headerBg.setFill()
        dirty.fill()
        let font = ctl.headerFont
        let lo = index(g, off + (isRows ? dirty.minY : dirty.minX))
        let hi = index(g, off + (isRows ? dirty.maxY : dirty.maxX))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        for i in lo...hi {
            if ax.isHidden(i) { continue }
            let a = pos(g, i) - off, b = pos(g, i + 1) - off
            let state = ctl.headerState(i, rows: isRows)
            let cell = isRows ? NSRect(x: 0, y: a, width: bounds.width, height: b - a) : NSRect(x: a, y: 0, width: b - a, height: bounds.height)
            var textColor = Palette.headerText
            var bold = false
            switch state {
            case .none: break
            case .partial:
                Palette.headerSelBg.setFill(); cell.fill()
                textColor = Palette.headerSelText; bold = true
            case .full:
                Palette.headerFullBg.setFill(); cell.fill()
                textColor = Palette.headerSelText; bold = true
            }
            if state != .none {
                // Excel's green bar along the edge next to the grid.
                Palette.accent.setFill()
                if isRows { NSRect(x: bounds.width - 2, y: a, width: 2, height: b - a).fill() }
                else { NSRect(x: a, y: bounds.height - 2, width: b - a, height: 2).fill() }
            }
            Palette.headerLine.setFill()
            if isRows { NSRect(x: 0, y: b - 1, width: bounds.width, height: 1).fill() }
            else { NSRect(x: b - 1, y: 0, width: 1, height: bounds.height).fill() }
            // A hidden neighbour shows as a thicker line, which is where you drag to unhide.
            if i > 0 && ax.isHidden(i - 1) {
                NSColor(white: 0.45, alpha: 1).setFill()
                if isRows { NSRect(x: 0, y: a - 1, width: bounds.width, height: 2).fill() }
                else { NSRect(x: a - 1, y: 0, width: 2, height: bounds.height).fill() }
            }
            let label = isRows ? String(i + 1) : columnName(i)
            let f = bold ? NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) : font
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: textColor, .paragraphStyle: para]
            let size = (label as NSString).size(withAttributes: attrs)
            if (isRows ? cell.height : cell.width) > 4 {
                let r = NSRect(x: cell.minX, y: cell.midY - size.height / 2, width: cell.width, height: size.height)
                (label as NSString).draw(in: r, withAttributes: attrs)
            }
        }
        // The line between the headers and the grid.
        Palette.headerLine.setFill()
        if isRows { NSRect(x: bounds.width - 1, y: dirty.minY, width: 1, height: dirty.height).fill() }
        else { NSRect(x: dirty.minX, y: bounds.height - 1, width: dirty.width, height: 1).fill() }
        if let ghost {
            Palette.accent.withAlphaComponent(0.25).setFill()
            ghost.fill()
            Palette.accent.setFill()
            frameRect(ghost, 2)
        }
    }

    // MARK: Finding an edge

    /// The row or column whose edge is under the pointer, and whether grabbing it unhides it.
    private func edge(at v: CGFloat) -> (target: Int, unhide: Bool)? {
        let g = ctl.geo
        let ax = axis(ctl.sheet)
        let i = index(g, v)
        let start = pos(g, i), end = pos(g, i + 1)
        let tol: CGFloat = 4
        if v >= end - tol { return (i, false) }
        if v <= start + tol && i > 0 {
            if ax.isHidden(i - 1) && v >= start { return (i - 1, true) }
            var j = i - 1
            while j > 0 && ax.isHidden(j) { j -= 1 }
            if ax.isHidden(j) { return nil }
            return (j, false)
        }
        return nil
    }

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
        let v = along(convert(e.locationInWindow, from: nil))
        if let ed = edge(at: v) {
            (isRows ? (ed.unhide ? Cursors.rowUnhide : Cursors.rowResize) : (ed.unhide ? Cursors.colUnhide : Cursors.colResize)).set()
        } else if grabbable(index(ctl.geo, v)) != nil {
            NSCursor.openHand.set()
        } else {
            (isRows ? Cursors.rowSelect : Cursors.colSelect).set()
        }
    }

    /// The selected block of whole rows (or columns) containing i, if it can be picked up and moved.
    private func grabbable(_ i: Int) -> CellRange? {
        let s = ctl.sel
        guard s.ranges.count == 1 else { return nil }
        let r = s.last
        if isRows { return r.isWholeRows && !r.isWholeCols && i >= r.r0 && i <= r.r1 ? r : nil }
        return r.isWholeCols && !r.isWholeRows && i >= r.c0 && i <= r.c1 ? r : nil
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        ctl.commitEditing()
        ctl.focusGrid()
        let v = along(convert(e.locationInWindow, from: nil))
        if let ed = edge(at: v) {
            let targets = ctl.sizeTargets(for: ed.target, rows: isRows)
            if e.clickCount >= 2 {
                ctl.autofit(targets, rows: isRows)
                return
            }
            resize = Resize(target: ed.target, targets: targets, start: pos(ctl.geo, ed.target), before: ctl.doc.workbook)
            showTip(e)
            return
        }
        let i = index(ctl.geo, v)
        let f = e.modifierFlags
        if e.clickCount == 1, !f.contains(.shift), !f.contains(.command), let src = grabbable(i) {
            let start = isRows ? ctl.geo.y(src.r0) : ctl.geo.x(src.c0)
            grab = Grab(src: src, clicked: i, startV: v, grabOffset: v - start)
            NSCursor.closedHand.set()
            return
        }
        ctl.clickHeader(i, rows: isRows, shift: f.contains(.shift), cmd: f.contains(.command))
        selecting = true
    }

    override func mouseDragged(with e: NSEvent) {
        if let r = resize {
            let v = along(convert(e.locationInWindow, from: nil))
            let size = Double(max(0, v - r.start) / ctl.zoom).rounded()
            ctl.applySize(size, to: r.targets, rows: isRows, live: r.target)
            showTip(e)
            return
        }
        if var g = grab {
            let v = along(convert(e.locationInWindow, from: nil))
            if !g.moving && abs(v - g.startV) < 4 { return }
            g.moving = true
            ctl.grid.autoscroll(with: e)
            let geo = ctl.geo
            let v2 = along(convert(e.locationInWindow, from: nil))
            let k = index(geo, max(0, v2))
            let a = isRows ? geo.y(k) : geo.x(k), b = isRows ? geo.y(k + 1) : geo.x(k + 1)
            let t = v2 < (a + b) / 2 ? k : k + 1
            let lo = isRows ? g.src.r0 : g.src.c0, hi = isRows ? g.src.r1 : g.src.c1
            g.target = (t < lo || t > hi + 1) ? t : nil
            if let t = g.target {
                ctl.grid.feedback = isRows ? .insertRows(t) : .insertCols(t)
                ctl.showNameBox(isRows ? "Row \(t + 1)" : "Column \(columnName(t))")
            } else {
                ctl.grid.feedback = nil
                ctl.updateNameBox()
            }
            // The see-through copy follows the pointer.
            let length = isRows ? geo.y(hi + 1) - geo.y(lo) : geo.x(hi + 1) - geo.x(lo)
            let start = v2 - g.grabOffset - scrollOffset
            ghost = isRows ? NSRect(x: 0, y: start, width: bounds.width, height: length)
                           : NSRect(x: start, y: 0, width: length, height: bounds.height)
            let vis = ctl.grid.visibleRect
            let gridStart = v2 - g.grabOffset
            ctl.grid.ghost = isRows ? NSRect(x: vis.minX, y: gridStart, width: vis.width, height: length)
                                    : NSRect(x: gridStart, y: vis.minY, width: length, height: vis.height)
            grab = g
            needsDisplay = true
            NSCursor.closedHand.set()
            return
        }
        guard selecting else { return }
        ctl.grid.autoscroll(with: e)
        let p = convert(e.locationInWindow, from: nil)
        let clamped = NSPoint(x: min(max(p.x, 0), bounds.width - 1), y: min(max(p.y, 0), bounds.height - 1))
        ctl.dragHeader(to: index(ctl.geo, along(clamped)), rows: isRows)
    }

    override func mouseUp(with e: NSEvent) {
        if let r = resize {
            resize = nil
            SizeTip.shared.hide()
            ctl.doc.commit(isRows ? "Row Height" : "Column Width", before: r.before)
            return
        }
        if let g = grab {
            grab = nil
            ghost = nil
            needsDisplay = true
            ctl.grid.ghost = nil
            ctl.grid.feedback = nil
            ctl.updateNameBox()
            if !g.moving {
                ctl.clickHeader(g.clicked, rows: isRows, shift: false, cmd: false)
            } else if let t = g.target {
                let copy = e.modifierFlags.contains(.option)
                if isRows { ctl.moveRows(g.src.r0, g.src.rowCount, to: t, copy: copy) }
                else { ctl.moveCols(g.src.c0, g.src.colCount, to: t, copy: copy) }
            }
            return
        }
        if selecting { selecting = false; ctl.finishDragSelect() }
    }

    private func showTip(_ e: NSEvent) {
        guard let r = resize, let window else { return }
        let ax = axis(ctl.sheet)
        let px = ax.size(r.target)
        let text: String
        if isRows {
            text = String(format: "Height: %.2f (%d pixels)", px * 0.75, Int(px.rounded()))
        } else {
            text = String(format: "Width: %.2f (%d pixels)", max(0, (px - 5) / 7), Int(px.rounded()))
        }
        let p = window.convertPoint(toScreen: e.locationInWindow)
        SizeTip.shared.show(text, at: NSPoint(x: p.x + 14, y: p.y + 10))
    }

    override func scrollWheel(with event: NSEvent) { ctl.scroll.scrollWheel(with: event) }

    override func menu(for event: NSEvent) -> NSMenu? {
        ctl.commitEditing()
        let i = index(ctl.geo, along(convert(event.locationInWindow, from: nil)))
        if ctl.headerState(i, rows: isRows) != .full { ctl.clickHeader(i, rows: isRows, shift: false, cmd: false) }
        return ctl.headerMenu(rows: isRows)
    }
}

/// The box above the row numbers: click to select the whole sheet.
final class CornerView: NSView {
    unowned let ctl: SheetWindowController

    init(ctl: SheetWindowController) { self.ctl = ctl; super.init(frame: .zero); clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirty: NSRect) {
        Palette.headerBg.setFill(); bounds.fill()
        Palette.headerLine.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let s = min(bounds.width, bounds.height) * 0.45
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.width - 4, y: bounds.height - 4 - s))
        path.line(to: NSPoint(x: bounds.width - 4, y: bounds.height - 4))
        path.line(to: NSPoint(x: bounds.width - 4 - s, y: bounds.height - 4))
        path.close()
        let all = ctl.sel.ranges.contains { $0.isWholeRows && $0.isWholeCols }
        (all ? Palette.accent : NSColor(white: 0.72, alpha: 1)).setFill()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        ctl.commitEditing()
        ctl.focusGrid()
        ctl.selectAll()
    }
}
