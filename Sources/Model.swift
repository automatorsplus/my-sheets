import Foundation

// Excel's sheet size.
let maxRows = 1_048_576
let maxCols = 16_384

struct CellAddr: Hashable {
    var row: Int
    var col: Int
    init(_ row: Int, _ col: Int) { self.row = row; self.col = col }
}

/// An inclusive block of cells. Whole rows and whole columns are ranges that run to the sheet's edge.
struct CellRange: Hashable {
    var r0: Int, c0: Int, r1: Int, c1: Int

    init(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int) {
        self.r0 = min(r0, r1); self.r1 = max(r0, r1)
        self.c0 = min(c0, c1); self.c1 = max(c0, c1)
    }
    init(_ a: CellAddr, _ b: CellAddr) { self.init(a.row, a.col, b.row, b.col) }
    init(_ a: CellAddr) { self.init(a, a) }

    static func rows(_ a: Int, _ b: Int) -> CellRange { CellRange(a, 0, b, maxCols - 1) }
    static func cols(_ a: Int, _ b: Int) -> CellRange { CellRange(0, a, maxRows - 1, b) }
    static let all = CellRange(0, 0, maxRows - 1, maxCols - 1)

    var rowCount: Int { r1 - r0 + 1 }
    var colCount: Int { c1 - c0 + 1 }
    var isSingle: Bool { r0 == r1 && c0 == c1 }
    var isWholeRows: Bool { c0 == 0 && c1 == maxCols - 1 }
    var isWholeCols: Bool { r0 == 0 && r1 == maxRows - 1 }
    var topLeft: CellAddr { CellAddr(r0, c0) }

    func contains(_ a: CellAddr) -> Bool { a.row >= r0 && a.row <= r1 && a.col >= c0 && a.col <= c1 }
    func contains(_ o: CellRange) -> Bool { o.r0 >= r0 && o.r1 <= r1 && o.c0 >= c0 && o.c1 <= c1 }
    func intersects(_ o: CellRange) -> Bool { !(o.r1 < r0 || o.r0 > r1 || o.c1 < c0 || o.c0 > c1) }
    func offsetBy(_ dr: Int, _ dc: Int) -> CellRange { CellRange(r0 + dr, c0 + dc, r1 + dr, c1 + dc) }
}

struct Selection: Equatable {
    enum Kind { case cells, rows, cols }

    var ranges: [CellRange]
    /// The cell that typing goes into.
    var active: CellAddr
    /// The fixed corner of the last range, and the corner that Shift-click and Shift-arrow move.
    var anchor: CellAddr
    var corner: CellAddr
    var kind: Kind = .cells

    init(_ a: CellAddr) { ranges = [CellRange(a)]; active = a; anchor = a; corner = a }

    var last: CellRange { ranges[ranges.count - 1] }
    var isSingleCell: Bool { ranges.count == 1 && last.isSingle }

    static func span(_ a: CellAddr, _ b: CellAddr, _ kind: Kind) -> CellRange {
        switch kind {
        case .cells: return CellRange(a, b)
        case .rows: return .rows(a.row, b.row)
        case .cols: return .cols(a.col, b.col)
        }
    }

    static func rows(_ a: Int, _ b: Int, activeCol: Int) -> Selection {
        var s = Selection(CellAddr(a, activeCol))
        s.kind = .rows
        s.extend(to: CellAddr(b, activeCol))
        return s
    }

    static func cols(_ a: Int, _ b: Int, activeRow: Int) -> Selection {
        var s = Selection(CellAddr(activeRow, a))
        s.kind = .cols
        s.extend(to: CellAddr(activeRow, b))
        return s
    }

    static func all(active: CellAddr) -> Selection {
        var s = Selection(active)
        s.ranges = [.all]
        s.anchor = CellAddr(0, 0)
        s.corner = CellAddr(maxRows - 1, maxCols - 1)
        return s
    }

    /// Moves the far corner of the last range; the active cell stays where it is, as in Excel.
    mutating func extend(to c: CellAddr) {
        corner = c
        ranges[ranges.count - 1] = Selection.span(anchor, c, kind)
    }

    /// Cmd-click: starts another range and makes its cell active.
    mutating func add(_ a: CellAddr, kind: Kind) {
        self.kind = kind
        ranges.append(Selection.span(a, a, kind))
        active = a; anchor = a; corner = a
    }
}

// MARK: - Addresses

