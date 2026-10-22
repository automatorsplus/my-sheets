import Foundation

/// Shows numbers the way Excel's number formats do. Covers the common codes (decimals, thousands,
/// percentages, currency, dates and times, colours, up to four sections); not every corner of the syntax.
enum NumFmt {
    static let builtins: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00",
        5: "\"£\"#,##0;\\-\"£\"#,##0", 6: "\"£\"#,##0;[Red]\\-\"£\"#,##0",
        7: "\"£\"#,##0.00;\\-\"£\"#,##0.00", 8: "\"£\"#,##0.00;[Red]\\-\"£\"#,##0.00",
        9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??",
        14: "dd/mm/yyyy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy",
        18: "h:mm AM/PM", 19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss", 22: "dd/mm/yyyy h:mm",
        37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)",
        45: "mm:ss", 46: "[h]:mm:ss", 47: "mm:ss.0", 48: "##0.0E+0", 49: "@",
    ]

    struct NumSpec {
        var intZeros = 0
        var decZeros = 0
        var decHashes = 0
        var hasPoint = false
        var grouping = false
        var scale = 0
        var sciDigits: Int? = nil
        var sciPlus = false
    }

    enum Tok {
        case lit(String)
        case num(NumSpec)
        case date(String)
        case general
        case text
    }

    struct Section {
        var tokens: [Tok] = []
        var color: RGB? = nil
        var condition: (op: String, value: Double)? = nil
        var isDate = false
        var hasNumber = false
        var hasGeneral = false
        var percent = 0
    }

    private nonisolated(unsafe) static var cache: [String: [Section]] = [:]

    static func sections(_ code: String) -> [Section] {
        if let s = cache[code] { return s }
        var parts: [String] = []
        var cur = ""
        var inQuote = false
        var escape = false
        for ch in code {
            if escape { cur.append(ch); escape = false; continue }
            if ch == "\\" { cur.append(ch); escape = true; continue }
            if ch == "\"" { inQuote.toggle() }
            if ch == ";" && !inQuote { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        parts.append(cur)
        let s = parts.map(parseSection)
        cache[code] = s
        return s
    }

    static func isDate(_ code: String) -> Bool { sections(code).first?.isDate ?? false }

    static func hasTime(_ code: String) -> Bool {
        guard let s = sections(code).first else { return false }
        return s.tokens.contains { if case .date(let t) = $0 { return t.hasPrefix("h") || t.hasPrefix("n") || t.hasPrefix("s") || t.hasPrefix("[") } else { return false } }
    }

    static func hasDay(_ code: String) -> Bool {
        guard let s = sections(code).first else { return false }
        return s.tokens.contains { if case .date(let t) = $0 { return t.hasPrefix("d") || t.hasPrefix("m") || t.hasPrefix("y") } else { return false } }
    }

    private static let colorNames: [String: RGB] = [
        "black": RGB(0, 0, 0), "white": RGB(255, 255, 255), "red": RGB(255, 0, 0), "green": RGB(0, 255, 0),
        "blue": RGB(0, 0, 255), "yellow": RGB(255, 255, 0), "magenta": RGB(255, 0, 255), "cyan": RGB(0, 255, 255),
    ]

    private static func parseSection(_ s: String) -> Section {
        var sec = Section()
        let ch = Array(s)
        let n = ch.count
        var i = 0
        var lit = ""
        func flush() { if !lit.isEmpty { sec.tokens.append(.lit(lit)); lit = "" } }
        func isPlaceholder(_ k: Int) -> Bool { k < n && (ch[k] == "0" || ch[k] == "#" || ch[k] == "?") }
        func dateLetter(_ c: Character) -> Bool { "yYmMdDhHsS".contains(c) }

        while i < n {
            let c = ch[i]
            switch c {
            case "\"":
                i += 1
                while i < n && ch[i] != "\"" { lit.append(ch[i]); i += 1 }
                i += 1
            case "\\":
                if i + 1 < n { lit.append(ch[i + 1]) }
                i += 2
            case "_":
                lit.append(" ")
                i += 2
            case "*":
                i += 2
            case "[":
                var j = i + 1
                while j < n && ch[j] != "]" { j += 1 }
                let content = String(ch[min(i + 1, n)..<min(j, n)])
                let low = content.lowercased()
                i = j + 1
                if content.hasPrefix("$") {
                    let body = content.dropFirst()
                    lit += body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                } else if let f = content.first, "<>=".contains(f) {
                    var op = ""
                    var rest = Substring(content)
                    while let f = rest.first, "<>=".contains(f) { op.append(f); rest = rest.dropFirst() }
                    if let v = Double(rest) { sec.condition = (op, v) }
                } else if let col = colorNames[low] {
                    sec.color = col
                } else if ["h", "hh", "m", "mm", "s", "ss"].contains(low) {
                    flush()
                    sec.tokens.append(.date("[" + low.prefix(1) + "]"))
                    sec.isDate = true
                }
            case "%":
                lit.append("%")
                sec.percent += 1
                i += 1
            case "@":
                flush()
                sec.tokens.append(.text)
                i += 1
            case "0", "#", "?", ".", ",":
                if sec.isDate {
                    // Fractions of a second ("ss.0") aren't shown; other punctuation is literal.
                    if c == "." && isPlaceholder(i + 1) { i += 1; while isPlaceholder(i) { i += 1 }; continue }
                    lit.append(c); i += 1; continue
                }
                if (c == "." || c == ",") && !isPlaceholder(i + 1) && !sec.hasNumber {
                    lit.append(c); i += 1; continue
                }
                if sec.hasNumber {
                    if c == "," { i += 1; continue }
                    lit.append(c); i += 1; continue
                }
                flush()
                var spec = NumSpec()
                var afterPoint = false
                runLoop: while i < n {
                    let d = ch[i]
                    switch d {
                    case "0": if afterPoint { spec.decZeros += 1 } else { spec.intZeros += 1 }
                    case "#", "?": if afterPoint { spec.decHashes += 1 }
                    case ".":
                        if afterPoint { break runLoop }
                        afterPoint = true
                        spec.hasPoint = true
                    case ",":
                        if isPlaceholder(i + 1) && !afterPoint { spec.grouping = true } else { spec.scale += 1 }
                    case "E", "e":
                        guard i + 1 < n, ch[i + 1] == "+" || ch[i + 1] == "-" else { break runLoop }
                        spec.sciPlus = ch[i + 1] == "+"
                        i += 2
                        var digits = 0
                        while i < n && ch[i] == "0" { digits += 1; i += 1 }
                        spec.sciDigits = max(1, digits)
                        break runLoop
                    default: break runLoop
                    }
                    i += 1
                }
                sec.tokens.append(.num(spec))
                sec.hasNumber = true
            case "A", "a":
                let rest = String(ch[i..<n]).uppercased()
                if rest.hasPrefix("AM/PM") { flush(); sec.tokens.append(.date("ampm")); i += 5 }
                else if rest.hasPrefix("A/P") { flush(); sec.tokens.append(.date("ap")); i += 3 }
                else { lit.append(c); i += 1 }
            case "G", "g":
                if String(ch[i..<n]).lowercased().hasPrefix("general") {
                    flush(); sec.tokens.append(.general); sec.hasGeneral = true; i += 7
                } else { lit.append(c); i += 1 }
            default:
                if dateLetter(c) {
                    flush()
                    let low = Character(c.lowercased())
                    var run = ""
                    while i < n && Character(ch[i].lowercased()) == low { run.append(low); i += 1 }
                    sec.tokens.append(.date(run))
                    sec.isDate = true
                } else {
                    lit.append(c); i += 1
                }
            }
        }
        flush()

        // "m" next to hours or seconds means minutes; write those as "n".
        let dateIdx = sec.tokens.indices.filter { if case .date = sec.tokens[$0] { return true } else { return false } }
        for (k, idx) in dateIdx.enumerated() {
            guard case .date(let t) = sec.tokens[idx], t == "m" || t == "mm" else { continue }
            var prev = "", next = ""
            if k > 0, case .date(let p) = sec.tokens[dateIdx[k - 1]] { prev = p }
            if k + 1 < dateIdx.count, case .date(let q) = sec.tokens[dateIdx[k + 1]] { next = q }
            if prev.hasPrefix("h") || prev == "[h]" || next.hasPrefix("s") {
                sec.tokens[idx] = .date(t == "m" ? "n" : "nn")
            }
        }
        return sec
    }

    static func format(_ v: Double, _ code: String, date1904: Bool) -> (text: String, color: RGB?) {
        let all = sections(code)
        let numeric = Array(all.prefix(3))
        guard !numeric.isEmpty else { return (general(v), nil) }
        var sec = numeric[0]
        var x = v
        var autoMinus = false
        if numeric.contains(where: { $0.condition != nil }) {
            func passes(_ s: Section) -> Bool {
                guard let c = s.condition else { return false }
                switch c.op {
                case "<": return v < c.value
                case "<=": return v <= c.value
                case ">": return v > c.value
                case ">=": return v >= c.value
                case "=": return v == c.value
                case "<>": return v != c.value
                default: return false
                }
            }
            if passes(numeric[0]) { sec = numeric[0] }
            else if numeric.count > 1 && passes(numeric[1]) { sec = numeric[1] }
            else { sec = numeric.count > 2 ? numeric[2] : numeric[numeric.count - 1] }
            x = abs(v)
            autoMinus = v < 0 && sec.condition == nil
        } else if numeric.count >= 2 && v < 0 {
            sec = numeric[1]; x = -v
        } else if numeric.count >= 3 && v == 0 {
            sec = numeric[2]
        } else {
            autoMinus = v < 0
            x = abs(v)
        }
        if sec.isDate { return (formatDate(v, sec, date1904: date1904), sec.color) }

        var out = ""
        var shownNumber = false
        for tok in sec.tokens {
            switch tok {
            case .lit(let s): out += s
            case .general: out += general(x); shownNumber = true
            case .num(let spec): out += formatNumber(x * pow(100, Double(sec.percent)), spec); shownNumber = true
            case .date, .text: break
            }
        }
        if autoMinus && shownNumber && out.contains(where: { $0.isNumber && $0 != "0" }) { out = "-" + out }
        return (out, sec.color)
    }

    private static func formatNumber(_ value: Double, _ spec: NumSpec) -> String {
        let x = value / pow(1000, Double(spec.scale))
        let decs = spec.decZeros + spec.decHashes
        if let digits = spec.sciDigits {
            var e = x == 0 ? 0 : Int(floor(log10(x)))
            var m = x == 0 ? 0 : x / pow(10, Double(e))
            if Double(String(format: "%.\(decs)f", m)) ?? 0 >= 10 { m /= 10; e += 1 }
            let ms = String(format: "%.\(decs)f", m)
            let es = String(format: "%0\(digits)d", abs(e))
            return ms + "E" + (e < 0 ? "-" : (spec.sciPlus ? "+" : "")) + es
        }
        let s = String(format: "%.\(decs)f", x)
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var intPart = String(parts[0])
        var frac = parts.count > 1 ? String(parts[1]) : ""
        while frac.count > spec.decZeros && frac.hasSuffix("0") { frac.removeLast() }
        if intPart == "0" && spec.intZeros == 0 { intPart = "" }
        while intPart.count < spec.intZeros { intPart = "0" + intPart }
        if spec.grouping && intPart.count > 3 {
            var g = ""
            for (k, d) in intPart.reversed().enumerated() {
                if k > 0 && k % 3 == 0 { g.append(",") }
                g.append(d)
            }
            intPart = String(g.reversed())
        }
        return spec.hasPoint ? intPart + "." + frac : intPart
    }

    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                                     "August", "September", "October", "November", "December"]
    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Year, month, day and weekday (0 = Sunday) for a serial day number.
    static func dateParts(_ serialDay: Int, date1904: Bool) -> (y: Int, m: Int, d: Int, wd: Int) {
        let z: Int
        if date1904 {
            z = serialDay - 24107
        } else {
            // Excel counts 29 February 1900, which never existed (a Lotus 1-2-3 bug it kept).
            if serialDay == 0 { return (1900, 1, 0, 6) }
            if serialDay == 60 { return (1900, 2, 29, 3) }
            z = serialDay < 60 ? serialDay - 25568 : serialDay - 25569
        }
        let (y, m, d) = civilFromDays(z)
        let wd = ((z % 7) + 7 + 4) % 7
        return (y, m, d, wd)
    }

    private static func formatDate(_ v: Double, _ sec: Section, date1904: Bool) -> String {
        guard v >= 0, v < 2_958_466 else { return "########" }
        var day = Int(floor(v))
        var secs = Int(((v - floor(v)) * 86400).rounded())
        if secs >= 86400 { secs -= 86400; day += 1 }
        let p = dateParts(day, date1904: date1904)
        let h = secs / 3600, mi = (secs % 3600) / 60, s = secs % 60
        let twelve = sec.tokens.contains { if case .date(let t) = $0 { return t == "ampm" || t == "ap" } else { return false } }
        func two(_ n: Int) -> String { String(format: "%02d", n) }
        var out = ""
        for tok in sec.tokens {
            switch tok {
            case .lit(let l): out += l
            case .date(let t):
                switch t {
                case "y", "yy": out += two(p.y % 100)
                case let y where y.hasPrefix("y"): out += String(p.y)
                case "m": out += String(p.m)
                case "mm": out += two(p.m)
                case "mmm": out += String(monthNames[p.m - 1].prefix(3))
                case "mmmmm": out += String(monthNames[p.m - 1].prefix(1))
                case let m where m.hasPrefix("m"): out += monthNames[p.m - 1]
                case "d": out += String(p.d)
                case "dd": out += two(p.d)
                case "ddd": out += String(dayNames[p.wd].prefix(3))
                case let d where d.hasPrefix("d"): out += dayNames[p.wd]
                case "h", "hh":
                    let hour = twelve ? (h % 12 == 0 ? 12 : h % 12) : h
                    out += t == "h" ? String(hour) : two(hour)
                case "n": out += String(mi)
                case "nn": out += two(mi)
                case "s": out += String(s)
                case "ss": out += two(s)
                case "ampm": out += h < 12 ? "AM" : "PM"
                case "ap": out += h < 12 ? "A" : "P"
                case "[h]": out += String(day * 24 + h)
                case "[m]": out += String((day * 24 + h) * 60 + mi)
                case "[s]": out += String(((day * 24 + h) * 60 + mi) * 60 + s)
                default: break
                }
            default: break
            }
        }
        return out
    }

    /// Excel's General format: up to 11 characters, switching to scientific for very large or small numbers.
    static func general(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "#NUM!" }
        if v == 0 { return "0" }
        let a = abs(v)
        if a >= 1e11 || a < 1e-9 {
            let s = String(format: "%.5E", v)
            guard let e = s.firstIndex(of: "E") else { return s }
            var m = String(s[..<e])
            while m.hasSuffix("0") { m.removeLast() }
            if m.hasSuffix(".") { m.removeLast() }
            return m + s[e...]
        }
        let intDigits = max(1, Int(floor(log10(a))) + 1)
        let decs = max(0, 10 - intDigits - (v < 0 ? 1 : 0))
        var s = String(format: "%.\(decs)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// What the formula bar shows for a number: up to 15 significant digits.
    static func editNumber(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(format: "%.0f", v) }
        return String(format: "%.15g", v).uppercased()
    }

    // Howard Hinnant's civil-calendar conversions, in days since 1970-01-01.
    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Excel's serial day number for a date (1900 date system).
    static func serial(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let z = daysFromCivil(y, m, d)
        let s = z + 25569
        return s < 61 ? s - 1 : s
    }
}

