import XCTest
@testable import MarginGraphCore

final class SRSEngineTests: XCTestCase {
    func testSuccessfulSM2Intervals() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var item = ReviewItem(cardId: UUID(), dueDate: now)

        item = SRSEngine.review(item, grade: 5, at: now)
        XCTAssertEqual(item.repetitions, 1)
        XCTAssertEqual(item.intervalDays, 1)
        XCTAssertEqual(item.easeFactor, 2.6, accuracy: 0.0001)

        item = SRSEngine.review(item, grade: 5, at: now)
        XCTAssertEqual(item.repetitions, 2)
        XCTAssertEqual(item.intervalDays, 6)

        item = SRSEngine.review(item, grade: 4, at: now)
        XCTAssertEqual(item.repetitions, 3)
        XCTAssertGreaterThan(item.intervalDays, 6)
    }

    func testFailureResetsAndEaseHasFloor() {
        let now = Date()
        var item = ReviewItem(
            cardId: UUID(),
            easeFactor: 1.31,
            intervalDays: 30,
            repetitions: 5,
            dueDate: now
        )

        item = SRSEngine.review(item, grade: 0, at: now)
        XCTAssertEqual(item.repetitions, 0)
        XCTAssertEqual(item.intervalDays, 1)
        XCTAssertEqual(item.easeFactor, 1.3, accuracy: 0.0001)
        XCTAssertEqual(item.lastReviewed, now)
    }
}
