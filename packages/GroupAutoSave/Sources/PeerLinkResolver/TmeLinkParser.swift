import Foundation

public struct TmeLinkRef: Hashable, Equatable {
    public enum Target: Hashable, Equatable {
        case username(String)
        case privateChannel(rawId: Int64)
    }

    public let target: Target
    public let postId: Int32

    public init(target: Target, postId: Int32) {
        self.target = target
        self.postId = postId
    }
}

public enum TmeLinkParser {
    private static let domainPrefixes: [String] = [
        "t.me/",
        "telegram.me/",
        "telegram.dog/",
    ]

    private static let schemePrefixes: [String] = [
        "https://",
        "http://",
    ]

    public static func parse(_ rawUrl: String) -> TmeLinkRef? {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var working = trimmed
        let lowered = working.lowercased()
        for scheme in schemePrefixes where lowered.hasPrefix(scheme) {
            working = String(working.dropFirst(scheme.count))
            break
        }
        let workingLower = working.lowercased()
        var rest: String?
        for prefix in domainPrefixes where workingLower.hasPrefix(prefix) {
            rest = String(working.dropFirst(prefix.count))
            break
        }
        guard var path = rest else { return nil }
        if let queryStart = path.firstIndex(of: "?") {
            path = String(path[..<queryStart])
        }
        if let hashStart = path.firstIndex(of: "#") {
            path = String(path[..<hashStart])
        }
        let comps = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        if comps.count == 3, comps[0].lowercased() == "c", let channelId = Int64(comps[1]), let postId = Int32(comps[2]), postId > 0, channelId > 0 {
            return TmeLinkRef(target: .privateChannel(rawId: channelId), postId: postId)
        }
        if comps.count == 2 {
            let username = comps[0]
            if username.isEmpty { return nil }
            if username.first == "+" { return nil }
            if username.lowercased() == "joinchat" { return nil }
            if username.lowercased() == "c" { return nil }
            if !isValidTelegramUsername(username) { return nil }
            if let postId = Int32(comps[1]), postId > 0 {
                return TmeLinkRef(target: .username(username), postId: postId)
            }
        }
        return nil
    }

    private static func isValidTelegramUsername(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for scalar in s.unicodeScalars {
            let isAllowed = (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "_"
            if !isAllowed { return false }
        }
        return true
    }
}
