import Foundation

// Reads and writes .xlsx (Office Open XML, ECMA-376 / ISO/IEC 29500). Built from the published
// standard; MySheets reads values, sizes, hidden rows and columns, formats and sheets, and notes
// anything else a file holds so that saving can't quietly drop it.

enum XLSXError: LocalizedError {
    case bad(String)
    var errorDescription: String? {
        if case .bad(let s) = self { return "MySheets can't open this file: \(s)." }
        return nil
    }
}

struct LoadedWorkbook {
    var workbook: Workbook
    var styles: StyleTable
    var theme: Data?
    var date1904: Bool
    /// Things in the file this app can't keep, in plain words.
    var losses: [String]
    var hasFormulas: Bool
}

private let mainNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
private let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

private struct Rel { let id: String; let type: String; let target: String }

private func directory(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
}

private func resolve(_ target: String, base: String) -> String {
    if target.hasPrefix("/") { return String(target.dropFirst()) }
    var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
    for p in target.split(separator: "/") {
        if p == ".." { if !parts.isEmpty { parts.removeLast() } } else if p != "." { parts.append(String(p)) }
    }
    return parts.joined(separator: "/")
}

private func relsPath(for part: String) -> String {
    let dir = directory(of: part)
    let file = part.split(separator: "/").last.map(String.init) ?? part
    return (dir.isEmpty ? "" : dir + "/") + "_rels/" + file + ".rels"
}

private func readRels(_ data: Data?, base: String) throws -> [Rel] {
    guard let data else { return [] }
    let d = try XMLDocument(data: data, options: [])
    return (d.rootElement()?.kids("Relationship") ?? []).compactMap { e in
        guard let id = e.attr("Id"), let type = e.attr("Type"), let target = e.attr("Target"), e.attr("TargetMode") != "External" else { return nil }
        return Rel(id: id, type: type, target: resolve(target, base: base))
    }
}

