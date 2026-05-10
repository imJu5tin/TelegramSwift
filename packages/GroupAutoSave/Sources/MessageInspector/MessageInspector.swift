import Foundation
import Postbox
import TelegramCore

public struct MessageInspection: Equatable {
    public let directMedia: [Media]
    public let outgoingUrls: [String]

    public init(directMedia: [Media], outgoingUrls: [String]) {
        self.directMedia = directMedia
        self.outgoingUrls = outgoingUrls
    }

    public static func == (lhs: MessageInspection, rhs: MessageInspection) -> Bool {
        return lhs.outgoingUrls == rhs.outgoingUrls
            && lhs.directMedia.map { $0.id } == rhs.directMedia.map { $0.id }
    }
}

public enum MessageInspector {
    public static func inspect(_ message: Message) -> MessageInspection {
        return MessageInspection(
            directMedia: extractDirectMedia(message),
            outgoingUrls: extractOutgoingUrls(message)
        )
    }

    public static func extractDirectMedia(_ message: Message) -> [Media] {
        var result: [Media] = []
        for media in message.media {
            if media is TelegramMediaImage {
                result.append(media)
                continue
            }
            if let file = media as? TelegramMediaFile, qualifiesAsVideo(file) {
                result.append(media)
            }
        }
        return result
    }

    public static func qualifiesAsVideo(_ file: TelegramMediaFile) -> Bool {
        return file.isVideo
            && !file.isAnimated
            && !file.isInstantVideo
            && !file.isVoice
    }

    public static func extractOutgoingUrls(_ message: Message) -> [String] {
        let nsText = message.text as NSString
        var ranges: [TextEntityRange] = []
        for attribute in message.attributes {
            guard let entities = attribute as? TextEntitiesMessageAttribute else { continue }
            for entity in entities.entities {
                switch entity.type {
                case .Url:
                    ranges.append(TextEntityRange(lower: entity.range.lowerBound, upper: entity.range.upperBound, kind: .url))
                case let .TextUrl(url):
                    ranges.append(TextEntityRange(lower: entity.range.lowerBound, upper: entity.range.upperBound, kind: .textUrl(url)))
                default:
                    continue
                }
            }
        }
        return URLExtraction.extract(text: nsText as String, entities: ranges)
    }
}

public struct TextEntityRange: Equatable {
    public enum Kind: Equatable {
        case url
        case textUrl(String)
    }

    public let lower: Int
    public let upper: Int
    public let kind: Kind

    public init(lower: Int, upper: Int, kind: Kind) {
        self.lower = lower
        self.upper = upper
        self.kind = kind
    }
}

public enum URLExtraction {
    public static func extract(text: String, entities: [TextEntityRange]) -> [String] {
        let nsText = text as NSString
        var seen = Set<String>()
        var urls: [String] = []
        for entity in entities {
            let candidate: String?
            switch entity.kind {
            case .url:
                let lower = max(0, entity.lower)
                let upper = min(nsText.length, entity.upper)
                if upper > lower {
                    candidate = nsText.substring(with: NSRange(location: lower, length: upper - lower))
                } else {
                    candidate = nil
                }
            case let .textUrl(url):
                candidate = url
            }
            if let candidate = candidate, seen.insert(candidate).inserted {
                urls.append(candidate)
            }
        }
        return urls
    }
}

public struct MediaCandidate: Equatable {
    public let isImage: Bool
    public let isVideo: Bool
    public let isAnimated: Bool
    public let isInstantVideo: Bool
    public let isVoice: Bool

    public init(isImage: Bool = false, isVideo: Bool = false, isAnimated: Bool = false, isInstantVideo: Bool = false, isVoice: Bool = false) {
        self.isImage = isImage
        self.isVideo = isVideo
        self.isAnimated = isAnimated
        self.isInstantVideo = isInstantVideo
        self.isVoice = isVoice
    }
}

public enum MediaQualification {
    public static func qualifyingIndices(_ candidates: [MediaCandidate]) -> [Int] {
        var result: [Int] = []
        for (index, candidate) in candidates.enumerated() {
            if candidate.isImage {
                result.append(index)
                continue
            }
            if candidate.isVideo && !candidate.isAnimated && !candidate.isInstantVideo && !candidate.isVoice {
                result.append(index)
            }
        }
        return result
    }
}
