import Foundation

/// Checks that run without a window: `MySheets --self-test [folder]`.
enum SelfTest {
    private nonisolated(unsafe) static var failures = 0
    private nonisolated(unsafe) static var passes = 0

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1; print("FAIL: \(what) \(detail())") }
    }

    private static func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
        check(a == b, what, "got \(a), expected \(b)")
    }

    static func run(fixtures: String?) -> Int32 {
        addresses()
        axis()
        formats()
        typing()
        rowOps()
        zipRoundTrip()
        xlsxRoundTrip()
        if let fixtures { readFixtures(fixtures) }
        print("\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func addresses() {
        eq(columnName(0), "A", "column A")
        eq(columnName(25), "Z", "column Z")
        eq(columnName(26), "AA", "column AA")
        eq(columnName(16383), "XFD", "last column")
        eq(columnNumber("XFD"), 16383, "XFD number")
        eq(parseCell("B7"), CellAddr(6, 1), "parse B7")
        eq(parseCell("$C$3"), CellAddr(2, 2), "parse $C$3")
        eq(parseCell("XFD1048576"), CellAddr(maxRows - 1, maxCols - 1), "last cell")
        check(parseCell("XFE1") == nil, "past last column")
        eq(parseRange("A1:C5"), CellRange(0, 0, 4, 2), "range A1:C5")
        eq(parseRange("3:5"), CellRange.rows(2, 4), "rows 3:5")
        eq(parseRange("B:D"), CellRange.cols(1, 3), "cols B:D")
        eq(rangeName(.rows(2, 4)), "3:5", "name rows")
        eq(rangeName(.cols(1, 3)), "B:D", "name cols")
        eq(rangeName(CellRange(0, 0, 4, 2)), "A1:C5", "name range")
    }

    private static func axis() {
        var ax = Axis(count: 1000, defaultSize: 20)
        ax.set([3], size: 50)
        ax.set([7, 8], hidden: true)
        ax.set([10], size: 5)
        func brute(_ i: Int) -> Double { (0..<i).reduce(0) { $0 + ax.size($1) } }
        var ok = true
        for i in 0..<40 where ax.offset(i) != brute(i) { ok = false }
        check(ok, "axis offsets match a straight sum")
        var hit = true
        for i in 0..<40 where !ax.isHidden(i) {
            let mid = ax.offset(i) + ax.size(i) / 2
            if ax.index(at: mid) != i { hit = false; print("  index(at: \(mid)) = \(ax.index(at: mid)), expected \(i)") }
            if ax.index(at: ax.offset(i)) != i { hit = false; print("  index(at start of \(i)) = \(ax.index(at: ax.offset(i)))") }
        }
        check(hit, "axis index(at:) finds every visible row")
        eq(ax.index(at: ax.offset(7)), 9, "hidden rows are skipped")
        ax.remap(Sheet.insertMap(at: 2, count: 1))
        eq(ax.size(4), 50, "sizes follow an insert")
        check(ax.isHidden(8) && ax.isHidden(9) && !ax.isHidden(7), "hidden rows follow an insert")
    }

    private static func formats() {
        eq(NumFmt.general(1.0 / 3), "0.333333333", "General 1/3")
        eq(NumFmt.general(-2.0 / 3), "-0.66666667", "General -2/3")
        eq(NumFmt.general(123456.789012), "123456.789", "General 123456.789012")
        eq(NumFmt.general(42), "42", "General 42")
        eq(NumFmt.general(1.5e12), "1.5E+12", "General big")
        eq(NumFmt.format(1234.5, "#,##0.00", date1904: false).text, "1,234.50", "#,##0.00")
        eq(NumFmt.format(1234567, "#,##0", date1904: false).text, "1,234,567", "#,##0")
        eq(NumFmt.format(0.256, "0.0%", date1904: false).text, "25.6%", "0.0%")
        eq(NumFmt.format(-5, "#,##0;(#,##0)", date1904: false).text, "(5)", "negative section")
        eq(NumFmt.format(-1234.5, "#,##0.00", date1904: false).text, "-1,234.50", "single-section minus")
        eq(NumFmt.format(12.5, "\"£\"#,##0.00", date1904: false).text, "£12.50", "pounds")
        eq(NumFmt.format(12.5, "[$€-x-euro2] #,##0.00", date1904: false).text, "€ 12.50", "euro locale tag")
        eq(NumFmt.format(45658, "dd/mm/yyyy", date1904: false).text, "01/01/2025", "date 45658")
        eq(NumFmt.format(45658, "d mmmm yyyy", date1904: false).text, "1 January 2025", "long date")
        eq(NumFmt.format(45658, "dddd", date1904: false).text, "Wednesday", "weekday")
        eq(NumFmt.format(0.75, "h:mm AM/PM", date1904: false).text, "6:00 PM", "time 12-hour")
        eq(NumFmt.format(0.5 + 1.0 / 1440, "hh:mm", date1904: false).text, "12:01", "minutes, not months")
        eq(NumFmt.format(1.25, "[h]:mm", date1904: false).text, "30:00", "elapsed hours")
        eq(NumFmt.format(61, "dd/mm/yyyy", date1904: false).text, "01/03/1900", "after Excel's fake 29 Feb 1900")
        eq(NumFmt.format(0, "dd/mm/yyyy", date1904: true).text, "01/01/1904", "1904 date system")
        eq(NumFmt.format(1234.5678, "0.00E+00", date1904: false).text, "1.23E+03", "scientific")
        eq(NumFmt.format(1500000, "#,##0,\"k\"", date1904: false).text, "1,500k", "scaled thousands")
        eq(NumFmt.format(5, "0.00;[Red]-0.00", date1904: false).text, "5.00", "colour section, positive")
        check(NumFmt.format(-5, "0.00;[Red]-0.00", date1904: false).color == RGB(255, 0, 0), "red negatives")
        eq(NumFmt.serial(2025, 1, 1), 45658, "serial of 1 Jan 2025")
        eq(NumFmt.serial(1900, 1, 1), 1, "serial of 1 Jan 1900")
    }

    private static func typing() {
        eq(parseEntry("12"), .value(.number(12), format: nil), "typed 12")
        eq(parseEntry("-3.5"), .value(.number(-3.5), format: nil), "typed -3.5")
        eq(parseEntry("1,234"), .value(.number(1234), format: "#,##0"), "typed 1,234")
        eq(parseEntry("50%"), .value(.number(0.5), format: "0%"), "typed 50%")
        eq(parseEntry("12.5%"), .value(.number(0.125), format: "0.00%"), "typed 12.5%")
        eq(parseEntry("£3.50"), .value(.number(3.5), format: "\"£\"#,##0.00"), "typed £3.50")
        eq(parseEntry("03/04/2025", dayFirst: true), .value(.number(Double(NumFmt.serial(2025, 4, 3))), format: "dd/mm/yyyy"), "typed UK date")
        eq(parseEntry("2025-04-03"), .value(.number(Double(NumFmt.serial(2025, 4, 3))), format: "yyyy-mm-dd"), "typed ISO date")
        eq(parseEntry("31/02/2025", dayFirst: true), .value(.text("31/02/2025"), format: nil), "impossible date stays text")
        eq(parseEntry("9:30"), .value(.number(9.5 / 24), format: "h:mm"), "typed time")
        eq(parseEntry("'007"), .value(.text("007"), format: nil), "apostrophe keeps text")
        eq(parseEntry("=A1+1"), .formula("A1+1"), "formula kept")
        eq(parseEntry("true"), .value(.bool(true), format: nil), "typed TRUE")
        eq(parseEntry("hello world"), .value(.text("hello world"), format: nil), "typed text")
        eq(parseEntry(""), .clear, "empty clears")
        eq(editText(Cell(value: .number(0.125)), format: "0.00%", date1904: false), "12.5%", "percent edit text")
        eq(editText(Cell(value: .number(45658)), format: "d mmm yyyy", date1904: false), dayFirstDates ? "01/01/2025" : "01/01/2025", "date edit text")
    }

    private static func sample() -> Sheet {
        var s = Sheet(name: "Test")
        for r in 0..<6 { s.setValue(CellAddr(r, 0), .text("row\(r + 1)")); s.setValue(CellAddr(r, 1), .number(Double(r + 1))) }
        s.rows.set([1], size: 40)
        s.rowStyles[2] = 3
        return s
    }

    private static func rowOps() {
        var s = sample()
        s.remapRows(Sheet.moveMap(from: 4, count: 2, to: 1))   // rows 5-6 above row 2
        eq(s.cell(CellAddr(1, 0))?.value, .text("row5"), "move up: first moved row")
        eq(s.cell(CellAddr(2, 0))?.value, .text("row6"), "move up: second moved row")
        eq(s.cell(CellAddr(3, 0))?.value, .text("row2"), "move up: displaced row")
        eq(s.rows.customSize(3), 40, "row height travels with its row")
        eq(s.rowStyles[4], 3, "row format travels with its row")

        s = sample()
        s.remapRows(Sheet.moveMap(from: 0, count: 2, to: 5))   // rows 1-2 below row 5
        eq(s.cell(CellAddr(3, 0))?.value, .text("row1"), "move down: first moved row")
        eq(s.cell(CellAddr(4, 0))?.value, .text("row2"), "move down: second moved row")
        eq(s.cell(CellAddr(0, 0))?.value, .text("row3"), "move down: rows above close up")
        eq(s.cell(CellAddr(5, 0))?.value, .text("row6"), "move down: rows below stay")

        s = sample()
        s.remapRows(Sheet.insertMap(at: 1, count: 2))
        eq(s.cell(CellAddr(3, 0))?.value, .text("row2"), "insert rows pushes down")
        check(s.cell(CellAddr(1, 0)) == nil, "inserted row is empty")
        s.remapRows(Sheet.deleteMap(at: 1, count: 2))
        eq(s.cell(CellAddr(1, 0))?.value, .text("row2"), "delete rows pulls up")

        s = sample()
        s.remapCols(Sheet.moveMap(from: 1, count: 1, to: 0))
        eq(s.cell(CellAddr(0, 0))?.value, .number(1), "move column left")
        eq(s.cell(CellAddr(0, 1))?.value, .text("row1"), "column swapped")

        s = sample()
        s.moveRange(CellRange(0, 0, 1, 1), by: 3, 2, copy: false)
        eq(s.cell(CellAddr(3, 2))?.value, .text("row1"), "block moved")
        check(s.cell(CellAddr(0, 0)) == nil, "block source emptied")
        s.moveRange(CellRange(3, 2, 4, 3), by: -3, -2, copy: true)
        eq(s.cell(CellAddr(0, 0))?.value, .text("row1"), "block copied back")
        eq(s.cell(CellAddr(3, 2))?.value, .text("row1"), "copy leaves source")

        s = sample()
        s.insertCopies(ofRows: 0, count: 2, at: 4)
        eq(s.cell(CellAddr(4, 0))?.value, .text("row1"), "copied row 1 inserted")
        eq(s.cell(CellAddr(5, 0))?.value, .text("row2"), "copied row 2 inserted")
        eq(s.cell(CellAddr(6, 0))?.value, .text("row5"), "rows below pushed down")
        eq(s.rows.customSize(5), 40, "copied row keeps its height")

        s = sample()
        eq(s.jump(from: CellAddr(0, 0), 1, 0), CellAddr(5, 0), "Cmd-Down goes to end of data")
        eq(s.jump(from: CellAddr(5, 0), 1, 0), CellAddr(maxRows - 1, 0), "Cmd-Down from the end goes to the last row")
        eq(s.jump(from: CellAddr(0, 1), 0, 1), CellAddr(0, maxCols - 1), "Cmd-Right past data")
        eq(s.jump(from: CellAddr(0, 3), 0, -1), CellAddr(0, 1), "Cmd-Left reaches data")
    }

    private static func zipRoundTrip() {
        var z = ZipWriter()
        var bytes = [UInt8](repeating: 0, count: 200_000)
        for i in 0..<bytes.count { bytes[i] = UInt8((i * 7 + i / 13) % 251) }
        let big = Data(bytes)
        let text = String(repeating: "Hello, spreadsheet! ", count: 500)
        z.add("a.txt", text)
        z.add("folder/b.bin", big)
        z.add("tiny", "x")
        guard let r = try? ZipReader(z.finish()) else { check(false, "zip reads back"); return }
        eq((try? r.data("a.txt")) ?? nil, Data(text.utf8), "zip text entry")
        eq((try? r.data("folder/b.bin")) ?? nil, big, "zip binary entry")
        eq((try? r.data("tiny")) ?? nil, Data("x".utf8), "zip stored entry")
    }

    private static func xlsxRoundTrip() {
        let styles = StyleTable.blank()
        var s1 = Sheet(name: "Budget & Plan")
        s1.setValue(CellAddr(0, 0), .text("Item"))
        s1.setValue(CellAddr(0, 1), .text("Cost <£>"))
        s1.setValue(CellAddr(1, 0), .text("  Rent \"flat\"  "))
        s1.setValue(CellAddr(1, 1), .number(950.25), style: styles.withNumFmt(0, "\"£\"#,##0.00"))
        s1.setValue(CellAddr(2, 0), .text("Line one\nLine two"))
        s1.setValue(CellAddr(2, 1), .number(45658), style: styles.withNumFmt(0, "dd/mm/yyyy"))
        s1.setValue(CellAddr(3, 0), .bool(true))
        s1.setValue(CellAddr(3, 1), .error("#N/A"))
        s1.setValue(CellAddr(4, 1), .number(13), formula: "B2+3")
        s1.setValue(CellAddr(5, 2), .number(0.1 + 0.2))
        let boldBig = styles.withFont(styles.withFill(0, RGB(255, 192, 0)), bold: true, size: 18)
        s1.setValue(CellAddr(7, 0), .text("Big bold"), style: boldBig)
        s1.setValue(CellAddr(7, 1), .text("Slanted"), style: styles.withFont(0, italic: true))
        s1.rows.set([7], size: 30)
        s1.autoHeights.insert(7)
        let yellow = styles.withFill(0, RGB(255, 255, 0))
        s1.setCell(CellAddr(6, 3), Cell(style: yellow))
        s1.rowStyles[8] = yellow
        s1.colStyles[5] = styles.withFill(0, RGB(146, 208, 80))
        s1.rows.set([1], size: 30)
        s1.rows.set([4], hidden: true)
        s1.cols.set([0], size: 150)
        s1.cols.set([2, 3], size: 90)
        s1.cols.set([7], hidden: true)
        s1.selection = .covering(CellRange(1, 0, 3, 1), active: CellAddr(2, 1))
        var s2 = Sheet(name: "Second")
        s2.setValue(CellAddr(99, 25), .text("far away"))
        var book = Workbook(sheets: [s1, s2])
        book.active = 1

        let data = XLSXWriter.write(book, styles: styles, theme: nil, date1904: false)
        guard let back = try? XLSXReader.read(data) else { check(false, "written file reads back"); return }
        let b = back.workbook
        eq(b.sheets.count, 2, "sheet count")
        eq(b.active, 1, "active sheet")
        eq(b.sheets[0].name, "Budget & Plan", "sheet name with &")
        let t = b.sheets[0]
        for (a, c) in s1.cells.flatMap({ r, rc in rc.map { (CellAddr(r, $0.key), $0.value) } }) {
            eq(t.cell(a)?.value, c.value, "value at \(cellName(a))")
            eq(t.cell(a)?.formula, c.formula, "formula at \(cellName(a))")
            eq(back.styles[t.cell(a)?.style ?? 0].fill, styles[c.style].fill, "fill at \(cellName(a))")
            eq(back.styles[t.cell(a)?.style ?? 0].numFmt, styles[c.style].numFmt, "number format at \(cellName(a))")
        }
        eq(t.rows.customSize(1), 30, "row height")
        check(!t.autoHeights.contains(1), "row sized by hand stays custom")
        eq(t.rows.customSize(7), 30, "fitted row height")
        check(t.autoHeights.contains(7), "fitted row stays fitted")
        let bb = back.styles[t.styleAt(CellAddr(7, 0))]
        check(bb.bold && !bb.italic && bb.size == 18 && bb.fill == RGB(255, 192, 0), "bold 18pt keeps its fill", "\(bb)")
        let sl = back.styles[t.styleAt(CellAddr(7, 1))]
        check(sl.italic && !sl.bold && sl.size == 11, "italic")
        check(t.rows.isHidden(4), "hidden row")
        eq(t.cols.customSize(0), 150, "column width 150")
        eq(t.cols.customSize(2), 90, "column width 90 (run of two)")
        eq(t.cols.customSize(3), 90, "column width 90 (second of run)")
        check(t.cols.isHidden(7), "hidden column")
        eq(back.styles[t.rowStyles[8] ?? 0].fill, RGB(255, 255, 0), "row fill")
        eq(back.styles[t.colStyles[5] ?? 0].fill, RGB(146, 208, 80), "column fill")
        eq(t.selection.active, CellAddr(2, 1), "active cell")
        eq(t.selection.ranges, [CellRange(1, 0, 3, 1)], "selected range")
        eq(b.sheets[1].cell(CellAddr(99, 25))?.value, .text("far away"), "second sheet value")
        check(back.losses.isEmpty, "own file has nothing it can't keep", "\(back.losses)")
        check(back.hasFormulas, "formula noticed")

        // Saving the reopened file again gives the same workbook.
        let again = XLSXWriter.write(b, styles: back.styles, theme: back.theme, date1904: back.date1904)
        if let third = try? XLSXReader.read(again) {
            eq(third.workbook.sheets[0].cells.count, t.cells.count, "second round trip keeps every row")
        } else { check(false, "second round trip reads back") }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mysheets-selftest.xlsx")
        try? data.write(to: dir)
        print("wrote \(dir.path)")
    }

    private static func readFixtures(_ folder: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { check(false, "fixtures folder"); return }
        for name in names.sorted() where name.lowercased().hasSuffix(".xlsx") {
            let path = (folder as NSString).appendingPathComponent(name)
            do {
                let wb = try XLSXReader.read(Data(contentsOf: URL(fileURLWithPath: path)))
                let summary = wb.workbook.sheets.map { s in
                    let n = s.cells.values.reduce(0) { $0 + $1.count }
                    return "\(s.name): \(n) cells, \(s.rows.sizes.count) row heights, \(s.cols.sizes.count) col widths"
                }
                print("\(name): \(summary.joined(separator: "; "))" + (wb.losses.isEmpty ? "" : " | can't keep: \(wb.losses.joined(separator: ", "))"))
                passes += 1
            } catch {
                check(false, "read \(name)", error.localizedDescription)
            }
        }
    }
}
