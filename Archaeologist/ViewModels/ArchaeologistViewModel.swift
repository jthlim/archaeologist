import Foundation
import SwiftUI
import AppKit
import Combine

public typealias HistoryViewModel = ArchaeologistViewModel

@MainActor
public class ArchaeologistViewModel: ObservableObject {
    @Published public var selectedFileURL: URL?
    @Published public var repoContext: RepoContext?
    @Published public var commits: [CommitInfo] = []
    public var shouldRecordHistory: Bool = true
    public weak var tabManager: TabManager?

    @Published public var selectedCommitIndex: Int = 0 {
        willSet {
            if newValue != selectedCommitIndex && shouldRecordHistory {
                willChangeCommit()
            }
        }
        didSet {
            if selectedCommitIndex != oldValue {
                loadContentForCurrentCommit()
            }
        }
    }

    public var currentNavigationState: NavigationState? {
        guard let url = selectedFileURL,
              let commit = selectedCommit,
              let vcs = vcsType else {
            return nil
        }
        return NavigationState(fileURL: url, revision: commit.id, vcsType: vcs)
    }

    public func willChangeCommit() {
        if let current = currentNavigationState {
            tabManager?.pushNavigationState(from: current)
        }
    }

    @Published public var currentContent: FileRevisionContent?
    @Published public var isLoading: Bool = false
    @Published public var isContentLoading: Bool = false
    @Published public var errorMessage: String?
    @Published public var revertStates: [String: BlockRevertState] = [:]
    @Published public var revertErrorMessage: String? = nil

    // Background preloading status
    @Published public var preloadedCount: Int = 0
    @Published public var isPreloading: Bool = false
    private var preloadTask: Task<Void, Never>?
    private var currentCommitTask: Task<Void, Never>?
    private var currentCommitFilesTask: Task<Void, Never>?

    // Display preferences
    @Published public var showBlame: Bool = true
    @Published public var wrapLines: Bool = false
    @Published public var showDeletedLines: Bool = true
    @Published public var searchQuery: String = ""
    @Published public var isBinary: Bool = false
    @Published public var hexBytesPerRow: Int = 16

    // Files in the current commit
    @Published public var filesInCurrentCommit: [String] = []
    @Published public var isLoadingFilesInCommit: Bool = false
    @Published public var canSwapVCS: Bool = false
    private var commitFilesCache: [String: [String]] = [:]

    // Cache of fetched content per commit ID
    private var contentCache: [String: FileRevisionContent] = [:]

    public init() {}

    public var selectedCommit: CommitInfo? {
        guard !commits.isEmpty, selectedCommitIndex >= 0, selectedCommitIndex < commits.count else {
            return nil
        }
        return commits[selectedCommitIndex]
    }

    public var vcsType: VCSType? {
        repoContext?.vcsType
    }

    public var fileName: String {
        if let commit = selectedCommit, let rel = commit.filePath, !rel.isEmpty {
            return URL(fileURLWithPath: rel).lastPathComponent
        }
        return repoContext?.filename ?? selectedFileURL?.lastPathComponent ?? "No file selected"
    }

    public var relativePath: String {
        if let commit = selectedCommit, let rel = commit.filePath, !rel.isEmpty {
            return rel
        }
        return repoContext?.relativePath ?? ""
    }

    public var renameInfo: (oldPath: String, newPath: String)? {
        guard let commit = selectedCommit else { return nil }
        let currentPath = commit.filePath ?? repoContext?.relativePath ?? ""
        guard !currentPath.isEmpty else { return nil }

        if let old = commit.renamedFromPath, !old.isEmpty, old != currentPath {
            return (oldPath: old, newPath: currentPath)
        }

        if selectedCommitIndex > 0 && selectedCommitIndex < commits.count {
            let prevCommit = commits[selectedCommitIndex - 1]
            if let prevPath = prevCommit.filePath, !prevPath.isEmpty, prevPath != currentPath {
                return (oldPath: prevPath, newPath: currentPath)
            }
        }

        return nil
    }

    public var displayedPath: String {
        if let rename = renameInfo {
            return "\(rename.oldPath) ➞ \(rename.newPath)"
        }
        return relativePath
    }

    public func deltaCounts(for commit: CommitInfo) -> (added: Int, removed: Int) {
        if let added = commit.addedCount, let removed = commit.removedCount {
            return (added, removed)
        }
        if let cached = contentCache[commit.id] {
            return (cached.addedLinesCount, cached.removedLinesCount)
        }
        return (commit.addedCount ?? 0, commit.removedCount ?? 0)
    }

