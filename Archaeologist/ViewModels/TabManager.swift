import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
public class TabItem: Identifiable, ObservableObject {
    public let id: UUID
    public let viewModel: HistoryViewModel
    public let commitViewModel: CommitPromptViewModel?
    public let commitHistoryViewModel: CommitHistoryViewModel?
    private var cancellable: AnyCancellable?
    private var commitCancellable: AnyCancellable?
    private var historyCancellable: AnyCancellable?

    public init(id: UUID = UUID(), viewModel: HistoryViewModel) {
        self.id = id
        self.viewModel = viewModel
        self.commitViewModel = nil
        self.commitHistoryViewModel = nil
        self.cancellable = viewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public init(id: UUID = UUID(), commitViewModel: CommitPromptViewModel) {
        self.id = id
        self.viewModel = commitViewModel.previewViewModel
        self.commitViewModel = commitViewModel
        self.commitHistoryViewModel = nil
        self.commitCancellable = commitViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public init(id: UUID = UUID(), commitHistoryViewModel: CommitHistoryViewModel) {
        self.id = id
        let vm = HistoryViewModel()
        vm.repoContext = commitHistoryViewModel.repoContext
        vm.tabManager = commitHistoryViewModel.tabManager
        vm.shouldRecordHistory = false
        self.viewModel = vm
        self.commitViewModel = nil
        self.commitHistoryViewModel = commitHistoryViewModel
        self.historyCancellable = commitHistoryViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public init(id: UUID = UUID()) {
        let vm = HistoryViewModel()
        self.id = id
        self.viewModel = vm
        self.commitViewModel = nil
        self.commitHistoryViewModel = nil
        self.cancellable = vm.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public var isCommitPrompt: Bool {
        commitViewModel != nil
    }

    public var isCommitHistory: Bool {
        commitHistoryViewModel != nil
    }

    public var title: String {
        if let commitVM = commitViewModel {
            return "Commit: \(commitVM.repoContext.repoRoot.lastPathComponent)"
        }
        if let historyVM = commitHistoryViewModel {
            if let filePath = historyVM.filteredFilePath {
                return filePath
            }
            return historyVM.repoContext.repoRoot.lastPathComponent
        }
        return viewModel.fileName
    }

    public var vcsType: VCSType? {
        if let commitVM = commitViewModel {
            return commitVM.repoContext.vcsType
        }
        if let historyVM = commitHistoryViewModel {
            return historyVM.repoContext.vcsType
        }
        return viewModel.vcsType
    }

    public var subtitle: String {
        if commitViewModel != nil {
            return "Commit changes"
        }
        if let historyVM = commitHistoryViewModel {
            if let filePath = historyVM.filteredFilePath {
                return filePath
            }
            return "Commit history"
        }
        return viewModel.relativePath
    }

    public var isLoaded: Bool {
        if commitViewModel != nil || commitHistoryViewModel != nil {
            return true
        }
        return viewModel.selectedFileURL != nil
    }
}

@MainActor
public class TabManager: ObservableObject {
    public static let shared = TabManager()

    @Published public var tabs: [TabItem] = []
    @Published public var activeTabId: UUID?
    @Published public var backStack: [NavigationState] = []
    @Published public var forwardStack: [NavigationState] = []
    public var isNavigatingBack: Bool = false
    private var tabCancellables: [UUID: AnyCancellable] = [:]

    // Left Panel (Repository Files Sidebar) State
    @Published public var showSidebar: Bool = true
    @Published public var sidebarWidth: CGFloat = 240
    @Published public var repositoryFiles: [FileTreeNode] = []
    @Published public var repositoryFilesVersion: Int = 0
    @Published public var isLoadingRepoFiles: Bool = false
    @Published public var showUntrackedFiles: Bool = true
    @Published public var onlyShowModifiedFiles: Bool = false
    @Published public var hasWorkingCopyChanges: Bool = false
    @Published public var selectedRepoContext: RepoContext? = nil
    @Published public var isTransitioningToBlank: Bool = false
    private var fadeToBlankTask: Task<Void, Never>?
    public var cachedRepoPath: String? = nil
    public var cachedRepoVCSType: VCSType? = nil
    public var repositoryFilesCache: [String: [FileTreeNode]] = [:]
    private var repoFilesTask: Task<Void, Never>?
    private var directoryWatcher: DirectoryWatcher?
    private var watchingRepoPath: String?
    private var debouncedRefreshTask: Task<Void, Never>?
    private var debouncePaths: Set<String> = []

    // MARK: - Remotes State
    @Published public var remoteRepositories: [RemoteRepository] = []
    @Published public var isLoadingRemotes: Bool = false
    @Published public var activePushRemotes: Set<String> = []
    @Published public var activePullRemotes: Set<String> = []
    @Published public var isPushingAllRemotes: Bool = false
    @Published public var pushErrors: [String: String] = [:]
    @Published public var pullErrors: [String: String] = [:]
    @Published public var pushAllError: String? = nil
    private var remotesTask: Task<Void, Never>?

    public var activeRepoContext: RepoContext? {
        if let commitCtx = activeTab?.commitViewModel?.repoContext {
            return commitCtx
        }
        if let historyCtx = activeTab?.commitHistoryViewModel?.repoContext {
            return historyCtx
        }
        if let activeCtx = activeViewModel?.repoContext {
            return activeCtx
        }
        return selectedRepoContext
    }

    public var canCommit: Bool {
        activeRepoContext != nil && hasWorkingCopyChanges
    }

    public func updateWorkingCopyChangesStatus() {
        guard let context = activeRepoContext else {
            hasWorkingCopyChanges = false
            return
        }
        Task.detached(priority: .userInitiated) {
            let hasChanges = VCSManager.shared.hasRepositoryWorkingCopyChanges(context: context)
            await MainActor.run { [weak self] in
                self?.hasWorkingCopyChanges = hasChanges
            }
        }
    }

    public func openCommitTab(
        context: RepoContext? = nil,
        initialChanges: [WorkingFileChange]? = nil,
        initialSelectedFilePath: String? = nil,
        existingDiffViewModel: DiffViewModel? = nil
    ) {
        guard let ctx = context ?? activeRepoContext else { return }

        var effectiveChanges = initialChanges
        var effectiveSelectedPath = initialSelectedFilePath
        var effectiveDiffVM = existingDiffViewModel

        if effectiveChanges == nil {
            let candidateTabs: [TabItem] = {
                if let active = activeTab, active.commitHistoryViewModel != nil {
                    return [active] + tabs.filter { $0.id != active.id }
                }
                return tabs
            }()

            if let historyTab = candidateTabs.first(where: { tab in
                guard let hvm = tab.commitHistoryViewModel else { return false }
                return hvm.repoContext.repoRoot.standardizedFileURL.path == ctx.repoRoot.standardizedFileURL.path &&
                       hvm.selectedCommit?.isUncommitted == true
            }), let historyVM = historyTab.commitHistoryViewModel {
                effectiveChanges = historyVM.uncommittedWorkingChanges
                effectiveSelectedPath = historyVM.selectedFilePath
                effectiveDiffVM = historyVM.diffViewModel
            }
        }

        // If a commit tab is already open for this repo, select it
        if let existingTab = tabs.first(where: {
            $0.commitViewModel?.repoContext.repoRoot.standardizedFileURL.path == ctx.repoRoot.standardizedFileURL.path
        }) {
            selectTab(id: existingTab.id)
            existingTab.commitViewModel?.refreshWorkingDirectoryChanges()
            return
        }

        let commitVM = CommitPromptViewModel(
            repoContext: ctx,
            tabManager: self,
            initialChanges: effectiveChanges,
            initialSelectedFilePath: effectiveSelectedPath,
            existingDiffViewModel: effectiveDiffVM
        )
        let tab = TabItem(commitViewModel: commitVM)
        observeTab(tab)
        tabs.append(tab)
        activeTabId = tab.id
        checkActiveRepoChange()
    }

    @discardableResult
    public func openCommitHistoryTab(
        context: RepoContext? = nil,
        filePath: String? = nil,
        refreshIfExisting: Bool = true
    ) -> CommitHistoryViewModel? {
        guard let ctx = context ?? activeRepoContext else { return nil }

        // If a commit history tab is already open for this repo, VCS type, and same filePath, select it
        if let existingTab = tabs.first(where: {
            $0.commitHistoryViewModel?.repoContext.repoRoot == ctx.repoRoot &&
            $0.commitHistoryViewModel?.repoContext.vcsType == ctx.vcsType &&
            $0.commitHistoryViewModel?.filteredFilePath == filePath
        }) {
            selectTab(id: existingTab.id)
            if refreshIfExisting {
                if existingTab.commitHistoryViewModel?.hasLoaded == true {
                    existingTab.commitHistoryViewModel?.refreshInBackground()
                } else {
                    existingTab.commitHistoryViewModel?.loadBranchesAndHistory()
                }
            }
            return existingTab.commitHistoryViewModel
        }

        let historyVM = CommitHistoryViewModel(repoContext: ctx, filePath: filePath, tabManager: self)
        let tab = TabItem(commitHistoryViewModel: historyVM)
        observeTab(tab)
        tabs.append(tab)
        activeTabId = tab.id
        return historyVM
    }

    public var canGoBack: Bool {
        !backStack.isEmpty
    }

    public var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    public var activeTab: TabItem? {
        if let id = activeTabId {
            return tabs.first(where: { $0.id == id }) ?? tabs.first
        }
        return tabs.first
    }

    public var activeViewModel: HistoryViewModel? {
        activeTab?.viewModel
    }

    public init() {
        let initialTab = createTab()
        tabs = [initialTab]
        activeTabId = initialTab.id
    }

    public func createTab() -> TabItem {
        let vm = HistoryViewModel()
        let tab = TabItem(viewModel: vm)
        vm.tabManager = self
        observeTab(tab)
        return tab
    }

    private func observeTab(_ tab: TabItem) {
        tabCancellables[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public func checkActiveRepoChange(force: Bool = false) {
        let currentContext = activeRepoContext
        let currentPath = currentContext?.repoRoot.standardizedFileURL.path

        if currentPath == nil {
            // If the active tab has a selected file that matches the cached repository,
            // retain the cached files while the tab context initializes.
            if let targetURL = activeViewModel?.selectedFileURL,
               let cached = cachedRepoPath,
               targetURL.standardizedFileURL.path.hasPrefix(cached) {
                return
            }
            // Only clear if the tab has no file, no context, and no selected repository
            if activeViewModel?.selectedFileURL == nil && selectedRepoContext == nil {
                repositoryFiles = []
                remoteRepositories = []
                activePushRemotes.removeAll()
                activePullRemotes.removeAll()
                isPushingAllRemotes = false
                pushErrors.removeAll()
                pullErrors.removeAll()
                pushAllError = nil
                isLoadingRemotes = false
                remotesTask?.cancel()
                hasWorkingCopyChanges = false
                cachedRepoPath = nil
                cachedRepoVCSType = nil
                isLoadingRepoFiles = false
                directoryWatcher?.stop()
                directoryWatcher = nil
                watchingRepoPath = nil
                debouncedRefreshTask?.cancel()
            }
            return
        }

        guard let repoPath = currentPath, let context = currentContext else { return }

        // Keep directory watcher aligned with active repository
        updateDirectoryWatcher(for: context.repoRoot)

        // Load remotes if repo changed or forced or remotes are empty
        if force || repoPath != cachedRepoPath || context.vcsType != cachedRepoVCSType || remoteRepositories.isEmpty {
            loadRemotes()
        }

        // If it's already the active repo and we have files, nothing to do unless forced
        if !force && repoPath == cachedRepoPath && context.vcsType == cachedRepoVCSType && !repositoryFiles.isEmpty {
            updateWorkingCopyChangesStatus()
            return
        }

        cachedRepoPath = repoPath
        cachedRepoVCSType = context.vcsType

        let cacheKey = "\(context.vcsType.rawValue):\(repoPath)"

        // If not forced and we have a cached tree for this repo root, use it immediately
        if !force, let cachedNodes = repositoryFilesCache[cacheKey] ?? repositoryFilesCache[repoPath], !cachedNodes.isEmpty {
            repositoryFiles = cachedNodes
            hasWorkingCopyChanges = cachedNodes.contains(where: { $0.hasChanges() })
            isLoadingRepoFiles = false
            return
        }

        // Display existing cached nodes if available while refreshing in background
        if let cachedNodes = repositoryFilesCache[cacheKey] ?? repositoryFilesCache[repoPath] {
            repositoryFiles = cachedNodes
            hasWorkingCopyChanges = cachedNodes.contains(where: { $0.hasChanges() })
        } else if !repositoryFiles.isEmpty && cachedRepoPath == repoPath && cachedRepoVCSType == context.vcsType {
            hasWorkingCopyChanges = repositoryFiles.contains(where: { $0.hasChanges() })
        } else {
            repositoryFiles = []
            hasWorkingCopyChanges = false
        }

        repoFilesTask?.cancel()
        isLoadingRepoFiles = repositoryFiles.isEmpty

        let repoRoot = context.repoRoot
        let vcs = context.vcsType
        repoFilesTask = Task.detached(priority: .userInitiated) {
            let statusMap = VCSManager.shared.fetchRepositoryFileStatuses(context: context)
            guard !Task.isCancelled else { return }
            let nodes = FileTreeNode.buildTree(from: statusMap, repoRoot: repoRoot)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self = self, self.cachedRepoPath == repoPath, self.cachedRepoVCSType == vcs else { return }
                self.repositoryFilesCache[cacheKey] = nodes
                self.repositoryFilesCache[repoPath] = nodes
                self.repositoryFiles = nodes
                self.hasWorkingCopyChanges = nodes.contains(where: { $0.hasChanges() })
                self.isLoadingRepoFiles = false
            }
        }
    }

    public func refreshRepositoryFiles() {
        checkActiveRepoChange(force: true)
    }

    public func scheduleDebouncedRefresh(paths: [String]) {
        debouncedRefreshTask?.cancel()
        debouncePaths.formUnion(paths)
        debouncedRefreshTask = Task { @MainActor [weak self] in
            guard let localDebouncePaths = self?.debouncePaths else { return }
            self?.debouncePaths = []
            do {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
            } catch {
                return
            }
            guard !Task.isCancelled, let self = self else { return }
            self.refreshRepositoryFiles()
            for tab in self.tabs {
                tab.viewModel.checkWorkingDirectoryChanges(localDebouncePaths)
                if tab.commitHistoryViewModel?.hasLoaded == true {
                    tab.commitHistoryViewModel?.refreshInBackground()
                }
                tab.commitViewModel?.checkWorkingDirectoryChanges(localDebouncePaths)
            }
        }
    }

    private func updateDirectoryWatcher(for repoRoot: URL) {
        let repoPath = repoRoot.standardizedFileURL.path
        if watchingRepoPath == repoPath && directoryWatcher != nil {
            return
        }
        directoryWatcher?.stop()
        directoryWatcher = nil
        watchingRepoPath = repoPath

        directoryWatcher = DirectoryWatcher(url: repoRoot) { [weak self] (paths) in
            Task { @MainActor [weak self] in
              self?.scheduleDebouncedRefresh(paths: paths)
            }
        }
    }

    @discardableResult
    public func openRepository(at url: URL, preferredVCS: VCSType? = nil, fadeDuration: TimeInterval = 1.0) -> Bool {
        guard let context = VCSManager.shared.detectContext(for: url, preferredVCS: preferredVCS) else {
            return false
        }
        selectedRepoContext = context
        showSidebar = true
        fadeToBlankTask?.cancel()
        isTransitioningToBlank = false

        let tabsToClose = tabs
        for tab in tabsToClose {
            tabCancellables.removeValue(forKey: tab.id)
        }
        tabs.removeAll()
        activeTabId = nil

        openCommitHistoryTab(context: context)
        checkActiveRepoChange(force: true)

        return true
    }

    public func openItem(at url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.standardizedFileURL.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            openRepository(at: url)
        } else {
            openInTab(url: url)
        }
    }

    public func showOpenFileDialog() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose a file or repository"
        openPanel.prompt = "Open"
        openPanel.showsHiddenFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = true
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = false

        if openPanel.runModal() == .OK, let url = openPanel.url {
            openItem(at: url)
        }
    }

    public func showSelectRepositoryDialog() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Repository"
        openPanel.prompt = "Select"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = false

        if openPanel.runModal() == .OK, let url = openPanel.url {
            _ = openRepository(at: url)
        }
    }

    // MARK: - Optimistic Repository Updates
    public func updateRepositoryFilesCache(with nodes: [FileTreeNode]) {
        if let repoPath = activeRepoContext?.repoRoot.standardizedFileURL.path {
            self.repositoryFilesCache[repoPath] = nodes
        }
        if let ctx = activeRepoContext {
            let repoPath = ctx.repoRoot.standardizedFileURL.path
            let cacheKey = "\(ctx.vcsType.rawValue):\(repoPath)"
            self.repositoryFilesCache[cacheKey] = nodes
        } else if let cachedPath = cachedRepoPath {
            self.repositoryFilesCache[cachedPath] = nodes
            if let cachedVCS = cachedRepoVCSType {
                let cacheKey = "\(cachedVCS.rawValue):\(cachedPath)"
                self.repositoryFilesCache[cacheKey] = nodes
            }
        }
    }

    public func optimisticAddFile(relativePath: String) {
        var newTree = repositoryFiles.clone()
        if newTree.updateNodeStatus(targetPath: relativePath, newStatus: .new) {
            self.repositoryFiles = newTree
            self.repositoryFilesVersion += 1
            updateRepositoryFilesCache(with: newTree)
            self.hasWorkingCopyChanges = true
        }
    }

    public func optimisticDiscardChanges(relativePath: String, currentStatus: FileWorkingStatus) {
        var newTree = repositoryFiles.clone()
        let newStatus: FileWorkingStatus = (currentStatus == .new) ? .unknown : .clean
        if newTree.updateNodeStatus(targetPath: relativePath, newStatus: newStatus) {
            self.repositoryFiles = newTree
            self.repositoryFilesVersion += 1
            updateRepositoryFilesCache(with: newTree)
            self.hasWorkingCopyChanges = newTree.contains(where: { $0.hasChanges() })
        }
    }

    public func optimisticDeleteFile(relativePath: String, currentStatus: FileWorkingStatus) {
        var newTree = repositoryFiles.clone()
        let updated: Bool
        if currentStatus == .unknown {
            updated = newTree.removeNode(targetPath: relativePath)
        } else {
            updated = newTree.updateNodeStatus(targetPath: relativePath, newStatus: .deleted)
        }
        if updated {
            self.repositoryFiles = newTree
            self.repositoryFilesVersion += 1
            updateRepositoryFilesCache(with: newTree)
            self.hasWorkingCopyChanges = newTree.contains(where: { $0.hasChanges() })
        }
    }

    public func optimisticCommit(files: [String]) {
        var newTree = repositoryFiles.clone()
        var changed = false
        for filePath in files {
            if let node = newTree.findNode(withRelativePath: filePath) {
                if node.status == .deleted {
                    if newTree.removeNode(targetPath: filePath) {
                        changed = true
                    }
                } else {
                    if newTree.updateNodeStatus(targetPath: filePath, newStatus: .clean) {
                        changed = true
                    }
                }
            }
        }
        if changed {
            self.repositoryFiles = newTree
            self.repositoryFilesVersion += 1
            updateRepositoryFilesCache(with: newTree)
            self.hasWorkingCopyChanges = newTree.contains(where: { $0.hasChanges() })
        }
    }

    public func addFile(for node: FileTreeNode) {
        guard let context = activeRepoContext else { return }
        optimisticAddFile(relativePath: node.id)
      
        let paths : Set<String> = [node.fullURL.relativePath]
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try VCSManager.shared.addFile(context: context, relativePath: node.id)
                self.refreshRepositoryFiles()
                for tab in self.tabs {
                    tab.viewModel.checkWorkingDirectoryChanges(paths)
                    if tab.commitHistoryViewModel?.hasLoaded == true {
                        tab.commitHistoryViewModel?.refreshInBackground()
                    }
                    tab.commitViewModel?.checkWorkingDirectoryChanges(paths)
                }
            } catch {
                print("Failed to add file \(node.id): \(error)")
                self.refreshRepositoryFiles()
            }
        }
    }

