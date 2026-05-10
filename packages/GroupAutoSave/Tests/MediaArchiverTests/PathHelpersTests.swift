import XCTest
@testable import MediaArchiver

final class PathHelpersTests: XCTestCase {
    func testSanitizedFolderName_basic() {
        XCTAssertEqual(PathHelpers.sanitizedFolderName(title: "My Group", fallbackId: 1), "My Group")
    }

    func testSanitizedFolderName_stripsSlashesAndIllegal() {
        XCTAssertEqual(
            PathHelpers.sanitizedFolderName(title: "a/b\\c:d*e?f\"g<h>i|j", fallbackId: 1),
            "abcdefghij"
        )
    }

    func testSanitizedFolderName_stripsControlChars() {
        XCTAssertEqual(
            PathHelpers.sanitizedFolderName(title: "hello\nworld\t!", fallbackId: 1),
            "hello world !"
        )
    }

    func testSanitizedFolderName_collapsesWhitespace() {
        XCTAssertEqual(
            PathHelpers.sanitizedFolderName(title: "a    b\t\tc", fallbackId: 1),
            "a b c"
        )
    }

    func testSanitizedFolderName_truncatesAt80() {
        let title = String(repeating: "x", count: 200)
        let result = PathHelpers.sanitizedFolderName(title: title, fallbackId: 1)
        XCTAssertEqual(result.count, 80)
    }

    func testSanitizedFolderName_emptyFallsBackToId() {
        XCTAssertEqual(PathHelpers.sanitizedFolderName(title: "", fallbackId: 12345), "12345")
    }

    func testSanitizedFolderName_onlyIllegalCharsFallsBackToId() {
        XCTAssertEqual(PathHelpers.sanitizedFolderName(title: "////", fallbackId: 99), "99")
    }

    func testSanitizedFolderName_keepsEmoji() {
        XCTAssertEqual(
            PathHelpers.sanitizedFolderName(title: "Cool Group 🚀", fallbackId: 1),
            "Cool Group 🚀"
        )
    }

    // Timestamps in tests are evaluated against the runner's local time zone so the
    // stamp prefix isn't compared literally — only structure + suffix.
    private func splitName(_ name: String) -> (stamp: String, suffix: String) {
        let parts = name.components(separatedBy: "__")
        precondition(parts.count == 2)
        return (parts[0], parts[1])
    }

    func testMessageSubfolderName_album() {
        let name = PathHelpers.messageSubfolderName(messageId: 12, groupingKey: 9876543210, timestamp: 1700000000)
        let (_, suffix) = splitName(name)
        XCTAssertEqual(suffix, "g9876543210")
    }

    func testMessageSubfolderName_msgWhenNoGroupingKey() {
        let name = PathHelpers.messageSubfolderName(messageId: 42, groupingKey: nil, timestamp: 1700000000)
        let (_, suffix) = splitName(name)
        XCTAssertEqual(suffix, "m42")
    }

    func testMessageSubfolderName_msgWhenGroupingKeyIsZero() {
        let name = PathHelpers.messageSubfolderName(messageId: 42, groupingKey: 0, timestamp: 1700000000)
        let (_, suffix) = splitName(name)
        XCTAssertEqual(suffix, "m42")
    }

    func testMessageSubfolderName_timestampStampShape() {
        // Whatever the local TZ, the stamp matches yyyy-MM-dd_HH-mm-ss
        let name = PathHelpers.messageSubfolderName(messageId: 1, groupingKey: nil, timestamp: 1700000000)
        let (stamp, _) = splitName(name)
        XCTAssertNotNil(stamp.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#, options: .regularExpression))
    }

    func testMessageSubfolderName_deterministicForSameInputs() {
        let a = PathHelpers.messageSubfolderName(messageId: 5, groupingKey: 99, timestamp: 1700000000)
        let b = PathHelpers.messageSubfolderName(messageId: 5, groupingKey: 99, timestamp: 1700000000)
        XCTAssertEqual(a, b)
    }

    func testArchiveDirectory_combinesPieces() {
        let dir = PathHelpers.archiveDirectory(root: "/tmp/archive", peerTitle: "Group A", peerId: 100, messageId: 5, groupingKey: nil, timestamp: 1700000000)
        XCTAssertTrue(dir.hasPrefix("/tmp/archive/Group A/"))
        XCTAssertTrue(dir.hasSuffix("__m5"))
    }

    func testArchiveDirectory_albumLayout() {
        let dir = PathHelpers.archiveDirectory(root: "/tmp/archive", peerTitle: "Group A", peerId: 100, messageId: 5, groupingKey: 1234, timestamp: 1700000000)
        XCTAssertTrue(dir.hasPrefix("/tmp/archive/Group A/"))
        XCTAssertTrue(dir.hasSuffix("__g1234"))
    }

    func testSkippedLogPath() {
        XCTAssertEqual(
            PathHelpers.skippedLogPath(root: "/tmp/x", peerTitle: "G", peerId: 7),
            "/tmp/x/G/skipped.txt"
        )
    }

    func testNextAvailablePath_freeBaseName() {
        let result = PathHelpers.nextAvailablePath(
            directory: "/tmp/dir",
            baseName: "photo.jpg",
            fileExists: { _ in false },
            sameContent: { _ in false }
        )
        XCTAssertEqual(result, .free("/tmp/dir/photo.jpg"))
    }

    func testNextAvailablePath_takesNextSuffix() {
        let existing: Set<String> = ["/tmp/dir/photo.jpg", "/tmp/dir/photo (2).jpg"]
        let result = PathHelpers.nextAvailablePath(
            directory: "/tmp/dir",
            baseName: "photo.jpg",
            fileExists: { existing.contains($0) },
            sameContent: { _ in false }
        )
        XCTAssertEqual(result, .free("/tmp/dir/photo (3).jpg"))
    }

    func testNextAvailablePath_detectsAlreadyArchived() {
        let result = PathHelpers.nextAvailablePath(
            directory: "/tmp/dir",
            baseName: "photo.jpg",
            fileExists: { $0 == "/tmp/dir/photo.jpg" },
            sameContent: { $0 == "/tmp/dir/photo.jpg" }
        )
        XCTAssertEqual(result, .alreadyArchived("/tmp/dir/photo.jpg"))
    }

    func testNextAvailablePath_extensionless() {
        let result = PathHelpers.nextAvailablePath(
            directory: "/tmp/dir",
            baseName: "data",
            fileExists: { $0 == "/tmp/dir/data" },
            sameContent: { _ in false }
        )
        XCTAssertEqual(result, .free("/tmp/dir/data (2)"))
    }

    func testFormatSkippedLogLine_structure() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let line = PathHelpers.formatSkippedLogLine(
            timestamp: timestamp,
            reason: "no-access",
            originPeerId: 1234,
            originMessageId: 5,
            link: "t.me/foo/9"
        )
        XCTAssertTrue(line.hasSuffix("\tno-access\t1234/5\tt.me/foo/9\n"))
        XCTAssertTrue(line.hasPrefix("2023-11-14"))
    }

    func testFormatSkippedLogLine_stripsTabsFromInputs() {
        let line = PathHelpers.formatSkippedLogLine(
            timestamp: Date(timeIntervalSince1970: 0),
            reason: "bad\treason",
            originPeerId: 1,
            originMessageId: 1,
            link: "x\ty"
        )
        let fields = line.split(separator: "\t").map(String.init)
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[1], "bad reason")
        XCTAssertEqual(fields[3], "x y\n")
    }
}