    /// Calculate vertical delta line length based on a log2 scale:
    /// - 0 lines -> 0 pt (no line)
    /// - 1 line -> 1 pt
    /// - Up to 256 lines -> 8 pt (log2(256) = 8)
    /// - Capped at 20 pt
    public static func deltaLineLength(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        if count == 1 { return 1.0 }
        let val = log2(Double(count))
        return min(20.0, max(1.0, CGFloat(val)))
    }

    // MARK: - Open File
    public func openFile(
        url: URL,
        initialRevision: String? = nil,
        preferredVCS: VCSType? = nil,
        knownContext: RepoContext? = nil,
        targetSummary: String? = nil
    ) {
        let vcsToPrefer = preferredVCS ?? knownContext?.vcsType ?? self.repoContext?.vcsType
        preloadTask?.cancel()
        currentCommitTask?.cancel()
        shouldRecordHistory = false
        isLoading = true
        isPreloading = false
        preloadedCount = 0
        errorMessage = nil
        selectedFileURL = url
        // Check up to the first 4KB for a nul byte to tag as binary
        self.isBinary = VCSManager.isBinaryFile(at: url)
        contentCache.removeAll()
        commits = []
        selectedCommitIndex = 0
        currentContent = nil
        revertStates.removeAll()
        revertErrorMessage = nil

        let usableKnownContext: RepoContext?
        if let known = knownContext,
           (preferredVCS == nil || preferredVCS == known.vcsType),
           known.fullURL.standardizedFileURL.path == url.standardizedFileURL.path {
            usableKnownContext = known
        } else {
            usableKnownContext = nil
        }

        // Synchronously resolve context if known or detectable so that active tab & sidebar
        // can immediately reflect the repo context and file location without waiting for background commits.
        if let immediateContext = usableKnownContext ?? VCSManager.shared.detectContext(for: url, preferredVCS: vcsToPrefer) {
            self.repoContext = immediateContext
            if self.tabManager?.activeViewModel === self {
                self.tabManager?.selectedRepoContext = immediateContext
            }
            self.tabManager?.checkActiveRepoChange()
        }

        Task.detached(priority: .userInitiated) {
            let gitContext = VCSManager.shared.detectContext(for: url, preferredVCS: .git)
            let hgContext = VCSManager.shared.detectContext(for: url, preferredVCS: .hg)
            let hasBoth = (gitContext?.vcsType == .git && hgContext?.vcsType == .hg)

            guard let context = usableKnownContext ?? VCSManager.shared.detectContext(for: url, preferredVCS: vcsToPrefer) else {
                await MainActor.run {
                    self.shouldRecordHistory = true
                    self.isLoading = false
                    self.canSwapVCS = false
                    self.errorMessage = "The file '\(url.lastPathComponent)' is not in a Git or Mercurial repository."
                }
                return
            }

            do {
                let commits = try VCSManager.shared.fetchCommits(for: context)
                await MainActor.run {
                    if self.repoContext?.repoRoot != context.repoRoot || self.repoContext?.vcsType != context.vcsType {
                        self.commitFilesCache.removeAll()
                    }
                    self.repoContext = context
                    if self.tabManager?.activeViewModel === self {
                        self.tabManager?.selectedRepoContext = context
                    }
                    self.tabManager?.checkActiveRepoChange()
                    self.commits = commits
                    self.isLoading = false
                    self.canSwapVCS = hasBoth
                    if commits.isEmpty {
                        self.errorMessage = "No commit history found for '\(context.relativePath)'."
                    } else {
                        // If initialRevision is given, find that commit
                        let targetIndex: Int
                        if let initialRevision = initialRevision,
                           let foundIndex = commits.firstIndex(where: { $0.matches(revision: initialRevision) }) {
                            targetIndex = foundIndex
                        } else if let targetSummary = targetSummary,
                                  let foundIndex = commits.firstIndex(where: { $0.summary == targetSummary }) {
                            targetIndex = foundIndex
                        } else {
                            targetIndex = commits.count - 1
                        }

                        if self.selectedCommitIndex == targetIndex {
                            self.loadContentForCurrentCommit()
                        } else {
                            self.selectedCommitIndex = targetIndex
                        }
                        self.shouldRecordHistory = true

                        // Start background preloading all revisions
                        self.startBackgroundPreload(context: context, commits: commits)
                    }
                }
            } catch {
                await MainActor.run {
                    self.shouldRecordHistory = true
                    self.isLoading = false
                    self.canSwapVCS = hasBoth
                    self.repoContext = context
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Refresh
    public func refresh(keepRevision: Bool = true) {
        guard let url = selectedFileURL else { return }
        let currentRev = keepRevision ? selectedCommit?.id : nil
        openFile(url: url, initialRevision: currentRev, preferredVCS: vcsType)
    }

    // MARK: - Check Working Directory Changes Only
    public func checkWorkingDirectoryChanges(_ debouncePaths : Set<String>) {
        guard let relativePath = selectedFileURL?.relativePath else { return }
        guard let context = repoContext, !isLoading, !commits.isEmpty else { return }
        guard debouncePaths.contains(relativePath) else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let hasChanges = VCSManager.shared.hasWorkingCopyChanges(context: context)
            await MainActor.run {
                self.updateWorkingCopyStatus(hasChanges: hasChanges, context: context)
            }
        }
    }

    public func invalidateUncommittedCache() {
        let uncommittedId = commits.last?.id ?? CommitInfo.uncommittedHash
        contentCache.removeValue(forKey: uncommittedId)
        contentCache.removeValue(forKey: CommitInfo.uncommittedHash)
        commitFilesCache.removeValue(forKey: uncommittedId)
        commitFilesCache.removeValue(forKey: CommitInfo.uncommittedHash)
        if let idx = commits.indices.last, commits[idx].isUncommitted {
            commits[idx].addedCount = nil
            commits[idx].removedCount = nil
        }
    }

    private func updateWorkingCopyStatus(hasChanges: Bool, context: RepoContext) {
        let currentlyHasUncommitted = (commits.last?.isUncommitted == true)

        if hasChanges && !currentlyHasUncommitted {
            // Working directory now has changes: append uncommitted commit node
            invalidateUncommittedCache()
            let uncommitted = VCSManager.shared.createUncommittedCommit(context: context, index: commits.count)
            let wasAtLatest = (selectedCommitIndex == commits.count - 1)
            commits.append(uncommitted)
            reindexCommitsInPlace()
            if wasAtLatest {
                selectedCommitIndex = commits.count - 1
            }
        } else if !hasChanges && currentlyHasUncommitted {
            // Working directory changes were committed or reverted: remove uncommitted node
            let wasAtUncommitted = (selectedCommitIndex == commits.count - 1)
            invalidateUncommittedCache()
            commits.removeLast()
            reindexCommitsInPlace()
            if wasAtUncommitted {
                selectedCommitIndex = max(0, commits.count - 1)
            }
        } else if hasChanges && currentlyHasUncommitted {
            // Still has uncommitted changes: invalidate cached uncommitted content since file was saved/modified
            invalidateUncommittedCache()
            if let commit = selectedCommit, commit.isUncommitted {
                loadContentForCurrentCommit()
            }
        }
    }

    private func reindexCommitsInPlace() {
        for i in 0..<commits.count {
            commits[i].index = i
        }
    }

    // MARK: - Swap VCS
    public func swapVCS() {
        guard let url = selectedFileURL, let currentVCS = vcsType, canSwapVCS else { return }
        let targetVCS: VCSType = (currentVCS == .git) ? .hg : .git
        let currentSummary = selectedCommit?.summary

        if let tabManager = tabManager {
            tabManager.openInTab(
                url: url,
                preferredVCS: targetVCS,
                targetSummary: currentSummary
            )
        } else {
            openFile(url: url, preferredVCS: targetVCS, targetSummary: currentSummary)
        }
    }

    public var hasUncachedCommits: Bool {
        guard !commits.isEmpty else { return false }
        return commits.contains { contentCache[$0.id] == nil }
    }

    // MARK: - Load Content for Selected Commit
    public func loadContentForCurrentCommit() {
        loadFilesInCurrentCommit()
        revertStates.removeAll()
        revertErrorMessage = nil

        guard let context = repoContext, let commit = selectedCommit else {
            currentCommitTask?.cancel()
            currentContent = nil
            isContentLoading = false
            return
        }

        let commitId = commit.id

        if let cached = contentCache[commitId] {
            currentCommitTask?.cancel()
            currentContent = cached
            isBinary = cached.isBinary
            isContentLoading = false
            if let idx = commits.firstIndex(where: { $0.id == commitId }) {
                if commits[idx].addedCount == nil {
                    commits[idx].addedCount = cached.addedLinesCount
                }
                if commits[idx].removedCount == nil {
                    commits[idx].removedCount = cached.removedLinesCount
                }
            }
            // If background preloading is idle and there are uncached commits, ensure it runs
            if (!isPreloading || preloadTask == nil || preloadTask?.isCancelled == true) && hasUncachedCommits {
                startBackgroundPreload(context: context, commits: commits)
            }
            return
        }

        // Ensure background preloading is running in the background if there are uncached commits
        if (!isPreloading || preloadTask == nil || preloadTask?.isCancelled == true) && hasUncachedCommits {
            startBackgroundPreload(context: context, commits: commits)
        }

        // Cancel any pending fetch for a previously selected revision
        currentCommitTask?.cancel()

        isContentLoading = true

        currentCommitTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // Debounce slightly (50ms) so rapid slider scrubbing across uncached commits
            // does not spawn and kill dozens of subprocesses per second.
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }

            do {
                let content = try VCSManager.shared.fetchFileContent(context: context, commit: commit)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.contentCache[commitId] = content
                    self.preloadedCount = self.contentCache.count
                    if self.selectedCommit?.id == commitId {
                        self.currentContent = content
                        self.isBinary = content.isBinary
                        self.isContentLoading = false
                        if let idx = self.commits.firstIndex(where: { $0.id == commitId }) {
                            self.commits[idx].addedCount = content.addedLinesCount
                            self.commits[idx].removedCount = content.removedLinesCount
                        }
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    let errContent = FileRevisionContent(
                        isImage: false,
                        binaryData: nil,
                        textLines: [],
                        rawText: "",
                        errorMessage: error.localizedDescription
                    )
                    self.contentCache[commitId] = errContent
                    self.preloadedCount = self.contentCache.count
                    if self.selectedCommit?.id == commitId {
                        self.currentContent = errContent
                        self.isContentLoading = false
                    }
                }
            }
        }
    }

    // MARK: - Load Files in Selected Commit
    public func loadFilesInCurrentCommit() {
        guard let context = repoContext, let commit = selectedCommit else {
            currentCommitFilesTask?.cancel()
            filesInCurrentCommit = []
            isLoadingFilesInCommit = false
            return
        }

        let commitId = commit.id
        if let cached = commitFilesCache[commitId] {
            currentCommitFilesTask?.cancel()
            filesInCurrentCommit = cached
            isLoadingFilesInCommit = false
            return
        }

        currentCommitFilesTask?.cancel()
        isLoadingFilesInCommit = true
        currentCommitFilesTask = Task.detached(priority: .utility) { [weak self] in
            // Debounce slightly (75ms) so rapid scrubber dragging doesn't flood subprocesses
            try? await Task.sleep(nanoseconds: 75_000_000)
            if Task.isCancelled { return }

            var files = VCSManager.shared.fetchFilesInCommit(context: context, commit: commit)
            if Task.isCancelled { return }
            if !files.contains(context.relativePath) && !context.relativePath.isEmpty {
                files.append(context.relativePath)
                files.sort()
            }
            let finalFiles = files
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.commitFilesCache[commitId] = finalFiles
                if self.selectedCommit?.id == commitId {
                    self.filesInCurrentCommit = finalFiles
                    self.isLoadingFilesInCommit = false
                }
            }
        }
    }

