import SwiftUI

public enum MainNavigationTab: String, CaseIterable, Identifiable {
    case document = "Document"
    case study = "Study"
    case review = "Review"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .document: return "doc.text.fill"
        case .study: return "arrow.triangle.branch"
        case .review: return "rectangle.stack.badge.play"
        }
    }
}

public struct MarginNoteSidebar: View {
    @Binding public var selectedTab: MainNavigationTab
    public var onSearch: () -> Void
    public var onHelp: () -> Void
    public var onSettings: () -> Void

    public init(
        selectedTab: Binding<MainNavigationTab>,
        onSearch: @escaping () -> Void = {},
        onHelp: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {}
    ) {
        self._selectedTab = selectedTab
        self.onSearch = onSearch
        self.onHelp = onHelp
        self.onSettings = onSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Search button
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(MarginNoteTheme.sidebarTextInactive)
                    .frame(width: 56, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.top, 28)

            Spacer()

            // Main navigation items
            VStack(spacing: 6) {
                ForEach(MainNavigationTab.allCases) { tab in
                    tabButton(tab)
                }
            }

            Spacer()

            // Bottom Utility buttons
            VStack(spacing: 12) {
                Button(action: onHelp) {
                    Image(systemName: "questionmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MarginNoteTheme.sidebarTextInactive)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button(action: onSettings) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MarginNoteTheme.sidebarTextInactive)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)
        }
        .frame(width: 60)
        .background(MarginNoteTheme.sidebarBackground)
    }

    private func tabButton(_ tab: MainNavigationTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 0) {
                // Left teal indicator line
                Rectangle()
                    .fill(isSelected ? MarginNoteTheme.sidebarActiveIndicator : Color.clear)
                    .frame(width: 3)

                VStack(spacing: 4) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 19, weight: .medium))
                    Text(tab.rawValue)
                        .font(.system(size: 10, weight: isSelected ? .medium : .regular))
                }
                .foregroundStyle(isSelected ? MarginNoteTheme.sidebarTextActive : MarginNoteTheme.sidebarTextInactive)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .background(isSelected ? MarginNoteTheme.sidebarActiveBackground : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
