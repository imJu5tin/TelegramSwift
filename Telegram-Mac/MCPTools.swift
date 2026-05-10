import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import MCPServer
import MessageInspector
import PeerLinkResolver
import MediaArchiver
import MessageWalker

private let toolsQueue = DispatchQueue(label: "com.n71903.telegram.mcp.tools", qos: .utility)

private final class WalkSessionStore {
    private struct Entry {
        let peerId: PeerId
        var state: SearchMessagesState?
        var returnedCount: Int
        var lastTouched: Date
    }
    private var sessions: [String: Entry] = [:]
    private let lock = NSLock()
    private let capacity = 64

    func snapshot(sessionId: String, expectedPeer: PeerId) -> (state: SearchMessagesState?, returnedCount: Int)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard var entry = self.sessions[sessionId], entry.peerId == expectedPeer else { return nil }
        entry.lastTouched = Date()
        self.sessions[sessionId] = entry
        return (entry.state, entry.returnedCount)
    }

    func put(sessionId: String, peerId: PeerId, state: SearchMessagesState?, returnedCount: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.sessions[sessionId] = Entry(peerId: peerId, state: state, returnedCount: returnedCount, lastTouched: Date())
        if self.sessions.count > self.capacity {
            let sortedByOldest = self.sessions.sorted { $0.value.lastTouched < $1.value.lastTouched }
            let evictCount = self.sessions.count - self.capacity
            for (key, _) in sortedByOldest.prefix(evictCount) {
                self.sessions.removeValue(forKey: key)
            }
        }
    }
}

private let walkSessions = WalkSessionStore()

private struct PostAssignment {
    let postId: Int64
    let caption: String
    let mediaCount: Int
}

/// Cluster a newest→oldest batch of messages into "posts" (albums).
/// Uses groupingKey when present; otherwise falls back to a 10-second
/// timestamp window over consecutive media-bearing messages.
private func clusterPosts(_ messages: [Message]) -> [Int: PostAssignment] {
    let albumWindow: Int32 = 10
    func messageHasMedia(_ m: Message) -> Bool {
        for media in m.media {
            if media is TelegramMediaImage { return true }
            if let f = media as? TelegramMediaFile, f.isVideo, !f.isAnimated, !f.isInstantVideo, !f.isVoice {
                return true
            }
        }
        return false
    }
    var clusterIndex: [Int: Int] = [:]   // message-array-index → cluster-index
    var clusters: [[Int]] = []           // cluster-index → [message-array-index]
    var current: [Int] = []
    var prevTs: Int32 = 0
    var prevHadMedia = false
    var prevGK: Int64? = nil
    for (i, m) in messages.enumerated() {
        let ts = m.timestamp
        let hasMedia = messageHasMedia(m)
        let gk = m.groupingKey
        let sameByGK: Bool = (gk != nil && prevGK != nil && gk == prevGK)
        let sameByTs: Bool = !current.isEmpty && hasMedia && prevHadMedia && abs(ts - prevTs) <= albumWindow
        if sameByGK || sameByTs {
            current.append(i)
        } else {
            if !current.isEmpty { clusters.append(current) }
            current = [i]
        }
        prevTs = ts
        prevHadMedia = hasMedia
        prevGK = gk
    }
    if !current.isEmpty { clusters.append(current) }
    var assignments: [Int: PostAssignment] = [:]
    for cluster in clusters {
        let msgs = cluster.map { messages[$0] }
        let captionMsg = msgs.first(where: { !$0.text.isEmpty }) ?? msgs.first!
        let postIdRaw: Int64 = msgs.compactMap({ $0.groupingKey }).first ?? Int64(msgs.map({ $0.id.id }).min() ?? 0)
        let mediaCount = msgs.reduce(0) { $0 + (messageHasMedia($1) ? 1 : 0) }
        let assignment = PostAssignment(postId: postIdRaw, caption: captionMsg.text, mediaCount: mediaCount)
        for idx in cluster {
            assignments[idx] = assignment
        }
    }
    return assignments
}

