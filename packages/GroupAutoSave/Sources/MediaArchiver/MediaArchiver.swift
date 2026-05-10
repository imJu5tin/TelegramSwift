import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

public struct ArchiveRequest {
    public let media: Media
    public let mediaReference: AnyMediaReference
    public let peerTitle: String
    public let originPeerId: PeerId
    public let originMessageId: MessageId
    public let originGroupingKey: Int64?
    public let originTimestamp: Int32
    public let archiveRootOverride: String?

    public init(media: Media, mediaReference: AnyMediaReference, peerTitle: String, originPeerId: PeerId, originMessageId: MessageId, originGroupingKey: Int64?, originTimestamp: Int32, archiveRootOverride: String? = nil) {
        self.media = media
        self.mediaReference = mediaReference
        self.peerTitle = peerTitle
        self.originPeerId = originPeerId
        self.originMessageId = originMessageId
        self.originGroupingKey = originGroupingKey
        self.originTimestamp = originTimestamp
        self.archiveRootOverride = archiveRootOverride
    }
}

public enum ArchiveError: Error {
    case notSupportedMediaType
    case incompleteResource
    case copyFailed
    case noUniqueDestination
}

public protocol MediaArchiving: AnyObject {
    func archive(_ request: ArchiveRequest) -> Signal<String?, NoError>
    func logSkipped(peerTitle: String, peerId: PeerId, originMessageId: MessageId, reason: String, link: String, archiveRootOverride: String?)
}

public final class MediaArchiver: MediaArchiving {
    private let postbox: Postbox
    private let archiveRoot: String
    private let resourcesQueue: Queue
    private let fileManager: FileManager

    public init(postbox: Postbox, archiveRoot: String = PathHelpers.defaultArchiveRoot(), resourcesQueue: Queue = Queue()) {
        self.postbox = postbox
        self.archiveRoot = archiveRoot
        self.resourcesQueue = resourcesQueue
        self.fileManager = .default
    }

    public func archive(_ request: ArchiveRequest) -> Signal<String?, NoError> {
        guard let preferredFileName = preferredFileName(for: request.media),
              let resource = preferredResource(for: request.media) else {
            return .single(nil)
        }
        let postbox = self.postbox
        let archiveRoot = self.archiveRoot
        let fileManager = self.fileManager
        let resourcesQueue = self.resourcesQueue
        let effectiveRoot = request.archiveRootOverride ?? archiveRoot
        return postbox.mediaBox.resourceData(resource)
        |> filter { $0.complete }
        |> take(1)
        |> deliverOn(resourcesQueue)
        |> map { data -> String? in
            let directory = PathHelpers.archiveDirectory(
                root: effectiveRoot,
                peerTitle: request.peerTitle,
                peerId: request.originPeerId.toInt64(),
                messageId: request.originMessageId.id,
                groupingKey: request.originGroupingKey,
                timestamp: request.originTimestamp
            )
            do {
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return nil
            }
            let nextPath = PathHelpers.nextAvailablePath(
                directory: directory,
                baseName: preferredFileName,
                fileExists: { fileManager.fileExists(atPath: $0) },
                sameContent: { existing in
                    guard let attrs = try? fileManager.attributesOfItem(atPath: existing),
                          let existingSize = attrs[.size] as? NSNumber,
                          let candidateAttrs = try? fileManager.attributesOfItem(atPath: data.path),
                          let candidateSize = candidateAttrs[.size] as? NSNumber else {
                        return false
                    }
                    return existingSize.int64Value == candidateSize.int64Value
                }
            )
            switch nextPath {
            case let .free(destination):
                do {
                    try fileManager.copyItem(atPath: data.path, toPath: destination)
                    return destination
                } catch {
                    return nil
                }
            case let .alreadyArchived(existing):
                return existing
            case .exhausted:
                return nil
            }
        }
    }

    public func logSkipped(peerTitle: String, peerId: PeerId, originMessageId: MessageId, reason: String, link: String, archiveRootOverride: String? = nil) {
        let effectiveRoot = archiveRootOverride ?? self.archiveRoot
        let path = PathHelpers.skippedLogPath(root: effectiveRoot, peerTitle: peerTitle, peerId: peerId.toInt64())
        let directory = (path as NSString).deletingLastPathComponent
        try? self.fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        let line = PathHelpers.formatSkippedLogLine(
            timestamp: Date(),
            reason: reason,
            originPeerId: originMessageId.peerId.toInt64(),
            originMessageId: originMessageId.id,
            link: link
        )
        guard let data = line.data(using: .utf8) else { return }
        if self.fileManager.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func preferredFileName(for media: Media) -> String? {
        if media is TelegramMediaImage {
            return "photo.jpg"
        }
        if let file = media as? TelegramMediaFile {
            if let name = file.fileName, !name.isEmpty {
                return sanitizeFileName(name)
            }
            if file.isVideo {
                return "video.mp4"
            }
        }
        return nil
    }

    private func preferredResource(for media: Media) -> TelegramMediaResource? {
        if let image = media as? TelegramMediaImage {
            return largestImageRepresentation(image.representations)?.resource
        }
        if let file = media as? TelegramMediaFile {
            return file.resource
        }
        return nil
    }

    private func sanitizeFileName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_")
        var range = (s as NSString).range(of: ".")
        while range.location == 0 {
            s = (s as NSString).replacingCharacters(in: range, with: "_")
            range = (s as NSString).range(of: ".")
        }
        return s
    }
}
