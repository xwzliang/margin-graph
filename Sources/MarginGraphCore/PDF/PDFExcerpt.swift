import Foundation
import CoreGraphics

public struct PDFExcerpt: Sendable {
    public var bookMD5: String
    public var pageIndex: Int
    public var bounds: CGRect
    public var text: String
    public var croppedImageData: Data?

    public init(
        bookMD5: String,
        pageIndex: Int,
        bounds: CGRect,
        text: String = "",
        croppedImageData: Data? = nil
    ) {
        self.bookMD5 = bookMD5
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.text = text
        self.croppedImageData = croppedImageData
    }
}

public final class ExcerptCoordinator: @unchecked Sendable {
    private let database: Database
    private let mediaStorage: MediaStorage

    public init(database: Database, mediaStorage: MediaStorage) {
        self.database = database
        self.mediaStorage = mediaStorage
    }

    @discardableResult
    public func createCard(
        from excerpt: PDFExcerpt,
        topicId: UUID,
        title: String? = nil,
        colorIndex: Int = 0
    ) throws -> NoteCard {
        let imageHash = try excerpt.croppedImageData.map { try mediaStorage.saveImage($0, format: "png") }
        let card = NoteCard(
            topicId: topicId,
            bookMD5: excerpt.bookMD5,
            title: title ?? excerpt.text.prefix(80).description,
            highlightText: excerpt.text,
            startPage: excerpt.pageIndex,
            endPage: excerpt.pageIndex,
            startPos: CGPoint(x: excerpt.bounds.minX, y: excerpt.bounds.minY),
            endPos: CGPoint(x: excerpt.bounds.maxX, y: excerpt.bounds.maxY),
            colorIndex: colorIndex,
            highlightPicHash: imageHash
        )
        try database.insertCard(card)
        return card
    }
}
