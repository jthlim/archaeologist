import SwiftUI

// MARK: - Flattened Tree Item for 100% Virtualized Lazy Layout
struct FlatFileTreeItem: Identifiable, Equatable {
    let node: FileTreeNode
    let level: Int
    var id: String { node.nodeIdentity }

    static func == (lhs: FlatFileTreeItem, rhs: FlatFileTreeItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.level == rhs.level
    }
}

public struct RepositorySidebarView: View {
    @ObservedObject var tabManager: TabManager
    @State private var filterQuery: String = ""
    @State private var expandedNodes: Set<String> = []
    @State private var collapsedInSearch: Set<String> = []
    @State private var filteredNodes: [FileTreeNode] = []
    @State private var visibleFlatItems: [FlatFileTreeItem] = []
    @State private var filterTask: Task<Void, Never>? = nil

    public init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    private var activeContext: RepoContext? {
        tabManager.activeRepoContext
    }

    private var activeFileURL: URL? {
        tabManager.activeViewModel?.selectedFileURL?.standardizedFileURL
    }

    private var activeRelativePath: String? {
        if let rel = tabManager.activeViewModel?.relativePath, !rel.isEmpty {
            return rel
        }
        if let url = activeFileURL, let root = activeContext?.repoRoot {
            let rootPath = root.standardizedFileURL.path
            let filePath = url.path
            if filePath.hasPrefix(rootPath) {
                return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        return nil
    }

    private var isSearching: Bool {
        !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isFiltering: Bool {
        isSearching || tabManager.onlyShowModifiedFiles
    }

    private func isNodeActive(_ node: FileTreeNode) -> Bool {
        guard !node.isDirectory else { return false }
        if let rel = activeRelativePath, !rel.isEmpty {
            return node.id == rel
        }
        if let active = activeFileURL {
            return node.fullURL.standardizedFileURL.path == active.path ||
                   node.fullURL.resolvingSymlinksInPath().path == active.resolvingSymlinksInPath().path
        }
        return false
    }

    private func syncActiveNode() {
        if let rel = activeRelativePath {
            expandAncestors(for: rel)
            updateFlatItems()
        }
    }

    private func expandAncestors(for relativePath: String) {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return }
        var current = ""
        for i in 0..<(parts.count - 1) {
            current = current.isEmpty ? parts[i] : "\(current)/\(parts[i])"
            expandedNodes.insert(current)
        }
    }

    private var totalFileCount: Int {
        tabManager.repositoryFiles.reduce(0) { $0 + $1.totalFileCount }
    }

    private func updateFlatItems() {
        var items: [FlatFileTreeItem] = []
        let filtering = isFiltering

        func collect(nodes: [FileTreeNode], level: Int) {
            for node in nodes {
                items.append(FlatFileTreeItem(node: node, level: level))
                if node.isDirectory {
                    let expanded = filtering ? !collapsedInSearch.contains(node.id) : expandedNodes.contains(node.id)
                    if expanded, let children = node.children {
                        collect(nodes: children, level: level + 1)
                    }
                }
            }
        }

        collect(nodes: filteredNodes, level: 0)
        self.visibleFlatItems = items
    }

    private func applyFilter(immediate: Bool = false) {
        filterTask?.cancel()
        let query = filterQuery
        let onlyModified = tabManager.onlyShowModifiedFiles
        let showUntracked = tabManager.showUntrackedFiles
        let files = tabManager.repositoryFiles

        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !onlyModified && showUntracked {
            self.filteredNodes = files
            self.collapsedInSearch.removeAll()
            self.updateFlatItems()
            return
        }

        if immediate {
            let filtered = files.compactMap { $0.filter(query: query, onlyModified: onlyModified, showUntracked: showUntracked) }
            self.filteredNodes = filtered
            self.updateFlatItems()
            return
        }

        filterTask = Task { @MainActor in
            // Short debounce to batch rapid keystrokes without UI hitch
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            guard !Task.isCancelled else { return }

            let filtered = await Task.detached(priority: .userInitiated) {
                files.compactMap { $0.filter(query: query, onlyModified: onlyModified, showUntracked: showUntracked) }
            }.value

            guard !Task.isCancelled else { return }
            self.filteredNodes = filtered
            self.updateFlatItems()
        }
    }

    private func toggleExpand(_ node: FileTreeNode) {
        if isFiltering {
            if collapsedInSearch.contains(node.id) {
                collapsedInSearch.remove(node.id)
            } else {
                collapsedInSearch.insert(node.id)
            }
        } else {
            if expandedNodes.contains(node.id) {
                expandedNodes.remove(node.id)
            } else {
                expandedNodes.insert(node.id)
            }
        }
        updateFlatItems()
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            headerView

            Divider()

            // MARK: - Search / Filter Bar with Only Modified Files Toggle
            filterBar

            Divider()

            // MARK: - Tree / Content
            contentBody

            if activeContext != nil {
                Divider()

                // MARK: - Remotes Section
                remotesSection
            }

            Divider()

            // MARK: - Footer
            footerView
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            if activeContext != nil && tabManager.remoteRepositories.isEmpty {
                tabManager.loadRemotes()
            }
            if tabManager.onlyShowModifiedFiles || !tabManager.showUntrackedFiles || isSearching {
                applyFilter(immediate: true)
            } else {
                filteredNodes = tabManager.repositoryFiles
                syncActiveNode()
                updateFlatItems()
            }
        }
        .onChange(of: filterQuery) {
            applyFilter()
        }
        .onChange(of: tabManager.showUntrackedFiles) {
            applyFilter(immediate: true)
        }
        .onChange(of: tabManager.onlyShowModifiedFiles) {
            applyFilter(immediate: true)
        }
        .onChange(of: tabManager.repositoryFiles) {
            applyFilter(immediate: true)
        }
        .onChange(of: tabManager.repositoryFilesVersion) {
            applyFilter(immediate: true)
        }
        .onChange(of: tabManager.activeTabId) {
            syncActiveNode()
            tabManager.loadRemotes()
        }
        .onChange(of: activeFileURL) {
            syncActiveNode()
            tabManager.loadRemotes()
        }
    }

    // MARK: - Header View
    private var headerView: some View {
        HStack(spacing: 8) {
            if let context = activeContext {
                Image(systemName: context.vcsType.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)

                Text(context.repoRoot.lastPathComponent)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(context.repoRoot.path)

                // VCS Badge
                Text(context.vcsType.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)

                Text("Repository Files")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 36)
    }

    // MARK: - Filter Bar
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("Filter files...", text: $filterQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !filterQuery.isEmpty {
                    Button(action: { filterQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(NSColor.textBackgroundColor).opacity(0.7))
            .cornerRadius(6)

            Toggle(isOn: $tabManager.showUntrackedFiles) {
                Text("Show untracked")
                    .font(.system(size: 11))
                    .foregroundColor(tabManager.showUntrackedFiles ? .primary : .secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .padding(.horizontal, 2)

            Toggle(isOn: $tabManager.onlyShowModifiedFiles) {
                Text("Only modified files")
                    .font(.system(size: 11))
                    .foregroundColor(tabManager.onlyShowModifiedFiles ? .primary : .secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Content Body
    @ViewBuilder
    private var contentBody: some View {
        if activeContext == nil {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.6))
                Text("No Repository")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Open a file or repository to view repository files.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tabManager.isLoadingRepoFiles && tabManager.repositoryFiles.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                    .scaleEffect(0.9)
                Text("Scanning repository files...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredNodes.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary.opacity(0.6))
                Text("No matching files")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                if tabManager.onlyShowModifiedFiles && !filterQuery.isEmpty {
                    Text("No modified files match '\(filterQuery)'")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                } else if tabManager.onlyShowModifiedFiles {
                    Text("No modified files in repository")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                } else if !filterQuery.isEmpty {
                    Text("No files match '\(filterQuery)'")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                } else if !tabManager.showUntrackedFiles {
                    Text("No tracked files in repository")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleFlatItems) { item in
                        let isExpanded = isFiltering ? !collapsedInSearch.contains(item.node.id) : expandedNodes.contains(item.node.id)
                        FileTreeItemRow(
                            node: item.node,
                            status: item.node.status,
                            level: item.level,
                            isExpanded: isExpanded,
                            isActive: isNodeActive(item.node),
                            onToggleExpand: {
                                toggleExpand(item.node)
                            },
                            onSelect: {
                                expandAncestors(for: item.node.id)
                                tabManager.openInTab(
                                    url: item.node.fullURL,
                                    preferredVCS: activeContext?.vcsType
                                )
                            },
                            onAdd: {
                                tabManager.addFile(for: item.node)
                            },
                            onDiscardChanges: {
                                tabManager.discardChanges(for: item.node)
                            },
                            onDelete: {
                                tabManager.deleteFile(for: item.node)
                            },
                            onShowTimeline: {
                                expandAncestors(for: item.node.id)
                                tabManager.openInTab(
                                    url: item.node.fullURL,
                                    preferredVCS: activeContext?.vcsType
                                )
                            },
                            onShowCommits: {
                                let ctx = activeContext ?? VCSManager.shared.detectContext(for: item.node.fullURL)
                                let path = (item.node.id == "/" || item.node.id.isEmpty) ? nil : item.node.id
                                tabManager.openCommitHistoryTab(
                                    context: ctx,
                                    filePath: path
                                )
                            },
                            onShowInFinder: {
                                NSWorkspace.shared.activateFileViewerSelecting([item.node.fullURL])
                            }
                        )
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Remotes Section
    private var remotesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Remotes Header
            HStack(spacing: 6) {
                Text("Remotes")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                // Push to all remotes button
                RemoteActionButton(
                    type: .push,
                    isActive: tabManager.isPushingAllRemotes,
                    hasError: tabManager.pushAllError != nil,
                    errorMessage: tabManager.pushAllError,
                    defaultHelp: "Push to all remotes",
                    action: {
                        tabManager.pushAllRemotes()
                    }
                )
                .disabled(tabManager.isPushingAllRemotes || tabManager.remoteRepositories.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))

            if tabManager.isLoadingRemotes && tabManager.remoteRepositories.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading remotes...")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            } else if tabManager.remoteRepositories.isEmpty {
                Text("No remotes configured")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.vertical, showsIndicators: tabManager.remoteRepositories.count > 4) {
                    VStack(spacing: 1) {
                        ForEach(tabManager.remoteRepositories) { remote in
                            RemoteRepositoryRow(
                                remote: remote,
                                isPushing: tabManager.activePushRemotes.contains(remote.name),
                                isPulling: tabManager.activePullRemotes.contains(remote.name),
                                pushError: tabManager.pushErrors[remote.name],
                                pullError: tabManager.pullErrors[remote.name],
                                onPull: {
                                    tabManager.pull(from: remote)
                                },
                                onPush: {
                                    tabManager.push(to: remote)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: min(CGFloat(tabManager.remoteRepositories.count * 24 + 4), 120))
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Footer View
    private var footerView: some View {
        HStack {
            if activeContext != nil {
                let displayedCount = filteredNodes.reduce(0) { $0 + $1.totalFileCount }
                if !filterQuery.isEmpty || tabManager.onlyShowModifiedFiles || !tabManager.showUntrackedFiles {
                    Text("\(displayedCount) of \(totalFileCount) files")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text("\(totalFileCount) files")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 24)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }
}

// MARK: - File Tree Row (Virtualized single row)
struct FileTreeItemRow: View {
    let node: FileTreeNode
    let status: FileWorkingStatus
    let level: Int
    let isExpanded: Bool
    let isActive: Bool
    let onToggleExpand: () -> Void
    var onSelect: (() -> Void)? = nil
    var onAdd: (() -> Void)? = nil
    var onDiscardChanges: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onShowTimeline: (() -> Void)? = nil
    var onShowCommits: (() -> Void)? = nil
    var onShowInFinder: (() -> Void)? = nil

    @State private var isMenuShowing: Bool = false

    private var isHighlighted: Bool {
        isActive || isMenuShowing
    }

    private var itemTextColor: Color {
        if let statusColor = node.statusTextColor {
            return statusColor
        }
        return isHighlighted ? .accentColor : .primary
    }

    private var iconColor: Color {
        if node.isDirectory {
            if let statusColor = node.statusTextColor {
                return statusColor
            }
            return Color(NSColor.systemBlue)
        }
        if let statusColor = node.statusTextColor {
            return statusColor
        }
        return node.iconColor
    }

    var body: some View {
        HStack(spacing: 4) {
            // Indentation level
            if level > 0 {
                Spacer()
                    .frame(width: CGFloat(level * 12))
            }

            // Disclosure arrow for directories
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(node.statusTextColor ?? .secondary)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onToggleExpand()
                    }
            } else {
                Spacer()
                    .frame(width: 12)
            }

            // File or Directory Icon
            Image(systemName: node.isDirectory ? (isExpanded ? "folder.fill" : "folder") : node.iconName)
                .font(.system(size: 11))
                .foregroundColor(iconColor)
                .frame(width: 14, height: 14)

            // Name
            Text(node.name)
                .font(.system(size: 11, weight: isHighlighted ? .semibold : .regular))
                .foregroundColor(itemTextColor)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .padding(.horizontal, 4)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear
        )
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isHighlighted ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .overlay(
            SidebarContextMenuHighlightOverlay(
                onMenuWillOpen: {
                    isMenuShowing = true
                },
                onMenuDidClose: {
                    isMenuShowing = false
                },
                menuBuilder: {
                    makeContextMenu()
                }
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                onToggleExpand()
            } else {
                if let onShowTimeline = onShowTimeline {
                    onShowTimeline()
                } else {
                    onSelect?()
                }
            }
        }
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "File Context Menu")
        if !node.isDirectory {
            let isAlreadyTracked = (status != .unknown)
            let hasChanges = (status == .modified || status == .deleted || status == .new)

            menu.addItem(sidebarMenuItem("Add File", isEnabled: !isAlreadyTracked) {
                onAdd?()
            })

            menu.addItem(sidebarMenuItem("Discard Changes", isEnabled: hasChanges) {
                onDiscardChanges?()
            })

            menu.addItem(sidebarMenuItem("Delete File", isEnabled: true, isDestructive: true) {
                onDelete?()
            })

            menu.addItem(NSMenuItem.separator())

            menu.addItem(sidebarMenuItem("Show Timeline", isEnabled: true) {
                if let onShowTimeline = onShowTimeline {
                    onShowTimeline()
                } else {
                    onSelect?()
                }
            })

            menu.addItem(sidebarMenuItem("Show Commits", isEnabled: true) {
                onShowCommits?()
            })

            menu.addItem(NSMenuItem.separator())

            menu.addItem(sidebarMenuItem("Show in Finder", isEnabled: true) {
                if let onShowInFinder = onShowInFinder {
                    onShowInFinder()
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([node.fullURL])
                }
            })
        } else {
            menu.addItem(sidebarMenuItem("Show Commits", isEnabled: true) {
                onShowCommits?()
            })

            menu.addItem(NSMenuItem.separator())

            menu.addItem(sidebarMenuItem("Show in Finder", isEnabled: true) {
                if let onShowInFinder = onShowInFinder {
                    onShowInFinder()
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([node.fullURL])
                }
            })
        }
        return menu
    }
}

// MARK: - Remote Action Type
enum RemoteActionType {
    case push
    case pull

    var defaultIconName: String {
        switch self {
        case .push: return "arrow.up"
        case .pull: return "arrow.down"
        }
    }
}

// MARK: - Remote Action Button
struct RemoteActionButton: View {
    let type: RemoteActionType
    let isActive: Bool
    let hasError: Bool
    let errorMessage: String?
    let defaultHelp: String
    let action: () -> Void

    @State private var isHovered: Bool = false
    @State private var isSpinning: Bool = false

    private var helpText: String {
        if let err = errorMessage, !err.isEmpty {
            return "\(type == .push ? "Push" : "Pull") failed: \(err)"
        }
        return defaultHelp
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isActive {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .rotationEffect(.degrees(isSpinning ? 360 : 0))
                } else if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                } else {
                    Image(systemName: type.defaultIconName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isHovered ? .primary : .secondary)
                }
            }
            .frame(width: 18, height: 18)
            .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            .cornerRadius(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            if isActive {
                startSpinning()
            }
        }
        .onChange(of: isActive) {
            if isActive {
                startSpinning()
            } else {
                isSpinning = false
            }
        }
    }

    private func startSpinning() {
        isSpinning = false
        withAnimation(Animation.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            isSpinning = true
        }
    }
}

// MARK: - Remote Repository Row
struct RemoteRepositoryRow: View {
    let remote: RemoteRepository
    let isPushing: Bool
    let isPulling: Bool
    let pushError: String?
    let pullError: String?
    let onPull: () -> Void
    let onPush: () -> Void

    @State private var isHovered: Bool = false
    @State private var isMenuShowing: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: 11))
                .foregroundColor(isMenuShowing ? .accentColor : .secondary)
                .frame(width: 14, height: 14)

            Text(remote.name)
                .font(.system(size: 11, weight: isMenuShowing ? .semibold : .medium))
                .foregroundColor(isMenuShowing ? .accentColor : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(remote.urlString ?? remote.name)

            Spacer(minLength: 4)

            // Pull button
            RemoteActionButton(
                type: .pull,
                isActive: isPulling,
                hasError: pullError != nil,
                errorMessage: pullError,
                defaultHelp: "Pull from \(remote.name)",
                action: onPull
            )
            .disabled(isPulling || isPushing)

            // Push button
            RemoteActionButton(
                type: .push,
                isActive: isPushing,
                hasError: pushError != nil,
                errorMessage: pushError,
                defaultHelp: "Push to \(remote.name)",
                action: onPush
            )
            .disabled(isPushing || isPulling)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(
            isMenuShowing ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isMenuShowing ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .overlay(
            SidebarContextMenuHighlightOverlay(
                onMenuWillOpen: {
                    isMenuShowing = true
                },
                onMenuDidClose: {
                    isMenuShowing = false
                },
                menuBuilder: {
                    makeContextMenu()
                }
            )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Remote Context Menu")
        if let url = remote.urlString {
            menu.addItem(sidebarMenuItem("Copy Remote URL", isEnabled: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
            menu.addItem(NSMenuItem.separator())
        }
        menu.addItem(sidebarMenuItem("Pull from \(remote.name)", isEnabled: !(isPulling || isPushing)) {
            onPull()
        })

        menu.addItem(sidebarMenuItem("Push to \(remote.name)", isEnabled: !(isPushing || isPulling)) {
            onPush()
        })

        return menu
    }
}

// MARK: - Context Menu Highlight Support
private final class MenuItemActionTarget: NSObject {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func performAction(_ sender: Any?) {
        action()
    }
}

func sidebarMenuItem(_ title: String, isEnabled: Bool = true, isDestructive: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(MenuItemActionTarget.performAction(_:)), keyEquivalent: "")
    let target = MenuItemActionTarget(action: action)
    item.target = target
    item.representedObject = target
    item.isEnabled = isEnabled
    return item
}

final class ContextMenuHighlightNSView: NSView, NSMenuDelegate {
    var onMenuWillOpen: (() -> Void)?
    var onMenuDidClose: (() -> Void)?
    var menuBuilder: (() -> NSMenu)?
    private var trackingEndObserver: NSObjectProtocol?
    private var isTrackingMenu: Bool = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isSecondaryClick = event.type == .rightMouseDown ||
            event.type == .rightMouseUp ||
            (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) ||
            (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isSecondaryClick {
            return self
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let builder = menuBuilder else { return nil }
        let menu = builder()
        menu.delegate = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        isTrackingMenu = true
        onMenuWillOpen?()
        if let obs = trackingEndObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        trackingEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: menu,
            queue: .main
        ) { [weak self] _ in
            self?.handleMenuDidClose()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        handleMenuDidClose()
    }

    private func handleMenuDidClose() {
        guard isTrackingMenu else { return }
        isTrackingMenu = false
        if let obs = trackingEndObserver {
            NotificationCenter.default.removeObserver(obs)
            trackingEndObserver = nil
        }
        onMenuDidClose?()
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let builder = menuBuilder else { return false }
        let menu = builder()
        menu.delegate = self
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: self)
        return true
    }

    deinit {
        if let obs = trackingEndObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}

struct SidebarContextMenuHighlightOverlay: NSViewRepresentable {
    var onMenuWillOpen: () -> Void
    var onMenuDidClose: () -> Void
    var menuBuilder: () -> NSMenu

    func makeNSView(context: Context) -> ContextMenuHighlightNSView {
        let view = ContextMenuHighlightNSView()
        view.onMenuWillOpen = onMenuWillOpen
        view.onMenuDidClose = onMenuDidClose
        view.menuBuilder = menuBuilder
        return view
    }

    func updateNSView(_ nsView: ContextMenuHighlightNSView, context: Context) {
        nsView.onMenuWillOpen = onMenuWillOpen
        nsView.onMenuDidClose = onMenuDidClose
        nsView.menuBuilder = menuBuilder
    }
}
