import XCTest
import CoreGraphics
@testable import MarginGraphCore

final class ReferenceLinkGeometryTests: XCTestCase {
    func testOverlappingReferencesUseSeparateLanesAndVisibleDestinationArrows() throws {
        let topic = UUID(), a = UUID(), b = UUID(), c = UUID()
        let frames = [a: CGRect(x: 0, y: 0, width: 100, height: 60),
                      b: CGRect(x: 250, y: 0, width: 100, height: 60),
                      c: CGRect(x: 500, y: 0, width: 100, height: 60)]
        let first = CardLink(topicId: topic, sourceCardId: a, targetCardId: c)
        let second = CardLink(topicId: topic, sourceCardId: b, targetCardId: c)
        let one = try XCTUnwrap(ReferenceLinkGeometry.make(link: first, links: [first, second], frames: frames))
        let two = try XCTUnwrap(ReferenceLinkGeometry.make(link: second, links: [first, second], frames: frames))
        XCTAssertNotEqual(one.path.boundingBox.midY, two.path.boundingBox.midY)
        XCTAssertEqual(one.path.currentPoint, CGPoint(x: 550, y: 30))
        XCTAssertFalse(frames[c]!.intersects(one.arrow.boundingBox))
        XCTAssertFalse(frames[c]!.intersects(two.arrow.boundingBox))
    }
    func testSingleReferenceIsStraightAndArrowFollowsReverseDirection() throws {
        let a = UUID(), b = UUID()
        let frames = [a: CGRect(x: 0, y: 0, width: 100, height: 60), b: CGRect(x: 500, y: 0, width: 100, height: 60)]
        let link = CardLink(topicId: UUID(), sourceCardId: b, targetCardId: a)
        let geometry = try XCTUnwrap(ReferenceLinkGeometry.make(link: link, links: [link], frames: frames))
        XCTAssertEqual(geometry.path.boundingBox.height, 0)
        XCTAssertGreaterThan(geometry.arrow.boundingBox.minX, frames[a]!.maxX)
    }
}
