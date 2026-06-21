import XCTest
@testable import tvara

final class EmbedMessageWorkerTests: XCTestCase {

    private var tempDB: String!
    private var embedDB: String!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        tempDB  = NSTemporaryDirectory() + "events_embed_\(id).db"
        embedDB = NSTemporaryDirectory() + "embeddings_\(id).db"
    }

    override func tearDown() {
        for path in [tempDB, embedDB] {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path! + suffix)
            }
        }
        super.tearDown()
    }

    /// No API key in env → worker completes events without hitting OpenAI.
    /// The queue must drain rather than stack up `failed` rows.
    func testNoApiKeyDrainsQueueCleanly() async throws {
        unsetenv("OPENAI_API_KEY")
        // Move to /tmp so the .env walk-up doesn't find a real key.
        let originalCWD = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(NSTemporaryDirectory())
        defer { FileManager.default.changeCurrentDirectoryPath(originalCWD) }

        let bus = EventBus(dbPath: tempDB)
        let store = EmbeddingStore(dbPath: embedDB)
        let imsg = AppleMessagesService()
        let worker = EmbedMessageWorker(store: store, imessage: imsg)
        let runner = WorkerRunner(bus: bus, worker: worker)

        for rowid in [1001, 1002, 1003] {
            let p = EmbedMessagePayload(messageId: Int64(rowid), source: EventSource.imessage)
            await bus.enqueue(
                type: EventType.embedMessage,
                source: EventSource.imessage,
                payload: p,
                dedupeKey: "embed:imessage:\(rowid)"
            )
        }

        await runner.start()
        try await waitUntil(timeout: 2.0) {
            let d = await bus.depthByStatus()
            return d["done"] == 3
        }
        await runner.stop()

        let depth = await bus.depthByStatus()
        XCTAssertEqual(depth["done"], 3)
        XCTAssertNil(depth["pending"])
        XCTAssertNil(depth["failed"])
    }

    func testKeyLoaderFindsEnvVar() {
        setenv("OPENAI_API_KEY", "sk-test-fake", 1)
        defer { unsetenv("OPENAI_API_KEY") }
        XCTAssertEqual(OpenAIKey.load(), "sk-test-fake")
    }

    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("waitUntil timed out")
    }
}
