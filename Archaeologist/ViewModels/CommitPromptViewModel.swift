import Foundation
import SwiftUI
import Combine

public struct WorkingFileChange: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let fullURL: URL
    public let status: FileWorkingStatus

    public init(relativePath: String, fullURL: URL, status: FileWorkingStatus) {
        self.relativePath = relativePath
        self.fullURL = fullURL
        self.status = status
    }
}

@MainActor
public class CommitPromptViewModel: ObservableObject, Identifiable {
    public let id: UUID
    public let repoContext: RepoContext
    public weak var tabManager: TabManager?

    @Published public var commitMessage: String = ""
    @Published public var changedFiles: [WorkingFileChange] = []
    @Published public var checkedFilePaths: Set<String> = []
    @Published public var selectedFilePath: String? = nil
    @Published public var fileViewMode: CommitFileViewMode = .tree
    @Published public var showUntracked: Bool = true {
        didSet {
            onShowUntrackedChanged()
        }
    }
    @Published public var isCommitting: Bool = false
    @Published public var errorMessage: String? = nil

    public let previewViewModel: HistoryViewModel
    public let diffViewModel: DiffViewModel

    private var directoryWatcher: DirectoryWatcher?
    private var debouncedRefreshTask: Task<Void, Never>?
    private var refreshTaskId: UUID?
    private var hasInitialInMemoryData: Bool = false

    public init(
        repoContext: RepoContext,
        tabManager: TabManager? = nil,
        initialChanges: [WorkingFileChange]? = nil,
        initialSelectedFilePath: String? = nil,
        existingDiffViewModel: DiffViewModel? = nil
    ) {
        self.id = UUID()
        self.repoContext = repoContext
        self.tabManager = tabManager
        let pvm = HistoryViewModel()
        pvm.tabManager = tabManager
        self.previewViewModel = pvm
        self.diffViewModel = DiffViewModel(repoContext: repoContext)

        if let initialChanges = initialChanges {
            initializeWithInMemoryChanges(
                changes: initialChanges,
                selectedFilePath: initialSelectedFilePath,
                existingDiffViewModel: existingDiffViewModel
            )
        } else {
            loadChangedFiles()
        }
    }

    public func initializeWithInMemoryChanges(
        changes: [WorkingFileChange],
        selectedFilePath: String? = nil,
        existingDiffViewModel: DiffViewModel? = nil
    ) {
        self.hasInitialInMemoryData = true
        self.changedFiles = changes
        self.checkedFilePaths = Set(changes.filter { $0.status != .unknown }.map { $0.relativePath })

        let initialVisible = showUntracked ? changes : changes.filter { $0.status != .unknown }
        let targetPath: String?
        if let sel = selectedFilePath, initialVisible.contains(where: { $0.relativePath == sel }) {
            targetPath = sel
        } else {
            targetPath = initialVisible.first?.relativePath
        }

        if let path = targetPath, let change = changedFiles.first(where: { $0.relativePath == path }) {
            self.selectedFilePath = path
            if let existingDiffVM = existingDiffViewModel,
               existingDiffVM.fileChange?.relativePath == path,
               !existingDiffVM.isLoading {
                self.diffViewModel.copyState(from: existingDiffVM)
            } else {
                self.diffViewModel.loadFile(context: self.repoContext, change: change)
            }
            previewViewModel.openFile(url: change.fullURL, initialRevision: CommitInfo.uncommittedHash, preferredVCS: repoContext.vcsType)
        } else {
            self.selectedFilePath = nil
            self.diffViewModel.clear()
        }
    }

    deinit {
        directoryWatcher?.stop()
        debouncedRefreshTask?.cancel()
    }

