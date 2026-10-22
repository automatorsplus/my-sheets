import AppKit

/// Drives the real window with synthetic mouse and key events, the way a person would use it:
/// `MySheets --ui-test <folder>`. Writes screenshots and a saved workbook into the folder.
enum UITest {
    static func run(outDir: String) {
        let out = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // New workbooks save themselves into a folder of the test's own, and stay off Open Recent.
        Library.folder = out.appendingPathComponent("Workbooks", isDirectory: true)
        try? FileManager.default.removeItem(at: Library.folder)
        Library.keepsRecents = false
        // The New workbook box takes the name and place it suggests.
        SheetDocumentController.answerNewWorkbook = { $0 }
        NSApp.activate(ignoringOtherApps: true)
        guard let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) as? SheetDocument,
              let ctl = doc.controller, let win = ctl.window else {
            print("FAIL: couldn't open a window"); exit(2)
        }
        win.setFrame(NSRect(x: 60, y: 60, width: 1180, height: 780), display: true)
        win.makeKeyAndOrderFront(nil)
        // The whole script runs inside one event, so give each change its own undo step.
        doc.undoManager?.groupsByEvent = false
        ctl.setZoom(1.25)
        let d = Driver(doc: doc, ctl: ctl, win: win, out: out)
        d.pump(0.6)
        if ProcessInfo.processInfo.environment["UITEST_DEBUG"] != nil {
            for v in win.contentView!.subviews {
                print("view \(type(of: v)) frame=\(v.frame) visible=\(v.visibleRect) layerFrame=\(v.layer?.frame ?? .zero)")
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("part-\(type(of: v))-\(Int(v.frame.minY)).png"))
                }
            }
            print("contentView layer frame \(win.contentView!.layer?.frame ?? .zero) bounds \(win.contentView!.bounds) geometryFlipped \(win.contentView!.layer?.isGeometryFlipped ?? false)")
        }
        d.script()
        print("\(d.passes) passed, \(d.failures) failed")
        exit(d.failures == 0 ? 0 : 1)
    }
}

final class Driver {
    var doc: SheetDocument
    var ctl: SheetWindowController
    var win: NSWindow
    let out: URL
    var passes = 0, failures = 0

    init(doc: SheetDocument, ctl: SheetWindowController, win: NSWindow, out: URL) {
        self.doc = doc; self.ctl = ctl; self.win = win; self.out = out
    }

