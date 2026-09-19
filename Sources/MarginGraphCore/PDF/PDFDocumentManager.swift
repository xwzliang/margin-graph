import Foundation
import AppKit
import PDFKit
import CryptoKit

public struct PDFOutlineItem: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var pageIndex: Int?
    public var children: [PDFOutlineItem]

    public init(id: UUID = UUID(), title: String, pageIndex: Int?, children: [PDFOutlineItem] = []) {
        self.id = id
        self.title = title
        self.pageIndex = pageIndex
        self.children = children
    }
}

public final class PDFDocumentManager: @unchecked Sendable {
    public let url: URL
    public let document: PDFDocument
    public let md5: String
    public let title: String
    public let pageCount: Int
    public let outline: [PDFOutlineItem]

    public init(url: URL, md5: String? = nil) throws {
        guard let document = PDFDocument(url: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.url = url
        self.document = document
        self.pageCount = document.pageCount

        if let md5, !md5.isEmpty {
            self.md5 = md5
        } else {
            let data = try Data(contentsOf: url)
            self.md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        let attributeTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        self.title = (attributeTitle?.isEmpty == false ? attributeTitle : nil)
            ?? url.deletingPathExtension().lastPathComponent

        if let root = document.outlineRoot {
            self.outline = Self.makeOutlineItems(root: root, document: document)
        } else {
            self.outline = []
        }
    }

    public func page(at index: Int) -> PDFPage? {
        guard index >= 0, index < document.pageCount else { return nil }
        return document.page(at: index)
    }

    public func text(onPage index: Int) -> String {
        page(at: index)?.string ?? ""
    }

    public func text(in bounds: CGRect, pageIndex: Int) -> String {
        guard let page = page(at: pageIndex) else { return "" }
        return page.selection(for: bounds)?.string ?? ""
    }

    public func thumbnail(pageIndex: Int, size: CGSize = CGSize(width: 220, height: 300)) -> NSImage? {
        page(at: pageIndex)?.thumbnail(of: size, for: .cropBox)
    }

    public func crop(pageIndex: Int, bounds: CGRect, scale: CGFloat = 2) -> Data? {
        guard let page = page(at: pageIndex), bounds.width > 0, bounds.height > 0 else { return nil }

        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: context)

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func makeOutlineItems(root: PDFOutline, document: PDFDocument) -> [PDFOutlineItem] {
        var items: [PDFOutlineItem] = []
        for index in 0..<root.numberOfChildren {
            guard let child = root.child(at: index) else { continue }
            items.append(makeOutlineItem(child, document: document))
        }
        return items
    }

    private static func makeOutlineItem(_ outline: PDFOutline, document: PDFDocument) -> PDFOutlineItem {
        let pageIndex: Int?
        if let page = outline.destination?.page {
            let index = document.index(for: page)
            pageIndex = index == NSNotFound ? nil : index
        } else {
            pageIndex = nil
        }

        var children: [PDFOutlineItem] = []
        for index in 0..<outline.numberOfChildren {
            if let child = outline.child(at: index) {
                children.append(makeOutlineItem(child, document: document))
            }
        }

        return PDFOutlineItem(
            title: outline.label ?? "Untitled",
            pageIndex: pageIndex,
            children: children
        )
    }
}
