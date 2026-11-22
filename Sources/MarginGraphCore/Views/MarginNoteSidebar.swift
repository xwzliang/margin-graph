import SwiftUI

public enum MainNavigationTab: String, CaseIterable, Identifiable {
    case document = "Document"
    case study = "Study"
    case review = "Review"
    case reference = "Reference"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .document: return "doc.text.fill"
        case .study: return "arrow.triangle.branch"
        case .review: return "rectangle.stack.badge.play"
        case .reference: return "books.vertical"
        }
    }
}

public struct MarginNoteSidebar: View {
    @Binding public var selectedTab: MainNavigationTab
    public var isSearchActive: Bool
    public var recentBackupPaths: [String]
    public var isExternalDatabase: Bool
    public var activeDatabaseName: String
    public var libraries: [LibraryEntry]
    public var onSearch: () -> Void
    public var onHelp: () -> Void
    public var onOpenMarginNoteBackup: () -> Void
    public var onSelectRecentBackup: ((String) -> Void)?
    public var onSelectLibrary: ((LibraryEntry) -> Void)?
    public var onManageLibraries: (() -> Void)?
    public var onSwitchToDefaultDatabase: (() -> Void)?
    @Binding public var isMenuPresented: Bool
    public var onImportDocument: (() -> Void)?
    public var onCreateFolder: (() -> Void)?
    public var onSettings: () -> Void

    @State private var isHoveringSettings: Bool = false
    @State private var isHoveringHelp: Bool = false

    public init(
        selectedTab: Binding<MainNavigationTab>,
        isMenuPresented: Binding<Bool> = .constant(false),
        isSearchActive: Bool = false,
        recentBackupPaths: [String] = [],
        libraries: [LibraryEntry] = [],
        isExternalDatabase: Bool = false,
        activeDatabaseName: String = "",
        onSearch: @escaping () -> Void = {},
        onHelp: @escaping () -> Void = {},
        onOpenMarginNoteBackup: @escaping () -> Void = {},
        onSelectRecentBackup: ((String) -> Void)? = nil,
        onSelectLibrary: ((LibraryEntry) -> Void)? = nil,
        onManageLibraries: (() -> Void)? = nil,
        onSwitchToDefaultDatabase: (() -> Void)? = nil,
        onImportDocument: (() -> Void)? = nil,
        onCreateFolder: (() -> Void)? = nil,
        onSettings: @escaping () -> Void = {}
    ) {
        self._selectedTab = selectedTab
        self._isMenuPresented = isMenuPresented
        self.isSearchActive = isSearchActive
        self.recentBackupPaths = recentBackupPaths
        self.libraries = libraries
        self.isExternalDatabase = isExternalDatabase
        self.activeDatabaseName = activeDatabaseName
        self.onSearch = onSearch
        self.onHelp = onHelp
        self.onOpenMarginNoteBackup = onOpenMarginNoteBackup
        self.onSelectRecentBackup = onSelectRecentBackup
        self.onSelectLibrary = onSelectLibrary
        self.onManageLibraries = onManageLibraries
        self.onSwitchToDefaultDatabase = onSwitchToDefaultDatabase
        self.onImportDocument = onImportDocument
        self.onCreateFolder = onCreateFolder
        self.onSettings = onSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Search button
            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isSearchActive ? MarginNoteTheme.sidebarActiveIndicator : MarginNoteTheme.sidebarTextInactive)
                    .frame(width: MarginNoteTheme.sidebarWidth - 8, height: 44)
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
                        .foregroundStyle(isHoveringHelp ? MarginNoteTheme.sidebarTextActive : MarginNoteTheme.sidebarTextInactive)
                        .frame(width: 36, height: 32)
                        .background(isHoveringHelp ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringHelp = $0 }

                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isMenuPresented.toggle()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle((isMenuPresented || isHoveringSettings) ? MarginNoteTheme.sidebarTextActive : MarginNoteTheme.sidebarTextInactive)
                        .frame(width: 36, height: 32)
                        .background((isMenuPresented || isHoveringSettings) ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringSettings = $0 }
            }
            .padding(.bottom, 16)
        }
        .frame(width: MarginNoteTheme.sidebarWidth)
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

// MARK: - Sidebar Action Popover Card

public struct SidebarActionCardView: View {
    public var onOpenMarginNoteBackup: () -> Void
    public var recentBackupPaths: [String]
    public var isExternalDatabase: Bool
    public var activeDatabaseName: String
    public var libraries: [LibraryEntry]
    public var onSelectLibrary: ((LibraryEntry) -> Void)?
    public var onManageLibraries: (() -> Void)?
    public var onSelectRecentBackup: ((String) -> Void)?
    public var onSwitchToDefaultDatabase: (() -> Void)?
    public var onImportDocument: (() -> Void)?
    public var onCreateFolder: (() -> Void)?
    public var onHelp: (() -> Void)?
    public var onDismiss: () -> Void

    @State private var hoveredItem: String? = nil
    @State private var showingRecentBackups: Bool = false

