import Foundation

struct ParsedCookie {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiry: Double   // Apple epoch (seconds since 2001-01-01)
    let flags: UInt32    // bit 0 = Secure, bit 2 = HttpOnly
}

func parseBinaryCookies(_ data: Data) -> [ParsedCookie] {
    guard data.count >= 8,
          data[0..<4] == Data([0x63, 0x6f, 0x6f, 0x6b])  // "cook"
    else { return [] }

    func u32be(_ at: Int) -> UInt32? {
        guard at + 4 <= data.count else { return nil }
        return data[at..<at+4].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
    func u32le(_ at: Int) -> UInt32? {
        guard at + 4 <= data.count else { return nil }
        return data[at..<at+4].withUnsafeBytes { $0.load(as: UInt32.self) }
    }
    func f64(_ at: Int) -> Double? {
        guard at + 8 <= data.count else { return nil }
        return data[at..<at+8].withUnsafeBytes { $0.load(as: Double.self) }
    }
    func cstr(base: Int, offset: UInt32) -> String {
        var i = base + Int(offset)
        var bytes: [UInt8] = []
        while i < data.count && data[i] != 0 { bytes.append(data[i]); i += 1 }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    guard let pageCount = u32be(4) else { return [] }
    var pos = 8
    var pageSizes: [Int] = []
    for _ in 0..<pageCount {
        guard let sz = u32be(pos) else { return [] }
        pageSizes.append(Int(sz))
        pos += 4
    }

    var result: [ParsedCookie] = []
    for pageSize in pageSizes {
        let pageStart = pos
        guard pos + pageSize <= data.count, pos + 8 <= data.count else { break }
        let cookieCount = u32le(pos + 4) ?? 0
        var cookieOffsets: [UInt32] = []
        var oPos = pos + 8
        for _ in 0..<cookieCount {
            guard let off = u32le(oPos) else { break }
            cookieOffsets.append(off)
            oPos += 4
        }
        for off in cookieOffsets {
            let c = pageStart + Int(off)
            guard c + 44 <= data.count,
                  let flags    = u32le(c + 8),
                  let domainOff = u32le(c + 16),
                  let nameOff  = u32le(c + 20),
                  let pathOff  = u32le(c + 24),
                  let valueOff = u32le(c + 28),
                  let expiry   = f64(c + 36)
            else { continue }
            let name   = cstr(base: c, offset: nameOff)
            let value  = cstr(base: c, offset: valueOff)
            let domain = cstr(base: c, offset: domainOff)
            let path   = cstr(base: c, offset: pathOff)
            if !name.isEmpty {
                result.append(ParsedCookie(name: name, value: value, domain: domain,
                                           path: path, expiry: expiry, flags: flags))
            }
        }
        pos += pageSize
    }
    return result
}
