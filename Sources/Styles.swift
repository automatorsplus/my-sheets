import AppKit

struct RGB: Hashable {
    var r: UInt8, g: UInt8, b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    init(hex: UInt32) { self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF)) }

    /// "FFRRGGBB" or "RRGGBB".
    init?(argb s: String) {
        let t = s.count == 8 ? String(s.dropFirst(2)) : s
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        self.init(hex: v)
    }

    var argb: String { String(format: "FF%02X%02X%02X", r, g, b) }
    var color: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }

    /// Excel's tint: lightens (positive) or darkens (negative) in HLS space.
    func tinted(_ tint: Double) -> RGB {
        var (h, l, s) = hls()
        l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint
        return RGB.fromHLS(h, min(max(l, 0), 1), s)
    }

    private func hls() -> (Double, Double, Double) {
        let rr = Double(r) / 255, gg = Double(g) / 255, bb = Double(b) / 255
        let mx = max(rr, gg, bb), mn = min(rr, gg, bb)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, l, 0) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == rr { h = (gg - bb) / d + (gg < bb ? 6 : 0) }
        else if mx == gg { h = (bb - rr) / d + 2 }
        else { h = (rr - gg) / d + 4 }
        h /= 6
        return (h, l, s)
    }

    private static func fromHLS(_ h: Double, _ l: Double, _ s: Double) -> RGB {
        func ch(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        guard s != 0 else { return RGB(ch(l), ch(l), ch(l)) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGB(ch(hue(h + 1.0 / 3)), ch(hue(h)), ch(hue(h - 1.0 / 3)))
    }
}

struct Edge: Equatable {
    var style: String
    var color: RGB
}

/// What a cell format looks like, resolved for drawing.
struct CellStyle {
    var fill: RGB? = nil
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var size: Double = 11
    var color: RGB? = nil
    var hAlign: String? = nil
    var vAlign: String? = nil
    var wrap = false
    var numFmt = "General"
    var left: Edge? = nil, right: Edge? = nil, top: Edge? = nil, bottom: Edge? = nil

    var hasBorders: Bool { left != nil || right != nil || top != nil || bottom != nil }
}

extension XMLElement {
    func kids(_ local: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == local }
    }
    func kid(_ local: String) -> XMLElement? { kids(local).first }
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }
    func setAttr(_ name: String, _ value: String) {
        if let a = attribute(forName: name) { a.stringValue = value }
        else { addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }
}

/// The workbook's cell formats (xl/styles.xml). The original XML is kept and only added to,
/// so fonts, borders and other formatting this app doesn't edit survive a save.
final class StyleTable {
    private let doc: XMLDocument
    private(set) var styles: [CellStyle] = []
    private var themeColors: [RGB]
    private var fonts: [CellStyle] = []
    private var fills: [RGB?] = []
    private var borders: [(Edge?, Edge?, Edge?, Edge?)] = []
    private var customFormats: [Int: String] = [:]
    private var cache: [String: Int] = [:]

    /// Office's default theme: dk1, lt1, dk2, lt2, accent1-6, hyperlink, followed hyperlink.
    static let officeTheme: [RGB] = [0x000000, 0xFFFFFF, 0x44546A, 0xE7E6E6, 0x4472C4, 0xED7D31,
                                     0xA5A5A5, 0xFFC000, 0x5B9BD5, 0x70AD47, 0x0563C1, 0x954F72].map { RGB(hex: $0) }