    public init(
        onOpenMarginNoteBackup: @escaping () -> Void,
        recentBackupPaths: [String] = [],
        libraries: [LibraryEntry] = [],
        isExternalDatabase: Bool = false,
        activeDatabaseName: String = "",
        onSelectLibrary: ((LibraryEntry) -> Void)? = nil,
        onManageLibraries: (() -> Void)? = nil,
        onSelectRecentBackup: ((String) -> Void)? = nil,
        onSwitchToDefaultDatabase: (() -> Void)? = nil,
        onImportDocument: (() -> Void)? = nil,
        onCreateFolder: (() -> Void)? = nil,
        onHelp: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.onOpenMarginNoteBackup = onOpenMarginNoteBackup
        self.recentBackupPaths = recentBackupPaths
        self.libraries = libraries
        self.isExternalDatabase = isExternalDatabase
        self.activeDatabaseName = activeDatabaseName
        self.onSelectLibrary = onSelectLibrary
        self.onManageLibraries = onManageLibraries
        self.onSelectRecentBackup = onSelectRecentBackup
        self.onSwitchToDefaultDatabase = onSwitchToDefaultDatabase
        self.onImportDocument = onImportDocument
        self.onCreateFolder = onCreateFolder
        self.onHelp = onHelp
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showingRecentBackups {
                // Back button
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showingRecentBackups = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 16)
                        Text("Libraries")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "back" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "back" : nil }

                Divider()
                    .padding(.vertical, 2)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !libraries.isEmpty {
                            ForEach(libraries) { entry in
                                let isCurrent = entry.isBuiltIn
                                    ? !isExternalDatabase
                                    : (isExternalDatabase && (entry.displayName == activeDatabaseName || entry.name == activeDatabaseName))
                                Button {
                                    onDismiss()
                                    DispatchQueue.main.async {
                                        if let onSelectLibrary {
                                            onSelectLibrary(entry)
                                        } else if entry.isBuiltIn {
                                            onSwitchToDefaultDatabase?()
                                        } else {
                                            onSelectRecentBackup?(entry.path)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: entry.isBuiltIn ? "house.fill" : "externaldrive")
                                            .font(.system(size: 12))
                                            .foregroundStyle(isCurrent ? .secondary : Color.accentColor)
                                            .frame(width: 16)
                                        Text(entry.displayName)
                                            .font(.system(size: 12, weight: isCurrent ? .regular : .medium))
                                            .foregroundStyle(isCurrent ? .secondary : .primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if entry.isDefault {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.blue)
                                        }
                                        if isCurrent {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(hoveredItem == "lib_\(entry.id)" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isCurrent)
                                .onHover { hoveredItem = $0 ? "lib_\(entry.id)" : nil }
                            }
                        } else {
                            ForEach(recentBackupPaths, id: \.self) { path in
                                let name = URL(fileURLWithPath: path).lastPathComponent
                                let isCurrent = isExternalDatabase && name == activeDatabaseName
                                Button {
                                    onDismiss()
                                    DispatchQueue.main.async {
                                        onSelectRecentBackup?(path)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "externaldrive")
                                            .font(.system(size: 12))
                                            .foregroundStyle(isCurrent ? .secondary : Color.accentColor)
                                            .frame(width: 16)
                                        Text(name)
                                            .font(.system(size: 12, weight: isCurrent ? .regular : .medium))
                                            .foregroundStyle(isCurrent ? .secondary : .primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if isCurrent {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(hoveredItem == path ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isCurrent)
                                .onHover { hoveredItem = $0 ? path : nil }
                            }
                        }

                        if onManageLibraries != nil {
                            Divider()
                                .padding(.vertical, 2)

                            Button {
                                onDismiss()
                                DispatchQueue.main.async {
                                    onManageLibraries?()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "gearshape")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 16)
                                    Text("Manage Libraries…")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(hoveredItem == "manage_in_sub" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveredItem = $0 ? "manage_in_sub" : nil }
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else {
                // Item 1: Open MarginNote Database or Backup
                Button {
                    onDismiss()
                    DispatchQueue.main.async {
                        onOpenMarginNoteBackup()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 16)
                        Text("Open MarginNote Database or Backup…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "open_mn" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "open_mn" : nil }

                // Libraries Submenu (if any)
                if !libraries.isEmpty || !recentBackupPaths.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            showingRecentBackups = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "books.vertical")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .frame(width: 16)
                            Text("Libraries…")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(hoveredItem == "recent_libs" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredItem = $0 ? "recent_libs" : nil }
                }

                // Manage Libraries Button
                if let onManageLibraries {
                    Button {
                        onDismiss()
                        DispatchQueue.main.async {
                            onManageLibraries()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .frame(width: 16)
                            Text("Manage Libraries…")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(hoveredItem == "manage_libs" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredItem = $0 ? "manage_libs" : nil }
                }

                // If currently viewing external database, option to switch back to default
                if isExternalDatabase {
                    Button {
                        onDismiss()
                        DispatchQueue.main.async {
                            onSwitchToDefaultDatabase?()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "house.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 16)
                            Text("Switch to Default Library")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(hoveredItem == "switch_default" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredItem = $0 ? "switch_default" : nil }
                }

                Divider()
                    .padding(.vertical, 2)

                // Import Document
                if let onImportDocument {
                    Button {
                        onDismiss()
                        DispatchQueue.main.async {
                            onImportDocument()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .frame(width: 16)
                            Text("Import Document…")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(hoveredItem == "import_doc" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredItem = $0 ? "import_doc" : nil }
                }

                // New Folder
                if let onCreateFolder {
                    Button {
                        onDismiss()
                        DispatchQueue.main.async {
                            onCreateFolder()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .frame(width: 16)
                            Text("New Folder…")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(hoveredItem == "new_folder" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredItem = $0 ? "new_folder" : nil }
                }

                if onImportDocument != nil || onCreateFolder != nil {
                    Divider()
                        .padding(.vertical, 2)
                }

                // Help & Feedback
                Button {
                    onDismiss()
                    DispatchQueue.main.async {
                        onHelp?()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text("Help & Feedback")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hoveredItem == "help" ? Color.secondary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredItem = $0 ? "help" : nil }
            }
        }
        .padding(6)
        .frame(width: 335)
    }
}