func columnName(_ c: Int) -> String {
    var n = c + 1
    var s = ""
    while n > 0 {
        let r = (n - 1) % 26
        s = String(UnicodeScalar(UInt8(65 + r))) + s
        n = (n - 1) / 26
    }
    return s
}

func columnNumber<S: StringProtocol>(_ s: S) -> Int? {
    var n = 0
    for ch in s.uppercased().unicodeScalars {
        guard ch.value >= 65 && ch.value <= 90 else { return nil }
        n = n * 26 + Int(ch.value - 64)
    }
    return n > 0 && n <= maxCols ? n - 1 : nil
}

func cellName(_ a: CellAddr) -> String { columnName(a.col) + String(a.row + 1) }

/// "B7" or "$B$7".
func parseCell<S: StringProtocol>(_ text: S) -> CellAddr? {
    let s = text.replacingOccurrences(of: "$", with: "")
    let letters = s.prefix { $0.isLetter }
    let digits = s.dropFirst(letters.count)
    guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
          let c = columnNumber(letters), let r = Int(digits), r >= 1, r <= maxRows else { return nil }
    return CellAddr(r - 1, c)
}

/// "A1", "A1:C5", "B:D", "3:7", or a single column "C".
func parseRange(_ text: String) -> CellRange? {
    let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
    let parts = t.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 1 {
        if let a = parseCell(parts[0]) { return CellRange(a) }
        if let c = columnNumber(parts[0]) { return .cols(c, c) }
        if let r = Int(parts[0]), r >= 1, r <= maxRows { return .rows(r - 1, r - 1) }
        return nil
    }
    guard parts.count == 2 else { return nil }
    if let a = parseCell(parts[0]), let b = parseCell(parts[1]) { return CellRange(a, b) }
    if let a = columnNumber(parts[0]), let b = columnNumber(parts[1]) { return .cols(a, b) }
    if let a = Int(parts[0]), let b = Int(parts[1]), a >= 1, b >= 1, a <= maxRows, b <= maxRows { return .rows(a - 1, b - 1) }
    return nil
}

func rangeName(_ r: CellRange) -> String {
    if r.isWholeRows && r.isWholeCols { return "A1:\(cellName(CellAddr(maxRows - 1, maxCols - 1)))" }
    if r.isWholeRows { return "\(r.r0 + 1):\(r.r1 + 1)" }
    if r.isWholeCols { return "\(columnName(r.c0)):\(columnName(r.c1))" }
    if r.isSingle { return cellName(r.topLeft) }
    return "\(cellName(r.topLeft)):\(cellName(CellAddr(r.r1, r.c1)))"
}

// MARK: - Cells

enum CellValue: Equatable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case error(String)
}

struct Cell: Equatable {
    var value: CellValue? = nil
    /// Kept as written in the file (without "="); this app never calculates it.
    var formula: String? = nil
    /// Index into the workbook's cell formats (Excel's cellXfs).
    var style: Int = 0

    var isBlank: Bool { value == nil && formula == nil }
}

// MARK: - Row and column sizes

/// The sizes of every row (or column), in points at 100% zoom, with fast position lookups.
/// Only sizes that differ from the default are stored.
struct Axis {
    let count: Int
    private(set) var defaultSize: Double
    private(set) var sizes: [Int: Double]
    private(set) var hidden: Set<Int>

    // Sorted indices whose size differs from the default, with their start positions.
    private var keys: [Int] = []
    private var starts: [Double] = []
    private var effective: [Double] = []

    init(count: Int, defaultSize: Double, sizes: [Int: Double] = [:], hidden: Set<Int> = []) {
        self.count = count
        self.defaultSize = defaultSize
        self.sizes = sizes
        self.hidden = hidden
        rebuild()
    }

    func size(_ i: Int) -> Double { hidden.contains(i) ? 0 : (sizes[i] ?? defaultSize) }
    func customSize(_ i: Int) -> Double? { sizes[i] }
    func isHidden(_ i: Int) -> Bool { hidden.contains(i) }

    mutating func setDefault(_ s: Double) { defaultSize = s; rebuild() }

    mutating func set(_ indices: [Int], size: Double?) {
        for i in indices { sizes[i] = size }
        rebuild()
    }

    mutating func set(_ indices: [Int], hidden h: Bool) {
        for i in indices { if h { hidden.insert(i) } else { hidden.remove(i) } }
        rebuild()
    }