private func messageSummary(_ message: Message) -> [String: Any] {
    var dict: [String: Any] = [
        "peer_id": message.id.peerId.toInt64(),
        "message_id": message.id.id,
        "namespace": message.id.namespace,
        "timestamp": message.timestamp,
        "text": message.text,
    ]
    if let groupingKey = message.groupingKey, groupingKey != 0 {
        dict["grouping_key"] = groupingKey
    }
    if let groupInfo = message.groupInfo {
        dict["group_stable_id"] = groupInfo.stableId
    }
    if let forwardInfo = message.forwardInfo {
        dict["forwarded_from_peer_id"] = forwardInfo.author?.id.toInt64() ?? NSNull()
        dict["forwarded_source_peer_id"] = forwardInfo.source?.id.toInt64() ?? NSNull()
        if let sourceMessageId = forwardInfo.sourceMessageId {
            dict["forwarded_source_message_id"] = sourceMessageId.id
        }
    }
    var mediaSummaries: [[String: Any]] = []
    for media in message.media {
        if let image = media as? TelegramMediaImage {
            mediaSummaries.append([
                "type": "photo",
                "id": image.imageId.id,
            ])
        } else if let file = media as? TelegramMediaFile {
            mediaSummaries.append([
                "type": "file",
                "id": file.fileId.id,
                "is_video": file.isVideo,
                "is_voice": file.isVoice,
                "is_animated": file.isAnimated,
                "is_instant_video": file.isInstantVideo,
                "size": (file.size as Any?) ?? NSNull(),
                "file_name": (file.fileName as Any?) ?? NSNull(),
                "mime_type": file.mimeType,
            ])
        }
    }
    dict["media"] = mediaSummaries
    return dict
}

private func peerSummary(_ peer: Peer) -> [String: Any] {
    var dict: [String: Any] = [
        "peer_id": peer.id.toInt64(),
        "type": "peer",
    ]
    if let user = peer as? TelegramUser {
        dict["type"] = "user"
        dict["username"] = (user.username as Any?) ?? NSNull()
        dict["first_name"] = (user.firstName as Any?) ?? NSNull()
        dict["last_name"] = (user.lastName as Any?) ?? NSNull()
    } else if let group = peer as? TelegramGroup {
        dict["type"] = "group"
        dict["title"] = group.title
    } else if let channel = peer as? TelegramChannel {
        dict["type"] = channel.isChannel ? "channel" : "supergroup"
        dict["title"] = channel.title
        dict["username"] = (channel.username as Any?) ?? NSNull()
    } else if let secret = peer as? TelegramSecretChat {
        dict["type"] = "secret"
        dict["title"] = "Secret with \(secret.regularPeerId.toInt64())"
    }
    return dict
}

private func errorJSON(_ message: String) -> Data {
    let dict: [String: Any] = ["error": message]
    return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{\"error\":\"unknown\"}".utf8)
}

private func successJSON(_ payload: [String: Any]) -> Data {
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
}

@available(macOS 10.14, *)
func registerTelegramTools(
    server: MCPServer,
    account: Account,
    engine: TelegramEngine,
    openChatProvider: @escaping () -> ((Int64, Int32?) -> Void)? = { nil },
    currentViewProvider: @escaping () -> (() -> [String: Any])? = { nil },
    goBackProvider: @escaping () -> (() -> Bool)? = { nil },
    openUrlProvider: @escaping () -> ((String) -> [String: Any])? = { nil }
) {
    let archiver: MediaArchiving = MediaArchiver(postbox: account.postbox)
    let resolver: PeerLinkResolving = PeerLinkResolver(account: account, engine: engine)

    server.registry.register(makeListDialogsTool(account: account, engine: engine))
    server.registry.register(makeWalkHistoryTool(account: account, engine: engine))
    server.registry.register(makeInspectMessageTool(account: account, engine: engine))
    server.registry.register(makeListButtonsTool(account: account, engine: engine))
    server.registry.register(makeTapButtonTool(account: account, engine: engine))
    server.registry.register(makeResolveTmeLinkTool(resolver: resolver))
    server.registry.register(makeArchiveMessageTool(account: account, engine: engine, resolver: resolver, archiver: archiver))
    server.registry.register(makeGetNewMessagesSinceTool(account: account, engine: engine))
    server.registry.register(makeOpenInAppTool(openChatProvider: openChatProvider))
    server.registry.register(makeGetCurrentViewTool(currentViewProvider: currentViewProvider))
    server.registry.register(makeGoBackTool(goBackProvider: goBackProvider))
    server.registry.register(makeOpenUrlTool(openUrlProvider: openUrlProvider))
}