enum XLSXReader {
    static func read(_ data: Data) throws -> LoadedWorkbook {
        let zip = try ZipReader(data)
        var losses = Set<String>()
        for name in zip.names.map({ $0.lowercased() }) {
            // Comment boxes live in xl/drawings/*.vml; real drawings are DrawingML parts there, plus charts and media.
            if (name.hasPrefix("xl/drawings/") && name.hasSuffix(".xml")) || name.hasPrefix("xl/charts/") || name.hasPrefix("xl/media/") { losses.insert("charts and pictures") }
            if name.hasPrefix("xl/pivottables/") || name.hasPrefix("xl/pivotcache/") { losses.insert("pivot tables") }
            if name.hasPrefix("xl/tables/") { losses.insert("tables") }
            if name.hasPrefix("xl/comments") || name.hasPrefix("xl/threadedcomments/") { losses.insert("comments") }
            if name.hasPrefix("xl/externallinks/") { losses.insert("links to other files") }
            if name.hasSuffix("vbaproject.bin") { losses.insert("macros") }
            if name.hasPrefix("xl/slicers/") || name.hasPrefix("xl/timelines/") { losses.insert("slicers") }
        }

        let rootRels = try readRels(zip.data("_rels/.rels"), base: "")
        guard let wbPath = rootRels.first(where: { $0.type.hasSuffix("/officeDocument") })?.target,
              let wbData = try zip.data(wbPath) else { throw XLSXError.bad("it has no workbook inside") }
        let wbDoc = try XMLDocument(data: wbData, options: [])
        guard let wb = wbDoc.rootElement() else { throw XLSXError.bad("the workbook part is empty") }
        let rels = try readRels(zip.data(relsPath(for: wbPath)), base: directory(of: wbPath))
        func part(_ suffix: String) throws -> Data? {
            guard let r = rels.first(where: { $0.type.hasSuffix(suffix) }) else { return nil }
            return try zip.data(r.target)
        }

        let theme = try part("/theme")
        let styles = try StyleTable(stylesXML: try part("/styles"), themeXML: theme)
        var shared: [String] = []
        if let sst = try part("/sharedStrings") {
            let p = SharedStringsParser()
            shared = try p.parse(sst)
            if p.rich { losses.insert("mixed formatting inside a cell") }
        }
        let pr = wb.kid("workbookPr")
        let date1904 = pr?.attr("date1904") == "1" || pr?.attr("date1904") == "true"
        if let names = wb.kid("definedNames"), !names.kids("definedName").filter({ !($0.attr("name") ?? "").hasPrefix("_xlnm") }).isEmpty {
            losses.insert("named ranges")
        }
        if let p = wb.kid("workbookProtection"), ["lockStructure", "lockWindows", "lockRevision"].contains(where: { ["1", "true"].contains(p.attr($0) ?? "") }) {
            losses.insert("protection")
        }
        let activeTab = wb.kid("bookViews")?.kid("workbookView")?.attr("activeTab").flatMap(Int.init) ?? 0

        var sheets: [Sheet] = []
        var hasFormulas = false
        var activeIndex = 0
        for (i, s) in (wb.kid("sheets")?.kids("sheet") ?? []).enumerated() {
            let rid = s.attribute(forLocalName: "id", uri: relNS)?.stringValue ?? s.attr("r:id") ?? ""
            guard let rel = rels.first(where: { $0.id == rid }) else { continue }
            guard rel.type.hasSuffix("/worksheet") else { losses.insert("chart sheets"); continue }
            guard let sheetData = try zip.data(rel.target) else { continue }
            let p = SheetParser(name: s.attr("name") ?? "Sheet\(sheets.count + 1)", shared: shared)
            var sheet = try p.parse(sheetData)
            sheet.state = s.attr("state")
            losses.formUnion(p.losses)
            hasFormulas = hasFormulas || p.hasFormulas
            if i == activeTab { activeIndex = sheets.count }
            sheets.append(sheet)
        }
        if sheets.isEmpty { sheets = [Sheet(name: "Sheet1")] }
        var book = Workbook(sheets: sheets)
        book.active = min(activeIndex, sheets.count - 1)
        return LoadedWorkbook(workbook: book, styles: styles, theme: theme, date1904: date1904,
                              losses: losses.sorted(), hasFormulas: hasFormulas)
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var out: [String] = []
    private var current = ""
    private var inSI = false, inT = false, inPhonetic = false
    private var runs = 0, formattedRuns = 0
    private(set) var rich = false

    func parse(_ data: Data) throws -> [String] {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = self
        guard p.parse() else { throw XLSXError.bad("the shared text is damaged (\(p.parserError?.localizedDescription ?? "unknown"))") }
        return out
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "si": inSI = true; current = ""; runs = 0; formattedRuns = 0
        case "t": if inSI && !inPhonetic { inT = true }
        case "rPh": inPhonetic = true
        case "r": runs += 1
        case "rPr": formattedRuns += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "si":
            out.append(current); inSI = false
            if runs > 1 && formattedRuns > 0 { rich = true }
        case "t": inT = false
        case "rPh": inPhonetic = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inT { current += string } }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private var sheet: Sheet
    private let shared: [String]
    private(set) var losses = Set<String>()
    private(set) var hasFormulas = false

    private var defaultRow = 20.0, defaultCol = 64.0
    private var rowSizes: [Int: Double] = [:], rowHidden = Set<Int>()
    private var colSizes: [Int: Double] = [:], colHidden = Set<Int>()

    private var row = -1, col = -1
    private var cType = "n", cStyle = 0
    private var vText = "", fText = "", isText = ""
    private var hasF = false, fKind = ""
    private enum Capture { case none, v, f, t }
    private var capture = Capture.none
    private var inIs = false, inPhonetic = false
    private var sawSelection = false

    init(name: String, shared: [String]) {
        sheet = Sheet(name: name)
        self.shared = shared
    }

    func parse(_ data: Data) throws -> Sheet {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = self
        guard p.parse() else { throw XLSXError.bad("sheet “\(sheet.name)” is damaged (\(p.parserError?.localizedDescription ?? "unknown"))") }
        sheet.rows = Axis(count: maxRows, defaultSize: defaultRow, sizes: rowSizes, hidden: rowHidden)
        sheet.cols = Axis(count: maxCols, defaultSize: defaultCol, sizes: colSizes, hidden: colHidden)
        return sheet
    }

    private func yes(_ v: String?) -> Bool { v == "1" || v == "true" }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "sheetFormatPr":
            if let h = a["defaultRowHeight"].flatMap(Double.init), h > 0 { defaultRow = (h * 4 / 3 * 100).rounded() / 100 }
            if let w = a["defaultColWidth"].flatMap(Double.init), w > 0 { defaultCol = XLSXWriter.widthToPx(w) }
        case "col":
            guard let lo = a["min"].flatMap(Int.init), let hi = a["max"].flatMap(Int.init), lo >= 1 else { break }
            let width = a["width"].flatMap(Double.init).map(XLSXWriter.widthToPx)
            let style = a["style"].flatMap(Int.init) ?? 0
            for c in (lo - 1)..<min(hi, maxCols) {
                if let width, width != defaultCol { colSizes[c] = width }
                if yes(a["hidden"]) { colHidden.insert(c) }
                if style != 0 { sheet.colStyles[c] = style }
            }
        case "row":
            row = a["r"].flatMap(Int.init).map { $0 - 1 } ?? row + 1
            col = -1
            guard row >= 0 && row < maxRows else { break }
            if let ht = a["ht"].flatMap(Double.init) {
                let px = (ht * 4 / 3 * 100).rounded() / 100
                if yes(a["customHeight"]) { rowSizes[row] = px }
                else if abs(px - defaultRow) > 0.01 { rowSizes[row] = px; sheet.autoHeights.insert(row) }
            }
            if yes(a["hidden"]) { rowHidden.insert(row) }
            if yes(a["customFormat"]), let s = a["s"].flatMap(Int.init) { sheet.rowStyles[row] = s }
        case "c":
            if let r = a["r"], let addr = parseCell(r) { row = addr.row; col = addr.col } else { col += 1 }
            cType = a["t"] ?? "n"
            cStyle = a["s"].flatMap(Int.init) ?? 0
            vText = ""; fText = ""; isText = ""
            hasF = false; fKind = ""
        case "v": capture = .v
        case "f":
            capture = .f; hasF = true
            fKind = a["t"] ?? ""
            if fKind == "shared" && a["ref"] != nil { fKind = "sharedMaster" }
        case "is": inIs = true
        case "t": if inIs && !inPhonetic { capture = .t }
        case "rPh": inPhonetic = true
        case "mergeCell": losses.insert("merged cells")
        case "drawing", "picture": losses.insert("charts and pictures")
        case "legacyDrawing": losses.insert("comments")
        case "conditionalFormatting": losses.insert("conditional formatting")
        case "dataValidation": losses.insert("drop-down lists and data validation")
        case "hyperlink": losses.insert("links")
        case "tablePart": losses.insert("tables")
        case "sheetProtection": if yes(a["sheet"]) { losses.insert("protection") }
        case "autoFilter": losses.insert("filters")
        case "pane": if a["state"] == "frozen" || a["state"] == "frozenSplit" || a["xSplit"] != nil || a["ySplit"] != nil { losses.insert("frozen panes") }
        case "selection":
            guard !sawSelection else { break }
            sawSelection = true
            if let ac = a["activeCell"].flatMap({ parseCell($0) }) {
                var sel = Selection(ac)
                let ranges = (a["sqref"] ?? "").split(separator: " ").compactMap { parseRange(String($0)) }
                if !ranges.isEmpty {
                    sel.ranges = ranges
                    sel.anchor = ranges[ranges.count - 1].topLeft
                    sel.corner = CellAddr(ranges[ranges.count - 1].r1, ranges[ranges.count - 1].c1)
                    if ranges[ranges.count - 1].isWholeRows && !ranges[ranges.count - 1].isWholeCols { sel.kind = .rows }
                    else if ranges[ranges.count - 1].isWholeCols && !ranges[ranges.count - 1].isWholeRows { sel.kind = .cols }
                }
                sheet.selection = sel
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch capture {
        case .v: vText += string
        case .f: fText += string
        case .t: isText += string
        case .none: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "f": capture = .none
        case "t": if capture == .t { capture = .none }
        case "is": inIs = false
        case "rPh": inPhonetic = false
        case "c": finishCell()
        default: break
        }
    }

    private func finishCell() {
        guard row >= 0, row < maxRows, col >= 0, col < maxCols else { return }
        var cell = Cell(style: cStyle)
        switch cType {
        case "s": if let i = Int(vText), i >= 0, i < shared.count { cell.value = .text(shared[i]) }
        case "inlineStr": cell.value = .text(isText)
        case "str": cell.value = .text(vText)
        case "b": cell.value = vText.isEmpty ? nil : .bool(vText == "1" || vText == "true")
        case "e": cell.value = vText.isEmpty ? nil : .error(vText)
        case "d":
            // ISO 8601 date: keep the day as a serial number.
            let p = vText.prefix(10).split(separator: "-").compactMap { Int($0) }
            if p.count == 3 { cell.value = .number(Double(NumFmt.serial(p[0], p[1], p[2]))) }
        default: if let v = Double(vText) { cell.value = .number(v) }
        }
        if hasF {
            switch fKind {
            case "", "normal", "sharedMaster":
                if !fText.isEmpty { cell.formula = fText; hasFormulas = true }
            default:
                // Shared-formula copies, array formulas and data tables keep only their last value.
                losses.insert("some formulas (kept as their last values)")
            }
        }
        if cell.isBlank && cell.style == sheet.inheritedStyle(CellAddr(row, col)) { return }
        sheet.cells[row, default: [:]][col] = cell
    }
}

// MARK: - Writing

enum XLSXWriter {
    /// Excel column widths are in characters of the default font's widest digit (7 px for Calibri 11),
    /// plus 5 px of padding, in steps of 1/256.
    static func pxToWidth(_ px: Double) -> Double {
        let chars = max(0, (px - 5) / 7)
        return (((chars * 7 + 5) / 7) * 256).rounded(.down) / 256
    }

