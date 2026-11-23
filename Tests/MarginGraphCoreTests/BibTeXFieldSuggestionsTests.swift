import XCTest
@testable import MarginGraphCore

final class BibTeXFieldSuggestionsTests: XCTestCase {
    func testSuggestionsFollowEntryTypeAndHideExistingFields() {
        var draft = BibTeXEntryDraft()
        draft.fields.append(.init(name: " ISBN "))
        var names = draft.fieldSuggestions().map(\.name)
        XCTAssertTrue(names.contains("edition"))
        XCTAssertTrue(names.contains("publisher"))
        XCTAssertFalse(names.contains("isbn"))
        XCTAssertFalse(names.contains("title"))
        XCTAssertFalse(names.contains("journaltitle"))
        XCTAssertEqual(names.count, Set(names).count)

        draft.type = " Article "
        names = draft.fieldSuggestions().map(\.name)
        XCTAssertTrue(names.contains("journaltitle"))
        XCTAssertTrue(names.contains("issn"))
        XCTAssertFalse(names.contains("edition"))

        draft.type = "CustomEntryType"
        XCTAssertTrue(draft.fieldSuggestions().contains { $0.name == "file" })
    }

    func testSearchMatchesFieldNamesAndReadableLabels() {
        var draft = BibTeXEntryDraft()
        draft.type = "electronic"
        XCTAssertEqual(draft.fieldSuggestions(matching: "ACCESS DATE").map(\.name), ["urldate"])
        XCTAssertEqual(draft.fieldSuggestions(matching: "file").map(\.name), ["file"])
        XCTAssertTrue(draft.fieldSuggestions(matching: "project-id").isEmpty)
    }

    func testCustomFieldUsesDraftValidation() throws {
        let draft = BibTeXEntryDraft()
        XCTAssertEqual(try draft.fieldNameForAddition(" project_id "), "project_id")
        XCTAssertThrowsError(try draft.fieldNameForAddition("Title"))
        XCTAssertThrowsError(try draft.fieldNameForAddition("invalid field"))
        XCTAssertThrowsError(try draft.fieldNameForAddition(""))
    }
}
