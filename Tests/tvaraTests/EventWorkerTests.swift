import XCTest
@testable import tvara

/// In-memory worker for testing the runner loop. Counts processed events
/// and can be configured to throw on the first N attempts.
final class FakeWorker: EventWorker, @unchecked Sendable {
    let eventType: String
    let batchSize: Int = 10
    let pollInterval: TimeInterval = 0.05

    private let lock = NSLock()
    private var _processed: [Int64] = []
    private var _failuresLeft: Int
    private var _attemptCount = 0

    init(eventType: String, failuresLeft: Int = 0) {
        self.eventType = eventType
        self._failuresLeft = failuresLeft
    }

    var processed: [Int64] {
        lock.lock(); defer { lock.unlock() }
        return _processed
    }

    /// Total invocations of `process`, including the ones that threw.
    var attemptCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _attemptCount
    }

    func process(_ event: Event) async throws {
        lock.lock()
        _attemptCount += 1
        let throwNow = _failuresLeft > 0
        if throwNow { _failuresLeft -= 1 }
        if !throwNow { _processed.append(event.id) }
        lock.unlock()
        if throwNow {
            throw NSError(domain: "FakeWorker", code: 1, userInfo: nil)
        }
    }
}

final class EventWorkerTests: XCTestCase {

    private var tempDB: String!

    override func setUp() {
        super.setUp()
        tempDB = NSTemporaryDirectory() + "events_worker_\(UUID().uuidString).db"
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: tempDB + suffix)
        }
        super.tearDown()
    }

    func testWorkerProcessesEnqueuedEvents() async throws {
        let bus = EventBus(dbPath: tempDB)
        let worker = FakeWorker(eventType: EventType.fileAdded)
        let runner = WorkerRunner(bus: bus, worker: worker)

        for i in 0..<5 {
            _ = try await bus.enqueue(
                type: EventType.fileAdded, source: EventSource.fs,
                payload: "{}", dedupeKey: "f\(i)"
            )
        }

        await runner.start()
        try await waitUntil(timeout: 2.0) { worker.processed.count == 5 }
        await runner.stop()

        let depth = await bus.depthByStatus()
        XCTAssertEqual(depth["done"], 5)
    }

    func testWorkerFailureRequeuesEvent() async throws {
        let bus = EventBus(dbPath: tempDB)
        // Throw on the first attempt, succeed on the retry.
        let worker = FakeWorker(eventType: EventType.fileAdded, failuresLeft: 1)
        let runner = WorkerRunner(bus: bus, worker: worker)

        _ = try await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{}", dedupeKey: "retry"
        )
        await runner.start()

        // Wait for `bus.fail` to actually bump `attempts` for our row
        // before clearing backoff. Asserting on `attemptCount` (worker
        // side) raced because the worker increments that *before* the
        // runner calls `fail` — `_testClearBackoff` could win and then
        // `fail` would re-set `not_before` to ~2s, stalling the retry
        // past the test timeout.
        try await waitUntil(timeout: 2.0) {
            await bus._testAttempts(dedupeKey: "retry") >= 1
        }
        await bus._testClearBackoff()
        try await waitUntil(timeout: 2.0) { worker.processed.count == 1 }
        await runner.stop()

        let depth = await bus.depthByStatus()
        XCTAssertEqual(depth["done"], 1)
        XCTAssertNil(depth["failed"])
    }

    func testStopHaltsTheLoop() async throws {
        let bus = EventBus(dbPath: tempDB)
        let worker = FakeWorker(eventType: EventType.fileAdded)
        let runner = WorkerRunner(bus: bus, worker: worker)
        await runner.start()
        await runner.stop()

        // After stop, enqueueing should NOT result in processing.
        _ = try await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: "{}", dedupeKey: "post-stop"
        )
        // Give the (stopped) loop a chance to do nothing.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(worker.processed.count, 0)
        let depth = await bus.depthByStatus()
        XCTAssertEqual(depth["pending"], 1)
    }

    // MARK: - Helpers

    /// Polls `condition` until it returns true or `timeout` elapses.
    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("waitUntil timed out after \(timeout)s")
    }
}