    /// Moves every stored size to f(index); nil drops it.
    mutating func remap(_ f: (Int) -> Int?) {
        var s = [Int: Double]()
        for (k, v) in sizes { if let k2 = f(k), k2 >= 0, k2 < count { s[k2] = v } }
        var h = Set<Int>()
        for k in hidden { if let k2 = f(k), k2 >= 0, k2 < count { h.insert(k2) } }
        sizes = s
        hidden = h
        rebuild()
    }

    mutating func copyEntry(from a: Int, to b: Int) {
        sizes[b] = sizes[a]
        if hidden.contains(a) { hidden.insert(b) } else { hidden.remove(b) }
        rebuild()
    }

    private mutating func rebuild() {
        let all = Set(sizes.keys).union(hidden)
        keys = all.sorted().filter { size($0) != defaultSize }
        starts = []; effective = []
        starts.reserveCapacity(keys.count); effective.reserveCapacity(keys.count)
        var delta = 0.0
        for k in keys {
            let e = size(k)
            starts.append(Double(k) * defaultSize + delta)
            effective.append(e)
            delta += e - defaultSize
        }
    }

    /// Where index i starts.
    func offset(_ i: Int) -> Double {
        var lo = 0, hi = keys.count
        while lo < hi { let m = (lo + hi) / 2; if keys[m] < i { lo = m + 1 } else { hi = m } }
        if lo == 0 { return Double(i) * defaultSize }
        let j = lo - 1
        return starts[j] + effective[j] + Double(i - keys[j] - 1) * defaultSize
    }

    /// The index at position p (hidden ones are skipped).
    func index(at p: Double) -> Int {
        if p <= 0 { return firstVisible(from: 0) }
        var lo = 0, hi = keys.count
        while lo < hi { let m = (lo + hi) / 2; if starts[m] <= p { lo = m + 1 } else { hi = m } }
        let j = lo - 1
        let i: Int
        if j < 0 { i = Int(p / defaultSize) }
        else if p < starts[j] + effective[j] { i = keys[j] }
        else { i = keys[j] + 1 + Int((p - starts[j] - effective[j]) / defaultSize) }
        return min(max(i, 0), count - 1)
    }

    private func firstVisible(from i: Int) -> Int {
        var k = i
        while k < count - 1 && hidden.contains(k) { k += 1 }
        return k
    }
}

// MARK: - Sheets

struct Sheet {
    var name: String
    var cells: [Int: [Int: Cell]] = [:]
    var rows = Axis(count: maxRows, defaultSize: 20)
    var cols = Axis(count: maxCols, defaultSize: 64)
    /// Formats set on whole rows and columns (Excel's row "s" and col "style").
    var rowStyles: [Int: Int] = [:]
    var colStyles: [Int: Int] = [:]
    /// Rows whose height was set to fit their text (bigger fonts, extra lines) rather than by hand.
    /// They shrink back when the text does, and files mark them without customHeight, as Excel does.
    var autoHeights = Set<Int>()
    var selection = Selection(CellAddr(0, 0))
    /// "hidden" or "veryHidden" from the file, written back unchanged.
    var state: String? = nil

    init(name: String) { self.name = name }

    func cell(_ a: CellAddr) -> Cell? { cells[a.row]?[a.col] }

    func hasValue(_ a: CellAddr) -> Bool {
        guard let c = cells[a.row]?[a.col] else { return false }
        return !c.isBlank
    }

    func inheritedStyle(_ a: CellAddr) -> Int { rowStyles[a.row] ?? colStyles[a.col] ?? 0 }

    /// The format a cell shows: its own, else its row's, else its column's.
    func styleAt(_ a: CellAddr) -> Int { cells[a.row]?[a.col]?.style ?? inheritedStyle(a) }

    mutating func setCell(_ a: CellAddr, _ c: Cell?) {
        if let c, !(c.isBlank && c.style == inheritedStyle(a)) {
            cells[a.row, default: [:]][a.col] = c
        } else if cells[a.row] != nil {
            cells[a.row]![a.col] = nil
            if cells[a.row]!.isEmpty { cells[a.row] = nil }
        }
    }

    mutating func setValue(_ a: CellAddr, _ value: CellValue?, formula: String? = nil, style: Int? = nil) {
        var c = cell(a) ?? Cell(style: styleAt(a))
        c.value = value
        c.formula = formula
        if let style { c.style = style }
        setCell(a, c)
    }

