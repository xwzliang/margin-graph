import SwiftUI
import AVKit
import AVFoundation

public struct FilmstripThumbnail: Identifiable, @unchecked Sendable {
    public let id: Int
    public let time: Double
    public let image: NSImage

    public init(id: Int, time: Double, image: NSImage) {
        self.id = id
        self.time = time
        self.image = image
    }
}

public struct MediaPlaybackContainerView: View {
    public var document: Document
    public var cards: [NoteCard]
    public var selectedCardID: UUID?
    public var studyDocuments: [Document]
    public var mediaStorage: MediaStorage?
    public var onSwitchDocument: ((Document) -> Void)?
    public var onManageDocuments: (() -> Void)?
    public var onCreateVideoCard: ((_ startTime: Double, _ endTime: Double, _ title: String) -> Void)?
    public var onSelectCard: ((UUID) -> Void)?
    public var showsHeader: Bool

    @StateObject private var coordinator = MediaPlaybackCoordinator()
    @State private var markInTime: Double? = nil
    @State private var filmstripThumbnails: [FilmstripThumbnail] = []

    private var player: AVPlayer? { coordinator.player }
    private var isPlaying: Bool { coordinator.isPlaying }
    private var currentTime: Double { coordinator.currentTime }
    private var duration: Double { coordinator.duration }
    private var playbackRate: Float { coordinator.playbackRate }

    private let speedOptions: [(rate: Float, label: String)] = [
        (0.5, "0.5"),
        (0.75, "0.75"),
        (1.0, "1x"),
        (1.25, "1.25"),
        (1.5, "1.5x"),
        (2.0, "2x")
    ]

    public init(
        document: Document,
        cards: [NoteCard] = [],
        selectedCardID: UUID? = nil,
        studyDocuments: [Document] = [],
        mediaStorage: MediaStorage? = nil,
        showsHeader: Bool = true,
        onSwitchDocument: ((Document) -> Void)? = nil,
        onManageDocuments: (() -> Void)? = nil,
        onCreateVideoCard: ((_ startTime: Double, _ endTime: Double, _ title: String) -> Void)? = nil,
        onSelectCard: ((UUID) -> Void)? = nil
    ) {
        self.document = document
        self.cards = cards
        self.selectedCardID = selectedCardID
        self.studyDocuments = studyDocuments
        self.mediaStorage = mediaStorage
        self.showsHeader = showsHeader
        self.onSwitchDocument = onSwitchDocument
        self.onManageDocuments = onManageDocuments
        self.onCreateVideoCard = onCreateVideoCard
        self.onSelectCard = onSelectCard
    }

    private var isVideo: Bool {
        document.documentType == "video" || MediaDocumentHelper.documentType(for: URL(fileURLWithPath: document.filePath)) == "video"
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Header Bar (optional when embedded under tab bar)
            if showsHeader {
                headerBar
            }

            // 2. Playback Canvas
            ZStack {
                Color.black

                if isVideo {
                    if let player {
                        NativeVideoPlayerView(
                            player: player,
                            onTogglePlayPause: {
                                togglePlayPause()
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        loadingPlaceholder
                    }
                } else {
                    audioPlayerView
                        .contentShape(Rectangle())
                        .onTapGesture {
                            togglePlayPause()
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 3. Filmstrip & Transport Controls Bar
            controlsBar
        }
        .background(Color(white: 0.96))
        .onAppear {
            setupPlayer()
            if let selectedCardID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    handleCardSelected(selectedCardID)
                }
            }
        }
        .onDisappear {
            teardownPlayer()
        }
        .onChange(of: document.filePath) { _, _ in
            filmstripThumbnails = []
            markInTime = nil
            teardownPlayer()
            setupPlayer()
            if let selectedCardID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    handleCardSelected(selectedCardID)
                }
            }
        }
        .onChange(of: coordinator.duration) { _, newDuration in
            if filmstripThumbnails.isEmpty && newDuration > 0 {
                loadFilmstripThumbnails()
            }
        }
        .onChange(of: selectedCardID) { _, cardID in
            handleCardSelected(cardID)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Document Switcher Menu
            Menu {
                ForEach(studyDocuments, id: \.id) { doc in
                    Button {
                        onSwitchDocument?(doc)
                    } label: {
                        HStack {
                            if doc.id == document.id {
                                Image(systemName: "checkmark")
                            }
                            Text(doc.title)
                        }
                    }
                }
                Divider()
                Button("Manage Documents…") {
                    onManageDocuments?()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isVideo ? "video.fill" : "waveform")
                        .font(.system(size: 11))
                        .foregroundStyle(isVideo ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color(red: 0.12, green: 0.60, blue: 0.42))
                    Text(document.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 320, alignment: .leading)

            Spacer()

            // Quick 30s Excerpt Button
            Button {
                quickExcerpt(duration: 30)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.system(size: 10))
                    Text("Excerpt 30s")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Create note card covering the current 30 seconds")
        }
        .padding(.horizontal, 12)
        .frame(height: MarginNoteTheme.topToolbarHeight)
        .background(MarginNoteTheme.shelfBackground)
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(MarginNoteTheme.separatorColor),
            alignment: .bottom
        )
    }

