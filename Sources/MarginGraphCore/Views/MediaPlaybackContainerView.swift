import SwiftUI
import AVKit
import AVFoundation

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

    @StateObject private var coordinator = MediaPlaybackCoordinator()
    @State private var markInTime: Double? = nil
    @State private var markOutTime: Double? = nil
    @State private var draftCardTitle: String = ""
    @State private var showingSaveSheet: Bool = false

    private var player: AVPlayer? { coordinator.player }
    private var isPlaying: Bool { coordinator.isPlaying }
    private var currentTime: Double { coordinator.currentTime }
    private var duration: Double { coordinator.duration }
    private var playbackRate: Float { coordinator.playbackRate }

    public init(
        document: Document,
        cards: [NoteCard] = [],
        selectedCardID: UUID? = nil,
        studyDocuments: [Document] = [],
        mediaStorage: MediaStorage? = nil,
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
            // 1. Unified 44pt Header Bar
            headerBar

            // 2. Playback Canvas
            ZStack {
                Color.black

                if isVideo {
                    if let player {
                        NativeVideoPlayerView(player: player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        loadingPlaceholder
                    }
                } else {
                    audioPlayerView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 3. Excerpting & Scrubber Controls Bar
            controlsBar
        }
        .background(Color(white: 0.96))
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            teardownPlayer()
        }
        .onChange(of: document.filePath) { _, _ in
            teardownPlayer()
            setupPlayer()
        }
        .onChange(of: selectedCardID) { _, cardID in
            handleCardSelected(cardID)
        }
        .sheet(isPresented: $showingSaveSheet) {
            saveExcerptSheet
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

            // Playback Rate Menu
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        setRate(Float(rate))
                    } label: {
                        HStack {
                            if playbackRate == Float(rate) {
                                Image(systemName: "checkmark")
                            }
                            Text(String(format: "%.2fx", rate))
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(String(format: "%.1fx", playbackRate))
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "speedometer")
                        .font(.system(size: 10))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 3.5))
            }
            .menuStyle(.borderlessButton)

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
        VStack(spacing: 6) {
            // Timeline Scrubber & Card Markers
            VStack(spacing: 2) {
                // Slider
                Slider(
                    value: Binding(
                        get: { currentTime },
                        set: { newTime in
                            seek(to: newTime)
                        }
                    ),
                    in: 0...max(1, duration),
                    onEditingChanged: { editing in
                        coordinator.isScrubbing = editing
                    }
                )
                .tint(Color.accentColor)

                // Note Card Markers on Timeline
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        ForEach(cards.filter { $0.videoStartTime != nil }, id: \.id) { c in
                            if let start = c.videoStartTime, duration > 0 {
                                let pct = min(1.0, max(0.0, start / duration))
                                Circle()
                                    .fill(c.id == selectedCardID ? Color.accentColor : Color.orange)
                                    .frame(width: 7, height: 7)
                                    .offset(x: pct * w - 3.5, y: -2)
                                    .onTapGesture {
                                        onSelectCard?(c.id)
                                        seek(to: start)
                                    }
                                    .help("\(c.title.isEmpty ? "Video Note" : c.title) (\(MediaDocumentHelper.formatDuration(start)))")
                            }
                        }
                    }
                }
                .frame(height: 6)
            }

            // Playback and Mark In/Out Buttons
            HStack(spacing: 14) {
                // Rewind 5s
                Button {
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
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                        .background(Color.black.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                // Forward 5s
                Button {
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

                Spacer()

                // Mark In Button
                Button {
                    markInTime = currentTime
                    if let out = markOutTime, out <= currentTime {
                        markOutTime = min(duration, currentTime + 30)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.right.to.line")
                            .font(.system(size: 9))
                        Text(markInTime != nil ? "In: \(MediaDocumentHelper.formatDuration(markInTime!))" : "Mark In")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(markInTime != nil ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)

                // Mark Out Button
                Button {
                    markOutTime = currentTime
                    if markInTime == nil {
                        markInTime = max(0, currentTime - 30)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.left.to.line")
                            .font(.system(size: 9))
                        Text(markOutTime != nil ? "Out: \(MediaDocumentHelper.formatDuration(markOutTime!))" : "Mark Out")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(markOutTime != nil ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)

                // Save Range Card Button
                if markInTime != nil || markOutTime != nil {
                    Button {
                        draftCardTitle = "Note at \(MediaDocumentHelper.formatDuration(markInTime ?? currentTime))"
                        showingSaveSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                            Text("Create Card")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        markInTime = nil
                        markOutTime = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.98))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(MarginNoteTheme.separatorColor),
            alignment: .top
        )
    }

    // MARK: - Save Excerpt Sheet

    private var saveExcerptSheet: some View {
        VStack(spacing: 16) {
            Text("Create Video Note Card")
                .font(.headline)

            let start = markInTime ?? max(0, currentTime - 15)
            let end = markOutTime ?? min(duration, start + 30)

            HStack {
                Text("Time Range:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(MediaDocumentHelper.formatDuration(start)) – \(MediaDocumentHelper.formatDuration(end)) (\(Int((end - start).rounded()))s)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }

            TextField("Card Title (e.g. Decision Trees Definition)", text: $draftCardTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack(spacing: 12) {
                Button("Cancel") {
                    showingSaveSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Card") {
                    onCreateVideoCard?(start, end, draftCardTitle)
                    markInTime = nil
                    markOutTime = nil
                    showingSaveSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    // MARK: - Player Management

    private func setupPlayer() {
        coordinator.setup(filePath: document.filePath)
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
        let title = "Note at \(MediaDocumentHelper.formatDuration(start))"
        onCreateVideoCard?(start, end, title)
    }

    private func handleCardSelected(_ cardID: UUID?) {
        guard let cardID,
              let card = cards.first(where: { $0.id == cardID }),
              let start = card.videoStartTime else { return }
        coordinator.seek(to: start)
        coordinator.play()
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
    public var isScrubbing: Bool = false

    private var timeObserverToken: Any?

    public init() {}

    public func setup(filePath: String) {
        teardown()
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        let url = URL(fileURLWithPath: filePath)
        let playerItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.rate = playbackRate
        self.player = newPlayer
        self.duration = MediaDocumentHelper.mediaDuration(url: url)

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak newPlayer] time in
            DispatchQueue.main.async {
                guard let self, let newPlayer, !self.isScrubbing else { return }
                let sec = CMTimeGetSeconds(time)
                if sec.isFinite && !sec.isNaN {
                    self.currentTime = sec
                    self.isPlaying = newPlayer.timeControlStatus == .playing
                }
            }
        }
    }

    public func teardown() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        player = nil
        isPlaying = false
    }

    public func play() {
        player?.rate = playbackRate
        player?.play()
        isPlaying = true
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
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

    public init(player: AVPlayer?, showsControls: Bool = false) {
        self.player = player
        self.showsControls = showsControls
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = showsControls ? .inline : .none
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        let targetStyle: AVPlayerViewControlsStyle = showsControls ? .inline : .none
        if nsView.controlsStyle != targetStyle {
            nsView.controlsStyle = targetStyle
        }
    }
}
#endif

