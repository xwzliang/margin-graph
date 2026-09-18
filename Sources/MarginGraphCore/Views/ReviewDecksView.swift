import SwiftUI

public struct ReviewDeckItem: Identifiable {
    public var id: UUID
    public var title: String
    public var dueCount: Int
    public var totalCount: Int
    public var topicId: UUID?

    public init(id: UUID = UUID(), title: String, dueCount: Int, totalCount: Int, topicId: UUID? = nil) {
        self.id = id
        self.title = title
        self.dueCount = dueCount
        self.totalCount = totalCount
        self.topicId = topicId
    }
}

public struct ReviewDecksView: View {
    public var decks: [ReviewDeckItem]
    public var onStartReview: (ReviewDeckItem) -> Void

    @State private var sortMode: Int = 0 // 0: Recent, 1: Name
    @State private var filter: String = "All"

    public init(decks: [ReviewDeckItem], onStartReview: @escaping (ReviewDeckItem) -> Void) {
        self.decks = decks
        self.onStartReview = onStartReview
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack(spacing: 12) {
                Text("New")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)

                Spacer()

                Menu {
                    Button("All") { filter = "All" }
                } label: {
                    HStack(spacing: 4) {
                        Text(filter)
                            .font(.system(size: 13, weight: .regular))
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button("Select") {
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

                Image(systemName: "list.bullet")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Subheader
            Picker("", selection: $sortMode) {
                Text("Recent").tag(0)
                Text("Name").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .padding(.bottom, 18)

            Divider()
                .background(MarginNoteTheme.separatorColor)

            // Grid
            ScrollView {
                if decks.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.stack.badge.play")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Flashcard Decks")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 170), spacing: 24)], spacing: 28) {
                        ForEach(decks) { deck in
                            ReviewDeckCardView(deck: deck, onStart: { onStartReview(deck) })
                        }
                    }
                    .padding(28)
                }
            }
        }
        .background(MarginNoteTheme.shelfBackground)
    }
}

public struct ReviewDeckCardView: View {
    public var deck: ReviewDeckItem
    public var onStart: () -> Void

    public init(deck: ReviewDeckItem, onStart: @escaping () -> Void) {
        self.deck = deck
        self.onStart = onStart
    }

    public var body: some View {
        Button(action: onStart) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.92, green: 0.90, blue: 0.85))
                        .frame(height: 180)
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                    // Flashcard deck preview
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 0.99, green: 0.98, blue: 0.93))
                            .frame(width: 120, height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color(red: 0.85, green: 0.82, blue: 0.76), lineWidth: 0.8)
                            )
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 0.99, green: 0.98, blue: 0.93))
                            .frame(width: 126, height: 42)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color(red: 0.85, green: 0.82, blue: 0.76), lineWidth: 0.8)
                            )
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 0.99, green: 0.98, blue: 0.93))
                            .frame(width: 132, height: 48)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color(red: 0.85, green: 0.82, blue: 0.76), lineWidth: 0.8)
                            )
                    }
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity)

                    // Top-Left Due Count Badge
                    if deck.dueCount > 0 {
                        Text("\(deck.dueCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(red: 0.85, green: 0.25, blue: 0.20), in: RoundedRectangle(cornerRadius: 2))
                            .padding(5)
                    }

                    // Top-Right Total Count Badge
                    HStack {
                        Spacer()
                        Text("\(deck.totalCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(MarginNoteTheme.badgeGray.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
                            .padding(5)
                    }
                }

                // Title
                Text(deck.title)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)

                // More dots
                HStack {
                    Spacer()
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 148)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
