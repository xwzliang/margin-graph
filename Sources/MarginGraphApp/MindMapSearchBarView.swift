import SwiftUI
import AppKit
import MarginGraphCore

struct MindMapSearchBarView: View {
    @ObservedObject var model: AppModel
    @State private var showResultsList: Bool = false

    init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            FocusableSearchField(
                text: $model.mindMapSearchQuery,
                placeholder: "Search notes by title or content…",
                onSubmit: {
                    model.nextMindMapSearchResult()
                },
                onCancel: {
                    model.closeMindMapSearch()
                }
            )
            .frame(height: 20)

            // Search Scope Menu (All / Title / Content)
            Menu {
                Picker("Search Scope", selection: $model.mindMapSearchScope) {
                    Text("Title & Content").tag(MindMapSearchScope.all)
                    Text("Title Only").tag(MindMapSearchScope.title)
                    Text("Content Only").tag(MindMapSearchScope.content)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: model.mindMapSearchScope == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 11))
                    Text(model.mindMapSearchScope.rawValue)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(model.mindMapSearchScope == .all ? Color.secondary : Color(red: 0.15, green: 0.45, blue: 0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.mindMapSearchScope == .all ? Color.clear : Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.12))
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .marginNoteTooltip("Filter by Title or Note Content")

            let matches = model.matchingMindMapCards
            let clean = model.mindMapSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

            if !clean.isEmpty {
                if matches.isEmpty {
                    Text("No matches")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(model.currentMindMapMatchIndex + 1) of \(matches.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Button {
                        model.previousMindMapSearchResult()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(white: 0.3))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .marginNoteTooltip("Previous Match (⇧Enter)")

                    Button {
                        model.nextMindMapSearchResult()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(white: 0.3))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .marginNoteTooltip("Next Match (Enter)")

                    // Dropdown list button to show all matching cards in a popover
                    Button {
                        showResultsList.toggle()
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11, weight: showResultsList ? .bold : .regular))
                            .foregroundStyle(showResultsList ? Color(red: 0.15, green: 0.45, blue: 0.85) : Color.secondary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .marginNoteTooltip("Matching Notes List")
                    .popover(isPresented: $showResultsList, arrowEdge: .bottom) {
                        MindMapSearchResultsPopover(model: model, matches: matches, onSelect: { card in
                            if let idx = matches.firstIndex(where: { $0.id == card.id }) {
                                model.currentMindMapMatchIndex = idx
                            }
                            model.select(card: card)
                            model.cardIDToCenter = card.id
                            showResultsList = false
                        })
                    }
                }
            }

            Button {
                model.closeMindMapSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .marginNoteTooltip("Close Search (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(white: 0.96))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(MarginNoteTheme.separatorColor),
            alignment: .bottom
        )
    }
}

struct MindMapSearchResultsPopover: View {
    @ObservedObject var model: AppModel
    let matches: [NoteCard]
    let onSelect: (NoteCard) -> Void

    init(model: AppModel, matches: [NoteCard], onSelect: @escaping (NoteCard) -> Void) {
        self.model = model
        self.matches = matches
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Matching Cards (\(matches.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.97))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(MarginNoteTheme.separatorColor),
                alignment: .bottom
            )

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, card in
                        let isSelected = model.selectedCardID == card.id
                        Button {
                            onSelect(card)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(MarginNoteTheme.cardColors(for: card.colorIndex).accent)
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 4)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cardDisplayTitle(card))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let snippet = cardSnippet(card) {
                                        Text(snippet)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }

                                Spacer()

                                if let page = card.startPage {
                                    Text("p. \(page + 1)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.secondary.opacity(0.8))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isSelected ? Color(red: 0.15, green: 0.45, blue: 0.85).opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 320)
    }

    private func cardDisplayTitle(_ card: NoteCard) -> String {
        if !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return card.title
        }
        if !card.highlightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return card.highlightText
        }
        return "Untitled Note"
    }

    private func cardSnippet(_ card: NoteCard) -> String? {
        let clean = model.mindMapSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            if card.notesText.localizedCaseInsensitiveContains(clean) {
                return card.notesText
            }
            if card.highlightText.localizedCaseInsensitiveContains(clean) && !card.title.isEmpty {
                return card.highlightText
            }
            for seg in card.excerptSegments where seg.text.localizedCaseInsensitiveContains(clean) {
                return seg.text
            }
        }
        if !card.notesText.isEmpty {
            return card.notesText
        }
        if !card.highlightText.isEmpty && !card.title.isEmpty {
            return card.highlightText
        }
        return nil
    }
}
