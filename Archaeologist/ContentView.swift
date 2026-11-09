import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @ObservedObject private var tabManager: TabManager
    @State private var isTargetedForDrop: Bool = false
    @State private var sidebarDragStartWidth: CGFloat? = nil

    public init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    public init() {
        self.tabManager = TabManager.shared
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Panel (Repository Files Tree)
            if tabManager.showSidebar {
                RepositorySidebarView(tabManager: tabManager)
                    .frame(width: max(160, min(500, tabManager.sidebarWidth)))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(10)

                // Resizable handle between sidebar and main area
                sidebarResizeHandle
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(10)
            }

            // Main Editor & Tabs Area
            ZStack(alignment: .topLeading) {
                Color(NSColor.windowBackgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let activeTab = tabManager.activeTab {
                    VStack(alignment: .leading, spacing: 0) {
                        TabBarView(tabManager: tabManager)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let commitVM = activeTab.commitViewModel {
                            CommitPromptView(viewModel: commitVM)
                                .id(activeTab.id)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        } else if let historyVM = activeTab.commitHistoryViewModel {
                            CommitHistoryTabView(viewModel: historyVM)
                                .id(activeTab.id)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        } else {
                            TabContentView(viewModel: activeTab.viewModel)
                                .id(activeTab.id)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .opacity(tabManager.isTransitioningToBlank ? 0.0 : 1.0)
                    .animation(.easeInOut(duration: 1.0), value: tabManager.isTransitioningToBlank)
                    .allowsHitTesting(!tabManager.isTransitioningToBlank)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
            .layoutPriority(0)
        }
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity, alignment: .leading)
        .navigationTitle("")
        .toolbar {
            toolbarContent
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in
                        tabManager.openItem(at: url)
                    }
                }
            }
            return true
        }
        .focusedSceneObject(tabManager.activeViewModel)
    }

    // MARK: - Resizable Divider for Sidebar
    private var sidebarResizeHandle: some View {
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
                                if sidebarDragStartWidth == nil {
                                    sidebarDragStartWidth = tabManager.sidebarWidth
                                }
                                let newWidth = (sidebarDragStartWidth ?? tabManager.sidebarWidth) + gesture.translation.width
                                tabManager.sidebarWidth = max(160, min(500, newWidth))
                            }
                            .onEnded { _ in
                                sidebarDragStartWidth = nil
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

    // MARK: - Toolbar Content
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Group 1: Sidebar button
        ToolbarItem(placement: .navigation) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    tabManager.showSidebar.toggle()
                }
            }) {
                Image(systemName: "sidebar.leading")
            }
            .help("Toggle Sidebar (Cmd+Ctrl+S)")
        }

        // Group 2: Back and Forward buttons with divider
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button(action: { tabManager.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!tabManager.canGoBack)
                .help("Back to previous revision / file (Cmd+[)")

                Button(action: { tabManager.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!tabManager.canGoForward)
                .help("Forward to next revision / file (Cmd+])")
            }
            .controlGroupStyle(.navigation)
        }

        // Group 2.4: Commit History button
        ToolbarItem(placement: .automatic) {
            Button(action: {
                tabManager.openCommitHistoryTab()
            }) {
                Label("Commit History", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(tabManager.activeRepoContext == nil)
            .help(tabManager.activeRepoContext != nil ? "View repository commit history" : "Open a repository to view commit history")
        }

        // Group 2.5: Commit button (to the left of Open button)
        ToolbarItem(placement: .automatic) {
            Button(action: {
                tabManager.openCommitTab()
            }) {
                Label("Commit", systemImage: "checkmark.circle")
            }
            .disabled(!tabManager.canCommit)
            .help(tabManager.canCommit ? "Commit working directory changes" : "No working directory changes to commit")
        }

        // Group 3: Open file or repository
        ToolbarItem(placement: .automatic) {
            Button(action: {
                tabManager.showOpenFileDialog()
            }) {
                Label("Open...", systemImage: "folder")
            }
            .help("Open a file or repository (Cmd+O)")
        }
    }
}

// MARK: - Tab Content View
struct TabContentView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @State private var commitMessageHeight: CGFloat = 130
    @State private var dragStartHeight: CGFloat? = nil

    var body: some View {
        if viewModel.isLoading {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Reading commit history...")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.selectedFileURL == nil || (!viewModel.errorMessage.isNilOrEmpty && viewModel.commits.isEmpty) {
            EmptyStateView(viewModel: viewModel)
                .overlay(
                    Group {
                        if let err = viewModel.errorMessage {
                            VStack {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.yellow)
                                    Text(err)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Button("Dismiss") {
                                        viewModel.errorMessage = nil
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                }
                                .padding(10)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(8)
                                .shadow(radius: 4)
                                .padding()
                                Spacer()
                            }
                        }
                    }
                )
        } else {
            // Main Three-Section Vertical Layout: Timeline -> Commit Info -> Data View
            VStack(alignment: .leading, spacing: 0) {
                // SECTION 1: The Timeline Bar
                TimelineBarView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                // SECTION 2: Commit Message View (Commit Information)
                CommitMessageView(viewModel: viewModel)
                    .frame(height: max(70, min(400, commitMessageHeight)))
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Resizable divider between commit information and data view
                resizeHandle

                // SECTION 3: Content View (Data View)
                ContentViewer(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
        }
    }

    // MARK: - Resizable Divider
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(height: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { gesture in
                                if dragStartHeight == nil {
                                    dragStartHeight = commitMessageHeight
                                }
                                let newHeight = (dragStartHeight ?? commitMessageHeight) + gesture.translation.height
                                commitMessageHeight = max(70, min(400, newHeight))
                            }
                            .onEnded { _ in
                                dragStartHeight = nil
                            }
                    )
            )
            .onHover { isHovered in
                if isHovered {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        return self?.isEmpty ?? true
    }
}