    public func discardChanges(for node: FileTreeNode) {
        guard let context = activeRepoContext else { return }
        optimisticDiscardChanges(relativePath: node.id, currentStatus: node.status)
        let paths : Set<String> = [node.fullURL.relativePath]
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try VCSManager.shared.discardChanges(context: context, relativePath: node.id, status: node.status)
                self.refreshRepositoryFiles()
                for tab in self.tabs {
                    tab.viewModel.checkWorkingDirectoryChanges(paths)
                    if tab.viewModel.selectedFileURL?.standardizedFileURL.path == node.fullURL.standardizedFileURL.path {
                        tab.viewModel.loadContentForCurrentCommit()
                    }
                    if tab.commitHistoryViewModel?.hasLoaded == true {
                        tab.commitHistoryViewModel?.refreshInBackground()
                    }
                    tab.commitViewModel?.checkWorkingDirectoryChanges(paths)
                }
            } catch {
                print("Failed to discard changes for \(node.id): \(error)")
                self.refreshRepositoryFiles()
            }
        }
    }

    public var confirmUntrackedDeletion: ((FileTreeNode) -> Bool)? = nil

    private func showUntrackedDeletionWarning(for node: FileTreeNode) -> Bool {
        if let customPrompt = confirmUntrackedDeletion {
            return customPrompt(node)
        }
        let itemType = node.isDirectory ? "Folder" : "File"
        let alert = NSAlert()
        alert.messageText = "Delete Untracked \(itemType)?"
        alert.informativeText = "Are you sure you want to delete '\(node.name)'? This \(itemType.lowercased()) is untracked and will be removed permanently from disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func deleteFile(for node: FileTreeNode) {
        guard let context = activeRepoContext else { return }

        // When the deleted file is untracked, show a warning message that the file will be removed.
        // If the user proceeds, just delete it locally and remove it immediately from the file tree.
        if node.status == .unknown {
            guard showUntrackedDeletionWarning(for: node) else { return }

            if self.selectedRepoContext == nil {
                self.selectedRepoContext = context
            }

            // Remove immediately from the file tree
            optimisticDeleteFile(relativePath: node.id, currentStatus: .unknown)

            // Just delete it locally
            let targetPath = node.fullURL.standardizedFileURL.path
            let repoPath = context.repoRoot.appendingPathComponent(node.id).standardizedFileURL.path
            if FileManager.default.fileExists(atPath: targetPath) {
                try? FileManager.default.removeItem(atPath: targetPath)
            } else if FileManager.default.fileExists(atPath: repoPath) {
                try? FileManager.default.removeItem(atPath: repoPath)
            }

            // When deleting a file, remove any tab showing the file too.
            let targetResolved = node.fullURL.resolvingSymlinksInPath().path
            let tabsToClose = self.tabs.filter { tab in
                guard let fileURL = tab.viewModel.selectedFileURL else { return false }
                let filePath = fileURL.standardizedFileURL.path
                let fileResolved = fileURL.resolvingSymlinksInPath().path
                if filePath == targetPath || fileResolved == targetResolved {
                    return true
                }
                if !node.id.isEmpty && tab.viewModel.relativePath == node.id {
                    return true
                }
                if node.isDirectory {
                    if filePath.hasPrefix(targetPath + "/") || fileResolved.hasPrefix(targetResolved + "/") {
                        return true
                    }
                }
                return false
            }

            for tab in tabsToClose {
                self.closeTab(id: tab.id)
            }

            self.refreshRepositoryFiles()
            let paths : Set<String> = [node.fullURL.relativePath]

            for tab in self.tabs {
                tab.viewModel.checkWorkingDirectoryChanges(paths)
                if tab.commitHistoryViewModel?.hasLoaded == true {
                    tab.commitHistoryViewModel?.refreshInBackground()
                }
                tab.commitViewModel?.checkWorkingDirectoryChanges(paths)
            }
            return
        }

        optimisticDeleteFile(relativePath: node.id, currentStatus: node.status)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                if self.selectedRepoContext == nil {
                    self.selectedRepoContext = context
                }

                try VCSManager.shared.deleteFile(context: context, relativePath: node.id, status: node.status)

                // When deleting a file, remove any tab showing the file too.
                let targetPath = node.fullURL.standardizedFileURL.path
                let targetResolved = node.fullURL.resolvingSymlinksInPath().path
                let tabsToClose = self.tabs.filter { tab in
                    guard let fileURL = tab.viewModel.selectedFileURL else { return false }
                    let filePath = fileURL.standardizedFileURL.path
                    let fileResolved = fileURL.resolvingSymlinksInPath().path
                    if filePath == targetPath || fileResolved == targetResolved {
                        return true
                    }
                    if !node.id.isEmpty && tab.viewModel.relativePath == node.id {
                        return true
                    }
                    if node.isDirectory {
                        if filePath.hasPrefix(targetPath + "/") || fileResolved.hasPrefix(targetResolved + "/") {
                            return true
                        }
                    }
                    return false
                }

                for tab in tabsToClose {
                    self.closeTab(id: tab.id)
                }

                self.refreshRepositoryFiles()
                let paths : Set<String> = [node.fullURL.relativePath]
                for tab in self.tabs {
                    tab.viewModel.checkWorkingDirectoryChanges(paths)
                    if tab.commitHistoryViewModel?.hasLoaded == true {
                        tab.commitHistoryViewModel?.refreshInBackground()
                    }
                    tab.commitViewModel?.checkWorkingDirectoryChanges(paths)
                }
            } catch {
                print("Failed to delete file \(node.id): \(error)")
                self.refreshRepositoryFiles()
            }
        }
    }

    public func openNewEmptyTab() {
        fadeToBlankTask?.cancel()
        isTransitioningToBlank = false
        let tab = createTab()
        tabs.append(tab)
        activeTabId = tab.id
        checkActiveRepoChange()
        tab.viewModel.showOpenFileDialog()
    }

    public func selectTab(id: UUID) {
        if activeTabId != id {
            activeTabId = id
            if let tabCtx = activeViewModel?.repoContext
                ?? activeTab?.commitViewModel?.repoContext
                ?? activeTab?.commitHistoryViewModel?.repoContext {
                selectedRepoContext = tabCtx
            }
            checkActiveRepoChange()
            if let historyVM = activeTab?.commitHistoryViewModel,
               historyVM.hasLoaded,
               !historyVM.isLoading,
               !historyVM.isRefreshingInBackground {
                historyVM.refreshWorkingDirectoryChanges()
            }
        }
    }

    public func closeTab(id: UUID) {
        tabCancellables.removeValue(forKey: id)
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            activeTabId = nil
        } else if activeTabId == id {
            let nextIdx = max(0, min(tabs.count - 1, idx == 0 ? 0 : idx - 1))
            activeTabId = tabs[nextIdx].id
        }
        if let tabCtx = activeViewModel?.repoContext
            ?? activeTab?.commitViewModel?.repoContext
            ?? activeTab?.commitHistoryViewModel?.repoContext {
            selectedRepoContext = tabCtx
        }
        checkActiveRepoChange()
    }

    public func pushNavigationState(from state: NavigationState) {
        guard !isNavigatingBack else { return }
        // Do not add to the back list if the same file & revision is selected
        if let last = backStack.last, last == state {
            return
        }
        backStack.append(state)
        forwardStack.removeAll()
    }

    public func goBack() {
        guard !backStack.isEmpty else { return }
        let targetState = backStack.removeLast()

        if let currentState = activeViewModel?.currentNavigationState {
            forwardStack.append(currentState)
        }

        isNavigatingBack = true
        defer { isNavigatingBack = false }

        openInTab(
            url: targetState.fileURL,
            initialRevision: targetState.revision,
            preferredVCS: targetState.vcsType
        )
    }

    public func goForward() {
        guard !forwardStack.isEmpty else { return }
        let targetState = forwardStack.removeLast()

        if let currentState = activeViewModel?.currentNavigationState {
            backStack.append(currentState)
        }

        isNavigatingBack = true
        defer { isNavigatingBack = false }

        openInTab(
            url: targetState.fileURL,
            initialRevision: targetState.revision,
            preferredVCS: targetState.vcsType
        )
    }

    public func openInTab(
        url: URL,
        initialRevision: String? = nil,
        preferredVCS: VCSType? = nil,
        knownContext: RepoContext? = nil,
        targetSummary: String? = nil
    ) {
        fadeToBlankTask?.cancel()
        isTransitioningToBlank = false
        let stdURL = url.standardizedFileURL

        // Deduce context if knownContext not passed or not matching stdURL, using current activeViewModel repoContext if file is in repo
        // and preferredVCS is not requesting a different VCS type
        var effectiveContext: RepoContext?
        if let known = knownContext, known.fullURL.standardizedFileURL.path == stdURL.path {
            effectiveContext = known
        } else if let activeCtx = activeViewModel?.repoContext {
            if preferredVCS == nil || preferredVCS == activeCtx.vcsType {
                let repoPath = activeCtx.repoRoot.standardizedFileURL.path
                let filePath = stdURL.path
                if filePath.hasPrefix(repoPath) {
                    let rel = String(filePath.dropFirst(repoPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    effectiveContext = RepoContext(vcsType: activeCtx.vcsType, repoRoot: activeCtx.repoRoot, relativePath: rel, fullURL: stdURL)
                }
            }
        }
        if effectiveContext == nil {
            effectiveContext = VCSManager.shared.detectContext(for: stdURL, preferredVCS: preferredVCS)
        }

        // Check if an existing tab already has this file and VCS type
        if let existing = tabs.first(where: { tab in
            guard !tab.isCommitPrompt && !tab.isCommitHistory else { return false }
            guard let tabURL = tab.viewModel.selectedFileURL?.standardizedFileURL else { return false }
            let sameFile = (tabURL.path == stdURL.path)
            if let expectedVCS = preferredVCS ?? effectiveContext?.vcsType {
                return sameFile && tab.viewModel.vcsType == expectedVCS
            }
            return sameFile
        }) {
            activeTabId = existing.id
            if let tabCtx = existing.viewModel.repoContext ?? effectiveContext {
                selectedRepoContext = tabCtx
            }
            checkActiveRepoChange()
            if let rev = initialRevision {
                existing.viewModel.goToCommit(byHash: rev, recordHistory: false)
            } else if let summary = targetSummary,
                      let idx = existing.viewModel.commits.firstIndex(where: { $0.summary == summary }) {
                existing.viewModel.goToCommit(at: idx, recordHistory: false)
            }
            return
        }

        // Reuse active tab if it has no file loaded yet
        let targetTab: TabItem
        if let current = activeTab, !current.isLoaded {
            targetTab = current
        } else {
            targetTab = createTab()
            tabs.append(targetTab)
        }

        activeTabId = targetTab.id
        if let ctx = effectiveContext {
            selectedRepoContext = ctx
        }
        targetTab.viewModel.openFile(
            url: url,
            initialRevision: initialRevision,
            preferredVCS: preferredVCS,
            knownContext: effectiveContext,
            targetSummary: targetSummary
        )
        if let tabCtx = targetTab.viewModel.repoContext {
            selectedRepoContext = tabCtx
        }
        checkActiveRepoChange()
    }

    // MARK: - Remotes Management
    public func loadRemotes() {
        guard let context = activeRepoContext else {
            self.remoteRepositories = []
            self.activePushRemotes.removeAll()
            self.activePullRemotes.removeAll()
            self.isPushingAllRemotes = false
            self.pushErrors.removeAll()
            self.pullErrors.removeAll()
            self.pushAllError = nil
            self.isLoadingRemotes = false
            return
        }

        remotesTask?.cancel()
        isLoadingRemotes = true
        let repoRoot = context.repoRoot
        let vcs = context.vcsType

        remotesTask = Task.detached(priority: .userInitiated) {
            let remotes = VCSManager.shared.fetchRemotes(context: context)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard self.activeRepoContext?.repoRoot.standardizedFileURL.path == repoRoot.standardizedFileURL.path,
                      self.activeRepoContext?.vcsType == vcs else { return }
                self.remoteRepositories = remotes
                self.isLoadingRemotes = false
            }
        }
    }

    public func push(to remote: RemoteRepository) {
        guard let context = activeRepoContext else { return }
        let remoteName = remote.name
        pushErrors.removeValue(forKey: remoteName)
        activePushRemotes.insert(remoteName)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try VCSManager.shared.push(context: context, remote: remoteName)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            self.activePushRemotes.remove(remoteName)
            switch result {
            case .success:
                self.pushErrors.removeValue(forKey: remoteName)
                self.refreshAfterRemoteOperation()
            case .failure(let error):
                self.pushErrors[remoteName] = error.localizedDescription
            }
        }
    }

    public func pull(from remote: RemoteRepository) {
        guard let context = activeRepoContext else { return }
        let remoteName = remote.name
        pullErrors.removeValue(forKey: remoteName)
        activePullRemotes.insert(remoteName)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try VCSManager.shared.pull(context: context, remote: remoteName)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            self.activePullRemotes.remove(remoteName)
            switch result {
            case .success:
                self.pullErrors.removeValue(forKey: remoteName)
                self.refreshAfterRemoteOperation()
            case .failure(let error):
                self.pullErrors[remoteName] = error.localizedDescription
            }
        }
    }

    public func pushAllRemotes() {
        guard let context = activeRepoContext else { return }
        let remotes = self.remoteRepositories
        guard !remotes.isEmpty else { return }

        isPushingAllRemotes = true
        pushAllError = nil

        for remote in remotes {
            pushErrors.removeValue(forKey: remote.name)
            activePushRemotes.insert(remote.name)
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            var encounteredErrors: [String] = []

            for remote in remotes {
                let remoteName = remote.name
                let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        try VCSManager.shared.push(context: context, remote: remoteName)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }.value

                self.activePushRemotes.remove(remoteName)
                switch result {
                case .success:
                    self.pushErrors.removeValue(forKey: remoteName)
                case .failure(let error):
                    let desc = error.localizedDescription
                    self.pushErrors[remoteName] = desc
                    encounteredErrors.append("\(remoteName): \(desc)")
                }
            }

            self.isPushingAllRemotes = false
            if !encounteredErrors.isEmpty {
                self.pushAllError = encounteredErrors.joined(separator: "\n")
            } else {
                self.pushAllError = nil
                self.refreshAfterRemoteOperation()
            }
        }
    }

    public func refreshAfterRemoteOperation() {
        self.refreshRepositoryFiles()
        self.loadRemotes()
        for tab in self.tabs {
            if let rel = tab.viewModel.selectedFileURL?.relativePath {
                tab.viewModel.checkWorkingDirectoryChanges([rel])
            }
            if tab.commitHistoryViewModel?.hasLoaded == true {
                tab.commitHistoryViewModel?.refreshInBackground()
            }
            if let rel = tab.commitViewModel?.previewViewModel.selectedFileURL?.relativePath {
                tab.commitViewModel?.checkWorkingDirectoryChanges([rel])
            }
        }
    }
}
