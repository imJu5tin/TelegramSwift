import XCTest
@testable import MCPServer

final class HTTPServerParseTests: XCTestCase {
    func testParse_simplePost() {
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 16\r\n\r\n{\"hello\":\"world\"}"
        let buffer = Data(raw.utf8)
        let req = HTTPServer.tryParseRequest(buffer: buffer)
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.path, "/mcp")
        XCTAssertEqual(req?.body, Data("{\"hello\":\"world\"".utf8))
    }

    func testParse_returnsNilWhenIncomplete() {
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 100\r\n\r\nshort body"
        let buffer = Data(raw.utf8)
        let req = HTTPServer.tryParseRequest(buffer: buffer)
        XCTAssertNil(req)
    }

    func testParse_returnsNilWhenHeaderIncomplete() {
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1"
        let buffer = Data(raw.utf8)
        let req = HTTPServer.tryParseRequest(buffer: buffer)
        XCTAssertNil(req)
    }

    func testParse_caseInsensitiveHeaderLookup() {
        let raw = "POST /mcp HTTP/1.1\r\naUtHoRiZaTiOn: Bearer xyz\r\n\r\n"
        let buffer = Data(raw.utf8)
        let req = HTTPServer.tryParseRequest(buffer: buffer)
        XCTAssertEqual(req?.header("Authorization"), "Bearer xyz")
        XCTAssertEqual(req?.header("authorization"), "Bearer xyz")
    }

    func testParse_getHealth() {
        let raw = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let buffer = Data(raw.utf8)
        let req = HTTPServer.tryParseRequest(buffer: buffer)
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/health")
    }
}

final class BearerTokenTests: XCTestCase {
    func testGenerate_unique() {
        let a = BearerToken.generate()
        let b = BearerToken.generate()
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.count, 30)
    }

    func testGenerate_urlSafe() {
        for _ in 0..<10 {
            let t = BearerToken.generate()
            XCTAssertFalse(t.contains("+"))
            XCTAssertFalse(t.contains("/"))
            XCTAssertFalse(t.contains("="))
        }
    }

    func testExtractFromHeader_validBearer() {
        XCTAssertEqual(BearerToken.extractFromAuthorizationHeader("Bearer abc"), "abc")
    }

    func testExtractFromHeader_missing() {
        XCTAssertNil(BearerToken.extractFromAuthorizationHeader(nil))
    }

    func testExtractFromHeader_wrongScheme() {
        XCTAssertNil(BearerToken.extractFromAuthorizationHeader("Basic abc"))
    }

    func testConstantTimeEquals_match() {
        XCTAssertTrue(BearerToken.constantTimeEquals("abcdef", "abcdef"))
    }

    func testConstantTimeEquals_mismatch() {
        XCTAssertFalse(BearerToken.constantTimeEquals("abcdef", "abcdeg"))
    }

    func testConstantTimeEquals_differentLengths() {
        XCTAssertFalse(BearerToken.constantTimeEquals("abc", "abcd"))
    }
}
