import Foundation

enum ContainerScanner {

    private static let tokenKeys: [String] = [
        "token", "auth", "session", "secret", "password", "credential",
        "jwt", "bearer", "apikey", "api_key", "access_token", "refresh_token",
        "cdi", "sso", "cookie", "loginkey", "accesskey"
    ]
    private static let piiKeys: [String] = [
        "email", "phone", "mobile", "name", "account", "userid", "user_id",
        "wallet", "idcard", "firstname", "lastname", "fullname", "nationalid",
        "citizenid", "passport", "address", "birthdate", "dob"
    ]
    private static let highValueCookies: [String] = [
        "session", "sso", "auth", "token", "laravel", "xsrf", "csrf",
        "login", "sid", "jwt", "bearer", "access"
    ]

    static func scan(containerPath: String, bundleId: String) -> [Finding] {
        var findings: [Finding] = []
        let fm = FileManager.default

        // 1 — Cookies.binarycookies
        let cookiePath = containerPath + "/Library/Cookies/Cookies.binarycookies"
        if fm.fileExists(atPath: cookiePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: cookiePath)) {
            for c in parseBinaryCookies(data) {
                let n = c.name.lowercased()
                let sev: Finding.Severity = highValueCookies.contains(where: { n.contains($0) }) ? .high : .low
                findings.append(Finding(
                    id: UUID(), bundleId: bundleId, type: .sessionCookie,
                    file: "Library/Cookies/Cookies.binarycookies",
                    key: "\(c.name) @ \(c.domain)",
                    value: String(c.value.prefix(120)),
                    severity: sev
                ))
            }
        }

        // 2 — NSUserDefaults plists
        let prefsDir = containerPath + "/Library/Preferences"
        if let plists = try? fm.contentsOfDirectory(atPath: prefsDir) {
            for plist in plists where plist.hasSuffix(".plist") {
                let fullPath = prefsDir + "/" + plist
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                      let obj  = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }

                for (key, value) in obj {
                    guard let str = plistStr(value), str.count >= 8 else { continue }
                    let kl = key.lowercased()
                    if tokenKeys.contains(where: { kl.contains($0) }) {
                        findings.append(Finding(
                            id: UUID(), bundleId: bundleId, type: .plistToken,
                            file: "Library/Preferences/\(plist)",
                            key: key, value: String(str.prefix(120)), severity: .medium
                        ))
                    } else if piiKeys.contains(where: { kl.contains($0) }) {
                        findings.append(Finding(
                            id: UUID(), bundleId: bundleId, type: .plistPII,
                            file: "Library/Preferences/\(plist)",
                            key: key, value: String(str.prefix(120)), severity: .medium
                        ))
                    }
                }
            }
        }

        // 3 — Realm files → extract JWTs
        for realmPath in findFiles(at: containerPath, ext: "realm", depth: 6) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: realmPath)) else { continue }
            let rel = realmPath.replacingOccurrences(of: containerPath + "/", with: "")
            for jwt in jwtTokens(in: data) {
                findings.append(Finding(
                    id: UUID(), bundleId: bundleId, type: .jwt,
                    file: rel, key: "JWT",
                    value: String(jwt.prefix(120)) + "…",
                    severity: .high
                ))
            }
        }

        return findings
    }

    // MARK: - Helpers

    private static func plistStr(_ v: Any) -> String? {
        if let s = v as? String { return s }
        if let d = v as? Data   { return d.base64EncodedString() }
        return nil
    }

    private static func jwtTokens(in data: Data) -> [String] {
        var out: [String] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + 3 < bytes.count {
            // look for "eyJ" (0x65 0x79 0x4A)
            if bytes[i] == 0x65, bytes[i+1] == 0x79, bytes[i+2] == 0x4A {
                var j = i
                while j < bytes.count && bytes[j] >= 0x20 && bytes[j] <= 0x7E { j += 1 }
                if j - i > 20 {
                    let s = String(bytes: bytes[i..<j], encoding: .ascii) ?? ""
                    if s.filter({ $0 == "." }).count >= 2 { out.append(s) }
                }
                i = j
            } else { i += 1 }
        }
        return Array(Set(out))
    }

    private static func findFiles(at path: String, ext: String, depth: Int) -> [String] {
        guard depth > 0 else { return [] }
        var out: [String] = []
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        for item in items {
            let full = path + "/" + item
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue {
                out += findFiles(at: full, ext: ext, depth: depth - 1)
            } else if item.hasSuffix(".\(ext)") {
                out.append(full)
            }
        }
        return out
    }
}
