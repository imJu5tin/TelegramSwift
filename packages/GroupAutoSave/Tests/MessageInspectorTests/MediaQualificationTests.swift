import XCTest
@testable import MessageInspector

final class MediaQualificationTests: XCTestCase {
    func testQualifies_image() {
        let result = MediaQualification.qualifyingIndices([
            MediaCandidate(isImage: true),
        ])
        XCTAssertEqual(result, [0])
    }

    func testQualifies_video() {
        let result = MediaQualification.qualifyingIndices([
            MediaCandidate(isVideo: true),
        ])
        XCTAssertEqual(result, [0])
    }

    func testRejects_animatedGif() {
        let result = MediaQualification.qualifyingIndices([
            MediaCandidate(isVideo: true, isAnimated: true),
        ])
        XCTAssertEqual(result, [])
    }

    func testRejects_voiceMessage() {
        let result = MediaQualification.qualifyingIndices([
            MediaCandidate(isVoice: true),
        ])
        XCTAssertEqual(result, [])
    }

    func testRejects_videoNote() {
        let result = MediaQualification.qualifyingIndices([
            MediaCandidate(isVideo: true, isInstantVideo: true),
        ])
        XCTAssertEqual(result, [])
    }

    func testRejects_emptyCandidate() {
        let result = MediaQualification.qualifyingIndices([
            MediaCandidate(),
        ])
        XCTAssertEqual(result, [])
    }

    func testMixedBatch() {
        let result = MediaQualification.qualifyingIndices([
            MediaCandidate(isImage: true),                      // 0: keep
            MediaCandidate(isVoice: true),                      // 1: skip
            MediaCandidate(isVideo: true),                      // 2: keep
            MediaCandidate(isVideo: true, isInstantVideo: true),// 3: skip
            MediaCandidate(isVideo: true, isAnimated: true),    // 4: skip (gif)
            MediaCandidate(isImage: true),                      // 5: keep
        ])
        XCTAssertEqual(result, [0, 2, 5])
    }

    func testEmptyInput() {
        XCTAssertEqual(MediaQualification.qualifyingIndices([]), [])
    }
}
