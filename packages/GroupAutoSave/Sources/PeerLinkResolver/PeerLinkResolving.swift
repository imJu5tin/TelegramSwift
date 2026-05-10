import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

public enum PeerLinkResolutionError: Error, Equatable {
    case notFound
    case noAccess
    case messageMissing
}

public struct ResolvedLink {
    public let peer: Peer
    public let message: Message

    public init(peer: Peer, message: Message) {
        self.peer = peer
        self.message = message
    }
}

public protocol PeerLinkResolving: AnyObject {
    func resolve(_ link: TmeLinkRef) -> Signal<Result<ResolvedLink, PeerLinkResolutionError>, NoError>
}

public final class PeerLinkResolver: PeerLinkResolving {
    private let account: Account
    private let engine: TelegramEngine

    public init(account: Account, engine: TelegramEngine) {
        self.account = account
        self.engine = engine
    }

    public func resolve(_ link: TmeLinkRef) -> Signal<Result<ResolvedLink, PeerLinkResolutionError>, NoError> {
        let account = self.account
        let engine = self.engine
        let peerSignal: Signal<Peer?, NoError>
        switch link.target {
        case let .username(username):
            peerSignal = engine.peers.resolvePeerByName(name: username, referrer: nil)
                |> mapToSignal { result -> Signal<Peer?, NoError> in
                    switch result {
                    case .progress:
                        return .complete()
                    case let .result(enginePeer):
                        return .single(enginePeer?._asPeer())
                    }
                }
                |> take(1)
        case let .privateChannel(rawId):
            let id = PeerId.Id._internalFromInt64Value(rawId)
            let peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: id)
            peerSignal = account.postbox.transaction { transaction -> Peer? in
                return transaction.getPeer(peerId)
            } |> mapToSignal { peer -> Signal<Peer?, NoError> in
                if let peer = peer {
                    return .single(peer)
                }
                return engine.peers.findChannelById(channelId: peerId.id._internalGetInt64Value()) |> map { $0?._asPeer() }
            }
        }
        return peerSignal
        |> mapToSignal { peer -> Signal<Result<ResolvedLink, PeerLinkResolutionError>, NoError> in
            guard let peer = peer else {
                return .single(.failure(.notFound))
            }
            // Note: do not reject by participationStatus. Public channels are readable
            // without membership; private channels will fail at downloadMessage and
            // surface as .messageMissing.
            let messageId = MessageId(peerId: peer.id, namespace: Namespaces.Message.Cloud, id: link.postId)
            return engine.messages.downloadMessage(messageId: messageId)
            |> map { message in
                guard let message = message else {
                    return .failure(.messageMissing)
                }
                return .success(ResolvedLink(peer: peer, message: message))
            }
        }
    }
}