    static let template = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <fonts count="1"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>\
    <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
    </styleSheet>
    """

    static func blank() -> StyleTable { try! StyleTable(stylesXML: nil, themeXML: nil) }

    init(stylesXML: Data?, themeXML: Data?) throws {
        themeColors = themeXML.flatMap(StyleTable.readTheme) ?? StyleTable.officeTheme
        doc = try XMLDocument(data: stylesXML ?? Data(StyleTable.template.utf8), options: [])
        guard doc.rootElement() != nil else { throw XLSXError.bad("the styles part is empty") }
        readAll()
    }

    var count: Int { styles.count }

    subscript(i: Int) -> CellStyle { (i >= 0 && i < styles.count) ? styles[i] : (styles.first ?? CellStyle()) }

    private var root: XMLElement { doc.rootElement()! }

    private func element(_ local: String) -> XMLElement {
        let prefix = root.prefix ?? ""
        return XMLElement(name: prefix.isEmpty ? local : "\(prefix):\(local)")
    }

    private func readAll() {
        customFormats = [:]
        for f in root.kid("numFmts")?.kids("numFmt") ?? [] {
            if let id = f.attr("numFmtId").flatMap(Int.init), let code = f.attr("formatCode") { customFormats[id] = code }
        }
        fonts = (root.kid("fonts")?.kids("font") ?? []).map(readFont)
        fills = (root.kid("fills")?.kids("fill") ?? []).map(readFill)
        borders = (root.kid("borders")?.kids("border") ?? []).map(readBorder)
        styles = (root.kid("cellXfs")?.kids("xf") ?? []).map(resolve)
        if styles.isEmpty { styles = [CellStyle()] }
    }

    private func flag(_ e: XMLElement?) -> Bool {
        guard let e else { return false }
        let v = e.attr("val") ?? "1"
        return v != "0" && v != "false"
    }

    private func readFont(_ f: XMLElement) -> CellStyle {
        var s = CellStyle()
        s.bold = flag(f.kid("b"))
        s.italic = flag(f.kid("i"))
        s.underline = f.kid("u").map { ($0.attr("val") ?? "single") != "none" } ?? false
        s.strike = flag(f.kid("strike"))
        s.size = f.kid("sz")?.attr("val").flatMap(Double.init) ?? 11
        s.color = color(f.kid("color"))
        return s
    }

    private func readFill(_ f: XMLElement) -> RGB? {
        if let p = f.kid("patternFill") {
            let type = p.attr("patternType") ?? "none"
            if type == "none" || type == "gray125" { return nil }
            return color(p.kid("fgColor")) ?? (type == "solid" ? nil : color(p.kid("bgColor")))
        }
        if let g = f.kid("gradientFill") { return color(g.kids("stop").first?.kid("color")) }
        return nil
    }

    private func readBorder(_ b: XMLElement) -> (Edge?, Edge?, Edge?, Edge?) {
        func edge(_ names: [String]) -> Edge? {
            for n in names {
                guard let e = b.kid(n), let st = e.attr("style"), st != "none" else { continue }
                return Edge(style: st, color: color(e.kid("color")) ?? RGB(0, 0, 0))
            }
            return nil
        }
        return (edge(["left", "start"]), edge(["right", "end"]), edge(["top"]), edge(["bottom"]))
    }

    private func resolve(_ xf: XMLElement) -> CellStyle {
        let fontId = xf.attr("fontId").flatMap(Int.init) ?? 0
        var s = fontId < fonts.count ? fonts[fontId] : CellStyle()
        let fillId = xf.attr("fillId").flatMap(Int.init) ?? 0
        s.fill = fillId < fills.count ? fills[fillId] : nil
        let borderId = xf.attr("borderId").flatMap(Int.init) ?? 0
        if borderId < borders.count { (s.left, s.right, s.top, s.bottom) = borders[borderId] }
        let fmt = xf.attr("numFmtId").flatMap(Int.init) ?? 0
        s.numFmt = customFormats[fmt] ?? NumFmt.builtins[fmt] ?? "General"
        if let a = xf.kid("alignment") {
            s.hAlign = a.attr("horizontal")
            s.vAlign = a.attr("vertical")
            s.wrap = a.attr("wrapText") == "1" || a.attr("wrapText") == "true"
        }
        return s
    }

    private static let themeOrder = [1, 0, 3, 2, 4, 5, 6, 7, 8, 9, 10, 11]

    private func color(_ e: XMLElement?) -> RGB? {
        guard let e, e.attr("auto") != "1" else { return nil }
        var c: RGB?
        if let rgb = e.attr("rgb") { c = RGB(argb: rgb) }
        else if let t = e.attr("theme").flatMap(Int.init), t >= 0, t < StyleTable.themeOrder.count {
            let i = StyleTable.themeOrder[t]
            c = i < themeColors.count ? themeColors[i] : nil
        } else if let ix = e.attr("indexed").flatMap(Int.init), ix < StyleTable.indexed.count {
            c = RGB(hex: StyleTable.indexed[ix])
        }
        if let c0 = c, let tint = e.attr("tint").flatMap(Double.init), tint != 0 { c = c0.tinted(tint) }
        return c
    }

    private static func readTheme(_ data: Data) -> [RGB]? {
        guard let d = try? XMLDocument(data: data, options: []),
              let scheme = (try? d.nodes(forXPath: "//*[local-name()='clrScheme']"))?.first as? XMLElement else { return nil }
        let out: [RGB] = (scheme.children ?? []).compactMap { node in
            guard let e = node as? XMLElement else { return nil }
            if let s = e.kid("srgbClr")?.attr("val") { return RGB(argb: s) }
            if let s = e.kid("sysClr")?.attr("lastClr") { return RGB(argb: s) }
            return nil
        }
        return out.count >= 10 ? out : nil
    }

    // MARK: Adding formats

    private func ensure(_ local: String, atStart: Bool = false) -> XMLElement {
        if let e = root.kid(local) { return e }
        let e = element(local)
        if atStart { root.insertChild(e, at: 0) } else { root.addChild(e) }
        return e
    }

    private func addXf(copying base: Int, _ change: (XMLElement) -> Void) -> Int {
        let xfs = ensure("cellXfs")
        let list = xfs.kids("xf")
        let src = base >= 0 && base < list.count ? list[base] : list.first
        let x: XMLElement
        if let src, let copy = src.copy() as? XMLElement { x = copy }
        else {
            x = element("xf")
            for a in ["numFmtId", "fontId", "fillId", "borderId"] { x.setAttr(a, "0") }
        }
        change(x)
        if list.isEmpty {
            // A file with no formats at all gets a plain one first, so index 0 stays plain.
            let plain = element("xf")
            for a in ["numFmtId", "fontId", "fillId", "borderId"] { plain.setAttr(a, "0") }
            xfs.addChild(plain)
            styles = [resolve(plain)]
        }
        xfs.addChild(x)
        xfs.setAttr("count", String(xfs.kids("xf").count))
        styles.append(resolve(x))
        return styles.count - 1
    }

    /// The format that is `base` with a different fill (nil for no fill).
    func withFill(_ base: Int, _ rgb: RGB?) -> Int {
        let key = "\(base)|fill|\(rgb?.argb ?? "none")"
        if let i = cache[key] { return i }
        if self[base].fill == rgb { cache[key] = base; return base }
        var fillId = 0
        if let rgb {
            let fillsEl = ensure("fills")
            let fill = element("fill"), pf = element("patternFill"), fg = element("fgColor"), bg = element("bgColor")
            pf.setAttr("patternType", "solid")
            fg.setAttr("rgb", rgb.argb)
            bg.setAttr("indexed", "64")
            pf.addChild(fg); pf.addChild(bg); fill.addChild(pf)
            fillsEl.addChild(fill)
            fillsEl.setAttr("count", String(fillsEl.kids("fill").count))
            fills.append(rgb)
            fillId = fillsEl.kids("fill").count - 1
        }
        let i = addXf(copying: base) { x in
            x.setAttr("fillId", String(fillId))
            x.setAttr("applyFill", "1")
        }
        cache[key] = i
        return i
    }

    /// The format that is `base` with its font made bold or not, italic or not, or a different size.
    func withFont(_ base: Int, bold: Bool? = nil, italic: Bool? = nil, size: Double? = nil) -> Int {
        let cur = self[base]
        let b = bold ?? cur.bold, it = italic ?? cur.italic, sz = size ?? cur.size
        if b == cur.bold && it == cur.italic && sz == cur.size { return base }
        let key = "\(base)|font|\(b)|\(it)|\(sz)"
        if let i = cache[key] { return i }

        // A copy of the cell's own font with just these changed, so its name and colour stay.
        let fontsEl = ensure("fonts")
        let list = fontsEl.kids("font")
        let xfs = root.kid("cellXfs")?.kids("xf") ?? []
        let fontId = (base >= 0 && base < xfs.count ? xfs[base].attr("fontId").flatMap(Int.init) : nil) ?? 0
        let font = (fontId < list.count ? list[fontId].copy() as? XMLElement : nil) ?? element("font")
        for name in ["b", "i", "sz"] { for k in font.kids(name) { k.detach() } }
        // Excel insists on the schema's order: b, i, …, sz, then color, name, family, charset, scheme.
        if it { font.insertChild(element("i"), at: 0) }
        if b { font.insertChild(element("b"), at: 0) }
        let szEl = element("sz")
        szEl.setAttr("val", NumFmt.general(sz))
        let kids = (font.children ?? []).compactMap { $0 as? XMLElement }
        if let after = kids.firstIndex(where: { ["color", "name", "family", "charset", "scheme"].contains($0.localName ?? "") }) {
            font.insertChild(szEl, at: after)
        } else {
            font.addChild(szEl)
        }
        fontsEl.addChild(font)
        fontsEl.setAttr("count", String(fontsEl.kids("font").count))
        fonts.append(readFont(font))
        let newFontId = fonts.count - 1

        let i = addXf(copying: base) { x in
            x.setAttr("fontId", String(newFontId))
            x.setAttr("applyFont", "1")
        }
        cache[key] = i
        return i
    }

    /// The format that is `base` with a different number format.
    func withNumFmt(_ base: Int, _ code: String) -> Int {
        let key = "\(base)|fmt|\(code)"
        if let i = cache[key] { return i }
        if self[base].numFmt == code { cache[key] = base; return base }
        let portable = [1, 2, 3, 4, 9, 10, 11, 49]
        var id = portable.first { NumFmt.builtins[$0] == code }
            ?? customFormats.first { $0.value == code }?.key
        if id == nil {
            let newId = max(163, customFormats.keys.max() ?? 163) + 1
            let list = ensure("numFmts", atStart: true)
            let f = element("numFmt")
            f.setAttr("numFmtId", String(newId))
            f.setAttr("formatCode", code)
            list.addChild(f)
            list.setAttr("count", String(list.kids("numFmt").count))
            customFormats[newId] = code
            id = newId
        }
        let i = addXf(copying: base) { x in
            x.setAttr("numFmtId", String(id!))
            x.setAttr("applyNumberFormat", "1")
        }
        cache[key] = i
        return i
    }

    func xmlData() -> Data {
        doc.characterEncoding = "UTF-8"
        doc.isStandalone = true
        return doc.xmlData(options: [.nodeCompactEmptyElement])
    }

    /// Excel's legacy 64-colour palette, used by files that give colours as "indexed".
    static let indexed: [UInt32] = [
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
        0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
        0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
        0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
        0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
        0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
        0x000000, 0xFFFFFF,
    ]
}