    public func startWatching() {
        guard directoryWatcher == nil else { return }
        if !hasInitialInMemoryData {
            refreshWorkingDirectoryChanges()
        } else {
            hasInitialInMemoryData = false
        }
        directoryWatcher = DirectoryWatcher(url: repoContext.repoRoot) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedRefresh()
            }
        }
    }

    public func stopWatching() {
        directoryWatcher?.stop()
        directoryWatcher = nil
        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = nil
    }

    public func scheduleDebouncedRefresh(delayNanoseconds: UInt64 = 100_000_000) {
        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self = self else { return }
            self.refreshWorkingDirectoryChanges()
        }
    }

    public func checkWorkingDirectoryChanges(_ paths: Set<String> = []) {
        refreshWorkingDirectoryChanges()
    }

    @discardableResult
    public func refreshWorkingDirectoryChanges() -> Task<Void, Never> {
        guard !isCommitting else {
            return Task { @MainActor in }
        }

        let taskId = UUID()
        self.refreshTaskId = taskId
        let context = repoContext
        let currentSelected = selectedFilePath
        let prevChecked = checkedFilePaths
        let prevFiles = changedFiles

        return Task.detached(priority: .userInitiated) {
            let statusMap = VCSManager.shared.fetchRepositoryFileStatuses(context: context)
            guard !Task.isCancelled else { return }

            var changes: [WorkingFileChange] = []
            for (relPath, status) in statusMap where status != .clean {
                let fullURL = context.repoRoot.appendingPathComponent(relPath)
                changes.append(WorkingFileChange(relativePath: relPath, fullURL: fullURL, status: status))
            }

            let sortedChanges = changes.sorted { a, b in
                if a.status.commitSortPriority != b.status.commitSortPriority {
                    return a.status.commitSortPriority < b.status.commitSortPriority
                }
                return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
            }

            await MainActor.run { [weak self] in
                guard let self = self, self.refreshTaskId == taskId, !self.isCommitting else { return }
                self.applyRefreshedChanges(
                    changes: sortedChanges,
                    currentSelected: currentSelected,
                    prevChecked: prevChecked,
                    prevFiles: prevFiles
                )
            }
        }
    }

    private func applyRefreshedChanges(
        changes: [WorkingFileChange],
        currentSelected: String?,
        prevChecked: Set<String>,
        prevFiles: [WorkingFileChange]
    ) {
        self.changedFiles = changes

        let newFilePaths = Set(changes.map { $0.relativePath })
        // Requirement: Carry over file selection to new data set.
        // Any files that exist in the new set but not the old are unselected;
        // all other files retain their previous selection state.
        self.checkedFilePaths = prevChecked.intersection(newFilePaths)

        let visible = self.visibleChangedFiles

        // Requirement 2: If the selected file exists after the update, it should maintain it's display & scroll position
        if let sel = currentSelected, let change = visible.first(where: { $0.relativePath == sel }) {
            self.selectedFilePath = sel
            self.diffViewModel.loadFile(context: self.repoContext, change: change, quiet: true)
        } else if let first = visible.first {
            self.selectFile(first.relativePath)
        } else {
            self.selectedFilePath = nil
            self.diffViewModel.clear()
        }
    }

    public var visibleChangedFiles: [WorkingFileChange] {
        if showUntracked {
            return changedFiles
        } else {
            return changedFiles.filter { $0.status != .unknown }
        }
    }

    public var activeCheckedFilePaths: Set<String> {
        let visiblePaths = Set(visibleChangedFiles.map { $0.relativePath })
        return checkedFilePaths.intersection(visiblePaths)
    }

    public var visibleCheckedCount: Int {
        activeCheckedFilePaths.count
    }

    public var isAllVisibleChecked: Bool {
        !visibleChangedFiles.isEmpty && visibleCheckedCount == visibleChangedFiles.count
    }

    public func toggleAllOrNone() {
        let visiblePaths = visibleChangedFiles.map { $0.relativePath }
        if isAllVisibleChecked {
            checkedFilePaths.subtract(visiblePaths)
        } else {
            checkedFilePaths.formUnion(visiblePaths)
        }
    }

    public func loadChangedFiles() {
        let statusMap = VCSManager.shared.fetchRepositoryFileStatuses(context: repoContext)
        var changes: [WorkingFileChange] = []
        for (relPath, status) in statusMap where status != .clean {
            let fullURL = repoContext.repoRoot.appendingPathComponent(relPath)
            changes.append(WorkingFileChange(relativePath: relPath, fullURL: fullURL, status: status))
        }

        // Sort Added first, then Modified, Removed, Untracked, secondary by relativePath
        changes.sort { a, b in
            if a.status.commitSortPriority != b.status.commitSortPriority {
                return a.status.commitSortPriority < b.status.commitSortPriority
            }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }

        self.changedFiles = changes
        // Added, modified and removed files should be checked by default. Untracked should not be.
        self.checkedFilePaths = Set(changes.filter { $0.status != .unknown }.map { $0.relativePath })

        let initialVisible = showUntracked ? changes : changes.filter { $0.status != .unknown }
        if let sel = selectedFilePath, initialVisible.contains(where: { $0.relativePath == sel }) {
            selectFile(sel)
        } else if let first = initialVisible.first {
            selectFile(first.relativePath)
        } else {
            selectedFilePath = nil
        }
    }

    public func onShowUntrackedChanged() {
        if !showUntracked, let sel = selectedFilePath, let cur = changedFiles.first(where: { $0.relativePath == sel }), cur.status == .unknown {
            if let first = visibleChangedFiles.first {
                selectFile(first.relativePath)
            } else {
                selectedFilePath = nil
            }
        }
    }

    public func selectFile(_ path: String) {
        if selectedFilePath == path && diffViewModel.fileChange != nil {
            return
        }
        selectedFilePath = path
        guard let change = changedFiles.first(where: { $0.relativePath == path }) else { return }
        diffViewModel.loadFile(context: repoContext, change: change)
        previewViewModel.openFile(url: change.fullURL, initialRevision: CommitInfo.uncommittedHash, preferredVCS: repoContext.vcsType)
    }

    public func toggleCheck(_ path: String) {
        if checkedFilePaths.contains(path) {
            checkedFilePaths.remove(path)
        } else {
            checkedFilePaths.insert(path)
        }
    }

    public var canCommit: Bool {
        !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !activeCheckedFilePaths.isEmpty &&
        !isCommitting
    }

    public func performCommit() {
        guard canCommit else { return }
        isCommitting = true
        errorMessage = nil

        let committedChanges = visibleChangedFiles.filter { activeCheckedFilePaths.contains($0.relativePath) }
        let filesToCommit = committedChanges.map { $0.relativePath }
        let committedPathSet = Set(filesToCommit)
        let remainingWorkingChanges = changedFiles.filter { !committedPathSet.contains($0.relativePath) }
        let msg = commitMessage
        let context = repoContext

        // Optimistically update repository files tree immediately
        tabManager?.optimisticCommit(files: filesToCommit)

        Task.detached(priority: .userInitiated) {
            do {
                let committedCommit = try VCSManager.shared.commit(context: context, files: filesToCommit, message: msg)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isCommitting = false
                    self.tabManager?.refreshRepositoryFiles()
                    self.tabManager?.updateWorkingCopyChangesStatus()

                    let existingHistoryVM = self.tabManager?.tabs.first(where: {
                        $0.commitHistoryViewModel?.repoContext.repoRoot == context.repoRoot &&
                        $0.commitHistoryViewModel?.repoContext.vcsType == context.vcsType
                    })?.commitHistoryViewModel

                    if let historyVM = existingHistoryVM {
                        if historyVM.hasLoaded {
                            historyVM.optimisticInsertCommit(
                                message: msg,
                                changes: committedChanges,
                                remainingWorkingChanges: remainingWorkingChanges,
                                committedCommit: committedCommit
                            )
                        } else {
                            historyVM.loadBranchesAndHistory()
                        }
                    }

                    // Switch to CommitHistoryTabView
                    _ = self.tabManager?.openCommitHistoryTab(context: context, refreshIfExisting: false)

                    // Close the completed CommitPromptView tab
                    if let tab = self.tabManager?.tabs.first(where: { $0.commitViewModel?.id == self.id }) {
                        self.tabManager?.closeTab(id: tab.id)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isCommitting = false
                    self.errorMessage = error.localizedDescription
                    self.tabManager?.refreshRepositoryFiles()
                }
            }
        }
    }
}