private func makeGetCurrentViewTool(currentViewProvider: @escaping () -> (() -> [String: Any])?) -> ToolRegistration {
    return ToolRegistration(
        name: "get_current_view",
        description: "Inspect the Telegram macOS app's navigation stack. Returns the top controller's type, the chat peer_id if it's a chat view, and the navigation stack depth. Use this to know what the user is currently looking at before driving the UI further.",
        inputSchemaJSON: "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
        handler: { _, completion in
            guard let provider = currentViewProvider() else {
                completion(.failure(ToolError(message: "current view provider not registered (app not ready)")))
                return
            }
            let info = provider()
            completion(.success(successJSON(info)))
        }
    )
}

private func makeGoBackTool(goBackProvider: @escaping () -> (() -> Bool)?) -> ToolRegistration {
    return ToolRegistration(
        name: "go_back",
        description: "Pop the top of the Telegram macOS app's navigation stack — equivalent to clicking the back arrow. Returns whether a back transition actually happened (false if already at the root).",
        inputSchemaJSON: "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
        handler: { _, completion in
            guard let provider = goBackProvider() else {
                completion(.failure(ToolError(message: "go_back handler not registered")))
                return
            }
            let popped = provider()
            completion(.success(successJSON(["popped": popped])))
        }
    )
}

private func makeOpenUrlTool(openUrlProvider: @escaping () -> ((String) -> [String: Any])?) -> ToolRegistration {
    let schema = """
    {"type":"object","required":["url"],"properties":{"url":{"type":"string"}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "open_url",
        description: "Open an arbitrary URL through Telegram macOS's in-app link handler. Use this for t.me deep links the parser would normally handle on click — e.g. bot-start links like `https://t.me/<bot>?start=<payload>`, joinchat invites, sticker/emoji packs, share/start-app links. Plain `t.me/<user>/<post>` links work too but `open_in_app` with a peer_id is preferred when you already have one.",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            guard let args = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                  let url = args["url"] as? String, !url.isEmpty else {
                completion(.failure(ToolError(message: "open_url requires url (string)")))
                return
            }
            guard let handler = openUrlProvider() else {
                completion(.failure(ToolError(message: "open_url handler not registered (app not fully initialized)")))
                return
            }
            let result = handler(url)
            completion(.success(successJSON(result)))
        }
    )
}

private func makeOpenInAppTool(openChatProvider: @escaping () -> ((Int64, Int32?) -> Void)?) -> ToolRegistration {
    let schema = """
    {"type":"object","required":["peer_id"],"properties":{"peer_id":{"type":"integer"},"message_id":{"type":"integer"}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "open_in_app",
        description: "Bring the Telegram macOS app to the foreground and navigate its UI to the given peer. If `message_id` is supplied, scroll to that message. This tool drives the running app's chat list — useful when you want the user to see what you're inspecting/archiving.",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            guard let args = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                  let peerIdInt = args["peer_id"] as? Int64 ?? (args["peer_id"] as? Int).map(Int64.init) else {
                completion(.failure(ToolError(message: "open_in_app requires peer_id (int)")))
                return
            }
            let messageIdInt = (args["message_id"] as? Int).map(Int32.init)
            guard let handler = openChatProvider() else {
                completion(.failure(ToolError(message: "open_in_app handler not registered (app not fully initialized)")))
                return
            }
            handler(peerIdInt, messageIdInt)
            completion(.success(successJSON(["opened": true, "peer_id": peerIdInt, "message_id": messageIdInt as Any])))
        }
    )
}

// MARK: - list_dialogs

