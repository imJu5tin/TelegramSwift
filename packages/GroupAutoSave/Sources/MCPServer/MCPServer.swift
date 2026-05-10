import Foundation

public struct MCPServerInfo {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

@available(macOS 10.14, *)
public final class MCPServer {
    public let registry: ToolRegistry
    public let info: MCPServerInfo

    private let token: String
    private let server: HTTPServer
    private var listenedPort: UInt16?

    public init(info: MCPServerInfo, token: String = BearerToken.loadOrGenerate()) {
        self.info = info
        self.token = token
        self.registry = ToolRegistry()
        let registry = self.registry
        let serverInfo = info
        let bearerToken = self.token
        self.server = HTTPServer { request, complete in
            MCPServer.handle(request: request, token: bearerToken, info: serverInfo, registry: registry, complete: complete)
        }
    }

    public func start(port: UInt16 = 0) throws -> UInt16 {
        let p = try self.server.start(port: port)
        self.listenedPort = p
        return p
    }

    public func stop() {
        self.server.stop()
        self.listenedPort = nil
    }

    public var port: UInt16? { self.listenedPort }

    public var bearerToken: String { self.token }

    static func handle(request: HTTPRequest, token: String, info: MCPServerInfo, registry: ToolRegistry, complete: @escaping (HTTPResponse) -> Void) {
        if request.method == "GET" && request.path == "/health" {
            complete(HTTPResponse.plain(status: 200, message: "ok"))
            return
        }
        guard request.method == "POST" else {
            complete(HTTPResponse.plain(status: 405, message: "only POST is supported"))
            return
        }
        guard request.path == "/mcp" else {
            complete(HTTPResponse.plain(status: 404, message: "unknown path"))
            return
        }
        let providedToken = BearerToken.extractFromAuthorizationHeader(request.header("Authorization"))
        guard let providedToken = providedToken, BearerToken.constantTimeEquals(providedToken, token) else {
            complete(HTTPResponse.plain(status: 401, message: "missing or invalid bearer token"))
            return
        }
        let body = request.body
        let parsed: JSONRPCRequest
        do {
            parsed = try JSONDecoder().decode(JSONRPCRequest.self, from: body)
        } catch {
            let env = JSONRPCResponseEnvelope(id: nil, error: JSONRPCErrorPayload(.parseError, message: "JSON parse error: \(error)"))
            complete(HTTPResponse.json(status: 200, body: (try? env.encode()) ?? Data()))
            return
        }
        MCPServer.dispatch(jsonrpcRequest: parsed, info: info, registry: registry, complete: complete)
    }

    static func dispatch(jsonrpcRequest req: JSONRPCRequest, info: MCPServerInfo, registry: ToolRegistry, complete: @escaping (HTTPResponse) -> Void) {
        switch req.method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2025-06-18",
                "capabilities": [
                    "tools": [:],
                ],
                "serverInfo": [
                    "name": info.name,
                    "version": info.version,
                ],
            ]
            sendResult(id: req.id, result: result, complete: complete)
        case "notifications/initialized":
            complete(HTTPResponse.plain(status: 200, message: ""))
        case "tools/list":
            let resultData = registry.toolListJSON()
            if let id = req.id, let env = try? JSONRPCResponseEnvelope(id: id, result: resultData).encode() {
                complete(HTTPResponse.json(body: env))
            } else if let env = try? JSONRPCResponseEnvelope(id: nil, result: resultData).encode() {
                complete(HTTPResponse.json(body: env))
            } else {
                complete(HTTPResponse.plain(status: 500, message: "encode failed"))
            }
        case "tools/call":
            handleToolCall(req: req, registry: registry, complete: complete)
        case "ping":
            sendResult(id: req.id, result: [String: Any](), complete: complete)
        default:
            sendError(id: req.id, kind: .methodNotFound, message: "Unknown method: \(req.method)", complete: complete)
        }
    }

    static func handleToolCall(req: JSONRPCRequest, registry: ToolRegistry, complete: @escaping (HTTPResponse) -> Void) {
        guard let paramsData = req.params,
              let paramsAny = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any] else {
            sendError(id: req.id, kind: .invalidParams, message: "tools/call requires object params", complete: complete)
            return
        }
        guard let toolName = paramsAny["name"] as? String else {
            sendError(id: req.id, kind: .invalidParams, message: "tools/call requires 'name'", complete: complete)
            return
        }
        guard let tool = registry.tool(named: toolName) else {
            sendError(id: req.id, kind: .methodNotFound, message: "Tool not found: \(toolName)", complete: complete)
            return
        }
        let argsAny = paramsAny["arguments"] as? [String: Any] ?? [:]
        let argsData = (try? JSONSerialization.data(withJSONObject: argsAny, options: [])) ?? Data("{}".utf8)
        tool.handler(argsData) { result in
            switch result {
            case .success(let resultJSON):
                let textContent: [String: Any] = [
                    "type": "text",
                    "text": String(data: resultJSON, encoding: .utf8) ?? "",
                ]
                let payload: [String: Any] = [
                    "content": [textContent],
                    "isError": false,
                ]
                sendResult(id: req.id, result: payload, complete: complete)
            case .failure(let toolError):
                let textContent: [String: Any] = [
                    "type": "text",
                    "text": toolError.message,
                ]
                let payload: [String: Any] = [
                    "content": [textContent],
                    "isError": true,
                ]
                sendResult(id: req.id, result: payload, complete: complete)
            }
        }
    }

    static func sendResult(id: JSONRPCID?, result: Any, complete: @escaping (HTTPResponse) -> Void) {
        do {
            let resultData = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
            let env = JSONRPCResponseEnvelope(id: id, result: resultData)
            let body = try env.encode()
            complete(HTTPResponse.json(body: body))
        } catch {
            sendError(id: id, kind: .internalError, message: "result encode failed", complete: complete)
        }
    }

    static func sendError(id: JSONRPCID?, kind: JSONRPCError, message: String, complete: @escaping (HTTPResponse) -> Void) {
        let env = JSONRPCResponseEnvelope(id: id, error: JSONRPCErrorPayload(kind, message: message))
        let body = (try? env.encode()) ?? Data("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"encode failed\"}}".utf8)
        complete(HTTPResponse.json(body: body))
    }
}