    func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("ok   \(what)") } else { failures += 1; print("FAIL \(what) \(detail())") }
    }

    func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) { check(a == b, what, "got \(a), expected \(b)") }

    func pump(_ s: Double = 0.02) { RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }

    /// Pumps events until `done` is true, for up to `limit` seconds.
    func wait(_ limit: Double = 5, until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: limit)
        while !done() && Date() < end { pump(0.05) }
    }

    /// Points the events and checks at another workbook's window.
    func use(_ d: SheetDocument) {
        doc = d
        ctl = d.controller!
        win = ctl.window!
        doc.undoManager?.groupsByEvent = false
    }

    /// The middle of a view, in its window's coordinates.
    func centre(_ v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }

    // MARK: Events

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: now, windowNumber: win.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            win.sendEvent(e)
        }
        pump()
    }

    func type(_ s: String) { for ch in s { key(String(ch), 0) } }
    func ret(_ flags: NSEvent.ModifierFlags = []) { key("\r", 36, flags) }
    func tab(_ flags: NSEvent.ModifierFlags = []) { key("\t", 48, flags) }
    func esc() { key("\u{1b}", 53) }
    func backspace() { key("\u{7f}", 51) }
    func f2() { key(String(UnicodeScalar(UInt16(NSF2FunctionKey))!), 120, [.function]) }

    enum Dir { case up, down, left, right }
    func arrow(_ d: Dir, _ flags: NSEvent.ModifierFlags = []) {
        let (ch, code): (Int, UInt16) = {
            switch d {
            case .up: return (NSUpArrowFunctionKey, 126)
            case .down: return (NSDownArrowFunctionKey, 125)
            case .left: return (NSLeftArrowFunctionKey, 123)
            case .right: return (NSRightArrowFunctionKey, 124)
            }
        }()
        key(String(UnicodeScalar(UInt16(ch))!), code, flags.union([.numericPad, .function]))
    }

    func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: now, windowNumber: win.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
        win.sendEvent(e)
        pump(0.005)
    }

    func click(_ p: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        if ProcessInfo.processInfo.environment["UITEST_DEBUG"] != nil, let cv = win.contentView {
            let hit = cv.hitTest(cv.convert(p, from: nil))
            print("  click at \(p) hits \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing"); key=\(win.isKeyWindow) fr=\(String(describing: win.firstResponder.map { Swift.type(of: $0) }))")
        }
        if clicks == 2 { mouse(.leftMouseDown, p, clicks: 1, flags: flags); mouse(.leftMouseUp, p, clicks: 1, flags: flags) }
        mouse(.leftMouseDown, p, clicks: clicks, flags: flags)
        mouse(.leftMouseUp, p, clicks: clicks, flags: flags)
        pump()
    }

    func drag(_ a: NSPoint, _ b: NSPoint, downFlags: NSEvent.ModifierFlags = [], dragFlags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        mouse(.leftMouseDown, a, clicks: clicks, flags: downFlags)
        for i in 1...10 {
            let t = CGFloat(i) / 10
            mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: dragFlags)
        }
        mouse(.leftMouseUp, b, flags: dragFlags)
        pump(0.05)
    }

    func rightClick(_ p: NSPoint) -> NSMenu? {
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: now, windowNumber: win.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        guard let v = win.contentView?.hitTest(win.contentView!.convert(p, from: nil)) else { return nil }
        return v.menu(for: e)
    }

    // MARK: Places on screen, in window coordinates

    func cell(_ name: String) -> NSPoint {
        let a = parseCell(name)!
        let r = ctl.geo.rect(a)
        return ctl.grid.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
    }

    func cellEdge(_ name: String, top: Bool) -> NSPoint {
        let a = parseCell(name)!
        let r = ctl.geo.rect(a)
        return ctl.grid.convert(NSPoint(x: r.midX, y: top ? r.minY + 1 : r.maxY - 1), to: nil)
    }

    /// A point on the column header at grid x.
    func colHeader(_ gx: CGFloat) -> NSPoint {
        ctl.colHeader.convert(NSPoint(x: gx - ctl.clipBounds.minX, y: ctl.colHeader.bounds.midY), to: nil)
    }

    func rowHeader(_ gy: CGFloat) -> NSPoint {
        ctl.rowHeader.convert(NSPoint(x: ctl.rowHeader.bounds.midX, y: gy - ctl.clipBounds.minY), to: nil)
    }

    func value(_ name: String) -> CellValue? { ctl.sheet.cell(parseCell(name)!)?.value }
    func text(_ name: String) -> String? { if case .text(let s)? = value(name) { return s }; return nil }

    /// The window's real pixels on screen (an app may always capture its own windows).
    static func capture(_ w: NSWindow, to url: URL) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func snap(_ name: String) {
        pump(0.25)
        Driver.capture(win, to: out.appendingPathComponent(name + ".png"))
    }

    func undo() { ctl.commitEditing(); doc.undoManager?.undo(); pump() }

    // MARK: The script

    func script() {
        // Typing, Tab and Return: Tab-Tab-Return goes back to the first column, like Excel.
        click(cell("A1"))
        type("Name"); tab(); type("Score"); tab(); type("Joined"); ret()
        eq(text("A1"), "Name", "typed A1")
        eq(text("C1"), "Joined", "typed C1")
        eq(ctl.sel.active, parseCell("A2")!, "Tab, Tab, Return returns to column A")
        wait { doc.fileURL != nil }
        eq(doc.fileURL?.lastPathComponent, "Book1.xlsx", "typing saves a new workbook straight away, as Book1")
        check(doc.fileURL?.deletingLastPathComponent().lastPathComponent == "Workbooks", "…in the workbooks folder")
        let people: [(String, String, String)] = [("Ada", "92", "03/04/2025"), ("Ben", "85.5", "12/11/2024"),
                                                  ("Cara", "77", "01/06/2023"), ("Dev", "64", "15/09/2022")]
        for (n, s, j) in people { type(n); tab(); type(s); tab(); type(j); ret() }
        eq(value("B2"), .number(92), "number typed as a number")
        if case .number(let v)? = value("C2") { eq(v, Double(NumFmt.serial(2025, 4, 3)), "date typed as a date") } else { check(false, "date typed as a date") }
        eq(ctl.formulaField.stringValue, "", "formula bar shows the empty active cell")
        click(cell("C2"))
        eq(ctl.formulaField.stringValue, "03/04/2025", "formula bar shows the date")
        snap("01-typed")

        // Double-click edits in place; Cmd-Z undoes.
        click(cell("B3"), clicks: 2)
        check(ctl.editor?.mode == .edit, "double-click opens the editor in Edit mode")
        type("1"); ret()
        eq(value("B3"), .number(85.51), "edited in place")
        undo()
        eq(value("B3"), .number(85.5), "undo puts it back")

        // Typing then an arrow key commits and moves (Enter mode). F2 switches to Edit mode.
        click(cell("D2"))
        type("note"); arrow(.right)
        eq(text("D2"), "note", "arrow commits the entry")
        eq(ctl.sel.active, parseCell("E2")!, "arrow moves on")
        click(cell("D2")); f2(); arrow(.left); type("X"); ret()
        eq(text("D2"), "notXe", "F2 then arrows move the caret")
        click(cell("D2")); backspace()
        check(value("D2") == nil, "Delete clears the cell")
        click(cell("D2")); type("throwaway"); esc()
        check(value("D2") == nil, "Esc cancels typing")

        // The formula bar edits the active cell.
        click(cell("F2"))
        win.makeFirstResponder(ctl.formulaField)
        pump()
        type("From the bar"); ret()
        eq(text("F2"), "From the bar", "formula bar entry")
        eq(ctl.sel.active, parseCell("F3")!, "Return in the formula bar moves down")

        // The Name Box jumps to an address.
        win.makeFirstResponder(ctl.nameBox)
        ctl.nameBox.currentEditor()?.selectAll(nil)
        type("B4"); ret()
        eq(ctl.sel.active, parseCell("B4")!, "Name Box goes to B4")

        // Long text spills into the empty cells beside it.
        click(cell("A8"))
        type("This note is long enough to spill across several empty cells"); ret()
        snap("02-overflow")

        // Cmd-arrows jump to the edge of the data.
        click(cell("A1"))
        arrow(.down, [.command])
        eq(ctl.sel.active, parseCell("A5")!, "Cmd-Down stops at the last filled cell")
        arrow(.up, [.command, .shift])
        eq(ctl.sel.last, CellRange(0, 0, 4, 0), "Shift-Cmd-Up selects back to the top")

        // Drag-select a block; Return walks inside it.
        drag(cell("A2"), cell("B3"))
        eq(ctl.sel.last, CellRange(1, 0, 2, 1), "drag selects A2:B3")
        ret()
        eq(ctl.sel.active, parseCell("A3")!, "Return moves down inside the selection")
        ret()
        eq(ctl.sel.active, parseCell("B2")!, "and wraps to the next column")

        // Resize column A by dragging its right edge.
        let z = ctl.zoom
        let edgeA = ctl.geo.x(1)
        drag(colHeader(edgeA - 1), colHeader(edgeA + 100))
        check(abs(ctl.sheet.cols.size(0) - Double((edgeA - 1 + 100) / z)) <= 1.5, "column A is wider", "width \(ctl.sheet.cols.size(0))")
        // Double-click column C's right edge fits its contents.
        let edgeC = ctl.geo.x(3)
        click(colHeader(edgeC - 1), clicks: 2)
        check(ctl.sheet.cols.customSize(2) != nil && ctl.sheet.cols.size(2) > 60, "double-click fits column C", "width \(ctl.sheet.cols.size(2))")
        // Make row 1 taller.
        let edge1 = ctl.geo.y(1)
        drag(rowHeader(edge1 - 1), rowHeader(edge1 + 25))
        check(ctl.sheet.rows.size(0) > 35, "row 1 is taller", "height \(ctl.sheet.rows.size(0))")
        snap("03-resized")

        // Select row 3 by its number and highlight it yellow.
        click(rowHeader(ctl.geo.y(2) + 5))
        eq(ctl.sel.last, CellRange.rows(2, 2), "clicking a row number selects the row")
        ctl.fillColor = RGB(255, 255, 0)
        ctl.fillWithColour(nil)
        pump()
        eq(doc.styles[ctl.sheet.rowStyles[2] ?? 0].fill, RGB(255, 255, 0), "row 3 is yellow")
        eq(doc.styles[ctl.sheet.styleAt(parseCell("A3")!)].fill, RGB(255, 255, 0), "its cells are yellow")
        snap("04-highlighted")

        // Shift-drag row 5 (Dev) up between rows 2 and 3.
        click(rowHeader(ctl.geo.y(4) + 5))
        eq(ctl.sel.last, CellRange.rows(4, 4), "row 5 selected")
        drag(cellEdge("C5", top: true), ctl.grid.convert(NSPoint(x: ctl.geo.rect(parseCell("C3")!).midX, y: ctl.geo.y(2) + 2), to: nil),
             downFlags: [], dragFlags: [.shift])
        eq(text("A3"), "Dev", "Dev moved up to row 3")
        eq(text("A4"), "Ben", "Ben moved down to row 4")
        eq(text("A5"), "Cara", "Cara moved down to row 5")
        eq(doc.styles[ctl.sheet.rowStyles[3] ?? 0].fill, RGB(255, 255, 0), "Ben's yellow went with him")
        eq(ctl.sel.last, CellRange.rows(2, 2), "the moved row stays selected")
        snap("05-moved-row")

        // Shift held before grabbing: move column C (Joined) in front of column A, then undo.
        click(colHeader(ctl.geo.x(2) + 20))
        eq(ctl.sel.last, CellRange.cols(2, 2), "clicking a column letter selects the column")
        let leftEdgeC = ctl.grid.convert(NSPoint(x: ctl.geo.x(2) + 1, y: ctl.geo.rect(parseCell("C6")!).midY), to: nil)
        let intoA = ctl.grid.convert(NSPoint(x: ctl.geo.x(0) + 4, y: ctl.geo.rect(parseCell("A6")!).midY), to: nil)
        drag(leftEdgeC, intoA, downFlags: [.shift], dragFlags: [.shift])
        eq(text("A1"), "Joined", "column C moved to A")
        eq(text("B1"), "Name", "column A moved over to B")
        eq(ctl.sel.last, CellRange.cols(0, 0), "the moved column stays selected")
        undo()
        eq(text("A1"), "Name", "undo puts the columns back")

        // Google Sheets style: drag a selected row's number to move the row.
        click(rowHeader(ctl.geo.y(3) + 5))
        eq(text("A4"), "Ben", "Ben is in row 4")
        // Done by hand, to take a picture halfway with the see-through copy and the green line showing.
        let from = rowHeader(ctl.geo.y(3) + 10), to = rowHeader(ctl.geo.y(1) + 2)
        mouse(.leftMouseDown, from)
        for i in 1...10 {
            let t = CGFloat(i) / 10
            mouse(.leftMouseDragged, NSPoint(x: from.x, y: from.y + (to.y - from.y) * t))
        }
        snap("05a-dragging-row-number")
        mouse(.leftMouseUp, to)
        pump(0.05)
        eq(text("A2"), "Ben", "dragging a row number moves the row up")
        eq(text("A3"), "Ada", "the rows below make room")
        eq(ctl.sel.last, CellRange.rows(1, 1), "the dragged row stays selected")
        snap("05b-dragged-row-number")
        undo()
        eq(text("A4"), "Ben", "undo puts the dragged row back")
        // A plain click on a selected row's number selects just that row.
        drag(rowHeader(ctl.geo.y(1) + 5), rowHeader(ctl.geo.y(2) + 5))
        eq(ctl.sel.last, CellRange.rows(1, 2), "dragging across row numbers selects rows 2-3")
        click(rowHeader(ctl.geo.y(2) + 5))
        eq(ctl.sel.last, CellRange.rows(2, 2), "clicking one of them selects just that row")
        // Column letters move the same way.
        click(colHeader(ctl.geo.x(1) + 20))
        drag(colHeader(ctl.geo.x(1) + 20), colHeader(ctl.geo.x(3) - 8))
        eq(text("B1"), "Joined", "dragging a column letter moves the column")
        eq(text("C1"), "Score", "Score moved to column C")
        undo()
        eq(text("B1"), "Score", "undo puts the column back")

        // Drag a block to an empty place (no Shift): it moves.
        drag(cell("A2"), cell("B2"))
        let blockEdge = cellEdge("A2", top: true)
        drag(blockEdge, ctl.grid.convert(NSPoint(x: ctl.geo.rect(parseCell("A12")!).midX, y: ctl.geo.rect(parseCell("A12")!).minY + 1), to: nil))
        eq(text("A12"), "Ada", "block moved to A12")
        check(value("A2") == nil, "block's old place is empty")
        undo()
        eq(text("A2"), "Ada", "undo moves it back")

        // Hide column B by dragging its edge to zero, then unhide by dragging the hidden spot open.
        let bStart = ctl.geo.x(1), bEnd = ctl.geo.x(2)
        drag(colHeader(bEnd - 1), colHeader(bStart - 10))
        check(ctl.sheet.cols.isHidden(1), "column B hidden by dragging")
        let joint = ctl.geo.x(2)
        drag(colHeader(joint + 2), colHeader(joint + 80))
        check(!ctl.sheet.cols.isHidden(1) && ctl.sheet.cols.size(1) > 50, "column B unhidden by dragging", "size \(ctl.sheet.cols.size(1))")

        // Insert and delete a row.
        click(rowHeader(ctl.geo.y(1) + 5))
        ctl.insertRows(nil)
        check(value("A2") == nil && text("A3") == "Ada", "Insert Row pushes rows down")
        ctl.deleteRows(nil)
        eq(text("A2"), "Ada", "Delete Row pulls them back")

        // Copy and paste a block.
        drag(cell("A2"), cell("B3"))
        ctl.copy(nil)
        click(cell("H2"))
        ctl.paste(nil)
        eq(text("H2"), "Ada", "pasted A2")
        eq(value("I2"), .number(92), "pasted B2")
        eq(text("H3"), "Dev", "pasted A3")

        // Cut rows and insert them elsewhere (right-click, Insert Cut Rows).
        click(rowHeader(ctl.geo.y(1) + 5))
        ctl.cut(nil)
        click(rowHeader(ctl.geo.y(5) + 5))
        let menu = rightClick(rowHeader(ctl.geo.y(5) + 5))
        check(menu?.items.contains { $0.title == "Insert Cut Rows" } == true, "right-click offers Insert Cut Rows")
        ctl.insertCutCells(nil)
        eq(text("A2"), "Dev", "rows close up after the cut row leaves")
        eq(text("A5"), "Ada", "cut row inserted above row 6")

        // Shift-Space selects the row; Delete clears it.
        click(cell("H3")); key(" ", 49, [.shift])
        eq(ctl.sel.last, CellRange.rows(2, 2), "Shift-Space selects the row")

        // Sheets.
        ctl.insertSheet(nil)
        eq(doc.workbook.sheets.count, 2, "new sheet")
        click(cell("B2")); type("On sheet 2"); ret()
        ctl.selectSheet(0)
        eq(text("A1"), "Name", "back on sheet 1")

        // Zoom.
        ctl.setZoom(1.6)
        snap("06-zoomed")
        ctl.setZoom(1.25)

        // A cell with two lines (Option-Return).
        click(cell("D2"))
        type("Line one"); key("\r", 36, [.option]); type("Line two"); ret()
        eq(text("D2"), "Line one\nLine two", "Option-Return makes a new line in the cell")
        check(ctl.sheet.rows.size(1) > 30, "the row grows for two lines")
        snap("07-final")

        // Bold, italic and font size.
        func style(_ name: String) -> CellStyle { doc.styles[ctl.sheet.styleAt(parseCell(name)!)] }
        click(cell("A1"))
        ctl.toggleBold(nil)
        check(style("A1").bold, "Bold makes A1 bold")
        eq(ctl.boldButton.state, .on, "the Bold button shows it's on")
        ctl.toggleBold(nil)
        check(!style("A1").bold, "pressing Bold again takes it off")
        drag(cell("A1"), cell("C1"))
        ctl.toggleBold(nil)
        check(style("A1").bold && style("B1").bold && style("C1").bold, "Bold on a selected block")
        click(cell("B2"))
        ctl.toggleItalic(nil)
        check(style("B2").italic && !style("B2").bold, "Italic on B2")
        eq(ctl.italicButton.state, .on, "the Italic button shows it's on")
        click(cell("A4"))
        check(ctl.sheet.rows.customSize(3) == nil, "row 4 starts at the normal height")
        ctl.fontSizeBox.stringValue = "24"
        ctl.fontSizeChosen(nil)
        eq(style("A4").size, 24, "font size box sets 24")
        check(ctl.sheet.rows.size(3) > 30 && ctl.sheet.autoHeights.contains(3), "row 4 grows to fit", "height \(ctl.sheet.rows.size(3))")
        snap("09-big-text")
        ctl.decreaseFontSize(nil)
        eq(style("A4").size, 22, "Smaller steps 24 down to 22")
        ctl.fontSizeBox.stringValue = "11"
        ctl.fontSizeChosen(nil)
        check(ctl.sheet.rows.customSize(3) == nil, "row 4 shrinks back with small text")
        ctl.increaseFontSize(nil)
        eq(style("A4").size, 12, "Bigger steps 11 up to 12")
        eq(ctl.fontSizeBox.stringValue, "12", "the size box shows 12")
        let h1 = ctl.sheet.rows.size(0)
        click(cell("A1"))
        ctl.fontSizeBox.stringValue = "9"
        ctl.fontSizeChosen(nil)
        eq(ctl.sheet.rows.size(0), h1, "a row sized by hand keeps its height")
        undo()
        eq(style("A1").size, 11, "undo puts the size back")
        snap("10-fonts")

        // Save, then open the saved file in a second window.
        let url = out.appendingPathComponent("ui-test.xlsx")
        var saved = false
        doc.save(to: url, ofType: "org.openxmlformats.spreadsheetml.sheet", for: .saveAsOperation) { err in
            if let err { print("save error: \(err)") }
            saved = err == nil
        }
        for _ in 0..<100 where !saved { pump(0.05) }
        check(saved, "saved \(url.lastPathComponent)")
        // Read the saved file back from disk.
        guard let back = try? XLSXReader.read(Data(contentsOf: url)) else { check(false, "read the saved file back"); return }
        let s0 = back.workbook.sheets[0]
        eq(s0.cell(parseCell("A5")!)?.value, .text("Ada"), "reopened: moved row is where it was put")
        eq(s0.cell(parseCell("D2")!)?.value, .text("Line one\nLine two"), "reopened: two-line cell")
        eq(back.styles[s0.styleAt(parseCell("A3")!)].fill, ctl.doc.styles[ctl.doc.workbook.sheets[0].styleAt(parseCell("A3")!)].fill, "reopened: fill")
        eq(s0.cols.size(0), ctl.doc.workbook.sheets[0].cols.size(0), "reopened: column A width")
        eq(s0.rows.size(0), ctl.doc.workbook.sheets[0].rows.size(0), "reopened: row 1 height")
        eq(back.workbook.sheets.count, 2, "reopened: both sheets")
        eq(back.workbook.sheets[1].cell(parseCell("B2")!)?.value, .text("On sheet 2"), "reopened: second sheet")
        check(back.losses.isEmpty, "reopened: nothing it can't keep")
        check(back.styles[s0.styleAt(parseCell("A1")!)].bold, "reopened: bold")
        check(back.styles[s0.styleAt(parseCell("B2")!)].italic, "reopened: italic")
        eq(back.styles[s0.styleAt(parseCell("A4")!)].size, 12, "reopened: font size")

        closingSaves()
        homeTab()
        copyOfAFileWithExtras()
        homeComesBack()
    }

    /// Closing every workbook and Home's own tab leaves Home showing, so there's always a way back in.
    func homeComesBack() {
        AppDelegate.showsHomeWhenEmpty = true
        HomeWindowController.current?.close()
        pump(0.2)
        check(HomeWindowController.current == nil, "Home's tab can be closed")
        for d in NSDocumentController.shared.documents {
            d.windowControllers.first?.window?.performClose(nil)
            wait { !NSDocumentController.shared.documents.contains(d) }
        }
        check(NSDocumentController.shared.documents.isEmpty, "every workbook closed without asking")
        wait { HomeWindowController.current != nil }
        check(HomeWindowController.current?.window?.isVisible == true, "closing the last workbook brings Home back")
        let names = HomeWindowController.current?.entries.map(\.name) ?? []
        check(names.contains("Groceries") && names.contains("Groceries copy"), "…listing the workbooks", "\(names)")
    }

    /// Closing a window saves without asking, including what's still being typed in a cell.
    func closingSaves() {
        ctl.selectSheet(0)
        click(cell("F1"))
        type("Still typing")
        check(ctl.editor != nil, "still typing in F1 as the window closes")
        let file = doc.fileURL!
        let closing = doc
        win.performClose(nil)
        wait { !NSDocumentController.shared.documents.contains(closing) }
        check(!NSDocumentController.shared.documents.contains(closing), "the window closed without asking anything")
        let back = try? XLSXReader.read(Data(contentsOf: file))
        eq(back?.workbook.sheets[0].cell(parseCell("F1")!)?.value, .text("Still typing"), "closing saved what was being typed")
    }

    /// Home lists the saved workbooks, newest first, and opens them as tabs beside itself.
    func homeTab() {
        // Book1 is this test's sheet as first saved (it was then saved as ui-test.xlsx, outside the folder).
        try? FileManager.default.copyItem(at: out.appendingPathComponent("ui-test.xlsx"), to: Library.folder.appendingPathComponent("Old.xlsx"))
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 3)],
                                               ofItemAtPath: Library.folder.appendingPathComponent("Old.xlsx").path)
        let home = HomeWindowController.show()
        let hw = home.window!
        hw.setFrame(NSRect(x: 60, y: 60, width: 1180, height: 780), display: true)
        win = hw
        pump(0.3)
        eq(home.entries.map(\.name), ["Book1", "Old"], "Home lists the workbooks folder, newest first")
        eq(home.cards.count, 2, "one card each")

        click(centre(home.newTile))
        wait { NSDocumentController.shared.documents.count == 1 }
        guard let fresh = NSDocumentController.shared.documents.first as? SheetDocument, fresh.controller != nil else {
            check(false, "New workbook opens a workbook"); return
        }
        eq(fresh.fileURL?.lastPathComponent, "Book2.xlsx", "New workbook suggests Book2, since Book1 is taken, and makes the file straight away")
        check(FileManager.default.fileExists(atPath: Library.folder.appendingPathComponent("Book2.xlsx").path), "Book2.xlsx is there to double-click")
        eq(hw.tabGroup?.windows.count, 2, "it opens as a tab beside Home")
        check(hw.tabGroup?.windows.first === hw, "Home is the first tab")
        use(fresh)
        pump(0.3)
        click(cell("A1"))
        type("Fresh")
        ret()
        var saved = false
        fresh.autosave(withImplicitCancellability: false) { _ in saved = true }
        wait { saved }
        let freshBack = try? XLSXReader.read(Data(contentsOf: Library.folder.appendingPathComponent("Book2.xlsx")))
        eq(freshBack?.workbook.sheets[0].cell(parseCell("A1")!)?.value, .text("Fresh"), "what's typed saves into Book2.xlsx")

        HomeWindowController.show(beside: win)
        win = hw
        pump(0.3)
        check(hw.tabGroup?.selectedWindow === hw, "the Home button goes back to the Home tab")
        eq(home.entries.map(\.name), ["Book2", "Book1", "Old"], "Home shows the newest first")
        home.search.stringValue = "old"
        home.reload()
        eq(home.cards.map(\.entry.name), ["Old"], "searching for “old” finds Old")
        home.search.stringValue = ""
        home.reload()
        wait(8) { home.cards.allSatisfy { $0.hasPicture } }
        check(home.cards.allSatisfy { $0.hasPicture }, "every card shows a picture of its workbook")
        snap("11-home")

        guard let card = home.cards.first(where: { $0.entry.name == "Book1" }) else { check(false, "Book1 has a card"); return }
        click(centre(card))
        wait { NSDocumentController.shared.documents.count == 2 }
        let book1 = NSDocumentController.shared.documents.first { $0.fileURL?.lastPathComponent == "Book1.xlsx" } as? SheetDocument
        check(book1 != nil, "clicking Book1's card opens it")
        eq(hw.tabGroup?.windows.count, 3, "as a third tab")
        eq(book1?.workbook.sheets[0].cell(parseCell("A1")!)?.value, .text("Name"), "Book1 has the first thing typed into it")

        // Rename an open workbook from Home: its tab follows.
        if let e = home.entries.first(where: { $0.name == "Book2" }) {
            var renamed = false
            home.rename(e, to: "Groceries") { renamed = true }
            wait { renamed }
        }
        eq(fresh.fileURL?.lastPathComponent, "Groceries.xlsx", "renaming from Home renames the open workbook")
        eq(fresh.displayName, "Groceries", "…and its tab")
        check(!FileManager.default.fileExists(atPath: Library.folder.appendingPathComponent("Book2.xlsx").path), "no Book2 left behind")
        if let e = home.entries.first(where: { $0.name == "Groceries" }) {
            var copied: URL?
            home.duplicate(e) { copied = $0 }
            wait { copied != nil }
            eq(copied?.lastPathComponent, "Groceries copy.xlsx", "Duplicate makes “Groceries copy”")
        }
        eq(home.entries.count, 4, "Home now lists four workbooks")
    }

    /// Changes to a file with parts MySheets can't keep go into a copy beside it; the original isn't touched.
    func copyOfAFileWithExtras() {
        let plain = out.appendingPathComponent("ui-test.xlsx")
        guard let zip = try? ZipReader(Data(contentsOf: plain)) else { check(false, "read ui-test.xlsx"); return }
        var w = ZipWriter()
        let names = zip.names.sorted { a, b in a == "[Content_Types].xml" || (b != "[Content_Types].xml" && a < b) }
        for n in names { if let d = try? zip.data(n) { w.add(n, d) } }
        w.add("xl/comments1.xml", "<comments xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>")
        let original = out.appendingPathComponent("Extras.xlsx")
        let bytes = w.finish()
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: out.appendingPathComponent("Extras (MySheets).xlsx"))
        try? bytes.write(to: original)
        var opened: SheetDocument?
        NSDocumentController.shared.openDocument(withContentsOf: original, display: true) { d, _, _ in opened = d as? SheetDocument }
        wait { opened != nil }
        guard let d = opened else { check(false, "opened Extras.xlsx"); return }
        use(d)
        pump(0.3)
        check(d.losses.contains("comments"), "Extras.xlsx has comments MySheets can't keep")
        check(ctl.bannerText?.contains("copy") == true, "the yellow bar says changes go into a copy", ctl.bannerText ?? "no bar")
        click(cell("A1"))
        type("Changed")
        ret()
        wait { d.fileURL?.lastPathComponent != "Extras.xlsx" }
        eq(d.fileURL?.lastPathComponent, "Extras (MySheets).xlsx", "the first change saves a copy beside the original")
        check((try? Data(contentsOf: original)) == bytes, "the original file is untouched")
        check(d.losses.isEmpty, "the copy has nothing it can't keep")
        check(ctl.bannerText?.contains("“Extras” hasn't changed") == true, "the bar says this is the copy", ctl.bannerText ?? "no bar")
        let back = try? XLSXReader.read(Data(contentsOf: out.appendingPathComponent("Extras (MySheets).xlsx")))
        eq(back?.workbook.sheets[d.workbook.active].cell(parseCell("A1")!)?.value, .text("Changed"), "the copy has the change")
        snap("12-copy")
    }
}