private func makeListDialogsTool(account: Account, engine: TelegramEngine) -> ToolRegistration {
    let schema = """
    {"type":"object","properties":{"limit":{"type":"integer","default":50}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "list_dialogs",
        description: "List recent chats (dialogs) the active Telegram account participates in. Returns peer ids, titles, and types so you can pick a group to archive.",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            let args = (try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any]) ?? [:]
            let limit = (args["limit"] as? Int) ?? 50
            let listSignal = account.viewTracker.tailChatListView(groupId: .root, count: limit) |> take(1)
            _ = listSignal.start(next: { view, _ in
                var dialogs: [[String: Any]] = []
                for entry in view.entries.reversed() {
                    switch entry {
                    case let .MessageEntry(entryData):
                        if let peer = entryData.renderedPeer.chatMainPeer {
                            var item = peerSummary(peer)
                            item["unread_count"] = entryData.readState?.state.count ?? 0
                            dialogs.append(item)
                        }
                    case .HoleEntry:
                        continue
                    }
                }
                completion(.success(successJSON(["dialogs": dialogs])))
            })
        }
    )
}

// MARK: - walk_history

private func makeWalkHistoryTool(account: Account, engine: TelegramEngine) -> ToolRegistration {
    let schema = """
    {"type":"object","required":["peer_id","session_id"],"properties":{"peer_id":{"type":"integer"},"session_id":{"type":"string"},"limit":{"type":"integer","default":100}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "walk_history",
        description: "Paginate through a chat's message history from newest to oldest. Pass a stable session_id of your choosing; the server uses it to track pagination state. Subsequent calls with the same session_id return older batches. Each message also includes post_id/post_caption/post_media_count fields: messages sharing post_id are siblings in one album, post_caption is the caption shared across the album, post_media_count is the total media items in the album. Posts are clustered by groupingKey when present, else by a 10-second timestamp window over consecutive media-bearing messages.",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            guard let args = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                  let peerIdInt = args["peer_id"] as? Int64 ?? (args["peer_id"] as? Int).map(Int64.init),
                  let sessionId = args["session_id"] as? String else {
                completion(.failure(ToolError(message: "walk_history requires peer_id (int) and session_id (string)")))
                return
            }
            let limit = (args["limit"] as? Int).map(Int32.init) ?? 100
            let peerId = PeerId(peerIdInt)
            let snapshot = walkSessions.snapshot(sessionId: sessionId, expectedPeer: peerId)
            let priorState = snapshot?.state
            let priorReturnedCount = snapshot?.returnedCount ?? 0
            let location: SearchMessagesLocation = .peer(peerId: peerId, fromId: nil, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil)
            _ = engine.messages.searchMessages(location: location, query: "", state: priorState, limit: limit).start(next: { result, nextState in
                let allMessages = result.messages
                let newSlice: [Message]
                if priorReturnedCount < allMessages.count {
                    newSlice = Array(allMessages[priorReturnedCount...])
                } else {
                    newSlice = []
                }
                walkSessions.put(sessionId: sessionId, peerId: peerId, state: nextState, returnedCount: allMessages.count)
                let postAssignments = clusterPosts(newSlice)
                let summaries = newSlice.enumerated().map { index, message -> [String: Any] in
                    var dict = messageSummary(message)
                    if let post = postAssignments[index] {
                        dict["post_id"] = post.postId
                        dict["post_caption"] = post.caption
                        dict["post_media_count"] = post.mediaCount
                    }
                    return dict
                }
                let payload: [String: Any] = [
                    "messages": summaries,
                    "completed": result.completed || newSlice.isEmpty,
                    "session_id": sessionId,
                ]
                completion(.success(successJSON(payload)))
            })
        }
    )
}

// MARK: - inspect_message

