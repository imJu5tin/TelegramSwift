import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

public struct WalkBatch {
    public let messages: [Message]
    public let nextState: SearchMessagesState?
    public let completed: Bool

    public init(messages: [Message], nextState: SearchMessagesState?, completed: Bool) {
        self.messages = messages
        self.nextState = nextState
        self.completed = completed
    }
}

public protocol MessageWalking: AnyObject {
    func nextBatch(peerId: PeerId, state: SearchMessagesState?, limit: Int32) -> Signal<WalkBatch, NoError>
    func liveMessages() -> Signal<[Message], NoError>
}

public final class TelegramEngineMessageWalker: MessageWalking {
    private let account: Account
    private let engine: TelegramEngine

    public init(account: Account, engine: TelegramEngine) {
        self.account = account
        self.engine = engine
    }

    public func nextBatch(peerId: PeerId, state: SearchMessagesState?, limit: Int32 = 100) -> Signal<WalkBatch, NoError> {
        let location: SearchMessagesLocation = .peer(peerId: peerId, fromId: nil, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil)
        return self.engine.messages.searchMessages(location: location, query: "", state: state, limit: limit)
        |> map { result, nextState -> WalkBatch in
            return WalkBatch(
                messages: result.messages,
                nextState: nextState,
                completed: result.completed || result.messages.isEmpty
            )
        }
    }

    public func liveMessages() -> Signal<[Message], NoError> {
        return self.account.stateManager.notificationMessages
        |> map { batches -> [Message] in
            var collected: [Message] = []
            for (messages, _, _, _) in batches {
                collected.append(contentsOf: messages)
            }
            return collected
        }
    }
}

public final class MessageDedupCache {
    private let capacity: Int
    private var order: [MessageId] = []
    private var set: Set<MessageId> = []
    private let lock = NSLock()

    public init(capacity: Int = 1024) {
        self.capacity = capacity
    }

    public func contains(_ id: MessageId) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.set.contains(id)
    }

    public func insert(_ id: MessageId) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.set.insert(id).inserted else { return false }
        self.order.append(id)
        if self.order.count > self.capacity {
            let evicted = self.order.removeFirst()
            self.set.remove(evicted)
        }
        return true
    }

    public var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.set.count
    }
}