/// `MySheets --perf <file.xlsx>`: times the everyday operations on a big workbook.
enum Perf {
    static func run(_ file: URL) {
        func time(_ what: String, _ body: () -> Void) {
            let t = Date()
            body()
            print(String(format: "%-34@ %7.0f ms", what as NSString, Date().timeIntervalSince(t) * 1000))
        }
        var doc: SheetDocument?
        time("open") {
            doc = try? NSDocumentController.shared.makeDocument(withContentsOf: file, ofType: "org.openxmlformats.spreadsheetml.sheet") as? SheetDocument
            if let doc { NSDocumentController.shared.addDocument(doc); doc.makeWindowControllers(); doc.showWindows() }
        }
        guard let doc, let ctl = doc.controller, let win = ctl.window else { print("couldn't open"); exit(1) }
        doc.undoManager?.groupsByEvent = false
        let grid = ctl.grid!
        // Forces a real draw of what's on screen into a picture.
        func draw() {
            let r = grid.visibleRect
            if let rep = grid.bitmapImageRepForCachingDisplay(in: r) { grid.cacheDisplay(in: r, to: rep) }
        }
        print("visible area \(grid.visibleRect.size), zoom \(ctl.zoom), window on screen \(win.isVisible)")
        time("first draw") { draw() }
        time("draw a screen (x20)") { for _ in 0..<20 { grid.needsDisplay = true; draw() } }
        time("scroll to row 40,000 and draw") { ctl.scrollTo(CellAddr(40000, 0)); draw() }
        time("scroll 50 steps and draw") {
            for i in 0..<50 { ctl.scroll.contentView.scroll(to: NSPoint(x: 0, y: ctl.geo.y(20000 + i * 30))); draw() }
        }
        time("move row 10 to row 40,000") { ctl.moveRows(9, 1, to: 40000, copy: false); draw() }
        time("insert a row at the top") { ctl.sel = Selection.rows(0, 0, activeCol: 0); ctl.insertRows(nil); draw() }
        time("fill column B yellow") { ctl.sel = Selection.cols(1, 1, activeRow: 0); ctl.applyFill(RGB(255, 255, 0)); draw() }
        time("undo") { doc.undoManager?.undo(); draw() }
        time("type into a cell") { ctl.sel = Selection(CellAddr(5, 3)); ctl.beginEditing(.enter); ctl.editor?.string = "hello"; ctl.commitEditing(then: .enterDown); draw() }
        time("type into a second cell") { ctl.sel = Selection(CellAddr(6, 3)); ctl.beginEditing(.enter); ctl.editor?.string = "again"; ctl.commitEditing(then: .enterDown); draw() }
        time("  just open the editor") { ctl.sel = Selection(CellAddr(7, 3)); ctl.beginEditing(.enter) }
        time("  just commit") { ctl.editor?.string = "third"; ctl.commitEditing(then: .enterDown) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mysheets-perf.xlsx")
        time("save") { _ = try? doc.write(to: out, ofType: "org.openxmlformats.spreadsheetml.sheet") }
        print("saved \(out.path)")
        exit(0)
    }
}
