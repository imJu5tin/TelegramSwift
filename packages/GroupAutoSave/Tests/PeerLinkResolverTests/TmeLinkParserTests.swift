import XCTest
@testable import PeerLinkResolver

final class TmeLinkParserTests: XCTestCase {
    func testPublicLink_basic() {
        let ref = TmeLinkParser.parse("https://t.me/somechannel/123")
        XCTAssertEqual(ref, TmeLinkRef(target: .username("somechannel"), postId: 123))
    }

    func testPublicLink_noScheme() {
        XCTAssertEqual(
            TmeLinkParser.parse("t.me/somechannel/123"),
            TmeLinkRef(target: .username("somechannel"), postId: 123)
        )
    }

    func testPublicLink_httpScheme() {
        XCTAssertEqual(
            TmeLinkParser.parse("http://t.me/somechannel/42"),
            TmeLinkRef(target: .username("somechannel"), postId: 42)
        )
    }

    func testPublicLink_telegramMeAlias() {
        XCTAssertEqual(
            TmeLinkParser.parse("https://telegram.me/foo/9"),
            TmeLinkRef(target: .username("foo"), postId: 9)
        )
    }

    func testPublicLink_telegramDogAlias() {
        XCTAssertEqual(
            TmeLinkParser.parse("https://telegram.dog/foo/9"),
            TmeLinkRef(target: .username("foo"), postId: 9)
        )
    }

    func testPublicLink_uppercaseScheme() {
        XCTAssertEqual(
            TmeLinkParser.parse("HTTPS://t.me/foo/12"),
            TmeLinkRef(target: .username("foo"), postId: 12)
        )
    }

    func testPublicLink_uppercaseDomain() {
        XCTAssertEqual(
            TmeLinkParser.parse("https://T.ME/foo/12"),
            TmeLinkRef(target: .username("foo"), postId: 12)
        )
    }

    func testPublicLink_withQueryString() {
        XCTAssertEqual(
            TmeLinkParser.parse("https://t.me/foo/12?single"),
            TmeLinkRef(target: .username("foo"), postId: 12)
        )
    }

    func testPublicLink_withFragment() {
        XCTAssertEqual(
            TmeLinkParser.parse("https://t.me/foo/12#x"),
            TmeLinkRef(target: .username("foo"), postId: 12)
        )
    }

    func testPublicLink_withTrailingSlash() {
        XCTAssertEqual(
            TmeLinkParser.parse("https://t.me/foo/12/"),
            TmeLinkRef(target: .username("foo"), postId: 12)
        )
    }

    func testPublicLink_underscoresAllowed() {
        XCTAssertEqual(
            TmeLinkParser.parse("https://t.me/some_chan_1/42"),
            TmeLinkRef(target: .username("some_chan_1"), postId: 42)
        )
    }

    func testPrivateLink_basic() {
        XCTAssertEqual(
            TmeLinkParser.parse("https://t.me/c/1234567890/42"),
            TmeLinkRef(target: .privateChannel(rawId: 1234567890), postId: 42)
        )
    }

    func testPrivateLink_uppercase_c() {
        XCTAssertEqual(
            TmeLinkParser.parse("https://t.me/C/1234567890/42"),
            TmeLinkRef(target: .privateChannel(rawId: 1234567890), postId: 42)
        )
    }

    func testRejects_inviteLink() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/+abcdef"))
    }

    func testRejects_joinchatLink() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/joinchat/abcdef"))
    }

    func testRejects_usernameOnly() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/somechannel"))
    }

    func testRejects_nonTmeDomain() {
        XCTAssertNil(TmeLinkParser.parse("https://example.com/foo/12"))
    }

    func testRejects_nonNumericPostId() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/foo/notanumber"))
    }

    func testRejects_zeroPostId() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/foo/0"))
    }

    func testRejects_negativePostId() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/foo/-5"))
    }

    func testRejects_emptyString() {
        XCTAssertNil(TmeLinkParser.parse(""))
    }

    func testRejects_whitespaceOnly() {
        XCTAssertNil(TmeLinkParser.parse("   "))
    }

    func testRejects_invalidUsernameWithDashes() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/foo-bar/12"))
    }

    func testRejects_emojiInUsername() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/foo😀/12"))
    }

    func testRejects_extraPathComponents() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/foo/12/extra"))
    }

    func testRejects_privateChannelMissingPost() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/c/12345"))
    }

    func testRejects_privateChannelNonNumericId() {
        XCTAssertNil(TmeLinkParser.parse("https://t.me/c/abc/12"))
    }

    func testTrimsLeadingTrailingWhitespace() {
        XCTAssertEqual(
            TmeLinkParser.parse("  https://t.me/foo/12  "),
            TmeLinkRef(target: .username("foo"), postId: 12)
        )
    }

    func testHashable_distinguishesByTarget() {
        let a = TmeLinkRef(target: .username("foo"), postId: 1)
        let b = TmeLinkRef(target: .username("bar"), postId: 1)
        XCTAssertNotEqual(a, b)
    }

    func testHashable_distinguishesByPostId() {
        let a = TmeLinkRef(target: .username("foo"), postId: 1)
        let b = TmeLinkRef(target: .username("foo"), postId: 2)
        XCTAssertNotEqual(a, b)
    }

    func testHashable_dedupsInSet() {
        let a = TmeLinkRef(target: .username("foo"), postId: 1)
        let b = TmeLinkRef(target: .username("foo"), postId: 1)
        var set: Set<TmeLinkRef> = []
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1)
    }
}