    // MARK: - Audio Player View

    private var audioPlayerView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.12, green: 0.60, blue: 0.42), Color(red: 0.08, green: 0.40, blue: 0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 140, height: 140)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)

                Image(systemName: "waveform")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 4) {
                Text(document.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text(MediaDocumentHelper.formatDuration(currentTime) + " / " + MediaDocumentHelper.formatDuration(duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
            Text("Loading media…")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controls Bar

    private var controlsBar: some View {
        VStack(spacing: 0) {
            // Filmstrip Timeline Track (68pt tall with thumbnails, ticks ruler, note range highlights & playhead)
            filmstripTrack
                .frame(height: 68)

            // Transport and Excerpt Controls Row (42pt)
            HStack(spacing: 12) {
                // Rewind 5s
                Button {
                    coordinator.stopAtTime = nil
                    seek(to: max(0, currentTime - 5))
                } label: {
                    Image(systemName: "gobackward.5")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Rewind 5 seconds")

                // Play / Pause
                Button {
                    togglePlayPause()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .background(Color.black.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                // Forward 5s
                Button {
                    coordinator.stopAtTime = nil
                    seek(to: min(duration, currentTime + 5))
                } label: {
                    Image(systemName: "goforward.5")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Forward 5 seconds")

                // Time Display
                Text("\(MediaDocumentHelper.formatDuration(currentTime)) / \(MediaDocumentHelper.formatDuration(duration))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                // MarginNote-Style Playback Speed Segmented Buttons
                speedSegmentedPills

                Spacer()

                // Merged Single Mark In / Mark Out Button
                markExcerptButton
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(MarginNoteTheme.shelfBackground)
        }
        .background(Color(white: 0.98))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(MarginNoteTheme.separatorColor),
            alignment: .top
        )
    }

    // MARK: - Speed Segmented Controls (MarginNote Style)

    private var speedSegmentedPills: some View {
        HStack(spacing: 0) {
            ForEach(0..<speedOptions.count, id: \.self) { idx in
                let opt = speedOptions[idx]
                let isSelected = abs(playbackRate - opt.rate) < 0.05
                Button {
                    setRate(opt.rate)
                } label: {
                    Text(opt.label)
                        .font(.system(size: 10.5, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(isSelected ? Color.accentColor : Color.clear)
                }
                .buttonStyle(.plain)

                if idx < speedOptions.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 0.5, height: 12)
                }
            }
        }
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 3.5))
        .overlay(
            RoundedRectangle(cornerRadius: 3.5)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Merged Mark Button

    @ViewBuilder
    private var markExcerptButton: some View {
        HStack(spacing: 6) {
            if let inTime = markInTime {
                // In-Progress State: Second click performs Mark Out and immediately creates card
                Button {
                    handleMarkButton()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Finish Excerpt (\(MediaDocumentHelper.formatDuration(inTime)))")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4.5))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Complete excerpt and create note card (no title)")

                // Small cancel button to reset marking
                Button {
                    markInTime = nil
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel marking")
            } else {
                // Idle State: First click performs Mark In
                Button {
                    handleMarkButton()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Mark Excerpt")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 4.5))
                }
                .buttonStyle(.plain)
                .help("First click sets start point (Mark In), second click sets end point (Mark Out)")
            }
        }
    }

    private func handleMarkButton() {
        if let inTime = markInTime {
            // Second click: Mark Out -> Create card immediately without title or confirmation
            let outTime = currentTime
            let start = min(inTime, outTime)
            let end = max(inTime, outTime)
            let finalEnd = (end - start) < 0.5 ? min(duration, start + 2.0) : end
            onCreateVideoCard?(start, finalEnd, "")
            markInTime = nil
        } else {
            // First click: Mark In
            markInTime = currentTime
        }
    }

    // MARK: - Filmstrip Timeline Track (MarginNote Style)

    private var filmstripTrack: some View {
        GeometryReader { geo in
            let totalW = max(1, geo.size.width)
            let totalH: CGFloat = 68
            let rulerH: CGFloat = 16
            let bodyH: CGFloat = totalH - rulerH // 52 pt

            ZStack(alignment: .topLeading) {
                // 1. Dark Filmstrip Base
                Color(white: 0.12)
                    .frame(width: totalW, height: totalH)

                // 2. Filmstrip Body (Thumbnails or Audio waveform)
                filmstripBodyView(totalW: totalW, bodyH: bodyH)
                    .offset(y: rulerH)

                // 3. Ruler at Top with Ticks & Time Labels
                rulerView(totalW: totalW, rulerH: rulerH)

                // 4. Note Range Highlights with Card Colors (without center horizontal lines)
                noteRangesView(totalW: totalW, bodyH: bodyH, rulerH: rulerH)

                // 5. Active In-Progress Excerpt Box
                if let inTime = markInTime, duration > 0 {
                    activeMarkRangeView(inTime: inTime, totalW: totalW, bodyH: bodyH, rulerH: rulerH)
                }

                // 6. Playhead Indicator Needle & Vertical Bar (Dark grey, center-aligned)
                if duration > 0 {
                    let pct = min(1.0, max(0.0, currentTime / duration))
                    let playheadX = pct * totalW
                    playheadIndicator(x: playheadX, totalH: totalH, rulerH: rulerH)
                }
            }
            .frame(width: totalW, height: totalH)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        coordinator.isScrubbing = true
                        coordinator.stopAtTime = nil
                        guard duration > 0, totalW > 0 else { return }
                        let pct = min(1.0, max(0.0, value.location.x / totalW))
                        seek(to: pct * duration)
                    }
                    .onEnded { value in
                        coordinator.isScrubbing = false
                        coordinator.stopAtTime = nil
                        guard duration > 0, totalW > 0 else { return }
                        let pct = min(1.0, max(0.0, value.location.x / totalW))
                        let seekTime = pct * duration
                        seek(to: seekTime)
                    }
            )
        }
    }

    @ViewBuilder
    private func rulerView(totalW: CGFloat, rulerH: CGFloat) -> some View {
        let tickInterval = rulerTickInterval(duration: duration, width: totalW)
        ZStack(alignment: .topLeading) {
            Color(white: 0.95)
                .frame(width: totalW, height: rulerH)

            if duration > 0 && tickInterval > 0 {
                let count = Int(duration / tickInterval)
                ForEach(0...count, id: \.self) { i in
                    let t = Double(i) * tickInterval
                    if t <= duration {
                        let x = (t / duration) * totalW
                        // Major tick mark
                        Rectangle()
                            .fill(Color(white: 0.6))
                            .frame(width: 1, height: 4)
                            .offset(x: x, y: rulerH - 4)

                        // Time label matching MarginNote format (e.g. 3m20s)
                        Text(MediaDocumentHelper.formatRulerTime(t))
                            .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color(white: 0.35))
                            .offset(x: max(2, min(totalW - 35, x - 12)), y: 1)
                    }
                }
            }

            // Bottom border of ruler
            Rectangle()
                .fill(Color.black.opacity(0.15))
                .frame(width: totalW, height: 0.5)
                .offset(y: rulerH - 0.5)
        }
    }

    @ViewBuilder
    private func filmstripBodyView(totalW: CGFloat, bodyH: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            if isVideo && !filmstripThumbnails.isEmpty {
                HStack(spacing: 0) {
                    let itemW = totalW / CGFloat(filmstripThumbnails.count)
                    ForEach(filmstripThumbnails) { thumb in
                        Image(nsImage: thumb.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: itemW, height: bodyH)
                            .clipped()
                    }
                }
                .frame(width: totalW, height: bodyH)
            } else if isVideo {
                // Placeholder segments while thumbnails load
                HStack(spacing: 2) {
                    let placeholderCount = max(4, Int(totalW / 60))
                    let segmentW = totalW / CGFloat(placeholderCount)
                    ForEach(0..<placeholderCount, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(white: 0.22))
                            .frame(width: segmentW - 2, height: bodyH)
                    }
                }
                .frame(width: totalW, height: bodyH)
                .background(Color(white: 0.16))
            } else {
                // Stylized audio waveform pattern
                audioWaveformTrack(totalW: totalW, bodyH: bodyH)
            }
        }
        .frame(width: totalW, height: bodyH)
    }

    @ViewBuilder
    private func audioWaveformTrack(totalW: CGFloat, bodyH: CGFloat) -> some View {
        HStack(spacing: 2) {
            let barCount = max(10, Int(totalW / 4.0))
            ForEach(0..<barCount, id: \.self) { i in
                let factor = abs(sin(Double(i) * 0.25) * cos(Double(i) * 0.12))
                let h = max(4, bodyH * CGFloat(0.2 + factor * 0.65))
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.12, green: 0.60, blue: 0.42).opacity(0.75))
                    .frame(width: 2, height: h)
            }
        }
        .frame(width: totalW, height: bodyH)
        .background(Color(white: 0.14))
    }

    @ViewBuilder
    private func noteRangesView(totalW: CGFloat, bodyH: CGFloat, rulerH: CGFloat) -> some View {
        ForEach(cards.filter { $0.videoStartTime != nil }, id: \.id) { card in
            if let start = card.videoStartTime, duration > 0 {
                let rawEnd = card.videoEndTime ?? (start + 5.0)
                let end = min(duration, max(start + 0.5, rawEnd))
                let x1 = (start / duration) * totalW
                let x2 = (end / duration) * totalW
                let boxW = max(8.0, x2 - x1)
                let isSelected = (card.id == selectedCardID)
                let colors = MarginNoteTheme.cardColors(for: card.colorIndex)

                ZStack(alignment: .topLeading) {
                    // Translucent fill matching card accent
                    Rectangle()
                        .fill(colors.accent.opacity(isSelected ? 0.38 : 0.22))
                        .frame(width: boxW, height: bodyH)

                    // Outer perimeter outline (no horizontal line across center)
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(colors.border, lineWidth: isSelected ? 2.0 : 1.5)
                        .frame(width: boxW, height: bodyH)

                    // Left cap handle ([)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(colors.border)
                        .frame(width: isSelected ? 4.0 : 3.0, height: bodyH)
                        .offset(x: 0, y: 0)

                    // Right cap handle (])
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(colors.border)
                        .frame(width: isSelected ? 4.0 : 3.0, height: bodyH)
                        .offset(x: boxW - (isSelected ? 4.0 : 3.0), y: 0)
                }
                .frame(width: boxW, height: bodyH)
                .shadow(color: isSelected ? colors.border.opacity(0.5) : Color.clear, radius: 2)
                .offset(x: x1, y: rulerH)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelectCard?(card.id)
                    handleCardSelected(card.id)
                }
                .help(card.title.isEmpty ? "Video Note (\(MediaDocumentHelper.formatDuration(start)) - \(MediaDocumentHelper.formatDuration(end)))" : "\(card.title) (\(MediaDocumentHelper.formatDuration(start)) - \(MediaDocumentHelper.formatDuration(end)))")
            }
        }
    }

    @ViewBuilder
    private func activeMarkRangeView(inTime: Double, totalW: CGFloat, bodyH: CGFloat, rulerH: CGFloat) -> some View {
        let start = min(inTime, currentTime)
        let end = max(inTime, currentTime)
        let x1 = (start / duration) * totalW
        let x2 = (end / duration) * totalW
        let boxW = max(6.0, x2 - x1)

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.30))
                .frame(width: boxW, height: bodyH)

            // Outer perimeter border
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.accentColor, lineWidth: 2.0)
                .frame(width: boxW, height: bodyH)

            // Left cap handle
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3.5, height: bodyH)
                .offset(x: 0, y: 0)

            // Right cap handle
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3.5, height: bodyH)
                .offset(x: boxW - 3.5, y: 0)
        }
        .frame(width: boxW, height: bodyH)
        .offset(x: x1, y: rulerH)
    }

    @ViewBuilder
    private func playheadIndicator(x: CGFloat, totalH: CGFloat, rulerH: CGFloat) -> some View {
        let darkGrey = Color(white: 0.22)
        let markerW: CGFloat = 11.0
        let markerH: CGFloat = rulerH - 1.0 // 15pt
        let lineW: CGFloat = 1.5

        ZStack(alignment: .top) {
            // Vertical bar through filmstrip and ruler, precisely centered at x = 0
            Rectangle()
                .fill(darkGrey)
                .frame(width: lineW, height: totalH)
                .offset(x: -lineW / 2.0, y: 0)

            // Marker sign at ruler, precisely centered at x = 0
            Path { path in
                let halfW = markerW / 2.0
                path.move(to: CGPoint(x: -halfW, y: 0))
                path.addLine(to: CGPoint(x: halfW, y: 0))
                path.addLine(to: CGPoint(x: halfW, y: markerH - 4.0))
                path.addLine(to: CGPoint(x: 0, y: markerH))
                path.addLine(to: CGPoint(x: -halfW, y: markerH - 4.0))
                path.closeSubpath()
            }
            .fill(darkGrey)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
        }
        .frame(width: 0, height: totalH)
        .offset(x: x, y: 0)
        .allowsHitTesting(false)
    }

    private func rulerTickInterval(duration: Double, width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 10 }
        let targetCount = max(4, Int(width / 75.0))
        let raw = duration / Double(targetCount)
        let niceIntervals: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600]
        return niceIntervals.first(where: { $0 >= raw }) ?? 60.0
    }

    private func loadFilmstripThumbnails() {
        guard isVideo else { return }
        let path = document.filePath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let dur = duration > 0 ? duration : MediaDocumentHelper.mediaDuration(url: URL(fileURLWithPath: path))
        guard dur > 0 else { return }

        Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2.0, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2.0, preferredTimescale: 600)

            let count = 16
            var results: [FilmstripThumbnail] = []
            for i in 0..<count {
                let t = Double(i) * dur / Double(count)
                let cmTime = CMTime(seconds: t, preferredTimescale: 600)
                if let cg = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                    let nsImg = NSImage(cgImage: cg, size: NSSize(width: 160, height: 90))
                    results.append(FilmstripThumbnail(id: i, time: t, image: nsImg))
                }
            }
            await MainActor.run {
                self.filmstripThumbnails = results
            }
        }
    }

    // MARK: - Player Management

    private func setupPlayer() {
        coordinator.setup(filePath: document.filePath)
        loadFilmstripThumbnails()
    }

    private func teardownPlayer() {
        coordinator.teardown()
    }

    private func togglePlayPause() {
        coordinator.togglePlayPause()
    }

    private func seek(to seconds: Double) {
        coordinator.seek(to: seconds)
    }

    private func setRate(_ rate: Float) {
        coordinator.setRate(rate)
    }

    private func quickExcerpt(duration excerptLen: Double) {
        let start = max(0, coordinator.currentTime)
        let end = min(coordinator.duration, start + excerptLen)
        onCreateVideoCard?(start, end, "")
    }

    private func handleCardSelected(_ cardID: UUID?) {
        guard let cardID,
              let card = cards.first(where: { $0.id == cardID }),
              let start = card.videoStartTime else { return }
        let end = card.videoEndTime ?? (start + 5.0)
        coordinator.seek(to: start)
        coordinator.play(until: end)
    }
}

