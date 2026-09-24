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

import PDFKit

public enum PDFExcerptRenderer {
    public static func renderExcerpt(
        document: PDFDocument,
        pageIndex: Int,
        bounds: CGRect,
        scale: CGFloat = 2.0
    ) -> CGImage? {
        guard let page = document.page(at: pageIndex) else { return nil }
        let cropBox = page.bounds(for: .cropBox)
        let safeBounds = bounds.intersection(cropBox)
        guard safeBounds.width > 1, safeBounds.height > 1 else { return nil }

        let targetWidth = max(1, Int(safeBounds.width * scale))
        let targetHeight = max(1, Int(safeBounds.height * scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -safeBounds.origin.x, y: -safeBounds.origin.y)

        page.draw(with: .cropBox, to: context)
        return context.makeImage()
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
        let imageHash = try excerpt.croppedImageData.map { try mediaStorage.saveImage($0, format: "heic") }
        let card = NoteCard(
            topicId: topicId,
            bookMD5: excerpt.bookMD5,
            title: title ?? "",
            highlightText: excerpt.text,
            startPage: excerpt.pageIndex,
            endPage: excerpt.pageIndex,
            startPos: CGPoint(x: excerpt.bounds.minX, y: excerpt.bounds.minY),
            endPos: CGPoint(x: excerpt.bounds.maxX, y: excerpt.bounds.maxY),
            colorIndex: colorIndex,
            highlightPicHash: imageHash,
            highlightRects: [
                HighlightRect(
                    page: excerpt.pageIndex,
                    x: excerpt.bounds.origin.x,
                    y: excerpt.bounds.origin.y,
                    width: excerpt.bounds.width,
                    height: excerpt.bounds.height
                )
            ]
        )
        try database.insertCard(card)
        return card
    }
}

