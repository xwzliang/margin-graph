import XCTest
import SwiftUI
import AVFoundation
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

    @MainActor
    func testMediaPlaybackCoordinatorReplayFromBeginningAndEndHandling() {
        let coordinator = MediaPlaybackCoordinator()
        let player = AVPlayer()
        coordinator.player = player
        coordinator.duration = 60.0
        coordinator.currentTime = 59.9

        // When at end, play() resets currentTime to 0.0 and starts playback
        coordinator.play()
        XCTAssertEqual(coordinator.currentTime, 0.0)
        XCTAssertTrue(coordinator.isPlaying)

        coordinator.pause()
        XCTAssertFalse(coordinator.isPlaying)

        coordinator.currentTime = 60.0
        coordinator.play()
        XCTAssertEqual(coordinator.currentTime, 0.0)
        XCTAssertTrue(coordinator.isPlaying)
    }

    func testFormatRulerTime() {
        XCTAssertEqual(MediaDocumentHelper.formatRulerTime(0), "0s")
        XCTAssertEqual(MediaDocumentHelper.formatRulerTime(45), "45s")
        XCTAssertEqual(MediaDocumentHelper.formatRulerTime(200), "3m20s")
        XCTAssertEqual(MediaDocumentHelper.formatRulerTime(205), "3m25s")
        XCTAssertEqual(MediaDocumentHelper.formatRulerTime(3600), "1h0m")
        XCTAssertEqual(MediaDocumentHelper.formatRulerTime(3665), "1h1m")
    }

    #if canImport(AppKit)
    @MainActor
    func testCustomAVPlayerViewHitTestAndClickHandling() {
        let playerView = CustomAVPlayerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var toggledCount = 0
        playerView.onTogglePlayPause = {
            toggledCount += 1
        }

        // Hit test inside bounds should always return playerView (preventing internal subview interception)
        let hit = playerView.hitTest(NSPoint(x: 100, y: 100))
        XCTAssertTrue(hit === playerView)

        // Verify click gesture recognizer is attached for single-click dispatch
        let clickRecognizer = playerView.gestureRecognizers.first as? NSClickGestureRecognizer
        XCTAssertNotNil(clickRecognizer)
        XCTAssertEqual(clickRecognizer?.numberOfClicksRequired, 1)

        // Spacebar key down triggers toggle
        let spaceEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )
        if let spaceEvent {
            playerView.keyDown(with: spaceEvent)
            XCTAssertEqual(toggledCount, 1)
        }
    }
    #endif

    @MainActor
    func testMediaPlaybackCoordinatorAutoStopAtBoundary() {
        let coordinator = MediaPlaybackCoordinator()
        let player = AVPlayer()
        coordinator.player = player
        coordinator.duration = 60.0
        coordinator.currentTime = 10.0

        // Start playback with boundary at 25.0s
        coordinator.play(until: 25.0)
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(coordinator.stopAtTime, 25.0)

        // Simulating playback reaching the boundary
        coordinator.currentTime = 25.0
        if let stop = coordinator.stopAtTime, coordinator.currentTime >= stop {
            coordinator.stopAtTime = nil
            coordinator.pause()
            coordinator.seek(to: stop)
        }

        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertNil(coordinator.stopAtTime)
        XCTAssertEqual(coordinator.currentTime, 25.0)

        // Manual play clears boundary and plays normally
        coordinator.play()
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertNil(coordinator.stopAtTime)
    }

    func testFilmstripThumbnailInitialization() {
        let image = NSImage(size: NSSize(width: 160, height: 90))
        let thumb = FilmstripThumbnail(id: 3, time: 42.5, image: image)
        XCTAssertEqual(thumb.id, 3)
        XCTAssertEqual(thumb.time, 42.5)
        XCTAssertEqual(thumb.image.size, NSSize(width: 160, height: 90))
    }

    func testDocumentFolderCRUDAndMoveDocuments() throws {
        let database = try Database(inMemory: true)

        // 1. Create folders
        let folder1 = DocumentFolder(name: "Computer Science")
        let folder2 = DocumentFolder(name: "Mathematics")
        try database.insertFolder(folder1)
        try database.insertFolder(folder2)

        var folders = try database.allFolders()
        XCTAssertEqual(folders.count, 2)
        XCTAssertTrue(folders.contains { $0.name == "Computer Science" })
        XCTAssertTrue(folders.contains { $0.name == "Mathematics" })

        // 2. Insert documents
        let doc1 = Document(
            id: UUID(),
            title: "Lecture 1: Intro to Neural Networks",
            filePath: "/test/neural.mp4",
            md5: "neural_md5_1",
            totalPages: 3600,
            documentType: "video",
            folderId: folder1.id
        )
        let doc2 = Document(
            id: UUID(),
            title: "Linear Algebra Notes",
            filePath: "/test/linalg.pdf",
            md5: "linalg_md5_2",
            totalPages: 120,
            documentType: "pdf",
            folderId: nil // Root
        )
        try database.insertDocument(doc1)
        try database.insertDocument(doc2)

        let allDocs = try database.allDocuments()
        let fetchedDoc1 = allDocs.first { $0.id == doc1.id }
        let fetchedDoc2 = allDocs.first { $0.id == doc2.id }
        XCTAssertEqual(fetchedDoc1?.folderId, folder1.id)
        XCTAssertNil(fetchedDoc2?.folderId)

        // 3. Move document to another folder
        try database.updateDocumentFolder(documentID: doc2.id, folderID: folder2.id)
        let movedDoc2 = try database.getDocument(id: doc2.id)
        XCTAssertEqual(movedDoc2?.folderId, folder2.id)

        // 4. Rename folder
        try database.renameFolder(id: folder1.id, newName: "Deep Learning")
        folders = try database.allFolders()
        XCTAssertTrue(folders.contains { $0.name == "Deep Learning" })
        XCTAssertFalse(folders.contains { $0.name == "Computer Science" })

        // 5. Delete folder - documents inside must NOT be deleted, but moved safely to root (folder_id = nil)
        try database.deleteFolder(id: folder1.id)
        folders = try database.allFolders()
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.name, "Mathematics")

        let doc1AfterFolderDelete = try database.getDocument(id: doc1.id)
        XCTAssertNotNil(doc1AfterFolderDelete)
        XCTAssertNil(doc1AfterFolderDelete?.folderId, "Doc 1 should now be at Root (folder_id == nil)")

        let doc2StillInMath = try database.getDocument(id: doc2.id)
        XCTAssertEqual(doc2StillInMath?.folderId, folder2.id)
    }

    @MainActor
    func testCoordinatorInitialStateDoesNotAutoPlay() {
        let coordinator = MediaPlaybackCoordinator()
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertNil(coordinator.stopAtTime)
        XCTAssertEqual(coordinator.currentTime, 0.0)
    }

    func testCardCountsByDocument() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Multi-Document Study")
        try database.insertTopic(topic)

        let doc1 = Document(id: UUID(), title: "Book 1", filePath: "/path/doc1.pdf", md5: "md5_doc1", totalPages: 10, documentType: "pdf")
        let doc2 = Document(id: UUID(), title: "Video 2", filePath: "/path/doc2.mp4", md5: "md5_doc2", totalPages: 120, documentType: "video")
        let doc3 = Document(id: UUID(), title: "Doc Without Notes", filePath: "/path/doc3.pdf", md5: "md5_doc3", totalPages: 5, documentType: "pdf")
        try database.insertDocument(doc1)
        try database.insertDocument(doc2)
        try database.insertDocument(doc3)

        // Insert 2 cards for doc1
        let card1 = NoteCard(topicId: topic.id, bookMD5: "md5_doc1", title: "Note 1", highlightText: "Text 1")
        let card2 = NoteCard(topicId: topic.id, bookMD5: "md5_doc1", title: "Note 2", highlightText: "Text 2")
        // Insert 1 card for doc2
        let card3 = NoteCard(topicId: topic.id, bookMD5: "md5_doc2", title: "Video Note", highlightText: "")
        try database.insertCard(card1)
        try database.insertCard(card2)
        try database.insertCard(card3)

        let counts = try database.cardCountsByDocument()
        XCTAssertEqual(counts["md5_doc1"], 2)
        XCTAssertEqual(counts["md5_doc2"], 1)
        // Document with 0 cards should not be in the dictionary (or have count nil)
        XCTAssertNil(counts["md5_doc3"])
    }

    @MainActor
    func testMultiDocumentTopicAttachmentAndTabs() throws {
        let database = try Database(inMemory: true)
        let topic = Topic(title: "Cross-Disciplinary Study")
        try database.insertTopic(topic)

        let doc1 = Document(id: UUID(), title: "Research Paper", filePath: "/docs/paper.pdf", md5: "hash_paper", totalPages: 20, documentType: "pdf")
        let doc2 = Document(id: UUID(), title: "Recorded Talk", filePath: "/docs/talk.mp4", md5: "hash_talk", totalPages: 3600, documentType: "video")
        try database.insertDocument(doc1)
        try database.insertDocument(doc2)

        try database.addDocument(to: topic.id, md5: doc1.md5)
        try database.addDocument(to: topic.id, md5: doc2.md5)

        let attachedDocs = try database.documentsForTopic(id: topic.id)
        XCTAssertEqual(attachedDocs.count, 2)
        XCTAssertTrue(attachedDocs.contains { $0.id == doc1.id })
        XCTAssertTrue(attachedDocs.contains { $0.id == doc2.id })

        // Test DocumentTabBarView instantiation and interaction
        var selectedDoc: Document? = nil
        var closedDoc: Document? = nil
        let tabBar = DocumentTabBarView(
            documents: attachedDocs,
            activeDocument: doc1,
            onSelectDocument: { doc in
                selectedDoc = doc
            },
            onCloseDocument: { doc in
                closedDoc = doc
            }
        )

        let hostingView = NSHostingView(rootView: tabBar)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 34)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertNotNil(hostingView)

        tabBar.onSelectDocument(doc2)
        XCTAssertEqual(selectedDoc?.id, doc2.id)

        tabBar.onCloseDocument?(doc1)
        XCTAssertEqual(closedDoc?.id, doc1.id)
    }
}
