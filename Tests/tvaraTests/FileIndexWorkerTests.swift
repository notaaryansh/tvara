import XCTest
@testable import tvara

final class FileIndexWorkerTests: XCTestCase {

    private var tempDB: String!
    private var indexDB: String!
    private var workDir: String!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        tempDB  = NSTemporaryDirectory() + "events_file_\(id).db"
        indexDB = NSTemporaryDirectory() + "files_recent_\(id).db"
        workDir = NSTemporaryDirectory() + "fwk_\(id)"
        try? FileManager.default.createDirectory(
            atPath: workDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        for path in [tempDB, indexDB] {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path! + suffix)
            }
        }
        try? FileManager.default.removeItem(atPath: workDir)
        super.tearDown()
    }

    // MARK: - FileIndexService

    func testUpsertStoresPathThatExists() async {
        let file = workDir + "/hello.txt"
        try? "hi".write(toFile: file, atomically: true, encoding: .utf8)
        let svc = FileIndexService(dbPath: indexDB)
        let ok = await svc.upsert(path: file)
        XCTAssertTrue(ok)
        let count = await svc.count()
        XCTAssertEqual(count, 1)
    }

    func testUpsertDropsMissingPath() async {
        let svc = FileIndexService(dbPath: indexDB)
        let ok = await svc.upsert(path: workDir + "/does_not_exist.txt")
        XCTAssertFalse(ok)
        let count = await svc.count()
        XCTAssertEqual(count, 0)
    }

    func testUpsertIsIdempotent() async {
        let file = workDir + "/dup.txt"
        try? "x".write(toFile: file, atomically: true, encoding: .utf8)
        let svc = FileIndexService(dbPath: indexDB)
        await svc.upsert(path: file)
        await svc.upsert(path: file)
        await svc.upsert(path: file)
        let count = await svc.count()
        XCTAssertEqual(count, 1)
    }

    // MARK: - End-to-end: producer-style enqueue → worker → index

    func testWorkerIndexesEnqueuedPaths() async throws {
        let file1 = workDir + "/a.md"
        let file2 = workDir + "/b.md"
        try "1".write(toFile: file1, atomically: true, encoding: .utf8)
        try "2".write(toFile: file2, atomically: true, encoding: .utf8)

        let bus = EventBus(dbPath: tempDB)
        let svc = FileIndexService(dbPath: indexDB)
        let worker = FileIndexWorker(index: svc)
        let runner = WorkerRunner(bus: bus, worker: worker)

        // Enqueue directly (no FSEvents — would be flaky in tests).
        await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: FileAddedPayload(path: file1), dedupeKey: "fs:\(file1)"
        )
        await bus.enqueue(
            type: EventType.fileAdded, source: EventSource.fs,
            payload: FileAddedPayload(path: file2), dedupeKey: "fs:\(file2)"
        )

        await runner.start()
        try await waitUntil(timeout: 2.0) { await svc.count() == 2 }
        await runner.stop()
    }

    // MARK: - Producer path filter

    func testProducerFiltersHiddenAndTempFiles() {
        XCTAssertFalse(FileProducer.shouldEnqueue(path: "/Users/u/Downloads/.DS_Store"))
        XCTAssertFalse(FileProducer.shouldEnqueue(path: "/Users/u/Downloads/foo.crdownload"))
        XCTAssertFalse(FileProducer.shouldEnqueue(path: "/Users/u/Downloads/foo.part"))
        XCTAssertTrue(FileProducer.shouldEnqueue(path: "/Users/u/Downloads/foo.pdf"))
        XCTAssertTrue(FileProducer.shouldEnqueue(path: "/Users/u/Documents/notes.md"))
    }

    // MARK: - Helpers

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
