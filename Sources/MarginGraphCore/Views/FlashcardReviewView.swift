import SwiftUI
import AppKit

public struct FlashcardReviewView: View {
    public var cards: [NoteCard]
    public var documents: [Document]
    public var database: Database
    public var mediaStorage: MediaStorage?
    public var onJumpToPDF: (NoteCard) -> Void
    public var onDismiss: () -> Void

    @State private var index = 0
    @State private var showingAnswer = false
    @State private var reviewedCount = 0
    @State private var successfulCount = 0
    @State private var nextDueDates: [Date] = []
    @State private var finished = false

    public init(
        cards: [NoteCard],
        documents: [Document] = [],
        database: Database,
        mediaStorage: MediaStorage? = nil,
        onJumpToPDF: @escaping (NoteCard) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.cards = cards
        self.documents = documents
        self.database = database
        self.mediaStorage = mediaStorage
        self.onJumpToPDF = onJumpToPDF
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 24) {
            if finished || cards.isEmpty {
                summaryView
            } else {
                reviewView
            }
        }
        .padding(36)
        .frame(minWidth: 680, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var reviewView: some View {
        let card = cards[index]
        return VStack(spacing: 22) {
            HStack {
                Text("Card \(index + 1) of \(cards.count)")
                    .font(.headline)
                Spacer()
                Button("Close", action: onDismiss)
            }

            ProgressView(value: Double(index), total: Double(max(cards.count, 1)))

            Spacer(minLength: 8)

            VStack(spacing: 18) {
                Text(card.title.isEmpty ? "Flashcard" : card.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                if let image = image(for: card) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 520, maxHeight: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text(showingAnswer
                     ? ClozeParser.revealed(card.highlightText)
                     : ClozeParser.masked(card.highlightText))
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: 620)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                if showingAnswer {
                    if !card.notesText.isEmpty {
                        Text(card.notesText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 620, alignment: .leading)
                    }

                    if !card.tags.isEmpty {
                        Text(card.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(sourceLabel(for: card))
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Button("Jump to PDF") {
                        onJumpToPDF(card)
                    }
                }
            }

            Spacer()

            if showingAnswer {
                HStack(spacing: 12) {
                    gradeButton("Again", quality: 1, shortcut: "1")
                    gradeButton("Hard", quality: 2, shortcut: "2")
                    gradeButton("Good", quality: 4, shortcut: "3")
                    gradeButton("Easy", quality: 5, shortcut: "4")
                }
            } else {
                Button("Show Answer") {
                    showingAnswer = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button("") {
                if showingAnswer {
                    grade(quality: 4)
                } else {
                    showingAnswer = true
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .hidden()
        }
    }

    private var summaryView: some View {
        VStack(spacing: 20) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 58))
                .foregroundStyle(.tint)
            Text("Review Complete")
                .font(.largeTitle.bold())
            Text("\(reviewedCount) cards reviewed")
                .font(.title3)

            let accuracy = reviewedCount == 0
                ? 0
                : Int((Double(successfulCount) / Double(reviewedCount) * 100).rounded())
            Text("Accuracy: \(accuracy)%")
                .foregroundStyle(.secondary)

            if let next = nextDueDates.min() {
                Text("Next due: \(next.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }

            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gradeButton(_ title: String, quality: Int, shortcut: KeyEquivalent) -> some View {
        Button(title) {
            grade(quality: quality)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(shortcut, modifiers: [])
        .frame(minWidth: 100)
    }

    private func grade(quality: Int) {
        guard index < cards.count else { return }
        if let item = try? database.recordCardReview(id: cards[index].id, quality: quality) {
            nextDueDates.append(item.dueDate)
        }
        reviewedCount += 1
        if quality >= 3 { successfulCount += 1 }

        if index + 1 >= cards.count {
            finished = true
        } else {
            index += 1
            showingAnswer = false
        }
    }

    private func image(for card: NoteCard) -> NSImage? {
        guard let hash = card.highlightPicHash,
              let data = mediaStorage?.loadImage(hash: hash) else { return nil }
        return NSImage(data: data)
    }

    private func sourceLabel(for card: NoteCard) -> String {
        let book = card.bookMD5.flatMap { md5 in
            documents.first(where: { $0.md5 == md5 })?.title
        } ?? "Unknown source"
        if let page = card.startPage {
            return "\(book) · Page \(page + 1)"
        }
        return book
    }
}
