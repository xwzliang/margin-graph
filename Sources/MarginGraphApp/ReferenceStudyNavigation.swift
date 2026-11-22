import Foundation
import MarginGraphCore

struct ReferenceStudyTarget: Sendable {
    var topic: Topic?
    var document: Document?
    var attachment: URL?
    var isSaved = false

    var title: String? { topic?.title ?? document?.title ?? attachment?.deletingPathExtension().lastPathComponent }
}

enum ReferenceStudyError: LocalizedError {
    case cannotOpenPDF
    case cannotOpenNotebook

    var errorDescription: String? {
        switch self {
        case .cannotOpenPDF: "MarginGraph couldn’t open this PDF. Choose its current location and try again."
        case .cannotOpenNotebook: "This study notebook is no longer available in the current library."
        }
    }
}

extension AppModel {
    func referenceStudyTarget(for entry: BibTeXEntry, bibliography: URL) async throws -> ReferenceStudyTarget {
        let database = database
        let topics = topics
        let documents = documents
        return try await Task.detached {
            let saved = try database.referenceStudyLink(bibliography: bibliography, key: entry.key)
            let attachments = ReferenceStudyMatcher.pdfAttachments(for: entry, bibliography: bibliography)
            let attachment = attachments.first { FileManager.default.isReadableFile(atPath: $0.path) }
            if let saved, let topic = topics.first(where: { $0.id == saved.topicID }) {
                let notebookDocuments = try database.documentsForTopic(id: topic.id).filter(Self.isReadablePDF)
                let preferred = saved.bookMD5.flatMap { hash in
                    notebookDocuments.first { Database.bookHashesMatch(hash, $0.md5) }
                }
                let matched = preferred ?? ReferenceStudyMatcher.document(for: entry, attachments: attachments, in: notebookDocuments)
                let defaultPDF = saved.bookMD5 == nil
                    ? topic.lastDocumentMD5.flatMap { hash in
                        notebookDocuments.first { Database.bookHashesMatch(hash, $0.md5) }
                    } ?? notebookDocuments.first
                    : nil
                return ReferenceStudyTarget(topic: topic, document: matched ?? defaultPDF,
                                            attachment: attachment, isSaved: true)
            }

            let document = ReferenceStudyMatcher.document(for: entry, attachments: attachments, in: documents)
            if let document {
                let topic = try database.preferredTopic(for: document, topics: topics)
                return ReferenceStudyTarget(topic: topic, document: document, attachment: attachment)
            }
            if let topic = ReferenceStudyMatcher.topic(for: entry, in: topics) {
                let notebookDocuments = try database.documentsForTopic(id: topic.id).filter(Self.isReadablePDF)
                if notebookDocuments.count <= 1 {
                    return ReferenceStudyTarget(topic: topic, document: notebookDocuments.first, attachment: attachment)
                }
                // A title match alone cannot choose a PDF within a multi-document notebook.
            }
            return ReferenceStudyTarget(attachment: attachment)
        }.value
    }

    func saveReferenceStudyTarget(_ topic: Topic, for entry: BibTeXEntry, bibliography: URL) throws {
        guard topics.contains(where: { $0.id == topic.id }) else { throw ReferenceStudyError.cannotOpenNotebook }
        if try database.referenceStudyLink(bibliography: bibliography, key: entry.key)?.topicID == topic.id { return }
        try database.saveReferenceStudyLink(ReferenceStudyLink(topicID: topic.id), bibliography: bibliography, key: entry.key)
    }

    func openReferenceStudy(_ target: ReferenceStudyTarget, entry: BibTeXEntry, bibliography: URL,
                            locatedPDF: URL? = nil) throws {
        let intendedTopic = target.topic.flatMap { targetTopic in topics.first { $0.id == targetTopic.id } }
        var document = target.document
        if let file = locatedPDF ?? (document == nil ? target.attachment : nil) {
            let path = file.standardizedFileURL.path
            document = documents.first { URL(fileURLWithPath: $0.filePath).standardizedFileURL.path == path }
            if document == nil { document = openDocument(url: file) }
            guard document != nil else { throw ReferenceStudyError.cannotOpenPDF }
        }

        if let intendedTopic {
            if let document {
                let notebookDocuments = try database.documentsForTopic(id: intendedTopic.id)
                if !notebookDocuments.contains(where: { $0.id == document.id }) {
                    try database.addDocument(to: intendedTopic.id, md5: document.md5)
                }
            }
            enterStudyWorkspace(topic: intendedTopic)
            if let document, activeDocument?.id != document.id { switchToDocument(document) }
        } else if let document {
            openDocumentInReader(document: document)
        } else {
            throw ReferenceStudyError.cannotOpenNotebook
        }

        guard let topicID = selectedTopicID else { throw ReferenceStudyError.cannotOpenNotebook }
        if let document, activeDocument?.id != document.id || manager == nil {
            exitStudyWorkspace()
            throw ReferenceStudyError.cannotOpenPDF
        }
        if document == nil { workspaceMode = .mindMapOnly }
        if document == nil && target.isSaved { return }
        try database.saveReferenceStudyLink(ReferenceStudyLink(topicID: topicID, bookMD5: document?.md5),
                                            bibliography: bibliography, key: entry.key)
    }

    nonisolated private static func isReadablePDF(_ document: Document) -> Bool {
        !document.filePath.isEmpty &&
            (document.documentType == "pdf" || URL(fileURLWithPath: document.filePath).pathExtension.lowercased() == "pdf") &&
            FileManager.default.isReadableFile(atPath: document.filePath)
    }
}