private func makeInspectMessageTool(account: Account, engine: TelegramEngine) -> ToolRegistration {
    let schema = """
    {"type":"object","required":["peer_id","message_id"],"properties":{"peer_id":{"type":"integer"},"message_id":{"type":"integer"}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "inspect_message",
        description: "Inspect a single message: returns its qualifying media (photos, non-GIF/non-voice/non-instant videos) and any outgoing URLs found in text entities.",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            guard let args = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                  let peerIdInt = args["peer_id"] as? Int64 ?? (args["peer_id"] as? Int).map(Int64.init),
                  let messageIdInt = args["message_id"] as? Int else {
                completion(.failure(ToolError(message: "inspect_message requires peer_id and message_id")))
                return
            }
            let peerId = PeerId(peerIdInt)
            let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(messageIdInt))
            _ = engine.messages.downloadMessage(messageId: messageId).start(next: { message in
                guard let message = message else {
                    completion(.success(successJSON(["found": false])))
                    return
                }
                let inspection = MessageInspector.inspect(message)
                var mediaList: [[String: Any]] = []
                for media in inspection.directMedia {
                    if let image = media as? TelegramMediaImage {
                        mediaList.append(["type": "photo", "id": image.imageId.id])
                    } else if let file = media as? TelegramMediaFile {
                        mediaList.append([
                            "type": "video",
                            "id": file.fileId.id,
                            "size": (file.size as Any?) ?? NSNull(),
                            "file_name": (file.fileName as Any?) ?? NSNull(),
                        ])
                    }
                }
                let payload: [String: Any] = [
                    "found": true,
                    "direct_media": mediaList,
                    "outgoing_urls": inspection.outgoingUrls,
                    "summary": messageSummary(message),
                ]
                completion(.success(successJSON(payload)))
            })
        }
    )
}

// MARK: - list_buttons / tap_button

private func buttonActionDescriptor(_ action: ReplyMarkupButtonAction) -> [String: Any] {
    switch action {
    case .text:
        return ["kind": "text"]
    case let .url(url):
        return ["kind": "url", "url": url]
    case let .callback(requiresPassword, data):
        let bytes = Data(bytes: data.memory, count: data.length)
        return ["kind": "callback", "requires_password": requiresPassword, "data_base64": bytes.base64EncodedString(), "data_length": data.length]
    case .requestPhone:
        return ["kind": "requestPhone"]
    case .requestMap:
        return ["kind": "requestMap"]
    case let .switchInline(samePeer, query, _):
        return ["kind": "switchInline", "same_peer": samePeer, "query": query]
    case .openWebApp:
        return ["kind": "openWebApp"]
    case .payment:
        return ["kind": "payment"]
    case let .urlAuth(url, buttonId):
        return ["kind": "urlAuth", "url": url, "button_id": buttonId]
    case .setupPoll:
        return ["kind": "setupPoll"]
    case let .openUserProfile(peerId):
        return ["kind": "openUserProfile", "peer_id": peerId.toInt64()]
    case let .openWebView(url, simple):
        return ["kind": "openWebView", "url": url, "simple": simple]
    case .requestPeer:
        return ["kind": "requestPeer"]
    case let .copyText(payload):
        return ["kind": "copyText", "payload": payload]
    }
}

private func makeListButtonsTool(account: Account, engine: TelegramEngine) -> ToolRegistration {
    let schema = """
    {"type":"object","required":["peer_id","message_id"],"properties":{"peer_id":{"type":"integer"},"message_id":{"type":"integer"}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "list_buttons",
        description: "List the inline-keyboard buttons attached to a bot message. Returns a 2D layout (rows × buttons) where each entry has the button title and its action descriptor (callback data is base64). Use this before tap_button to discover what's tappable.",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            guard let args = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                  let peerIdInt = args["peer_id"] as? Int64 ?? (args["peer_id"] as? Int).map(Int64.init),
                  let messageIdInt = args["message_id"] as? Int else {
                completion(.failure(ToolError(message: "list_buttons requires peer_id and message_id")))
                return
            }
            let peerId = PeerId(peerIdInt)
            let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(messageIdInt))
            _ = engine.messages.downloadMessage(messageId: messageId).start(next: { message in
                guard let message = message else {
                    completion(.success(successJSON(["found": false])))
                    return
                }
                guard let markup = message.attributes.first(where: { $0 is ReplyMarkupMessageAttribute }) as? ReplyMarkupMessageAttribute else {
                    completion(.success(successJSON(["found": true, "has_markup": false])))
                    return
                }
                var rowsOut: [[[String: Any]]] = []
                for row in markup.rows {
                    var btns: [[String: Any]] = []
                    for btn in row.buttons {
                        var entry: [String: Any] = ["title": btn.title]
                        entry.merge(buttonActionDescriptor(btn.action)) { _, new in new }
                        btns.append(entry)
                    }
                    rowsOut.append(btns)
                }
                let payload: [String: Any] = [
                    "found": true,
                    "has_markup": true,
                    "rows": rowsOut,
                    "is_inline": markup.flags.contains(.inline)
                ]
                completion(.success(successJSON(payload)))
            })
        }
    )
}