    /// Visits only the cells that are stored inside r.
    func forEachCell(in r: CellRange, _ body: (CellAddr, Cell) -> Void) {
        func visit(_ row: Int, _ rc: [Int: Cell]) {
            if rc.count <= r.colCount {
                for (col, c) in rc where col >= r.c0 && col <= r.c1 { body(CellAddr(row, col), c) }
            } else {
                for col in r.c0...r.c1 { if let c = rc[col] { body(CellAddr(row, col), c) } }
            }
        }
        if r.rowCount <= cells.count {
            for row in r.r0...r.r1 { if let rc = cells[row] { visit(row, rc) } }
        } else {
            for (row, rc) in cells where row >= r.r0 && row <= r.r1 { visit(row, rc) }
        }
    }

    func hasValues(in r: CellRange, excluding ex: CellRange? = nil) -> Bool {
        var found = false
        forEachCell(in: r) { a, c in if !c.isBlank && !(ex?.contains(a) ?? false) { found = true } }
        return found
    }

    mutating func removeCells(in r: CellRange) {
        var addrs: [CellAddr] = []
        forEachCell(in: r) { a, _ in addrs.append(a) }
        for a in addrs {
            cells[a.row]?[a.col] = nil
            if cells[a.row]?.isEmpty == true { cells[a.row] = nil }
        }
    }

    /// Delete key: empties the cells but keeps their formatting.
    mutating func clearContents(in r: CellRange) {
        var addrs: [CellAddr] = []
        forEachCell(in: r) { a, c in if !c.isBlank { addrs.append(a) } }
        for a in addrs { var c = cell(a)!; c.value = nil; c.formula = nil; setCell(a, c) }
    }

    /// Rows and columns that hold anything, as counts from the top-left.
    func usedSize() -> (rows: Int, cols: Int) {
        var mr = -1, mc = -1
        for (r, rc) in cells where !rc.isEmpty {
            mr = max(mr, r)
            for c in rc.keys where c > mc { mc = c }
        }
        return (mr + 1, mc + 1)
    }

    // MARK: Inserting, deleting and moving rows and columns

    static func insertMap(at i: Int, count n: Int) -> (Int) -> Int? { { $0 >= i ? $0 + n : $0 } }
    static func deleteMap(at i: Int, count n: Int) -> (Int) -> Int? { { $0 < i ? $0 : ($0 < i + n ? nil : $0 - n) } }

    /// Takes n rows starting at a out, and puts them back in front of t (an index in the old numbering).
    static func moveMap(from a: Int, count n: Int, to t: Int) -> (Int) -> Int? {
        if t > a + n {
            return { x in
                if x >= a && x < a + n { return x + (t - n - a) }
                if x >= a + n && x < t { return x - n }
                return x
            }
        }
        return { x in
            if x >= a && x < a + n { return t + (x - a) }
            if x >= t && x < a { return x + n }
            return x
        }
    }

    private static func remap(_ d: [Int: Int], _ f: (Int) -> Int?, limit: Int) -> [Int: Int] {
        var out = [Int: Int]()
        for (k, v) in d { if let k2 = f(k), k2 >= 0, k2 < limit { out[k2] = v } }
        return out
    }

    mutating func remapRows(_ f: (Int) -> Int?) {
        var n = [Int: [Int: Cell]](minimumCapacity: cells.count)
        for (r, rc) in cells { if let r2 = f(r), r2 >= 0, r2 < maxRows { n[r2] = rc } }
        cells = n
        rows.remap(f)
        rowStyles = Sheet.remap(rowStyles, f, limit: maxRows)
        autoHeights = Set(autoHeights.compactMap(f).filter { $0 >= 0 && $0 < maxRows })
    }

    mutating func remapCols(_ f: (Int) -> Int?) {
        var n = [Int: [Int: Cell]](minimumCapacity: cells.count)
        for (r, rc) in cells {
            var m = [Int: Cell](minimumCapacity: rc.count)
            for (c, cell) in rc { if let c2 = f(c), c2 >= 0, c2 < maxCols { m[c2] = cell } }
            if !m.isEmpty { n[r] = m }
        }
        cells = n
        cols.remap(f)
        colStyles = Sheet.remap(colStyles, f, limit: maxCols)
    }

