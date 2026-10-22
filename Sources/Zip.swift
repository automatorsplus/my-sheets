import Compression
import Foundation

/// The ZIP container an .xlsx file is. Reads stored and deflated entries; writes deflated ones.
/// Apple's COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP uses.
enum ZipError: LocalizedError {
    case notZip, unsupported(String), damaged(String)
    var errorDescription: String? {
        switch self {
        case .notZip: return "This isn't an .xlsx file (it isn't a ZIP package)."
        case .unsupported(let s): return "This file uses a ZIP feature MySheets can't read: \(s)."
        case .damaged(let s): return "This file looks damaged: \(s)."
        }
    }
}

private let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        for b in p { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    }
    return c ^ 0xFFFFFFFF
}

struct ZipReader {
    struct Entry { let name: String; let method: UInt16; let crc: UInt32; let csize: Int; let usize: Int; let offset: Int }

    private let bytes: [UInt8]
    private(set) var entries: [String: Entry] = [:]
    private var lowercased: [String: String] = [:]

    var names: [String] { Array(entries.keys) }

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 65_535)
        while i >= stop {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = Int(u16(eocd + 10))
        let cdOffset = Int(u32(eocd + 16))
        if count == 0xFFFF || cdOffset == 0xFFFFFFFF { throw ZipError.unsupported("ZIP64") }
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { throw ZipError.damaged("the file list is broken") }
            let method = u16(p + 10)
            let crc = u32(p + 16)
            let csize = Int(u32(p + 20)), usize = Int(u32(p + 24))
            let nlen = Int(u16(p + 28)), xlen = Int(u16(p + 30)), clen = Int(u16(p + 32))
            let offset = Int(u32(p + 42))
            guard p + 46 + nlen <= bytes.count else { throw ZipError.damaged("a file name runs past the end") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            if csize == 0xFFFFFFFF || usize == 0xFFFFFFFF { throw ZipError.unsupported("ZIP64") }
            entries[name] = Entry(name: name, method: method, crc: crc, csize: csize, usize: usize, offset: offset)
            lowercased[name.lowercased()] = name
            p += 46 + nlen + xlen + clen
        }
    }

    private func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
    private func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24 }

    func contains(_ name: String) -> Bool { entries[name] != nil || lowercased[name.lowercased()] != nil }

    func data(_ name: String) throws -> Data? {
        guard let e = entries[name] ?? lowercased[name.lowercased()].flatMap({ entries[$0] }) else { return nil }
        let h = e.offset
        guard h + 30 <= bytes.count, u32(h) == 0x04034b50 else { throw ZipError.damaged("\(name) is missing") }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        guard start + e.csize <= bytes.count else { throw ZipError.damaged("\(name) is cut short") }
        let raw = bytes[start..<(start + e.csize)]
        switch e.method {
        case 0:
            return Data(raw)
        case 8:
            if e.usize == 0 { return Data() }
            var out = [UInt8](repeating: 0, count: e.usize)
            let n = raw.withUnsafeBufferPointer { src in
                compression_decode_buffer(&out, e.usize, src.baseAddress!, e.csize, nil, COMPRESSION_ZLIB)
            }
            guard n == e.usize else { throw ZipError.damaged("\(name) won't decompress") }
            return Data(out)
        default:
            throw ZipError.unsupported("compression method \(e.method)")
        }
    }
}

struct ZipWriter {
    private var out = Data()
    private var central = Data()
    private var count = 0

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }

    private static let dosTime: (time: Int, date: Int) = {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let time = (c.hour! << 11) | (c.minute! << 5) | (c.second! / 2)
        let date = ((c.year! - 1980) << 9) | (c.month! << 5) | c.day!
        return (time, date)
    }()

    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    mutating func add(_ name: String, _ data: Data) {
        let crc = crc32(data)
        var payload = data
        var method = 0
        if data.count > 64 {
            let cap = data.count + data.count / 10 + 1024
            var buf = [UInt8](repeating: 0, count: cap)
            let n = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                compression_encode_buffer(&buf, cap, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
            if n > 0 && n < data.count { payload = Data(buf[0..<n]); method = 8 }
        }
        let nameBytes = [UInt8](name.utf8)
        let offset = UInt32(out.count)
        let t = ZipWriter.dosTime
        var local: [UInt8] = ZipWriter.le32(0x04034b50) + ZipWriter.le16(20) + ZipWriter.le16(0x0800) + ZipWriter.le16(method)
        local += ZipWriter.le16(t.time) + ZipWriter.le16(t.date) + ZipWriter.le32(crc)
        local += ZipWriter.le32(UInt32(payload.count)) + ZipWriter.le32(UInt32(data.count))
        local += ZipWriter.le16(nameBytes.count) + ZipWriter.le16(0) + nameBytes
        out.append(contentsOf: local)
        out.append(payload)

        var c: [UInt8] = ZipWriter.le32(0x02014b50) + ZipWriter.le16(20) + ZipWriter.le16(20) + ZipWriter.le16(0x0800) + ZipWriter.le16(method)
        c += ZipWriter.le16(t.time) + ZipWriter.le16(t.date) + ZipWriter.le32(crc)
        c += ZipWriter.le32(UInt32(payload.count)) + ZipWriter.le32(UInt32(data.count))
        c += ZipWriter.le16(nameBytes.count) + ZipWriter.le16(0) + ZipWriter.le16(0) + ZipWriter.le16(0) + ZipWriter.le16(0)
        c += ZipWriter.le32(0) + ZipWriter.le32(offset) + nameBytes
        central.append(contentsOf: c)
        count += 1
    }

    func finish() -> Data {
        var d = out
        let cdOffset = UInt32(d.count)
        d.append(central)
        var end: [UInt8] = ZipWriter.le32(0x06054b50) + ZipWriter.le16(0) + ZipWriter.le16(0)
        end += ZipWriter.le16(count) + ZipWriter.le16(count) + ZipWriter.le32(UInt32(central.count)) + ZipWriter.le32(cdOffset) + ZipWriter.le16(0)
        d.append(contentsOf: end)
        return d
    }
}
