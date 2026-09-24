import XCTest
import SwiftUI
@testable import MarginGraphCore

final class MediaDocumentTests: XCTestCase {
    func testDocumentTypeDetection() {
        let videoURLs = [
            URL(fileURLWithPath: "/path/to/movie.mp4"),
            URL(fileURLWithPath: "/path/to/clip.mov"),
            URL(fileURLWithPath: "/path/to/show.m4v"),
            URL(fileURLWithPath: "/path/to/recording.mkv"),
            URL(fileURLWithPath: "/path/to/lecture.webm"),
            URL(fileURLWithPath: "/path/to/film.avi")
        ]
        for url in videoURLs {
            XCTAssertEqual(MediaDocumentHelper.documentType(for: url), "video", "Failed for \(url)")
            XCTAssertTrue(MediaDocumentHelper.isMedia(url: url))
            XCTAssertTrue(MediaDocumentHelper.isSupportedFile(url: url))
        }

        let audioURLs = [
            URL(fileURLWithPath: "/path/to/song.mp3"),
            URL(fileURLWithPath: "/path/to/audiobook.m4a"),
            URL(fileURLWithPath: "/path/to/sample.wav"),
            URL(fileURLWithPath: "/path/to/track.flac"),
            URL(fileURLWithPath: "/path/to/voice.aac"),
            URL(fileURLWithPath: "/path/to/instrument.aiff"),
            URL(fileURLWithPath: "/path/to/memo.caf")
        ]
        for url in audioURLs {
            XCTAssertEqual(MediaDocumentHelper.documentType(for: url), "audio", "Failed for \(url)")
            XCTAssertTrue(MediaDocumentHelper.isMedia(url: url))
            XCTAssertTrue(MediaDocumentHelper.isSupportedFile(url: url))
        }

        let pdfURL = URL(fileURLWithPath: "/path/to/book.pdf")
        XCTAssertEqual(MediaDocumentHelper.documentType(for: pdfURL), "pdf")
        XCTAssertFalse(MediaDocumentHelper.isMedia(url: pdfURL))
        XCTAssertTrue(MediaDocumentHelper.isSupportedFile(url: pdfURL))

        let epubURL = URL(fileURLWithPath: "/path/to/novel.epub")
        XCTAssertEqual(MediaDocumentHelper.documentType(for: epubURL), "epub")
        XCTAssertFalse(MediaDocumentHelper.isMedia(url: epubURL))
        XCTAssertTrue(MediaDocumentHelper.isSupportedFile(url: epubURL))

        let unknownURL = URL(fileURLWithPath: "/path/to/file.xyz")
        XCTAssertFalse(MediaDocumentHelper.isMedia(url: unknownURL))
        XCTAssertFalse(MediaDocumentHelper.isSupportedFile(url: unknownURL))
    }

    func testFormatDuration() {
        XCTAssertEqual(MediaDocumentHelper.formatDuration(0), "00:00")
        XCTAssertEqual(MediaDocumentHelper.formatDuration(9), "00:09")
        XCTAssertEqual(MediaDocumentHelper.formatDuration(65), "01:05")
        XCTAssertEqual(MediaDocumentHelper.formatDuration(3600), "1:00:00")
        XCTAssertEqual(MediaDocumentHelper.formatDuration(3665), "1:01:05")
        XCTAssertEqual(MediaDocumentHelper.formatDuration(7325), "2:02:05")
        XCTAssertEqual(MediaDocumentHelper.formatDuration(-10), "00:00")
    }

    func testStreamingFileMD5AndSidecarCaching() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleFile = tempDir.appendingPathComponent("sample_video.mp4")
        let dummyData = Data(repeating: 0x42, count: 2 * 1024 * 1024) // 2MB dummy payload
        try dummyData.write(to: sampleFile)

        let hash1 = MediaDocumentHelper.computeFileMD5(url: sampleFile)
        XCTAssertFalse(hash1.isEmpty)
        XCTAssertEqual(hash1.count, 32)

        // Verify sidecar exists
        let sidecarURL = sampleFile.appendingPathExtension("md5")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        let cachedContent = try String(contentsOf: sidecarURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(cachedContent, hash1)

        // Recompute: should read from sidecar instantly
        let hash2 = MediaDocumentHelper.computeFileMD5(url: sampleFile)
        XCTAssertEqual(hash1, hash2)
    }

    func testDatabaseSyncWithMediaFiles() throws {
        let database = try Database(inMemory: true)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoFile = tempDir.appendingPathComponent("Stanford_Lecture_01.mp4")
        let audioFile = tempDir.appendingPathComponent("History_Podcast_EP10.mp3")
        try "video content 12345".data(using: .utf8)!.write(to: videoFile)
        try "audio content 67890".data(using: .utf8)!.write(to: audioFile)

        try database.syncAvailableDocuments(additionalSearchPaths: [tempDir])

        let allDocs = try database.allDocuments()
        XCTAssertGreaterThanOrEqual(allDocs.count, 2)

        let videoDoc = allDocs.first(where: { $0.title == "Stanford_Lecture_01" })
        XCTAssertNotNil(videoDoc)
        XCTAssertEqual(videoDoc?.documentType, "video")
        XCTAssertTrue(videoDoc?.filePath.contains("Stanford_Lecture_01.mp4") == true)

        let audioDoc = allDocs.first(where: { $0.title == "History_Podcast_EP10" })
        XCTAssertNotNil(audioDoc)
        XCTAssertEqual(audioDoc?.documentType, "audio")
        XCTAssertTrue(audioDoc?.filePath.contains("History_Podcast_EP10.mp3") == true)
    }

    func testVideoExcerptNoteCardPersistence() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Machine Learning Course")
        try database.insertTopic(topic)

        let cardID = UUID()
        let videoCard = NoteCard(
            id: cardID,
            topicId: topic.id,
            bookMD5: "video_hash_12345",
            title: "Gradient Descent Concept",
            highlightText: "",
            notesText: "Explained between 02:15 and 04:30",
            mindPos: CGPoint(x: 150, y: 200),
            startPage: 0,
            endPage: 0,
            startPos: nil,
            endPos: nil,
            colorIndex: 1,
            highlightPicHash: "poster_abc123",
            mediaType: "video",
            videoStartTime: 135.0,
            videoEndTime: 270.0,
            createdAt: Date(),
            updatedAt: Date()
        )

        try database.insertCard(videoCard)

        let fetched = try database.getCard(id: cardID)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.mediaType, "video")
        XCTAssertEqual(fetched?.videoStartTime, 135.0)
        XCTAssertEqual(fetched?.videoEndTime, 270.0)
        XCTAssertEqual(fetched?.highlightPicHash, "poster_abc123")
        XCTAssertEqual(fetched?.title, "Gradient Descent Concept")
    }

    @MainActor
    func testMediaPlaybackContainerViewInstantiation() {
        let doc = Document(
            title: "Test Lecture",
            filePath: "/tmp/test.mp4",
            md5: "dummy_md5_123",
            totalPages: 120,
            documentType: "video"
        )
        let view = MediaPlaybackContainerView(document: doc)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertNotNil(hostingView)
    }
}