// MARK: - Typing

enum Entry: Equatable {
    case clear
    case value(CellValue, format: String?)
    case formula(String)
}

private func whole(_ s: String, _ pattern: String) -> Bool {
    s.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil
}

let dayFirstDates = !Locale.current.identifier.hasSuffix("_US")

/// Works out what typed text means, as Excel does: numbers, percentages, money, dates, times,
/// TRUE/FALSE, formulas (kept, not calculated), and a leading ' to force text.
func parseEntry(_ raw: String, dayFirst: Bool = dayFirstDates) -> Entry {
    if raw.isEmpty { return .clear }
    if raw.hasPrefix("'") { return .value(.text(String(raw.dropFirst())), format: nil) }
    if raw.hasPrefix("="), raw.count > 1 { return .formula(String(raw.dropFirst())) }
    let s = raw.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return .value(.text(raw), format: nil) }
    let up = s.uppercased()
    if up == "TRUE" { return .value(.bool(true), format: nil) }
    if up == "FALSE" { return .value(.bool(false), format: nil) }

    let plain = "[+-]?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?"
    let grouped = "[+-]?\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?"
    func number(_ t: String) -> Double? {
        if whole(t, plain) { return Double(t) }
        if whole(t, grouped) { return Double(t.replacingOccurrences(of: ",", with: "")) }
        return nil
    }
    func hasDecimals(_ t: String) -> Bool { t.contains(".") }

    if s.hasSuffix("%"), let v = number(String(s.dropLast()).trimmingCharacters(in: .whitespaces)) {
        return .value(.number(v / 100), format: hasDecimals(s) ? "0.00%" : "0%")
    }
    for sym in ["£", "$", "€"] {
        var t = s
        var negative = false
        if t.hasPrefix("-") { negative = true; t.removeFirst() }
        guard t.hasPrefix(sym) else { continue }
        t.removeFirst()
        if let v = number(t), !t.hasPrefix("-"), !t.hasPrefix("+") {
            let code = "\"\(sym)\"#,##0" + (hasDecimals(t) ? ".00" : "")
            return .value(.number(negative ? -v : v), format: code)
        }
    }
    if whole(s, grouped), let v = number(s) {
        return .value(.number(v), format: hasDecimals(s) ? "#,##0.00" : "#,##0")
    }
    if whole(s, plain), let v = Double(s) { return .value(.number(v), format: nil) }

    // Dates: 3/4/2025 (day first outside the US) and 2025-04-03.
    let parts = s.split(whereSeparator: { $0 == "/" || $0 == "-" }).map(String.init)
    if parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
        var y = 0, m = 0, d = 0
        var code = "dd/mm/yyyy"
        if parts[0].count == 4 {
            y = Int(parts[0])!; m = Int(parts[1])!; d = Int(parts[2])!
            code = "yyyy-mm-dd"
        } else if parts[2].count == 4 || parts[2].count == 2 {
            let a = Int(parts[0])!, b = Int(parts[1])!
            (d, m) = dayFirst ? (a, b) : (b, a)
            if !dayFirst { code = "mm/dd/yyyy" }
            y = Int(parts[2])!
            if parts[2].count == 2 { y += y < 30 ? 2000 : 1900 }
        }
        if y >= 1900, y <= 9999, m >= 1, m <= 12, d >= 1, d <= 31 {
            let back = NumFmt.civilFromDays(NumFmt.daysFromCivil(y, m, d))
            if back.1 == m && back.2 == d {
                return .value(.number(Double(NumFmt.serial(y, m, d))), format: code)
            }
        }
    }
    // Times: 9:30 and 14:05:20.
    let tp = s.split(separator: ":").map(String.init)
    if (tp.count == 2 || tp.count == 3), tp.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
        let h = Int(tp[0])!, mi = Int(tp[1])!, sec = tp.count == 3 ? Int(tp[2])! : 0
        if h < 24, mi < 60, sec < 60, tp[1].count == 2 {
            return .value(.number(Double(h * 3600 + mi * 60 + sec) / 86400), format: tp.count == 3 ? "h:mm:ss" : "h:mm")
        }
    }
    return .value(.text(raw), format: nil)
}

/// The text the formula bar and the in-cell editor start with.
func editText(_ c: Cell?, format: String, date1904: Bool) -> String {
    guard let c else { return "" }
    if let f = c.formula { return "=" + f }
    switch c.value {
    case nil: return ""
    case .text(let s): return s
    case .bool(let b): return b ? "TRUE" : "FALSE"
    case .error(let e): return e
    case .number(let v):
        if NumFmt.isDate(format) {
            let datePart = dayFirstDates ? "dd/mm/yyyy" : "mm/dd/yyyy"
            let hasDay = NumFmt.hasDay(format), hasTime = NumFmt.hasTime(format) || v != v.rounded()
            let code = hasDay && hasTime ? datePart + " hh:mm:ss" : (hasDay ? datePart : "h:mm:ss")
            return NumFmt.format(v, code, date1904: date1904).text
        }
        if format.contains("%") && !format.contains("\"%") { return NumFmt.editNumber(v * 100) + "%" }
        return NumFmt.editNumber(v)
    }
}
