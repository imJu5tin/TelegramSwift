import Foundation

public enum PathHelpers {
    public static func sanitizedFolderName(title: String, fallbackId: Int64) -> String {
        let normalized = title.precomposedStringWithCanonicalMapping
        let withSpaces = normalized
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let scrubbed = String(String.UnicodeScalarView(withSpaces.unicodeScalars.filter { !illegal.contains($0) }))
        let collapsed = scrubbed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = String(collapsed.prefix(80))
        if trimmed.isEmpty {
            return String(fallbackId)
        }
        return trimmed
    }

    public static func messageSubfolderName(messageId: Int32, groupingKey: Int64?, timestamp: Int32) -> String {
        let stamp = formatTimestamp(timestamp)
        if let groupingKey = groupingKey, groupingKey != 0 {
            return "\(stamp)__g\(groupingKey)"
        }
        return "\(stamp)__m\(messageId)"
    }

    private static func formatTimestamp(_ ts: Int32) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    public static func defaultArchiveRoot() -> String {
        return ("~/Downloads/TelegramAutoSave" as NSString).expandingTildeInPath
    }

    public static func archiveDirectory(root: String, peerTitle: String, peerId: Int64, messageId: Int32, groupingKey: Int64?, timestamp: Int32) -> String {
        let folder = sanitizedFolderName(title: peerTitle, fallbackId: peerId)
        let subfolder = messageSubfolderName(messageId: messageId, groupingKey: groupingKey, timestamp: timestamp)
        return "\(root)/\(folder)/\(subfolder)"
    }

    public static func skippedLogPath(root: String, peerTitle: String, peerId: Int64) -> String {
        let folder = sanitizedFolderName(title: peerTitle, fallbackId: peerId)
        return "\(root)/\(folder)/skipped.txt"
    }

    public static func nextAvailablePath(
        directory: String,
        baseName: String,
        fileExists: (String) -> Bool,
        sameContent: (String) -> Bool
    ) -> NextPathResult {
        let basePath = "\(directory)/\(baseName)"
        if !fileExists(basePath) {
            return .free(basePath)
        }
        if sameContent(basePath) {
            return .alreadyArchived(basePath)
        }
        let nameWithoutExt = (baseName as NSString).deletingPathExtension
        let ext = (baseName as NSString).pathExtension
        var i = 2
        while i < 1000 {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(nameWithoutExt) (\(i))"
            } else {
                candidateName = "\(nameWithoutExt) (\(i)).\(ext)"
            }
            let candidatePath = "\(directory)/\(candidateName)"
            if !fileExists(candidatePath) {
                return .free(candidatePath)
            }
            if sameContent(candidatePath) {
                return .alreadyArchived(candidatePath)
            }
            i += 1
        }
        return .exhausted
    }

    public enum NextPathResult: Equatable {
        case free(String)
        case alreadyArchived(String)
        case exhausted
    }

    public static func formatSkippedLogLine(timestamp: Date, reason: String, originPeerId: Int64, originMessageId: Int32, link: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let safeReason = reason.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        let safeLink = link.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "\(formatter.string(from: timestamp))\t\(safeReason)\t\(originPeerId)/\(originMessageId)\t\(safeLink)\n"
    }
}
