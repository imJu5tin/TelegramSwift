import Foundation
import Security

public enum BearerToken {
    public static func tokenFilePath() -> String {
        let home = (NSHomeDirectory() as NSString)
        return home.appendingPathComponent(".config/telegram-archive-mcp/token")
    }

    public static func loadOrGenerate() -> String {
        let path = tokenFilePath()
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let token = generate()
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        try? token.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return token
    }

    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func extractFromAuthorizationHeader(_ header: String?) -> String? {
        guard let header = header else { return nil }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return nil }
        return String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var result: UInt8 = 0
        for i in 0..<aBytes.count {
            result |= aBytes[i] ^ bBytes[i]
        }
        return result == 0
    }
}
