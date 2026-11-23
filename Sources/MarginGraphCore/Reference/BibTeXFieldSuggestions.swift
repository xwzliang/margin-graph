import Foundation

public struct BibTeXFieldSuggestion: Identifiable, Equatable {
    public let name: String
    public let label: String?

    public var id: String { name }
}

extension BibTeXEntryDraft {
    public func fieldSuggestions(matching query: String = "") -> [BibTeXFieldSuggestion] {
        let entryType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var excluded = fieldNames
        return (Self.fields(for: entryType) + Self.sharedFields).compactMap { name in
            guard excluded.insert(name).inserted else { return nil }
            let label = Self.fieldLabels[name]
            let searchText = [name, label ?? ""].joined(separator: " ")
            guard words.allSatisfy({ searchText.localizedCaseInsensitiveContains($0) }) else { return nil }
            return BibTeXFieldSuggestion(name: name, label: label)
        }
    }

    private static func fields(for type: String) -> [String] {
        let book = ["title", "author", "editor", "publisher", "location", "date", "year", "edition",
                    "series", "volume", "number", "isbn", "pagetotal", "translator"]
        switch type {
        case "article":
            return ["title", "author", "journaltitle", "journal", "date", "year", "volume", "number", "issue",
                    "pages", "issn", "eprint", "eprinttype"]
        case "book", "mvbook", "collection", "mvcollection", "reference", "mvreference", "proceedings", "mvproceedings":
            return book
        case "inbook", "bookinbook", "suppbook", "incollection", "suppcollection", "inreference":
            return ["title", "author", "booktitle", "bookauthor", "pages", "chapter"] + book
        case "inproceedings", "conference":
            return ["title", "author", "booktitle", "eventtitle", "eventdate", "venue", "pages",
                    "editor", "organization", "publisher", "location", "date", "year", "isbn"]
        case "thesis", "mastersthesis", "phdthesis", "report", "techreport":
            return ["title", "author", "institution", "type", "number", "location", "date", "year", "pagetotal"]
        case "online", "electronic", "www":
            return ["title", "author", "organization", "url", "urldate", "date", "year", "version"]
        case "movie", "video", "audio", "music", "performance":
            return ["title", "author", "director", "producer", "editor", "date", "year",
                    "publisher", "location", "howpublished", "type"]
        case "dataset", "software":
            return ["title", "author", "version", "organization", "publisher", "date", "year", "url", "doi"]
        case "patent":
            return ["title", "author", "holder", "number", "type", "location", "date", "year"]
        case "periodical", "suppperiodical":
            return ["title", "editor", "issuetitle", "volume", "number", "issue", "date", "year", "issn"]
        case "manual", "booklet":
            return ["title", "author", "organization", "edition", "version", "howpublished", "location", "date", "year"]
        default:
            return ["title", "author", "date", "year", "howpublished"]
        }
    }

    private static let sharedFields = [
        "subtitle", "shorttitle", "abstract", "keywords", "langid", "language", "note", "annotation",
        "file", "url", "urldate", "doi", "crossref"
    ]

    private static let fieldLabels = [
        "annotation": "Personal annotation",
        "bookauthor": "Book author",
        "booktitle": "Book or proceedings title",
        "crossref": "Parent citation key",
        "doi": "Digital object identifier",
        "eprint": "Archive identifier",
        "eprinttype": "Archive name",
        "eventdate": "Event date",
        "eventtitle": "Event title",
        "file": "File attachment",
        "holder": "Patent holder",
        "howpublished": "How published",
        "issuetitle": "Issue title",
        "journal": "Journal title (BibTeX)",
        "journaltitle": "Journal title (BibLaTeX)",
        "langid": "Language identifier",
        "location": "Place of publication",
        "pagetotal": "Total pages",
        "shorttitle": "Short title",
        "urldate": "URL access date"
    ]
}
