import XCTest
@testable import MCPServer

final class ToolRegistryTests: XCTestCase {
    func testRegisterAndLookup() {
        let registry = ToolRegistry()
        let tool = ToolRegistration(
            name: "echo",
            description: "echo back input",
            inputSchemaJSON: "{\"type\":\"object\"}",
            handler: { _, completion in completion(.success(Data("{}".utf8))) }
        )
        registry.register(tool)
        XCTAssertNotNil(registry.tool(named: "echo"))
        XCTAssertNil(registry.tool(named: "nonexistent"))
    }

    func testToolListJSON_includesAllTools() throws {
        let registry = ToolRegistry()
        registry.register(ToolRegistration(
            name: "alpha",
            description: "first",
            inputSchemaJSON: "{\"type\":\"object\"}",
            handler: { _, completion in completion(.success(Data("{}".utf8))) }
        ))
        registry.register(ToolRegistration(
            name: "beta",
            description: "second",
            inputSchemaJSON: "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\"}}}",
            handler: { _, completion in completion(.success(Data("{}".utf8))) }
        ))
        let json = registry.toolListJSON()
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let tools = try XCTUnwrap(dict["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0]["name"] as? String, "alpha")
        XCTAssertEqual(tools[1]["name"] as? String, "beta")
        let betaSchema = try XCTUnwrap(tools[1]["inputSchema"] as? [String: Any])
        let props = try XCTUnwrap(betaSchema["properties"] as? [String: Any])
        XCTAssertNotNil(props["x"])
    }

    func testToolListJSON_sortedAlphabetically() throws {
        let registry = ToolRegistry()
        for name in ["zulu", "alpha", "mike"] {
            registry.register(ToolRegistration(
                name: name,
                description: "_",
                inputSchemaJSON: "{\"type\":\"object\"}",
                handler: { _, completion in completion(.success(Data("{}".utf8))) }
            ))
        }
        let json = registry.toolListJSON()
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let tools = try XCTUnwrap(dict["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["alpha", "mike", "zulu"])
    }

    func testUnregister() {
        let registry = ToolRegistry()
        registry.register(ToolRegistration(
            name: "tmp", description: "tmp",
            inputSchemaJSON: "{\"type\":\"object\"}",
            handler: { _, completion in completion(.success(Data("{}".utf8))) }
        ))
        XCTAssertNotNil(registry.tool(named: "tmp"))
        registry.unregister(name: "tmp")
        XCTAssertNil(registry.tool(named: "tmp"))
    }

    func testHandler_invokedWithArgs() {
        let registry = ToolRegistry()
        var receivedArgs: Data?
        let exp = expectation(description: "handler called")
        registry.register(ToolRegistration(
            name: "capture",
            description: "_",
            inputSchemaJSON: "{\"type\":\"object\"}",
            handler: { argsJSON, completion in
                receivedArgs = argsJSON
                completion(.success(Data("{\"ok\":true}".utf8)))
                exp.fulfill()
            }
        ))
        let tool = registry.tool(named: "capture")!
        tool.handler(Data("{\"x\":1}".utf8)) { _ in }
        wait(for: [exp], timeout: 1.0)
        let received = try? JSONSerialization.jsonObject(with: receivedArgs ?? Data()) as? [String: Any]
        XCTAssertEqual(received?["x"] as? Int, 1)
    }
}
