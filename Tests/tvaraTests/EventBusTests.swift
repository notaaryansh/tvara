import XCTest
@testable import tvara

final class EventBusTests: XCTestCase {

    private var tempDB: String!

    override func setUp() {
        super.setUp()
        tempDB = NSTemporaryDirectory() + "events_\(UUID().uuidString).db"
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempDB + suffix)
        }
        super.tearDown()
    }

    // MARK: - enqueue

    func testEnqueueReturnsRowId() async {
        let bus = EventBus(dbPath: tempDB)
        let id = await bus.enqueue(
            type: EventType.messageAdded,
            source: EventSource.imessage,
            payload: "{}"
        )
        XCTAssertNotNil(id)
        XCTAssertGreaterThan(id!, 0)
    }

    func testDedupeKeyPreventsDoubleEnqueue() async {
        let bus = EventBus(dbPath: tempDB)
        let first = await bus.enqueue(
            type: EventType.messageAdded, source: EventSource.imessage,
            payload: "{}", dedupeKey: "imessage:42"
        )
        let second = await bus.enqueue(
            type: EventType.messageAdded, source: EventSource.imessage,
            payload: "{}", dedupeKey: "imessage:42"
        )
        XCTAssertNotNil(first)
        XCTAssertNil(second, "duplicate dedupe_key must be a silent no-op")
    }

    func testNilDedupeKeyAllowsRepeatedEnqueue() async {
        let bus = EventBus(dbPath: tempDB)
        let a = await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{\"path\":\"/a\"}"
        )
        let b = await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{\"path\":\"/a\"}"
        )
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - claim

    func testClaimReturnsOnlyMatchingType() async {
        let bus = EventBus(dbPath: tempDB)
        await bus.enqueue(
            type: EventType.messageAdded, source: EventSource.imessage,
            payload: "{}", dedupeKey: "a"
        )
        await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{}", dedupeKey: "b"
        )

        let messages = await bus.claim(type: EventType.messageAdded, limit: 10)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.type, EventType.messageAdded)
    }

    func testClaimRespectsLimit() async {
        let bus = EventBus(dbPath: tempDB)
        for i in 0..<5 {
            await bus.enqueue(
                type: EventType.fileAdded, source: EventSource.fs,
                payload: "{}", dedupeKey: "k\(i)"
            )
        }
        let batch = await bus.claim(type: EventType.fileAdded, limit: 3)
        XCTAssertEqual(batch.count, 3)
    }

    func testSecondClaimSkipsAlreadyProcessing() async {
        let bus = EventBus(dbPath: tempDB)
        await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{}", dedupeKey: "x"
        )
        let first = await bus.claim(type: EventType.fileAdded, limit: 10)
        let second = await bus.claim(type: EventType.fileAdded, limit: 10)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 0, "an in-flight event must not be re-claimed")
    }

    // MARK: - complete + fail

    func testCompleteMarksDone() async {
        let bus = EventBus(dbPath: tempDB)
        await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{}", dedupeKey: "p"
        )
        let batch = await bus.claim(type: EventType.fileAdded, limit: 10)
        await bus.complete(id: batch[0].id)

        let depth = await bus.depthByStatus()
        XCTAssertEqual(depth["done"], 1)
        XCTAssertNil(depth["pending"])
        XCTAssertNil(depth["processing"])
    }

    func testFailRequeuesUnderMaxAttempts() async {
        let bus = EventBus(dbPath: tempDB)
        await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{}", dedupeKey: "q"
        )
        let batch = await bus.claim(type: EventType.fileAdded, limit: 10)
        await bus.fail(id: batch[0].id, error: "transient")

        let depth = await bus.depthByStatus()
        XCTAssertEqual(depth["pending"], 1)
        XCTAssertNil(depth["failed"])
    }

    func testFailFinalisesAfterMaxAttempts() async {
        let bus = EventBus(dbPath: tempDB)
        await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{}", dedupeKey: "r"
        )
        for _ in 0..<EventBus.maxAttempts {
            let batch = await bus.claim(type: EventType.fileAdded, limit: 10)
            if let e = batch.first {
                await bus.fail(id: e.id, error: "boom")
            }
            await bus._testClearBackoff()
        }
        let depth = await bus.depthByStatus()
        XCTAssertEqual(depth["failed"], 1)
        XCTAssertNil(depth["pending"])
    }

    func testBackoffPreventsImmediateReclaim() async {
        let bus = EventBus(dbPath: tempDB)
        await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{}", dedupeKey: "bf"
        )
        let batch = await bus.claim(type: EventType.fileAdded, limit: 10)
        await bus.fail(id: batch[0].id, error: "x")

        let again = await bus.claim(type: EventType.fileAdded, limit: 10)
        XCTAssertEqual(again.count, 0, "backoff must hide the event from the next claim")
    }

    // MARK: - Codable payload helpers

    func testCodablePayloadRoundTrip() async {
        let bus = EventBus(dbPath: tempDB)
        let payload = MessageAddedPayload(rowid: 12345, chatId: "+15551234567")
        await bus.enqueue(
            type: EventType.messageAdded,
            source: EventSource.imessage,
            payload: payload,
            dedupeKey: "imessage:12345"
        )
        let batch = await bus.claim(type: EventType.messageAdded, limit: 1)
        XCTAssertEqual(batch.count, 1)
        let decoded = batch.first?.decode(MessageAddedPayload.self)
        XCTAssertEqual(decoded?.rowid, 12345)
        XCTAssertEqual(decoded?.chatId, "+15551234567")
    }

    // MARK: - Recovery

    func testStaleProcessingRowRecoveredOnReopen() async {
        let bus1 = EventBus(dbPath: tempDB)
        await bus1.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{}", dedupeKey: "s"
        )
        _ = await bus1.claim(type: EventType.fileAdded, limit: 10)
        await bus1._testAgeProcessingClaims(by: EventBus.staleClaimTimeout + 1)

        let bus2 = EventBus(dbPath: tempDB)
        // Trigger ensureOpen → recoverStaleClaims.
        let depth = await bus2.depthByStatus()
        XCTAssertEqual(depth["pending"], 1)
        XCTAssertNil(depth["processing"])
    }
}
