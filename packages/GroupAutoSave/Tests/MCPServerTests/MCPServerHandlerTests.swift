import XCTest
@testable import MCPServer

final class MCPServerHandlerTests: XCTestCase {
    private let token = "test-token-123"
    private let info = MCPServerInfo(name: "test-server", version: "0.0.1")

    private func makeRegistry() -> ToolRegistry {
        let registry = ToolRegistry()
        registry.register(ToolRegistration(
            name: "echo",
            description: "echo back",
            inputSchemaJSON: "{\"type\":\"object\"}",
            handler: { argsJSON, completion in
                completion(.success(argsJSON))
            }
        ))
        registry.register(ToolRegistration(
            name: "fail",
            description: "always errors",
            inputSchemaJSON: "{\"type\":\"object\"}",
            handler: { _, completion in
                completion(.failure(ToolError(message: "boom")))
            }
        ))
        return registry
    }

    private func handle(_ httpRequest: HTTPRequest) -> HTTPResponse {
        let exp = expectation(description: "response")
        var captured: HTTPResponse?
        MCPServer.handle(request: httpRequest, token: self.token, info: self.info, registry: makeRegistry()) { response in
            captured = response
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        return captured!
    }

    private func mcpRequest(method: String, body: String, authorized: Bool = true) -> HTTPRequest {
        var headers: [String: String] = ["Content-Type": "application/json"]
        if authorized {
            headers["Authorization"] = "Bearer \(token)"
        }
        return HTTPRequest(method: method, path: "/mcp", headers: headers, body: Data(body.utf8))
    }

    func testGetHealth_ok() {
        let req = HTTPRequest(method: "GET", path: "/health", headers: [:], body: Data())
        let res = handle(req)
        XCTAssertEqual(res.status, 200)
        XCTAssertEqual(String(data: res.body, encoding: .utf8), "ok")
    }

    func testRejectsNonPost() {
        let req = HTTPRequest(method: "GET", path: "/mcp", headers: [:], body: Data())
        let res = handle(req)
        XCTAssertEqual(res.status, 405)
    }

    func testRejectsUnknownPath() {
        let req = HTTPRequest(method: "POST", path: "/somethingelse", headers: ["Authorization": "Bearer \(token)"], body: Data("{}".utf8))
        let res = handle(req)
        XCTAssertEqual(res.status, 404)
    }

    func testRejectsMissingAuth() {
        let req = mcpRequest(method: "POST", body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", authorized: false)
        let res = handle(req)
        XCTAssertEqual(res.status, 401)
    }

    func testRejectsBadJSON() throws {
        let req = mcpRequest(method: "POST", body: "not json")
        let res = handle(req)
        XCTAssertEqual(res.status, 200)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        let err = try XCTUnwrap(dict["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, JSONRPCError.parseError.rawValue)
    }

    func testInitialize_returnsServerInfo() throws {
        let req = mcpRequest(method: "POST", body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")
        let res = handle(req)
        XCTAssertEqual(res.status, 200)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        XCTAssertEqual(dict["id"] as? Int, 1)
        let result = try XCTUnwrap(dict["result"] as? [String: Any])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "test-server")
        XCTAssertNotNil(result["protocolVersion"])
    }

    func testToolsList_includesRegisteredTools() throws {
        let req = mcpRequest(method: "POST", body: "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
        let res = handle(req)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        let result = try XCTUnwrap(dict["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["echo", "fail"])
    }

    func testToolsCall_success_echoesArgs() throws {
        let body = """
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"x":42}}}
        """
        let res = handle(mcpRequest(method: "POST", body: body))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        let result = try XCTUnwrap(dict["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let inner = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(inner["x"] as? Int, 42)
    }

    func testToolsCall_unknownTool_returnsError() throws {
        let body = """
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"unknown","arguments":{}}}
        """
        let res = handle(mcpRequest(method: "POST", body: body))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        let err = try XCTUnwrap(dict["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, JSONRPCError.methodNotFound.rawValue)
    }

    func testToolsCall_failureReturnsIsError() throws {
        let body = """
        {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"fail","arguments":{}}}
        """
        let res = handle(mcpRequest(method: "POST", body: body))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        let result = try XCTUnwrap(dict["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "boom")
    }

    func testUnknownMethod_returnsMethodNotFound() throws {
        let body = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"nonsense\"}"
        let res = handle(mcpRequest(method: "POST", body: body))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        let err = try XCTUnwrap(dict["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, JSONRPCError.methodNotFound.rawValue)
    }
}
