import SwiftUI

public struct AddToDeckSheet: View {
    public var card: NoteCard
    public var allCards: [NoteCard]
    public var existingDecks: [CardDeck]
    public var deckCardCounts: [UUID: Int]
    public var onAdd: (_ deckId: UUID?, _ newDeckTitle: String?, _ cardIds: [UUID]) -> Void
    public var onDismiss: () -> Void

    @State private var includeChildren: Bool
    @State private var deckChoiceMode: Int // 0: existing, 1: new
    @State private var selectedDeckID: UUID?
    @State private var newDeckTitle: String = ""

    private var descendants: [NoteCard] {
        card.allDescendants(in: allCards)
    }

    public init(
        card: NoteCard,
        allCards: [NoteCard],
        existingDecks: [CardDeck],
        deckCardCounts: [UUID: Int] = [:],
        onAdd: @escaping (_ deckId: UUID?, _ newDeckTitle: String?, _ cardIds: [UUID]) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.card = card
        self.allCards = allCards
        self.existingDecks = existingDecks
        self.deckCardCounts = deckCardCounts
        self.onAdd = onAdd
        self.onDismiss = onDismiss

        let hasDecks = !existingDecks.isEmpty
        _includeChildren = State(initialValue: !card.allDescendants(in: allCards).isEmpty)
        _deckChoiceMode = State(initialValue: hasDecks ? 0 : 1)
        _selectedDeckID = State(initialValue: existingDecks.first?.id)
    }

    private var targetCardIDs: [UUID] {
        if includeChildren {
            return [card.id] + descendants.map(\.id)
        } else {
            return [card.id]
        }
    }

    private var canSubmit: Bool {
        if deckChoiceMode == 0 {
            return selectedDeckID != nil
        } else {
            return !newDeckTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.play")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to Review Deck")
                        .font(.system(size: 15, weight: .semibold))
                    Text(displayNoteTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Scope / Children Option
                    if !descendants.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Cards to Include")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    includeChildren = false
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: !includeChildren ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                                        Text("This note only (1 card)")
                                            .font(.system(size: 13))
                                    }
                                }
                                .buttonStyle(.plain)

                                Button {
                                    includeChildren = true
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: includeChildren ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                                        Text("This note and all its children (\(1 + descendants.count) cards)")
                                            .font(.system(size: 13))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    // Card Deck Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select Card Deck")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        if !existingDecks.isEmpty {
                            Picker("", selection: $deckChoiceMode) {
                                Text("Existing Deck").tag(0)
                                Text("New Deck").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .padding(.bottom, 4)
                        }

                        if deckChoiceMode == 0 && !existingDecks.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Picker("Deck:", selection: $selectedDeckID) {
                                    ForEach(existingDecks) { deck in
                                        let count = deckCardCounts[deck.id] ?? 0
                                        Text("\(deck.title) (\(count) cards)").tag(Optional(deck.id))
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Deck Name")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)

                                TextField("e.g. Biology Exam Review, Chapter 1...", text: $newDeckTitle)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 13))
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(22)
            }

            Divider()

            // Footer actions
            HStack {
                Text("\(targetCardIDs.count) card\(targetCardIDs.count == 1 ? "" : "s") will be added")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)

                Button("Add to Deck") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var displayNoteTitle: String {
        let trimmedTitle = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let trimmedHighlight = card.highlightText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHighlight.isEmpty { return trimmedHighlight }
        return "Untitled Note"
    }

    private func submit() {
        let cardIds = targetCardIDs
        if deckChoiceMode == 0, let deckId = selectedDeckID {
            onAdd(deckId, nil, cardIds)
        } else {
            let title = newDeckTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            onAdd(nil, title, cardIds)
        }
        onDismiss()
    }
}
