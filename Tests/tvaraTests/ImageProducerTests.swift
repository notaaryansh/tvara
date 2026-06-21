import XCTest
@testable import tvara

final class ImageProducerTests: XCTestCase {

    func testProducerAcceptsCommonImageExtensions() {
        XCTAssertTrue(ImageProducer.shouldEnqueue(path: "/u/p/photo.jpg"))
        XCTAssertTrue(ImageProducer.shouldEnqueue(path: "/u/p/photo.JPG"))
        XCTAssertTrue(ImageProducer.shouldEnqueue(path: "/u/p/photo.png"))
        XCTAssertTrue(ImageProducer.shouldEnqueue(path: "/u/p/photo.heic"))
        XCTAssertTrue(ImageProducer.shouldEnqueue(path: "/u/p/photo.webp"))
        XCTAssertTrue(ImageProducer.shouldEnqueue(path: "/u/p/photo.gif"))
    }

    func testProducerRejectsNonImageExtensions() {
        XCTAssertFalse(ImageProducer.shouldEnqueue(path: "/u/p/notes.md"))
        XCTAssertFalse(ImageProducer.shouldEnqueue(path: "/u/p/song.mp3"))
        XCTAssertFalse(ImageProducer.shouldEnqueue(path: "/u/p/movie.mov"))
        XCTAssertFalse(ImageProducer.shouldEnqueue(path: "/u/p/script.swift"))
    }

    func testProducerRejectsHiddenFiles() {
        XCTAssertFalse(ImageProducer.shouldEnqueue(path: "/u/p/.thumb.jpg"))
        XCTAssertFalse(ImageProducer.shouldEnqueue(path: "/u/p/.DS_Store"))
    }
}
