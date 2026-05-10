import XCTest
import Postbox
@testable import MessageWalker

final class MessageDedupCacheTests: XCTestCase {
    private func makeId(_ id: Int32, peer: Int64 = 1, namespace: Int32 = 0) -> MessageId {
        return MessageId(peerId: PeerId(peer), namespace: namespace, id: id)
    }

    func testInsert_returnsTrueForNew() {
        let cache = MessageDedupCache(capacity: 8)
        XCTAssertTrue(cache.insert(makeId(1)))
        XCTAssertTrue(cache.insert(makeId(2)))
    }

    func testInsert_returnsFalseForDuplicate() {
        let cache = MessageDedupCache(capacity: 8)
        XCTAssertTrue(cache.insert(makeId(1)))
        XCTAssertFalse(cache.insert(makeId(1)))
    }

    func testContains_reflectsState() {
        let cache = MessageDedupCache(capacity: 8)
        XCTAssertFalse(cache.contains(makeId(1)))
        _ = cache.insert(makeId(1))
        XCTAssertTrue(cache.contains(makeId(1)))
    }

    func testEvictsOldestAtCapacity() {
        let cache = MessageDedupCache(capacity: 3)
        _ = cache.insert(makeId(1))
        _ = cache.insert(makeId(2))
        _ = cache.insert(makeId(3))
        XCTAssertEqual(cache.count, 3)
        _ = cache.insert(makeId(4))
        XCTAssertEqual(cache.count, 3)
        XCTAssertFalse(cache.contains(makeId(1)))
        XCTAssertTrue(cache.contains(makeId(2)))
        XCTAssertTrue(cache.contains(makeId(3)))
        XCTAssertTrue(cache.contains(makeId(4)))
    }

    func testEvictionDoesNotRevisitInserted() {
        let cache = MessageDedupCache(capacity: 2)
        _ = cache.insert(makeId(1))
        _ = cache.insert(makeId(2))
        _ = cache.insert(makeId(3)) // evicts 1
        XCTAssertTrue(cache.insert(makeId(1))) // 1 was evicted, insertable again
    }

    func testDistinctPeerIdsTreatedSeparately() {
        let cache = MessageDedupCache(capacity: 8)
        XCTAssertTrue(cache.insert(makeId(1, peer: 100)))
        XCTAssertTrue(cache.insert(makeId(1, peer: 200)))
        XCTAssertEqual(cache.count, 2)
    }

    func testCount_emptyOnInit() {
        XCTAssertEqual(MessageDedupCache(capacity: 8).count, 0)
    }

    func testThreadSafety_concurrentInserts() {
        let cache = MessageDedupCache(capacity: 1024)
        let exp = expectation(description: "concurrent inserts")
        exp.expectedFulfillmentCount = 4
        let queue = DispatchQueue(label: "test", attributes: .concurrent)
        for shard in 0..<4 {
            queue.async {
                for i in 0..<100 {
                    _ = cache.insert(self.makeId(Int32(shard * 100 + i)))
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(cache.count, 400)
    }
}