    public func selectFileInCurrentCommit(relativePath: String) {
        guard let context = repoContext, let commit = selectedCommit else { return }
        guard relativePath != context.relativePath else { return }

        let targetURL = context.repoRoot.appendingPathComponent(relativePath)
        let exactContext = RepoContext(
            vcsType: context.vcsType,
            repoRoot: context.repoRoot,
            relativePath: relativePath,
            fullURL: targetURL
        )

        if let tabManager = tabManager {
            tabManager.openInTab(
                url: targetURL,
                initialRevision: commit.id,
                preferredVCS: context.vcsType,
                knownContext: exactContext
            )
        } else {
            openFile(
                url: targetURL,
                initialRevision: commit.id,
                preferredVCS: context.vcsType,
                knownContext: exactContext
            )
        }
    }

    // MARK: - Background Preloading (Hybrid Caching)
    public func startBackgroundPreload(context: RepoContext, commits: [CommitInfo]) {
        guard commits.count > 1 else {
            preloadedCount = commits.count
            isPreloading = false
            return
        }

        guard hasUncachedCommits else {
            preloadedCount = commits.count
            isPreloading = false
            return
        }

        // If a preload task is already actively running, let it continue uninterrupted!
        if isPreloading, let task = preloadTask, !task.isCancelled {
            return
        }

        preloadTask?.cancel()
        isPreloading = true
        preloadedCount = contentCache.count

        // If it's an image or binary file, use standard individual preloading
        if VCSManager.shared.isImageFile(filename: context.filename) || self.isBinary {
            preloadTask = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.fallbackBackgroundPreload(context: context, commits: commits)
            }
            return
        }