private func makeTapButtonTool(account: Account, engine: TelegramEngine) -> ToolRegistration {
    let schema = """
    {"type":"object","required":["peer_id","message_id","row","col"],"properties":{"peer_id":{"type":"integer"},"message_id":{"type":"integer"},"row":{"type":"integer"},"col":{"type":"integer"}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "tap_button",
        description: "Tap an inline-keyboard callback button on a bot message by row/col indices (0-based). Triggers a callback_query and returns the bot's response (none/alert/toast/url). Only callback buttons are supported; URL/webview/payment buttons return an error.",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            guard let args = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                  let peerIdInt = args["peer_id"] as? Int64 ?? (args["peer_id"] as? Int).map(Int64.init),
                  let messageIdInt = args["message_id"] as? Int,
                  let row = args["row"] as? Int,
                  let col = args["col"] as? Int else {
                completion(.failure(ToolError(message: "tap_button requires peer_id, message_id, row, col")))
                return
            }
            let peerId = PeerId(peerIdInt)
            let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(messageIdInt))
            _ = engine.messages.downloadMessage(messageId: messageId).start(next: { message in
                guard let message = message else {
                    completion(.failure(ToolError(message: "message not found")))
                    return
                }
                guard let markup = message.attributes.first(where: { $0 is ReplyMarkupMessageAttribute }) as? ReplyMarkupMessageAttribute else {
                    completion(.failure(ToolError(message: "message has no inline keyboard")))
                    return
                }
                guard row >= 0, row < markup.rows.count else {
                    completion(.failure(ToolError(message: "row out of range; rows=\(markup.rows.count)")))
                    return
                }
                let buttons = markup.rows[row].buttons
                guard col >= 0, col < buttons.count else {
                    completion(.failure(ToolError(message: "col out of range; cols=\(buttons.count) in row \(row)")))
                    return
                }
                let button = buttons[col]
                guard case let .callback(_, data) = button.action else {
                    let desc = buttonActionDescriptor(button.action)
                    completion(.failure(ToolError(message: "button[\(row),\(col)] is not a callback button: \(desc)")))
                    return
                }
                _ = engine.messages.requestMessageActionCallback(messageId: messageId, isGame: false, password: nil, data: data).start(next: { result in
                    var payload: [String: Any] = ["tapped": true, "title": button.title]
                    switch result {
                    case .none:
                        payload["result_kind"] = "none"
                    case let .alert(text):
                        payload["result_kind"] = "alert"; payload["text"] = text
                    case let .toast(text):
                        payload["result_kind"] = "toast"; payload["text"] = text
                    case let .url(url):
                        payload["result_kind"] = "url"; payload["url"] = url
                    }
                    completion(.success(successJSON(payload)))
                }, error: { err in
                    completion(.failure(ToolError(message: "callback failed: \(err)")))
                })
            })
        }
    )
}

// MARK: - resolve_tme_link

private func makeResolveTmeLinkTool(resolver: PeerLinkResolving) -> ToolRegistration {
    let schema = """
    {"type":"object","required":["url"],"properties":{"url":{"type":"string"}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "resolve_tme_link",
        description: "Resolve a t.me/<user>/<id> or t.me/c/<chan>/<id> link to a (peer_id, message) pair. Returns the message if accessible, or an error reason if the chat is private or the message is gone.",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            guard let args = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                  let url = args["url"] as? String else {
                completion(.failure(ToolError(message: "resolve_tme_link requires url (string)")))
                return
            }
            guard let ref = TmeLinkParser.parse(url) else {
                completion(.success(successJSON(["resolved": false, "error": "url-not-recognized"])))
                return
            }
            _ = resolver.resolve(ref).start(next: { result in
                switch result {
                case let .success(linked):
                    let payload: [String: Any] = [
                        "resolved": true,
                        "peer": peerSummary(linked.peer),
                        "message": messageSummary(linked.message),
                    ]
                    completion(.success(successJSON(payload)))
                case let .failure(err):
                    let reason: String
                    switch err {
                    case .notFound: reason = "peer-not-found"
                    case .noAccess: reason = "no-access"
                    case .messageMissing: reason = "message-missing"
                    }
                    completion(.success(successJSON(["resolved": false, "error": reason])))
                }
            })
        }
    )
}

// MARK: - archive_message

