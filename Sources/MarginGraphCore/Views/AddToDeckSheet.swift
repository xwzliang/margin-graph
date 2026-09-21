import SwiftUI

public struct AddToDeckSheet: View {
    public var card: NoteCard
    public var allCards: [NoteCard]
    public var existingDecks: [ReviewDeckItem]
    public var onAdd: (_ deckId: UUID?, _ newDeckTitle: String?, _ cardIds: [UUID]) -> Void
    public var onDismiss: () -> Void

    @State private var includeChildren: Bool
    @State private var deckChoiceMode: Int // 0: existing deck, 1: create new deck
    @State private var selectedDeckID: UUID?
    @State private var newDeckTitle: String = ""
    @FocusState private var isNewDeckFieldFocused: Bool

    private var descendants: [NoteCard] {
        card.allDescendants(in: allCards)
    }

    public init(
        card: NoteCard,
        allCards: [NoteCard],
        existingDecks: [ReviewDeckItem],
        onAdd: @escaping (_ deckId: UUID?, _ newDeckTitle: String?, _ cardIds: [UUID]) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.card = card
        self.allCards = allCards
        self.existingDecks = existingDecks
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
        let trimmed = newDeckTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if deckChoiceMode == 1 {
            return !trimmed.isEmpty
        } else {
            return selectedDeckID != nil || !trimmed.isEmpty
        }
    }

    private var existingDecksListHeight: CGFloat {
        if existingDecks.isEmpty {
            return 44
        }
        let calculated = CGFloat(existingDecks.count * 34 + 12)
        return min(max(calculated, 78), 175)
    }

    private var sheetHeight: CGFloat {
        descendants.isEmpty ? 460 : 550
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
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 16) {
                // 1. Scope / Children Option
                if !descendants.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cards to Include")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                includeChildren = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: !includeChildren ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(Color(red: 0.15, green: 0.45, blue: 0.85))
                                    Text("This note only (1 card)")
                                        .font(.system(size: 12.5))
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
                                        .font(.system(size: 12.5))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                        )
                    }
                }

                // 2. Select Existing Deck Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select Existing Deck")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if existingDecks.isEmpty {
                        HStack {
                            Text("No existing decks found.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                        )
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 2) {
                                ForEach(existingDecks) { deck in
                                    let isSelected = (deckChoiceMode == 0 && selectedDeckID == deck.id)
                                    Button {
                                        deckChoiceMode = 0
                                        selectedDeckID = deck.id
                                        newDeckTitle = ""
                                        isNewDeckFieldFocused = false
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                                .font(.system(size: 13))
                                                .foregroundStyle(isSelected ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color.secondary.opacity(0.6))

                                            Image(systemName: "rectangle.stack")
                                                .font(.system(size: 12))
                                                .foregroundStyle(isSelected ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color.secondary)

                                            Text(deck.title)
                                                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            Spacer()

                                            Text("\(deck.totalCount) card\(deck.totalCount == 1 ? "" : "s")")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color(nsColor: .separatorColor).opacity(0.35), in: Capsule())
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(isSelected ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(6)
                        }
                        .frame(height: existingDecksListHeight)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                        )
                        .clipped()
                    }
                }

                // 3. Or Create New Deck Section
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        deckChoiceMode = 1
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: deckChoiceMode == 1 ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(deckChoiceMode == 1 ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color.secondary.opacity(0.6))

                            Text("Or Create a New Deck")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(deckChoiceMode == 1 ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Enter new deck name...", text: $newDeckTitle)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .focused($isNewDeckFieldFocused)
                            .onChange(of: isNewDeckFieldFocused) { _, isFocused in
                                if isFocused {
                                    deckChoiceMode = 1
                                }
                            }
                            .onChange(of: newDeckTitle) { _, text in
                                if !text.isEmpty {
                                    deckChoiceMode = 1
                                }
                            }
                            .onTapGesture {
                                deckChoiceMode = 1
                                isNewDeckFieldFocused = true
                            }
                            .onSubmit {
                                if canSubmit { submit() }
                            }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

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
        .frame(width: 480, height: sheetHeight)
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
        let trimmed = newDeckTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if deckChoiceMode == 1 || (!trimmed.isEmpty && selectedDeckID == nil) {
            guard !trimmed.isEmpty else { return }
            onAdd(nil, trimmed, cardIds)
        } else if deckChoiceMode == 0, let deckId = selectedDeckID {
            if !trimmed.isEmpty {
                onAdd(nil, trimmed, cardIds)
            } else {
                onAdd(deckId, nil, cardIds)
            }
        } else if !trimmed.isEmpty {
            onAdd(nil, trimmed, cardIds)
        }
        onDismiss()
    }
}
