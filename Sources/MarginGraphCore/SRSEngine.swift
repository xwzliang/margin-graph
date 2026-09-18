import Foundation

public enum SRSEngine {
    public static func review(_ item: ReviewItem, grade: Int, at reviewDate: Date = Date(), calendar: Calendar = .current) -> ReviewItem {
        let grade = min(5, max(0, grade))
        let q = Double(grade)
        let ease = max(1.3, item.easeFactor + (0.1 - (5.0 - q) * (0.08 + (5.0 - q) * 0.02)))

        var repetitions = item.repetitions
        let interval: Int
        if grade < 3 {
            repetitions = 0
            interval = 1
        } else {
            switch repetitions {
            case 0: interval = 1
            case 1: interval = 6
            default: interval = max(1, Int((Double(item.intervalDays) * ease).rounded()))
            }
            repetitions += 1
        }

        let dueDate = calendar.date(byAdding: .day, value: interval, to: reviewDate)
            ?? reviewDate.addingTimeInterval(Double(interval) * 86_400)

        return ReviewItem(
            cardId: item.cardId,
            easeFactor: ease,
            intervalDays: interval,
            repetitions: repetitions,
            dueDate: dueDate,
            lastReviewed: reviewDate
        )
    }
}