private func makeArchiveMessageTool(account: Account, engine: TelegramEngine, resolver: PeerLinkResolving, archiver: MediaArchiving) -> ToolRegistration {
    let schema = """
    {"type":"object","required":["peer_id","message_id","peer_title"],"properties":{"peer_id":{"type":"integer"},"message_id":{"type":"integer"},"peer_title":{"type":"string"},"follow_links":{"type":"boolean","default":true},"root_folder":{"type":"string","description":"Absolute path to the archive root. Defaults to ~/Downloads/TelegramAutoSave. Tilde and environment variables are NOT expanded; pass an absolute path."}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "archive_message",
        description: "Download all qualifying media from a single message and save into <root_folder>/<peer_title>/<msg_or_album>/. Also writes message.txt containing the message's text (or empty if none). If follow_links is true (default), also resolves t.me links in the text and archives media from the linked message into the same folder. Returns saved paths and skipped link reasons.",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            guard let args = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                  let peerIdInt = args["peer_id"] as? Int64 ?? (args["peer_id"] as? Int).map(Int64.init),
                  let messageIdInt = args["message_id"] as? Int,
                  let peerTitle = args["peer_title"] as? String else {
                completion(.failure(ToolError(message: "archive_message requires peer_id, message_id, peer_title")))
                return
            }
            let followLinks = (args["follow_links"] as? Bool) ?? true
            let archiveRootOverride = args["root_folder"] as? String
            let peerId = PeerId(peerIdInt)
            let originMessageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(messageIdInt))

            _ = engine.messages.downloadMessage(messageId: originMessageId).start(next: { originMessage in
                guard let originMessage = originMessage else {
                    completion(.success(successJSON(["found": false])))
                    return
                }
                runArchive(
                    originMessage: originMessage,
                    peerTitle: peerTitle,
                    originPeerId: peerId,
                    followLinks: followLinks,
                    archiveRootOverride: archiveRootOverride,
                    account: account,
                    engine: engine,
                    resolver: resolver,
                    archiver: archiver,
                    completion: completion
                )
            })
        }
    )
}

private func runArchive(originMessage: Message, peerTitle: String, originPeerId: PeerId, followLinks: Bool, archiveRootOverride: String?, account: Account, engine: TelegramEngine, resolver: PeerLinkResolving, archiver: MediaArchiving, completion: @escaping (Result<Data, ToolError>) -> Void) {
    let inspection = MessageInspector.inspect(originMessage)
    let originGroupingKey = originMessage.groupingKey
    let effectiveRoot = archiveRootOverride ?? PathHelpers.defaultArchiveRoot()

    // Write message.txt (always, even if no media — text-only messages get a folder too).
    let destinationDir = PathHelpers.archiveDirectory(
        root: effectiveRoot,
        peerTitle: peerTitle,
        peerId: originPeerId.toInt64(),
        messageId: originMessage.id.id,
        groupingKey: originGroupingKey,
        timestamp: originMessage.timestamp
    )
    try? FileManager.default.createDirectory(atPath: destinationDir, withIntermediateDirectories: true, attributes: nil)
    let messageTxtPath = "\(destinationDir)/message.txt"
    // Only write/overwrite when this message has text. For album siblings without a
    // caption, leave any existing message.txt intact (the caption-bearing sibling wins).
    if !originMessage.text.isEmpty {
        try? originMessage.text.write(toFile: messageTxtPath, atomically: true, encoding: .utf8)
    }

    let saveTargets = inspection.directMedia.map { (media: Media) -> ArchiveRequest in
        ArchiveRequest(
            media: media,
            mediaReference: .message(message: MessageReference(originMessage), media: media),
            peerTitle: peerTitle,
            originPeerId: originPeerId,
            originMessageId: originMessage.id,
            originGroupingKey: originGroupingKey,
            originTimestamp: originMessage.timestamp,
            archiveRootOverride: archiveRootOverride
        )
    }

    let saved = Atomic<[String]>(value: [])
    let skipped = Atomic<[[String: Any]]>(value: [])

    let directSignals: [Signal<Void, NoError>] = saveTargets.map { request in
        return prepareAndArchive(request: request, account: account, archiver: archiver)
        |> map { path in
            if let path = path {
                _ = saved.modify { current in
                    var copy = current
                    copy.append(path)
                    return copy
                }
            }
        }
    }

    var linkSignals: [Signal<Void, NoError>] = []
    if followLinks {
        for url in inspection.outgoingUrls {
            guard let ref = TmeLinkParser.parse(url) else { continue }
            let signal = resolver.resolve(ref)
            |> mapToSignal { result -> Signal<Void, NoError> in
                switch result {
                case let .success(linked):
                    let linkedInspection = MessageInspector.inspect(linked.message)
                    let nestedRequests = linkedInspection.directMedia.map { (media: Media) -> ArchiveRequest in
                        ArchiveRequest(
                            media: media,
                            mediaReference: .message(message: MessageReference(linked.message), media: media),
                            peerTitle: peerTitle,
                            originPeerId: originPeerId,
                            originMessageId: originMessage.id,
                            originGroupingKey: originGroupingKey,
                            originTimestamp: originMessage.timestamp,
                            archiveRootOverride: archiveRootOverride
                        )
                    }
                    if nestedRequests.isEmpty {
                        _ = skipped.modify { current in
                            var copy = current
                            copy.append(["url": url, "reason": "linked-message-has-no-qualifying-media"])
                            return copy
                        }
                        return .single(())
                    }
                    let nestedSignals: [Signal<Void, NoError>] = nestedRequests.map { req in
                        prepareAndArchive(request: req, account: account, archiver: archiver)
                        |> map { path in
                            if let path = path {
                                _ = saved.modify { current in
                                    var copy = current
                                    copy.append(path)
                                    return copy
                                }
                            }
                        }
                    }
                    return combineLatest(nestedSignals) |> map { _ in () }
                case let .failure(err):
                    let reason: String
                    switch err {
                    case .notFound: reason = "peer-not-found"
                    case .noAccess: reason = "no-access"
                    case .messageMissing: reason = "message-missing"
                    }
                    archiver.logSkipped(peerTitle: peerTitle, peerId: originPeerId, originMessageId: originMessage.id, reason: reason, link: url, archiveRootOverride: archiveRootOverride)
                    _ = skipped.modify { current in
                        var copy = current
                        copy.append(["url": url, "reason": reason])
                        return copy
                    }
                    return .single(())
                }
            }
            linkSignals.append(signal)
        }
    }

    let allSignals = directSignals + linkSignals
    if allSignals.isEmpty {
        let payload: [String: Any] = ["saved_paths": saved.with { $0 }, "skipped": skipped.with { $0 }, "message_txt": messageTxtPath]
        completion(.success(successJSON(payload)))
        return
    }

    _ = combineLatest(allSignals).start(completed: {
        let payload: [String: Any] = ["saved_paths": saved.with { $0 }, "skipped": skipped.with { $0 }, "message_txt": messageTxtPath]
        completion(.success(successJSON(payload)))
    })
}

private func prepareAndArchive(request: ArchiveRequest, account: Account, archiver: MediaArchiving) -> Signal<String?, NoError> {
    guard case let .message(messageReference, _) = request.mediaReference else {
        return .single(nil)
    }

    let userLocation: MediaResourceUserLocation
    let userContentType: MediaResourceUserContentType
    let reference: MediaResourceReference
    let statsCategory: MediaResourceStatsCategory

    if let image = request.media as? TelegramMediaImage,
       let largest = largestImageRepresentation(image.representations) {
        let imageRef = ImageMediaReference.message(message: messageReference, media: image)
        userLocation = imageRef.userLocation
        userContentType = imageRef.userContentType
        reference = imageRef.resourceReference(largest.resource)
        statsCategory = .image
    } else if let file = request.media as? TelegramMediaFile {
        let fileRef = FileMediaReference.message(message: messageReference, media: file)
        userLocation = fileRef.userLocation
        userContentType = fileRef.userContentType
        reference = fileRef.resourceReference(file.resource)
        statsCategory = .video
    } else {
        return .single(nil)
    }

    let fetchSignal: Signal<FetchResourceSourceType, NoError> = fetchedMediaResource(
        mediaBox: account.postbox.mediaBox,
        userLocation: userLocation,
        userContentType: userContentType,
        reference: reference,
        statsCategory: statsCategory,
        reportResultStatus: false
    ) |> `catch` { _ in return .complete() }

    return Signal<String?, NoError> { subscriber in
        let disposables = DisposableSet()
        disposables.add(fetchSignal.start())
        disposables.add(archiver.archive(request).start(next: { path in
            subscriber.putNext(path)
        }, completed: {
            subscriber.putCompletion()
        }))
        return disposables
    }
}

// MARK: - get_new_messages_since

private func makeGetNewMessagesSinceTool(account: Account, engine: TelegramEngine) -> ToolRegistration {
    let schema = """
    {"type":"object","required":["peer_id","after_message_id"],"properties":{"peer_id":{"type":"integer"},"after_message_id":{"type":"integer"},"limit":{"type":"integer","default":50}},"additionalProperties":false}
    """
    return ToolRegistration(
        name: "get_new_messages_since",
        description: "Returns up to `limit` messages in `peer_id` whose id is greater than `after_message_id`. Returns immediately (poll-based; for live monitoring, call repeatedly).",
        inputSchemaJSON: schema,
        handler: { argsJSON, completion in
            guard let args = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
                  let peerIdInt = args["peer_id"] as? Int64 ?? (args["peer_id"] as? Int).map(Int64.init),
                  let afterMessageId = args["after_message_id"] as? Int else {
                completion(.failure(ToolError(message: "get_new_messages_since requires peer_id and after_message_id")))
                return
            }
            let limit = (args["limit"] as? Int).map(Int32.init) ?? 50
            let peerId = PeerId(peerIdInt)
            let location: SearchMessagesLocation = .peer(peerId: peerId, fromId: nil, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil)
            _ = engine.messages.searchMessages(location: location, query: "", state: nil, limit: limit).start(next: { result, _ in
                let filtered = result.messages.filter { $0.id.id > Int32(afterMessageId) }
                let summaries = filtered.map(messageSummary)
                completion(.success(successJSON(["messages": summaries])))
            })
        }
    )
}
