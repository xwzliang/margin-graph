import AppKit
import XCTest
@testable import MarginGraphCore

final class DocumentCoverStoreTests: XCTestCase {
    func testCoverSurvivesWithoutSourceAndSeparatesLibraries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 8, height: 12))
        image.addRepresentation(bitmap)
        let source = "/unavailable/Library/Containers/other.app/book.pdf"
        DocumentCoverStore.save(image, path: source, variant: "shelf-v1", directory: directory)
        XCTAssertNotNil(DocumentCoverStore.load(path: source, variant: "shelf-v1", directory: directory))
        XCTAssertNil(DocumentCoverStore.load(path: "/another/library/book.pdf", variant: "shelf-v1", directory: directory))
        XCTAssertNil(DocumentCoverStore.load(path: source, variant: "notebook-v1", directory: directory))
    }
}