// MARK: - Media Playback Coordinator

@MainActor
public final class MediaPlaybackCoordinator: ObservableObject {
    @Published public var player: AVPlayer?
    @Published public var isPlaying: Bool = false
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var playbackRate: Float = 1.0
    @Published public var stopAtTime: Double? = nil
    public var isScrubbing: Bool = false

    private var timeObserverToken: Any?
    private var endObserverToken: Any?
    private var lastToggleTimestamp: TimeInterval = 0

    public init() {}

    public func setup(filePath: String) {
        teardown()
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        let url = URL(fileURLWithPath: filePath)
        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.actionAtItemEnd = .pause
        newPlayer.rate = 0.0
        self.player = newPlayer
        self.isPlaying = false
        self.stopAtTime = nil
        self.duration = MediaDocumentHelper.mediaDuration(url: url)

        // Observe end of media playback so pause button automatically becomes play button
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = false
                self.stopAtTime = nil
                self.player?.pause()
            }
        }

        // 50ms interval for precise playback observation and range stopping
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak newPlayer] time in
            DispatchQueue.main.async {
                guard let self, let newPlayer, !self.isScrubbing else { return }
                let sec = CMTimeGetSeconds(time)
                if sec.isFinite && !sec.isNaN {
                    self.currentTime = sec

                    // Check if reached end boundary of card excerpt
                    if let stop = self.stopAtTime, sec >= stop {
                        self.stopAtTime = nil
                        self.pause()
                        self.seek(to: stop)
                        return
                    }

                    if self.duration > 0 && sec >= self.duration - 0.15 {
                        self.isPlaying = false
                    } else {
                        self.isPlaying = newPlayer.timeControlStatus == .playing
                    }
                }
            }
        }
    }

    public func teardown() {
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        player = nil
        isPlaying = false
        stopAtTime = nil
    }

    public func play() {
        guard let player else { return }
        // When at or near the end, replay starting from the beginning
        if duration > 0 && currentTime >= max(0, duration - 0.25) {
            seek(to: 0)
        }
        player.rate = playbackRate
        player.play()
        isPlaying = true
    }

    public func play(until endTime: Double?) {
        self.stopAtTime = endTime
        play()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        stopAtTime = nil
    }

    public func togglePlayPause() {
        let now = Date().timeIntervalSinceReferenceDate
        // 300ms debounce protects against mouse bounce or duplicate event delivery
        guard now - lastToggleTimestamp > 0.3 else { return }
        lastToggleTimestamp = now

        guard player != nil else { return }
        stopAtTime = nil
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func seek(to seconds: Double) {
        currentTime = seconds
        let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }
}