    /// Inserts copies of n rows starting at a, in front of row t.
    mutating func insertCopies(ofRows a: Int, count n: Int, at t: Int) {
        remapRows(Sheet.insertMap(at: t, count: n))
        let src = a >= t ? a + n : a
        for i in 0..<n {
            cells[t + i] = cells[src + i]
            rows.copyEntry(from: src + i, to: t + i)
            rowStyles[t + i] = rowStyles[src + i]
            if autoHeights.contains(src + i) { autoHeights.insert(t + i) }
        }
    }

    mutating func insertCopies(ofCols a: Int, count n: Int, at t: Int) {
        remapCols(Sheet.insertMap(at: t, count: n))
        let src = a >= t ? a + n : a
        for (r, rc) in cells {
            var m = rc
            for i in 0..<n { m[t + i] = rc[src + i] }
            cells[r] = m
        }
        for i in 0..<n {
            cols.copyEntry(from: src + i, to: t + i)
            colStyles[t + i] = colStyles[src + i]
        }
    }

    /// Moves (or copies) a block of cells by an offset, replacing whatever was there.
    mutating func moveRange(_ src: CellRange, by dr: Int, _ dc: Int, copy: Bool) {
        var items: [(CellAddr, Cell)] = []
        forEachCell(in: src) { items.append(($0, $1)) }
        var rowItems: [(Int, Int)] = []
        var colItems: [(Int, Int)] = []
        if src.isWholeRows { for (r, s) in rowStyles where r >= src.r0 && r <= src.r1 { rowItems.append((r, s)) } }
        if src.isWholeCols { for (c, s) in colStyles where c >= src.c0 && c <= src.c1 { colItems.append((c, s)) } }
        let dst = src.offsetBy(dr, dc)
        if !copy {
            removeCells(in: src)
            for (r, _) in rowItems { rowStyles[r] = nil }
            for (c, _) in colItems { colStyles[c] = nil }
        }
        removeCells(in: dst)
        if dst.isWholeRows { for r in dst.r0...dst.r1 { rowStyles[r] = nil } }
        if dst.isWholeCols { for c in dst.c0...dst.c1 { colStyles[c] = nil } }
        for (r, s) in rowItems { rowStyles[r + dr] = s }
        for (c, s) in colItems { colStyles[c + dc] = s }
        for (a, c) in items { cells[a.row + dr, default: [:]][a.col + dc] = c }
    }

    /// The next row or column in a direction, skipping hidden ones, or nil at the sheet's edge.
    func step(_ a: CellAddr, _ dr: Int, _ dc: Int) -> CellAddr? {
        var r = a.row, c = a.col
        repeat {
            r += dr; c += dc
            if r < 0 || r >= maxRows || c < 0 || c >= maxCols { return nil }
        } while (dr != 0 && rows.isHidden(r)) || (dc != 0 && cols.isHidden(c))
        return CellAddr(r, c)
    }

    /// Cmd-arrow: to the edge of the current block of data, or to the next block, or to the sheet's edge.
    func jump(from a: CellAddr, _ dr: Int, _ dc: Int) -> CellAddr {
        guard let next = step(a, dr, dc) else { return a }
        if hasValue(a) && hasValue(next) {
            var cur = next
            while let n = step(cur, dr, dc), hasValue(n) { cur = n }
            return cur
        }
        // Find the nearest filled cell beyond `a` along the line.
        var best: Int? = nil
        if dc == 0 {
            for (r, rc) in cells where rc[a.col].map({ !$0.isBlank }) ?? false {
                if dr > 0, r > a.row, best.map({ r < $0 }) ?? true { best = r }
                if dr < 0, r < a.row, best.map({ r > $0 }) ?? true { best = r }
            }
            return CellAddr(best ?? (dr > 0 ? maxRows - 1 : 0), a.col)
        }
        for (c, cell) in cells[a.row] ?? [:] where !cell.isBlank {
            if dc > 0, c > a.col, best.map({ c < $0 }) ?? true { best = c }
            if dc < 0, c < a.col, best.map({ c > $0 }) ?? true { best = c }
        }
        return CellAddr(a.row, best ?? (dc > 0 ? maxCols - 1 : 0))
    }
}

struct Workbook {
    var sheets: [Sheet]
    var active = 0

    static func blank() -> Workbook { Workbook(sheets: [Sheet(name: "Sheet1")]) }

    var sheet: Sheet {
        get { sheets[active] }
        set { sheets[active] = newValue }
    }
}