        // Fast streaming diff / local delta reconstructor
        preloadTask = Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.hasUncachedCommits {
                        self.finishPreload()
                    } else if Task.isCancelled {
                        self.isPreloading = false
                    }
                }
            }

            do {
                _ = try await DeltaReconstructor.fetchAllRevisionsStreaming(
                    context: context,
                    commits: commits
                ) { [weak self] commitId, content in
                    guard let self else { return }
                    await MainActor.run {
                        self.applyPreloaded(content: content, for: commitId)
                    }
                }

                let uncached = await MainActor.run { [weak self] in
                    self?.hasUncachedCommits ?? false
                }
                if uncached {
                    // If any commits were skipped or missed, finish them via fallback
                    guard let self else { return }
                    await self.fallbackBackgroundPreload(context: context, commits: commits)
                } else {
                    await MainActor.run { [weak self] in
                        self?.finishPreload()
                    }
                }
            } catch {
                if Task.isCancelled { return }
                // If streaming reconstructor fails, fallback to radiating individual fetch
                guard let self else { return }
                await self.fallbackBackgroundPreload(context: context, commits: commits)
            }
        }
    }

    private nonisolated func fallbackBackgroundPreload(context: RepoContext, commits: [CommitInfo]) async {
        defer {
            Task { @MainActor [weak self] in
                self?.finishPreload()
            }
        }

        let commitCount = commits.count
        let initialSelected = await MainActor.run { self.selectedCommitIndex }

        let orderedIndices = (0..<commitCount)
            .filter { $0 != initialSelected }
            .sorted { abs($0 - initialSelected) < abs($1 - initialSelected) }

        for idx in orderedIndices {
            if Task.isCancelled { break }
            let commit = commits[idx]

            let alreadyCached = await self.isCommitCached(id: commit.id)
            if alreadyCached { continue }

            do {
                let content = try VCSManager.shared.fetchFileContent(context: context, commit: commit)
                if Task.isCancelled { break }
                await self.applyPreloaded(content: content, for: commit.id)
            } catch {
                // Cache an error placeholder so we don't repeatedly retry failing commits
                let errContent = FileRevisionContent(
                    isImage: false,
                    binaryData: nil,
                    textLines: [],
                    rawText: "",
                    errorMessage: error.localizedDescription
                )
                await self.applyPreloaded(content: errContent, for: commit.id)
            }
        }

        await self.finishPreload()
    }

    public func isCommitCached(id: String) -> Bool {
        contentCache[id] != nil
    }

    private func applyPreloaded(content: FileRevisionContent, for commitId: String) {
        if contentCache[commitId] == nil {
            contentCache[commitId] = content
        }
        if let idx = commits.firstIndex(where: { $0.id == commitId }) {
            commits[idx].addedCount = content.addedLinesCount
            commits[idx].removedCount = content.removedLinesCount
        }
        preloadedCount = contentCache.count
        if selectedCommit?.id == commitId {
            currentContent = content
            isContentLoading = false
        }
    }

    private func finishPreload() {
        isPreloading = false
        preloadedCount = contentCache.count
    }

    // MARK: - Navigation
    public func goToCommit(at index: Int, recordHistory: Bool = true) {
        guard !commits.isEmpty else { return }
        let clamped = max(0, min(commits.count - 1, index))
        let prevRecord = shouldRecordHistory
        shouldRecordHistory = recordHistory
        selectedCommitIndex = clamped
        shouldRecordHistory = prevRecord
    }

    public func goToCommit(byHash hash: String, recordHistory: Bool = true) {
        if let idx = commits.firstIndex(where: { $0.matches(revision: hash) }) {
            goToCommit(at: idx, recordHistory: recordHistory)
        }
    }

    public func nextCommit() {
        guard !commits.isEmpty else { return }
        if selectedCommitIndex < commits.count - 1 {
            selectedCommitIndex += 1
        }
    }

    public func previousCommit() {
        guard !commits.isEmpty else { return }
        if selectedCommitIndex > 0 {
            selectedCommitIndex -= 1
        }
    }

    public func firstCommit() {
        guard !commits.isEmpty else { return }
        selectedCommitIndex = 0
    }

    public func lastCommit() {
        guard !commits.isEmpty else { return }
        selectedCommitIndex = commits.count - 1
    }

    // MARK: - Open File or Repository Dialog
    public func showOpenFileDialog() {
        if let tabManager = tabManager {
            tabManager.showOpenFileDialog()
        } else {
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
    }

    public func openItem(at url: URL) {
        if let tabManager = tabManager {
            tabManager.openItem(at: url)
        } else {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.standardizedFileURL.path, isDirectory: &isDir)
            if exists && isDir.boolValue {
                openRepository(at: url)
            } else {
                openFile(url: url)
            }
        }
    }

    @discardableResult
    public func openRepository(at url: URL, preferredVCS: VCSType? = nil) -> Bool {
        guard let context = VCSManager.shared.detectContext(for: url, preferredVCS: preferredVCS) else {
            self.errorMessage = "The selected folder is not a Git or Mercurial repository."
            return false
        }
        self.repoContext = context
        return true
    }

    // MARK: - Revert Block
    public func revertBlock(targetIndex: Int) {
        guard let content = currentContent, let context = repoContext else { return }
        let lines = content.textLines
        let range = BlameLine.calculateBlockRange(lines: lines, targetIndex: targetIndex, vcsType: vcsType)
        guard !range.isEmpty else { return }

        let blockLines = Array(lines[range])

        func clean(_ str: String) -> String {
            str.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        }

        var contextBefore: [String] = []
        var i = range.lowerBound - 1
        while i >= 0 && contextBefore.count < 3 {
            if lines[i].changeType == .unchanged {
                contextBefore.insert(clean(lines[i].content), at: 0)
            }
            i -= 1
        }

        var contextAfter: [String] = []
        var j = range.upperBound
        while j < lines.count && contextAfter.count < 3 {
            if lines[j].changeType == .unchanged {
                contextAfter.append(clean(lines[j].content))
            }
            j += 1
        }

        let fileURL = context.fullURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let errorMsg = RevertError.fileNotFound(context.relativePath).localizedDescription
            self.revertErrorMessage = errorMsg
            for line in blockLines {
                self.revertStates[line.id] = .error(message: errorMsg)
            }
            return
        }

        guard let rawData = try? Data(contentsOf: fileURL) else {
            let errorMsg = RevertError.unreadableFile.localizedDescription
            self.revertErrorMessage = errorMsg
            for line in blockLines {
                self.revertStates[line.id] = .error(message: errorMsg)
            }
            return
        }

        let workingText = String(data: rawData, encoding: .utf8)
            ?? String(data: rawData, encoding: .ascii)
            ?? String(decoding: rawData, as: UTF8.self)

        let result = BlameLine.applyRevert(
            workingContent: workingText,
            blockLines: blockLines,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )

        switch result {
        case .success(let updatedContent):
            do {
                try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
                self.revertErrorMessage = nil
                for line in blockLines {
                    self.revertStates[line.id] = .success
                }
                self.invalidateUncommittedCache()
            } catch {
                let errorMsg = RevertError.writeFailed(error.localizedDescription).localizedDescription
                self.revertErrorMessage = errorMsg
                for line in blockLines {
                    self.revertStates[line.id] = .error(message: errorMsg)
                }
            }
        case .failure(let error):
            let errorMsg = error.localizedDescription
            self.revertErrorMessage = errorMsg
            for line in blockLines {
                self.revertStates[line.id] = .error(message: errorMsg)
            }
        }
    }

    // MARK: - Copy Commit Hash
    public func copyCommitHash() {
        guard let commit = selectedCommit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.fullRevision, forType: .string)
    }

    public func cancelPreload() {
        preloadTask?.cancel()
        currentCommitTask?.cancel()
    }

    deinit {
        preloadTask?.cancel()
        currentCommitTask?.cancel()
    }
}