// MARK: - Native Video Player View (AppKit AVPlayerView)

#if canImport(AppKit)
public struct NativeVideoPlayerView: NSViewRepresentable {
    public var player: AVPlayer?
    public var showsControls: Bool = false
    public var onTogglePlayPause: (() -> Void)?

    public init(player: AVPlayer?, showsControls: Bool = false, onTogglePlayPause: (() -> Void)? = nil) {
        self.player = player
        self.showsControls = showsControls
        self.onTogglePlayPause = onTogglePlayPause
    }

    public func makeNSView(context: Context) -> CustomAVPlayerView {
        let view = CustomAVPlayerView()
        view.player = player
        view.controlsStyle = showsControls ? .inline : .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.onTogglePlayPause = onTogglePlayPause
        return view
    }

    public func updateNSView(_ nsView: CustomAVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.onTogglePlayPause = onTogglePlayPause
        let targetStyle: AVPlayerViewControlsStyle = showsControls ? .inline : .none
        if nsView.controlsStyle != targetStyle {
            nsView.controlsStyle = targetStyle
        }
    }
}

public final class CustomAVPlayerView: AVPlayerView {
    public var onTogglePlayPause: (() -> Void)?
    private var clickRecognizer: NSClickGestureRecognizer?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupClickHandling()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupClickHandling()
    }

    private func setupClickHandling() {
        let click = NSClickGestureRecognizer(target: self, action: #selector(handlePlayerClick(_:)))
        click.numberOfClicksRequired = 1
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
        self.clickRecognizer = click
    }

    @objc private func handlePlayerClick(_ sender: NSClickGestureRecognizer) {
        onTogglePlayPause?()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Intercept hits on internal AVPlayerView subviews and return self
        // so gesture recognizers reliably fire on CustomAVPlayerView.
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // Spacebar
            onTogglePlayPause?()
        } else {
            super.keyDown(with: event)
        }
    }
}
#endif