    static func widthToPx(_ w: Double) -> Double { (((256 * w + 18) / 256) * 7).rounded(.down) }

    static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\r": break
            default:
                // XML 1.0 can't hold most control characters.
                if u.value < 0x20 && u != "\t" && u != "\n" { continue }
                if u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    static func num(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    private static func pt(_ px: Double) -> String { num((px * 0.75 * 100).rounded() / 100) }

    private final class SharedStrings {
        var list: [String] = []
        var index: [String: Int] = [:]
        var uses = 0
        func id(_ s: String) -> Int {
            uses += 1
            if let i = index[s] { return i }
            index[s] = list.count
            list.append(s)
            return list.count - 1
        }
    }

    static func write(_ book: Workbook, styles: StyleTable, theme: Data?, date1904: Bool) -> Data {
        let sst = SharedStrings()
        var hasFormulas = false
        let sheetsXML = book.sheets.enumerated().map { i, s in sheetXML(s, selected: i == book.active, sst, &hasFormulas) }
        let n = book.sheets.count

        var types = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        """
        for i in 1...n {
            types += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        if theme != nil { types += "<Override PartName=\"/xl/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>" }
        types += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        types += "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
        types += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        types += "</Types>"

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """

        let app = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>MySheets</Application></Properties>
        """

        var wb = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        wb += "<workbook xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\">"
        if date1904 { wb += "<workbookPr date1904=\"1\"/>" }
        wb += "<bookViews><workbookView activeTab=\"\(book.active)\"/></bookViews><sheets>"
        for (i, s) in book.sheets.enumerated() {
            let state = s.state.map { " state=\"\(esc($0))\"" } ?? ""
            wb += "<sheet name=\"\(esc(s.name))\" sheetId=\"\(i + 1)\"\(state) r:id=\"rId\(i + 1)\"/>"
        }
        wb += "</sheets>"
        // MySheets doesn't calculate, so ask Excel to recalculate any formulas when it opens the file.
        if hasFormulas { wb += "<calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/>" }
        wb += "</workbook>"

        var wbRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        wbRels += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 1...n {
            wbRels += "<Relationship Id=\"rId\(i)\" Type=\"\(relNS)/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>"
        }
        wbRels += "<Relationship Id=\"rId\(n + 1)\" Type=\"\(relNS)/styles\" Target=\"styles.xml\"/>"
        wbRels += "<Relationship Id=\"rId\(n + 2)\" Type=\"\(relNS)/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        if theme != nil { wbRels += "<Relationship Id=\"rId\(n + 3)\" Type=\"\(relNS)/theme\" Target=\"theme/theme1.xml\"/>" }
        wbRels += "</Relationships>"

        var strings = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        strings += "<sst xmlns=\"\(mainNS)\" count=\"\(sst.uses)\" uniqueCount=\"\(sst.list.count)\">"
        for s in sst.list {
            let keep = s.first?.isWhitespace == true || s.last?.isWhitespace == true || s.contains("\n")
            strings += keep ? "<si><t xml:space=\"preserve\">\(esc(s))</t></si>" : "<si><t>\(esc(s))</t></si>"
        }
        strings += "</sst>"

        var z = ZipWriter()
        z.add("[Content_Types].xml", types)
        z.add("_rels/.rels", rootRels)
        z.add("docProps/app.xml", app)
        z.add("xl/workbook.xml", wb)
        z.add("xl/_rels/workbook.xml.rels", wbRels)
        for (i, x) in sheetsXML.enumerated() { z.add("xl/worksheets/sheet\(i + 1).xml", x) }
        z.add("xl/styles.xml", styles.xmlData())
        z.add("xl/sharedStrings.xml", strings)
        if let theme { z.add("xl/theme/theme1.xml", theme) }
        return z.finish()
    }

    private static func sheetXML(_ s: Sheet, selected: Bool, _ sst: SharedStrings, _ hasFormulas: inout Bool) -> String {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        x += "<worksheet xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\">"
        let used = s.usedSize()
        x += "<dimension ref=\"\(used.rows > 0 && used.cols > 0 ? "A1:" + cellName(CellAddr(used.rows - 1, used.cols - 1)) : "A1")\"/>"
        let sel = s.selection
        x += "<sheetViews><sheetView workbookViewId=\"0\"\(selected ? " tabSelected=\"1\"" : "")>"
        x += "<selection activeCell=\"\(cellName(sel.active))\" sqref=\"\(sel.ranges.map(rangeName).joined(separator: " "))\"/>"
        x += "</sheetView></sheetViews>"
        x += "<sheetFormatPr defaultRowHeight=\"\(pt(s.rows.defaultSize))\""
        if s.cols.defaultSize != 64 { x += " defaultColWidth=\"\(num(pxToWidth(s.cols.defaultSize)))\"" }
        x += "/>"

        // Columns: runs of neighbours with the same width, hiding and format share one <col>.
        let colKeys = Set(s.cols.sizes.keys).union(s.cols.hidden).union(s.colStyles.keys).sorted()
        if !colKeys.isEmpty {
            x += "<cols>"
            var i = 0
            while i < colKeys.count {
                let c = colKeys[i]
                let key = (s.cols.customSize(c), s.cols.isHidden(c), s.colStyles[c])
                var j = i
                while j + 1 < colKeys.count, colKeys[j + 1] == colKeys[j] + 1,
                      s.cols.customSize(colKeys[j + 1]) == key.0, s.cols.isHidden(colKeys[j + 1]) == key.1, s.colStyles[colKeys[j + 1]] == key.2 { j += 1 }
                x += "<col min=\"\(c + 1)\" max=\"\(colKeys[j] + 1)\" width=\"\(num(pxToWidth(key.0 ?? s.cols.defaultSize)))\""
                if key.0 != nil { x += " customWidth=\"1\"" }
                if key.1 { x += " hidden=\"1\"" }
                if let st = key.2 { x += " style=\"\(st)\"" }
                x += "/>"
                i = j + 1
            }
            x += "</cols>"
        }

        x += "<sheetData>"
        let rowKeys = Set(s.cells.keys).union(s.rows.sizes.keys).union(s.rows.hidden).union(s.rowStyles.keys).sorted()
        for r in rowKeys {
            x += "<row r=\"\(r + 1)\""
            if let h = s.rows.customSize(r) { x += " ht=\"\(pt(h))\"" + (s.autoHeights.contains(r) ? "" : " customHeight=\"1\"") }
            if s.rows.isHidden(r) { x += " hidden=\"1\"" }
            if let st = s.rowStyles[r] { x += " s=\"\(st)\" customFormat=\"1\"" }
            guard let rc = s.cells[r], !rc.isEmpty else { x += "/>"; continue }
            x += ">"
            for c in rc.keys.sorted() {
                let cell = rc[c]!
                x += "<c r=\"\(cellName(CellAddr(r, c)))\""
                if cell.style != 0 { x += " s=\"\(cell.style)\"" }
                if let f = cell.formula {
                    hasFormulas = true
                    let fx = "<f>\(esc(f))</f>"
                    switch cell.value {
                    case .text(let t)?: x += " t=\"str\">\(fx)<v>\(esc(t))</v></c>"
                    case .number(let v)?: x += ">\(fx)<v>\(num(v))</v></c>"
                    case .bool(let b)?: x += " t=\"b\">\(fx)<v>\(b ? 1 : 0)</v></c>"
                    case .error(let e)?: x += " t=\"e\">\(fx)<v>\(esc(e))</v></c>"
                    case nil: x += ">\(fx)</c>"
                    }
                    continue
                }
                switch cell.value {
                case .text(let t)?: x += " t=\"s\"><v>\(sst.id(t))</v></c>"
                case .number(let v)?: x += "><v>\(num(v))</v></c>"
                case .bool(let b)?: x += " t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                case .error(let e)?: x += " t=\"e\"><v>\(esc(e))</v></c>"
                case nil: x += "/>"
                }
            }
            x += "</row>"
        }
        x += "</sheetData>"
        x += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
        x += "</worksheet>"
        return x
    }
}
