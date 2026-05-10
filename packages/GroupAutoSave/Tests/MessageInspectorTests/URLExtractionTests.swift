import XCTest
@testable import MessageInspector

final class URLExtractionTests: XCTestCase {
    func testExtract_emptyEntities() {
        XCTAssertEqual(URLExtraction.extract(text: "no urls here", entities: []), [])
    }

    func testExtract_singleUrlEntity() {
        let text = "see https://example.com here"
        let entity = TextEntityRange(lower: 4, upper: 23, kind: .url)
        XCTAssertEqual(URLExtraction.extract(text: text, entities: [entity]), ["https://example.com"])
    }

    func testExtract_textUrlUsesUrlField() {
        let text = "see [the link]"
        let entity = TextEntityRange(lower: 4, upper: 14, kind: .textUrl("https://example.com/real"))
        XCTAssertEqual(URLExtraction.extract(text: text, entities: [entity]), ["https://example.com/real"])
    }

    func testExtract_multipleEntities() {
        let text = "first https://a.com and https://b.com"
        let entities = [
            TextEntityRange(lower: 6, upper: 19, kind: .url),
            TextEntityRange(lower: 24, upper: 37, kind: .url),
        ]
        XCTAssertEqual(
            URLExtraction.extract(text: text, entities: entities),
            ["https://a.com", "https://b.com"]
        )
    }

    func testExtract_dedupsRepeated() {
        let text = "a https://x.com b https://x.com c"
        let entities = [
            TextEntityRange(lower: 2, upper: 15, kind: .url),
            TextEntityRange(lower: 18, upper: 31, kind: .url),
        ]
        XCTAssertEqual(URLExtraction.extract(text: text, entities: entities), ["https://x.com"])
    }

    func testExtract_clampsOutOfRangeBounds() {
        let text = "abc"
        let entity = TextEntityRange(lower: -5, upper: 100, kind: .url)
        XCTAssertEqual(URLExtraction.extract(text: text, entities: [entity]), ["abc"])
    }

    func testExtract_emptyRangeReturnsNothing() {
        let text = "abc"
        let entity = TextEntityRange(lower: 1, upper: 1, kind: .url)
        XCTAssertEqual(URLExtraction.extract(text: text, entities: [entity]), [])
    }

    func testExtract_preservesOrder() {
        let text = "see https://second.com and https://first.com"
        let entities = [
            TextEntityRange(lower: 4, upper: 22, kind: .url),
            TextEntityRange(lower: 27, upper: 44, kind: .url),
        ]
        XCTAssertEqual(
            URLExtraction.extract(text: text, entities: entities),
            ["https://second.com", "https://first.com"]
        )
    }

    func testExtract_mixedKinds() {
        let text = "raw https://a.com markdown"
        let entities = [
            TextEntityRange(lower: 4, upper: 17, kind: .url),
            TextEntityRange(lower: 18, upper: 26, kind: .textUrl("https://b.com")),
        ]
        XCTAssertEqual(
            URLExtraction.extract(text: text, entities: entities),
            ["https://a.com", "https://b.com"]
        )
    }
}
