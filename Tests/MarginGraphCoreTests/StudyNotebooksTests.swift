import XCTest
@testable import MarginGraphCore

final class StudyNotebooksTests: XCTestCase {
    func testProtectedContainerPathsRequireExplicitOpen() {
        XCTAssertTrue(DocumentFileAccess.requiresExplicitOpen("/Users/test/Library/Containers/other.app/Data/book.pdf"))
        XCTAssertTrue(DocumentFileAccess.requiresExplicitOpen("/Users/test/Library/Group Containers/group.other/book.pdf"))
        XCTAssertFalse(DocumentFileAccess.requiresExplicitOpen("/Users/test/Library/Application Support/MarginGraph/Documents/book.pdf"))
        XCTAssertFalse(DocumentFileAccess.requiresExplicitOpen("/Volumes/library/Containers/book.pdf"))
    }

    @MainActor
    func testNotebookMatchingDoesNotRequireAnAvailableFile() {
        let document = Document(title: "Book", filePath: "/unavailable/share/book.pdf",
                                md5: "abcdef123", totalPages: 10)
        let byHash = Topic(title: "My notebook", bookMD5List: ["abcdef"])
        XCTAssertEqual(StudyNotebooksView.matchingDocument(for: byHash, documents: [document]), document)
        let byTitle = Topic(title: "Book")
        XCTAssertEqual(StudyNotebooksView.matchingDocument(for: byTitle, documents: [document]), document)
        let placeholder = Document(title: "Book", filePath: "", md5: "abcdef123", totalPages: 10)
        XCTAssertNil(StudyNotebooksView.matchingDocument(for: byTitle, documents: [placeholder]))
        XCTAssertNil(StudyNotebooksView.matchingDocument(for: Topic(title: "Unrelated"), documents: [document]))
    }
}
