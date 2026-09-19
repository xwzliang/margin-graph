import Foundation

public extension Database {
    func cardsForDocument(md5: String) throws -> [NoteCard] {
        try cards(
            sql: "SELECT * FROM cards WHERE book_md5 = ? OR book_md5 LIKE ? OR ? LIKE (book_md5 || '%') ORDER BY created_at",
            values: [md5, "\(md5)%", md5]
        )
    }
}
