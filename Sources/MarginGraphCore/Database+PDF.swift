import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

public extension Database {
    func cardsForDocument(md5: String) throws -> [NoteCard] {
        try cards(
            sql: "SELECT * FROM cards WHERE book_md5 = ? OR book_md5 LIKE ? OR ? LIKE (book_md5 || '%') ORDER BY created_at",
            values: [md5, "\(md5)%", md5]
        )
    }

    /// Deletes all cards associated with a specific document by MD5.
    func deleteCardsForDocument(md5: String) throws {
        try withStatement("DELETE FROM cards WHERE book_md5 = ? OR book_md5 LIKE ? OR ? LIKE (book_md5 || '%')") { statement in
            bind(md5, to: 1, in: statement)
            bind("\(md5)%", to: 2, in: statement)
            bind(md5, to: 3, in: statement)
            try requireDone(statement)
        }
    }

    func getBookmarks(for md5: String) throws -> Set<Int> {
        try withStatement("SELECT page_index FROM document_bookmarks WHERE document_md5=? ORDER BY page_index") { statement in
            bind(md5, to: 1, in: statement)
            var pages = Set<Int>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let p = int(statement, 0) {
                    pages.insert(p)
                }
            }
            return pages
        }
    }

    func setBookmark(md5: String, pageIndex: Int, isBookmarked: Bool) throws {
        if isBookmarked {
            try withStatement("INSERT OR REPLACE INTO document_bookmarks(document_md5, page_index, created_at) VALUES(?,?,?)") { statement in
                bind(md5, to: 1, in: statement)
                bind(pageIndex, to: 2, in: statement)
                bind(Date().timeIntervalSince1970, to: 3, in: statement)
                sqlite3_step(statement)
            }
        } else {
            try withStatement("DELETE FROM document_bookmarks WHERE document_md5=? AND page_index=?") { statement in
                bind(md5, to: 1, in: statement)
                bind(pageIndex, to: 2, in: statement)
                sqlite3_step(statement)
            }
        }
    }
}
