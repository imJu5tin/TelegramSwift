import XCTest
@testable import MCPServer

final class JSONRPCTests: XCTestCase {
    func testIDDecoding_string() throws {
        let json = Data("\"abc\"".utf8)
        let id = try JSONDecoder().decode(JSONRPCID.self, from: json)
        XCTAssertEqual(id, .string("abc"))
    }

    func testIDDecoding_int() throws {
        let json = Data("42".utf8)
        let id = try JSONDecoder().decode(JSONRPCID.self, from: json)
        XCTAssertEqual(id, .int(42))
    }

    func testIDDecoding_null() throws {
        let json = Data("null".utf8)
        let id = try JSONDecoder().decode(JSONRPCID.self, from: json)
        XCTAssertEqual(id, .null)
    }

    func testRequestDecoding_withParams() throws {
        let json = Data("""
        {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"foo","arguments":{"x":1}}}
        """.utf8)
        let req = try JSONDecoder().decode(JSONRPCRequest.self, from: json)
        XCTAssertEqual(req.jsonrpc, "2.0")
        XCTAssertEqual(req.id, .int(7))
        XCTAssertEqual(req.method, "tools/call")
        XCTAssertNotNil(req.params)
    }

    func testRequestDecoding_noParams() throws {
        let json = Data("""
        {"jsonrpc":"2.0","id":1,"method":"ping"}
        """.utf8)
        let req = try JSONDecoder().decode(JSONRPCRequest.self, from: json)
        XCTAssertEqual(req.method, "ping")
        XCTAssertNil(req.params)
    }

    func testResponseEncoding_result() throws {
        let resultJSON = Data("{\"hello\":\"world\"}".utf8)
        let env = JSONRPCResponseEnvelope(id: .int(5), result: resultJSON)
        let data = try env.encode()
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(dict["id"] as? Int, 5)
        let result = try XCTUnwrap(dict["result"] as? [String: Any])
        XCTAssertEqual(result["hello"] as? String, "world")
        XCTAssertNil(dict["error"])
    }

    func testResponseEncoding_error() throws {
        let env = JSONRPCResponseEnvelope(id: .string("req-1"), error: JSONRPCErrorPayload(.methodNotFound, message: "no such method"))
        let data = try env.encode()
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["id"] as? String, "req-1")
        let err = try XCTUnwrap(dict["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, JSONRPCError.methodNotFound.rawValue)
        XCTAssertEqual(err["message"] as? String, "no such method")
        XCTAssertNil(dict["result"])
    }

    func testResponseEncoding_nilIdEncodesNull() throws {
        let env = JSONRPCResponseEnvelope(id: nil, error: JSONRPCErrorPayload(.parseError, message: "bad"))
        let data = try env.encode()
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(dict["id"] is NSNull)
    }
}
