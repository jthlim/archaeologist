import SwiftUI
import AppKit

public struct CommitPromptView: View {
    @ObservedObject var viewModel: CommitPromptViewModel
    public static let viewAsListIconName = "list.bullet"
    public static let viewAsTreeIconName = "list.bullet.indent"
    public static let viewAsListHelp = "View as list"
    public static let viewAsTreeHelp = "View as tree"

    @State private var checklistWidth: CGFloat = 280
    @State private var dragStartWidth: CGFloat? = nil
    @State private var collapsedNodes: Set<String> = []
    @State private var treeNodes: [FileTreeNode] = []
    @State private var visibleFlatTreeItems: [FlatFileTreeItem] = []

    public init(viewModel: CommitPromptViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // TOP SECTION: Commit message text entry box + Commit button
            topCommitBar

            Divider()

            // BOTTOM SECTION: Split horizontally (Left checklist, Right content view)
            HStack(spacing: 0) {
                checklistPane
                    .frame(width: max(180, min(500, checklistWidth)))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)

                splitResizeHandle
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)

                rightContentView
                    .layoutPriority(0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            viewModel.startWatching()
        }
        .onDisappear {
            viewModel.stopWatching()
        }
    }

    // MARK: - Top Commit Bar
    private var topCommitBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                // Multiline text entry box
                ZStack(alignment: .topLeading) {
                    if viewModel.commitMessage.isEmpty {
                        Text("Commit message (Cmd+Enter to commit)...")
                            .font(.system(size: 12))
                            .foregroundColor(Color(NSColor.placeholderTextColor))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }

                    CommitMessageTextEditor(
                        text: $viewModel.commitMessage,
                        onCommit: {
                            if viewModel.canCommit {
                                viewModel.performCommit()
                            }
                        }
                    )
                }
                .frame(minHeight: 56, maxHeight: 90)
                .padding(2)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )

                // Commit Button at the end of the line
                Button(action: {
                    if viewModel.canCommit {
                        viewModel.performCommit()
                    }
                }) {
                    HStack(spacing: 5) {
                        if viewModel.isCommitting {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text("Commit")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(minHeight: 26)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.canCommit)
                .help(
                    viewModel.checkedFilePaths.isEmpty
                        ? "Select at least one file to commit"
                        : (viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Enter a commit message"
                            : "Commit checked files (Cmd+Enter)")
                )
            }

            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 11))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Checklist Pane (Left)
    private var checklistPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text("Files to Commit")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(viewModel.visibleCheckedCount) of \(viewModel.visibleChangedFiles.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                Button(action: {
                    viewModel.toggleAllOrNone()
                }) {
                    Text(viewModel.isAllVisibleChecked ? "None" : "All")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                HStack(spacing: 2) {
                    Button(action: {
                        viewModel.fileViewMode = .list
                    }) {
                        Image(systemName: Self.viewAsListIconName)
                            .font(.system(size: 10, weight: viewModel.fileViewMode == .list ? .bold : .regular))
                            .foregroundColor(viewModel.fileViewMode == .list ? .accentColor : .secondary)
                            .frame(width: 18, height: 18)
                            .background(viewModel.fileViewMode == .list ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help(Self.viewAsListHelp)

                    Button(action: {
                        viewModel.fileViewMode = .tree
                    }) {
                        Image(systemName: Self.viewAsTreeIconName)
                            .font(.system(size: 10, weight: viewModel.fileViewMode == .tree ? .bold : .regular))
                            .foregroundColor(viewModel.fileViewMode == .tree ? .accentColor : .secondary)
                            .frame(width: 18, height: 18)
                            .background(viewModel.fileViewMode == .tree ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help(Self.viewAsTreeHelp)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .overlay(Divider(), alignment: .bottom)

            // "Show untracked" filter at the top of the list (default to on)
            HStack {
                Toggle(isOn: $viewModel.showUntracked) {
                    Text("Show untracked")
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.showUntracked ? .primary : .secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .overlay(Divider(), alignment: .bottom)

            if viewModel.visibleChangedFiles.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(viewModel.changedFiles.isEmpty ? "No working directory changes" : "No files to display")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.fileViewMode == .tree {
                treeFilesListView
            } else {
                flatFilesListView
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .onAppear {
            rebuildTree()
        }
        .onChange(of: viewModel.visibleChangedFiles) {
            rebuildTree()
        }
        .onChange(of: viewModel.selectedFilePath) {
            if let sel = viewModel.selectedFilePath {
                expandAncestors(for: sel)
                updateFlatTreeItems()
            }
        }
    }

    private var flatFilesListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.visibleChangedFiles) { change in
                    let isChecked = viewModel.checkedFilePaths.contains(change.relativePath)
                    let isSelected = viewModel.selectedFilePath == change.relativePath

                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { isChecked },
                            set: { _ in viewModel.toggleCheck(change.relativePath) }
                        )) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)

                        statusBadge(change.status)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: change.relativePath).lastPathComponent)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(change.status.textColor)

                            if change.relativePath.contains("/") {
                                Text(change.relativePath)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        isSelected
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.selectFile(change.relativePath)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var displayFlatTreeItems: [FlatFileTreeItem] {
        if visibleFlatTreeItems.isEmpty && !viewModel.visibleChangedFiles.isEmpty {
            var statusMap: [String: FileWorkingStatus] = [:]
            for change in viewModel.visibleChangedFiles {
                statusMap[change.relativePath] = change.status
            }
            let nodes = FileTreeNode.buildTree(from: statusMap, repoRoot: viewModel.repoContext.repoRoot)
            let defaultCollapsed = collapsedNodes.isEmpty ? nodes.defaultCollapsedUntrackedNodeIds() : collapsedNodes
            var items: [FlatFileTreeItem] = []
            func collect(nodes: [FileTreeNode], level: Int) {
                for node in nodes {
                    items.append(FlatFileTreeItem(node: node, level: level))
                    if node.isDirectory {
                        let isExpanded = !defaultCollapsed.contains(node.id)
                        if isExpanded, let children = node.children {
                            collect(nodes: children, level: level + 1)
                        }
                    }
                }
            }
            collect(nodes: nodes, level: 0)
            return items
        }
        return visibleFlatTreeItems
    }

    private var treeFilesListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(displayFlatTreeItems) { item in
                    let isExpanded = !collapsedNodes.contains(item.node.id)
                    let isSelected = !item.node.isDirectory && viewModel.selectedFilePath == item.node.id
                    let descendantPaths = allDescendantFilePaths(for: item.node)
                    let isChecked = item.node.isDirectory
                        ? (!descendantPaths.isEmpty && descendantPaths.allSatisfy { viewModel.checkedFilePaths.contains($0) })
                        : viewModel.checkedFilePaths.contains(item.node.id)

                    CommitPromptFileTreeRow(
                        node: item.node,
                        level: item.level,
                        isExpanded: isExpanded,
                        isSelected: isSelected,
                        isChecked: isChecked,
                        onToggleExpand: {
                            toggleExpand(item.node)
                        },
                        onToggleCheck: {
                            if item.node.isDirectory {
                                if isChecked {
                                    viewModel.checkedFilePaths.subtract(descendantPaths)
                                } else {
                                    viewModel.checkedFilePaths.formUnion(descendantPaths)
                                }
                            } else {
                                viewModel.toggleCheck(item.node.id)
                            }
                        },
                        onSelect: {
                            viewModel.selectFile(item.node.id)
                        }
                    )
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
    }

    private func rebuildTree() {
        var statusMap: [String: FileWorkingStatus] = [:]
        for change in viewModel.visibleChangedFiles {
            statusMap[change.relativePath] = change.status
        }
        self.treeNodes = FileTreeNode.buildTree(from: statusMap, repoRoot: viewModel.repoContext.repoRoot)
        self.collapsedNodes = self.treeNodes.defaultCollapsedUntrackedNodeIds()
        if let sel = viewModel.selectedFilePath {
            expandAncestors(for: sel)
        }
        updateFlatTreeItems()
    }

    private func updateFlatTreeItems() {
        var items: [FlatFileTreeItem] = []

        func collect(nodes: [FileTreeNode], level: Int) {
            for node in nodes {
                items.append(FlatFileTreeItem(node: node, level: level))
                if node.isDirectory {
                    let isExpanded = !collapsedNodes.contains(node.id)
                    if isExpanded, let children = node.children {
                        collect(nodes: children, level: level + 1)
                    }
                }
            }
        }

        collect(nodes: treeNodes, level: 0)
        self.visibleFlatTreeItems = items
    }

    private func toggleExpand(_ node: FileTreeNode) {
        if collapsedNodes.contains(node.id) {
            collapsedNodes.remove(node.id)
        } else {
            collapsedNodes.insert(node.id)
        }
        updateFlatTreeItems()
    }

    private func expandAncestors(for relativePath: String) {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return }
        var current = ""
        for i in 0..<(parts.count - 1) {
            current = current.isEmpty ? parts[i] : "\(current)/\(parts[i])"
            if let node = treeNodes.findNode(withRelativePath: current), node.containsOnlyUntrackedFiles() {
                continue
            }
            collapsedNodes.remove(current)
        }
    }

    private func allDescendantFilePaths(for node: FileTreeNode) -> [String] {
        if !node.isDirectory {
            return [node.id]
        }
        return node.children?.flatMap { allDescendantFilePaths(for: $0) } ?? []
    }

    // MARK: - Resizable Split Handle
    private var splitResizeHandle: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { gesture in
                                if dragStartWidth == nil {
                                    dragStartWidth = checklistWidth
                                }
                                let newWidth = (dragStartWidth ?? checklistWidth) + gesture.translation.width
                                checklistWidth = max(180, min(500, newWidth))
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                            }
                    )
            )
            .onHover { isHovered in
                if isHovered {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    // MARK: - Content View (Right)
    private var rightContentView: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)

            if viewModel.selectedFilePath != nil {
                DiffView(viewModel: viewModel.diffViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("Select a file to preview changes")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status Badge
    private func statusBadge(_ status: FileWorkingStatus) -> some View {
        Text(status.badgeLabel)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(status.textColor)
            .frame(width: 16, height: 16)
            .background(status.textColor.opacity(0.15))
            .cornerRadius(4)
    }
}

// MARK: - Multiline Commit Message Text Editor Representable
struct CommitMessageTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = CommitMessageTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.onCommit = onCommit

        scrollView.documentView = textView
        context.coordinator.textView = textView

        DispatchQueue.main.async { [weak textView] in
            textView?.makeActive()
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? CommitMessageTextView else { return }
        textView.onCommit = onCommit
        if textView.string != text {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommitMessageTextEditor
        weak var textView: CommitMessageTextView?

        init(_ parent: CommitMessageTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.text != tv.string {
                parent.text = tv.string
            }
        }
    }
}

final class CommitMessageTextView: NSTextView {
    var onCommit: (() -> Void)?
    private var hasMadeActiveByDefault = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            makeActive()
        }
    }

    func makeActive() {
        guard !hasMadeActiveByDefault else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window, !self.hasMadeActiveByDefault else { return }
            self.hasMadeActiveByDefault = true
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturnOrEnter = (event.keyCode == 36 || event.keyCode == 76)
        if event.modifierFlags.contains(.command) && isReturnOrEnter {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let isReturnOrEnter = (event.keyCode == 36 || event.keyCode == 76)
        if event.modifierFlags.contains(.command) && isReturnOrEnter {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Commit Prompt File Tree Row
struct CommitPromptFileTreeRow: View {
    let node: FileTreeNode
    let level: Int
    let isExpanded: Bool
    let isSelected: Bool
    let isChecked: Bool
    let onToggleExpand: () -> Void
    let onToggleCheck: () -> Void
    let onSelect: () -> Void

    private var itemTextColor: Color {
        if let statusColor = node.statusTextColor {
            return statusColor
        }
        return isSelected ? .accentColor : .primary
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

    private func statusBadge(_ status: FileWorkingStatus) -> some View {
        Text(status.badgeLabel)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(status.textColor)
            .frame(width: 16, height: 16)
            .background(status.textColor.opacity(0.15))
            .cornerRadius(4)
    }

    var body: some View {
        HStack(spacing: 4) {
            // Indentation
            if level > 0 {
                Spacer()
                    .frame(width: CGFloat(level * 12))
            }

            if node.isDirectory {
                // Disclosure chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(node.statusTextColor ?? .secondary)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onToggleExpand()
                    }

                // Checkbox for directory
                Toggle(isOn: Binding(
                    get: { isChecked },
                    set: { _ in onToggleCheck() }
                )) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                // Directory Icon (colored similar to RepositorySidebarView.swift)
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 11))
                    .foregroundColor(iconColor)
                    .frame(width: 14, height: 14)

                // Name
                Text(node.name)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(itemTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            } else {
                Spacer()
                    .frame(width: 12)

                // Checkbox for file
                Toggle(isOn: Binding(
                    get: { isChecked },
                    set: { _ in onToggleCheck() }
                )) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                // File Icon
                Image(systemName: node.iconName)
                    .font(.system(size: 11))
                    .foregroundColor(iconColor)
                    .frame(width: 14, height: 14)

                // Name
                Text(node.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(itemTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                // Status Badge
                statusBadge(node.status)
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 4)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        )
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                onToggleExpand()
            } else {
                onSelect()
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.fullURL])
            }
        }
    }
}
