import Foundation
import SwiftUI
import Combine

public enum CommitFileViewMode: String, CaseIterable, Equatable, Sendable {
    case list
    case tree
}

public struct GraphLaneSegment: Equatable, Hashable {
    public let fromLane: Int
    public let toLane: Int
    public let colorIndex: Int

    public init(fromLane: Int, toLane: Int, colorIndex: Int) {
        self.fromLane = fromLane
        self.toLane = toLane
        self.colorIndex = colorIndex
    }
}

public struct CommitGraphRow: Identifiable, Equatable {
    public var id: String { commit.id }
    public let commit: CommitInfo
    public let parentIds: [String]
    public let nodeLane: Int
    public let nodeColorIndex: Int
    public let incomingSegments: [GraphLaneSegment]
    public let outgoingSegments: [GraphLaneSegment]
    public let maxActiveLane: Int

    private let customBranches: [String]?
    private let customTags: [String]?

    public var branches: [String] {
        customBranches ?? commit.branches
    }

    public var tags: [String] {
        customTags ?? commit.tags
    }

    public init(
        commit: CommitInfo,
        parentIds: [String],
        nodeLane: Int,
        nodeColorIndex: Int,
        incomingSegments: [GraphLaneSegment],
        outgoingSegments: [GraphLaneSegment],
        maxActiveLane: Int,
        branches: [String]? = nil,
        tags: [String]? = nil
    ) {
        self.commit = commit
        self.parentIds = parentIds
        self.nodeLane = nodeLane
        self.nodeColorIndex = nodeColorIndex
        self.incomingSegments = incomingSegments
        self.outgoingSegments = outgoingSegments
        self.maxActiveLane = maxActiveLane
        self.customBranches = branches
        self.customTags = tags
    }
}

public enum CommitGraphBuilder {
    private struct LaneState {
        var targetCommitId: String
        var colorIndex: Int
    }

    public static func buildRows(
        from entries: [(commit: CommitInfo, parentIds: [String])]
    ) -> (rows: [CommitGraphRow], maxLanes: Int) {
        guard !entries.isEmpty else { return ([], 1) }

        var indexByCommitId: [String: Int] = [:]
        indexByCommitId.reserveCapacity(entries.count)
        for (idx, entry) in entries.enumerated() {
            indexByCommitId[entry.commit.id] = idx
        }

        var lanes: [LaneState?] = []
        var nextColorIndex: Int = 0
        var rows: [CommitGraphRow] = []
        rows.reserveCapacity(entries.count)
        var globalMaxLane: Int = 0

        for (rowIndex, entry) in entries.enumerated() {
            let commit = entry.commit
            let commitId = commit.id

            // Only connect to parents that appear below this row in the displayed list
            let validParents = entry.parentIds.filter { parentId in
                if let pIdx = indexByCommitId[parentId] {
                    return pIdx > rowIndex
                }
                return false
            }

            // 1. Find existing lanes targeting this commit
            var matchingLanes: [Int] = []
            for (col, state) in lanes.enumerated() {
                if state?.targetCommitId == commitId {
                    matchingLanes.append(col)
                }
            }

            // 2. Determine nodeLane and nodeColorIndex
            let nodeLane: Int
            let nodeColorIndex: Int
            if let firstMatch = matchingLanes.first {
                nodeLane = firstMatch
                nodeColorIndex = lanes[firstMatch]!.colorIndex
            } else {
                let assignedColor = nextColorIndex
                nextColorIndex += 1
                if let freeIdx = lanes.firstIndex(where: { $0 == nil }) {
                    nodeLane = freeIdx
                } else {
                    nodeLane = lanes.count
                    lanes.append(nil)
                }
                nodeColorIndex = assignedColor
            }

            // 3. Build incoming segments (top half: y = 0 -> midY)
            var incomingSegments: [GraphLaneSegment] = []
            let matchingSet = Set(matchingLanes)
            for (col, stateOpt) in lanes.enumerated() {
                guard let state = stateOpt else { continue }
                if matchingSet.contains(col) {
                    incomingSegments.append(
                        GraphLaneSegment(fromLane: col, toLane: nodeLane, colorIndex: state.colorIndex)
                    )
                    lanes[col] = nil
                } else {
                    incomingSegments.append(
                        GraphLaneSegment(fromLane: col, toLane: col, colorIndex: state.colorIndex)
                    )
                }
            }

            // 4. Build outgoing segments (bottom half: y = midY -> rowHeight)
            var outgoingSegments: [GraphLaneSegment] = []

            // Existing pass-through lanes continue straight down
            for (col, stateOpt) in lanes.enumerated() {
                guard let state = stateOpt else { continue }
                outgoingSegments.append(
                    GraphLaneSegment(fromLane: col, toLane: col, colorIndex: state.colorIndex)
                )
            }

            // Connect commit node to its parents
            for (pIdx, parentId) in validParents.enumerated() {
                if pIdx == 0 {
                    // Primary parent continues in nodeLane with nodeColorIndex
                    lanes[nodeLane] = LaneState(targetCommitId: parentId, colorIndex: nodeColorIndex)
                    outgoingSegments.append(
                        GraphLaneSegment(fromLane: nodeLane, toLane: nodeLane, colorIndex: nodeColorIndex)
                    )
                } else {
                    // Merge parent: check if another lane is already targeting parentId
                    if let existingCol = lanes.firstIndex(where: { $0?.targetCommitId == parentId }),
                       let existingState = lanes[existingCol] {
                        outgoingSegments.append(
                            GraphLaneSegment(fromLane: nodeLane, toLane: existingCol, colorIndex: existingState.colorIndex)
                        )
                    } else {
                        let branchColor = nextColorIndex
                        nextColorIndex += 1
                        let newCol: Int
                        if let freeIdx = lanes.firstIndex(where: { $0 == nil }) {
                            newCol = freeIdx
                            lanes[freeIdx] = LaneState(targetCommitId: parentId, colorIndex: branchColor)
                        } else {
                            newCol = lanes.count
                            lanes.append(LaneState(targetCommitId: parentId, colorIndex: branchColor))
                        }
                        outgoingSegments.append(
                            GraphLaneSegment(fromLane: nodeLane, toLane: newCol, colorIndex: branchColor)
                        )
                    }
                }
            }

            // Trim trailing empty lanes
            while let last = lanes.last, last == nil {
                lanes.removeLast()
            }

            var rowMaxLane = nodeLane
            for seg in incomingSegments {
                rowMaxLane = max(rowMaxLane, seg.fromLane, seg.toLane)
            }
            for seg in outgoingSegments {
                rowMaxLane = max(rowMaxLane, seg.fromLane, seg.toLane)
            }
            globalMaxLane = max(globalMaxLane, rowMaxLane)

            rows.append(
                CommitGraphRow(
                    commit: commit,
                    parentIds: entry.parentIds,
                    nodeLane: nodeLane,
                    nodeColorIndex: nodeColorIndex,
                    incomingSegments: incomingSegments,
                    outgoingSegments: outgoingSegments,
                    maxActiveLane: rowMaxLane
                )
            )
        }

        return (rows: rows, maxLanes: max(1, globalMaxLane + 1))
    }
}

@MainActor
public class CommitHistoryViewModel: ObservableObject, Identifiable {
    public static let allBranchesOption = "All Branches"

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    public let id: UUID
    public let repoContext: RepoContext
    public weak var tabManager: TabManager?

    @Published public var branches: [String] = []
    @Published public var selectedBranch: String = CommitHistoryViewModel.allBranchesOption {
        didSet {
            if selectedBranch != oldValue {
                loadHistory()
            }
        }
    }

    @Published public var rows: [CommitGraphRow] = [] {
        didSet {
            var map: [String: Int] = [:]
            map.reserveCapacity(rows.count)
            for (idx, row) in rows.enumerated() {
                map[row.id] = idx
            }
            rowIndexById = map
        }
    }
    public internal(set) var allRows: [CommitGraphRow] = []
    @Published public var searchText: String = "" {
        didSet {
            if searchText != oldValue {
                applyFilter()
            }
        }
    }
    public var filterText: String {
        get { searchText }
        set { searchText = newValue }
    }
    private var rowIndexById: [String: Int] = [:]
    @Published public var maxGraphLanes: Int = 1
    @Published public var selectedCommitId: String? = nil
    @Published public var changedFiles: [WorkingFileChange] = []
    @Published public var selectedFilePath: String? = nil
    @Published public var fileViewMode: CommitFileViewMode = .tree

    @Published public var isLoading: Bool = false
    @Published public var isRefreshingInBackground: Bool = false
    @Published public var hasLoaded: Bool = false
    @Published public var isLoadingFiles: Bool = false
    @Published public var errorMessage: String? = nil

    // Draggable column widths for CommitHistoryListView
    @Published public var customGraphColumnWidth: CGFloat? = nil
    @Published public var authorColumnWidth: CGFloat = 140
    @Published public var dateColumnWidth: CGFloat = 140
    @Published public var revisionColumnWidth: CGFloat = 110

    @Published public var currentCheckedOutCommitId: String? = nil
    @Published public var checkoutErrorMessage: String? = nil
    public var onCheckoutError: ((String) -> Void)? = nil

    @Published public var comparisonCommitId: String? = nil
    @Published public var comparisonBaseCommit: CommitInfo? = nil
    @Published public var comparisonTargetCommit: CommitInfo? = nil

    public var isComparingCommits: Bool {
        comparisonCommitId != nil && comparisonBaseCommit != nil && comparisonTargetCommit != nil
    }

    public var isWorkingSetLoading: Bool {
        if !hasLoaded || isLoading { return true }
        if selectedCommitId == CommitInfo.uncommittedHash || selectedCommit?.isUncommitted == true {
            if isLoadingFiles || isRefreshingInBackground { return true }
            if commitFilesCache[CommitInfo.uncommittedHash] == nil { return true }
        }
        return false
    }

    public var isCommitButtonEnabled: Bool {
        !isWorkingSetLoading && selectedCommit?.isUncommitted == true && !isComparingCommits
    }

    public func rowIndex(for commitId: String) -> Int? {
        if let idx = rowIndexById[commitId], idx < rows.count, rows[idx].id == commitId {
            return idx
        }
        return rows.firstIndex(where: { $0.id == commitId })
    }

    public func isRowInComparisonRange(_ commitId: String) -> Bool {
        guard let selId = selectedCommitId,
              let compId = comparisonCommitId,
              let idx1 = rowIndex(for: selId),
              let idx2 = rowIndex(for: compId),
              let rowIdx = rowIndex(for: commitId) else {
            return false
        }
        let minIdx = min(idx1, idx2)
        let maxIdx = max(idx1, idx2)
        return rowIdx >= minIdx && rowIdx <= maxIdx
    }

    public let diffViewModel: DiffViewModel
    public let filteredFilePath: String?

    public var isFilteredPathADirectory: Bool {
        guard let path = filteredFilePath else { return false }
        var isDir: ObjCBool = false
        let fullPath = repoContext.repoRoot.appendingPathComponent(path).path
        return FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
    }

    private var rawEntries: [(commit: CommitInfo, parentIds: [String])] = []
    public internal(set) var commitFilesCache: [String: [WorkingFileChange]] = [:]
    private var cachedCurrentUser: (name: String, email: String)? = nil
    private var loadHistoryTaskId: UUID?
    private var loadFilesTaskId: UUID?
    private var directoryWatcher: DirectoryWatcher?
    private var debouncedRefreshTask: Task<Void, Never>?

    public init(repoContext: RepoContext, filePath: String? = nil, tabManager: TabManager? = nil) {
        self.id = UUID()
        self.repoContext = repoContext
        self.filteredFilePath = filePath
        self.tabManager = tabManager
        self.diffViewModel = DiffViewModel(repoContext: repoContext)

        loadBranchesAndHistory()
    }

    deinit {
        directoryWatcher?.stop()
        debouncedRefreshTask?.cancel()
    }

    public func startWatching() {
        guard directoryWatcher == nil else { return }
        refreshWorkingDirectoryChanges()
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

    public var effectiveGraphColumnWidth: CGFloat {
        if let custom = customGraphColumnWidth {
            return max(36, min(300, custom))
        }
        let calculated = CommitGraphCellView.leftPadding * 2 + CGFloat(max(0, maxGraphLanes - 1)) * CommitGraphCellView.laneSpacing
        return max(56, min(220, calculated))
    }

    public var selectedRow: CommitGraphRow? {
        guard let commitId = selectedCommitId else { return nil }
        if let idx = rowIndexById[commitId], idx < rows.count, rows[idx].id == commitId {
            return rows[idx]
        }
        return rows.first(where: { $0.id == commitId })
    }

    public var selectedCommit: CommitInfo? {
        selectedRow?.commit
    }

    public func commitMatchesFilter(_ commit: CommitInfo, query: String) -> Bool {
        commit.matchesFilter(query: query, vcsType: repoContext.vcsType)
    }

    public func applyFilter() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            rows = allRows
        } else {
            rows = allRows.filter { row in
                commitMatchesFilter(row.commit, query: searchText)
            }
        }
    }

    public func loadBranchesAndHistory() {
        let context = repoContext
        Task.detached(priority: .userInitiated) {
            let repoBranches = VCSManager.shared.fetchRepositoryBranches(context: context)
            let user = VCSManager.shared.fetchCurrentUser(context: context)
            let headHash = VCSManager.shared.fetchWorkingCopyParentHash(context: context)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.branches = repoBranches
                self.cachedCurrentUser = user
                self.currentCheckedOutCommitId = headHash
            }
        }
        loadHistory()
    }

    public func loadHistory() {
        isLoading = true
        errorMessage = nil
        let taskId = UUID()
        loadHistoryTaskId = taskId
        let context = repoContext
        let branchFilter = (selectedBranch == Self.allBranchesOption) ? nil : selectedBranch
        let fileFilter = filteredFilePath

        Task.detached(priority: .userInitiated) {
            do {
                let (entries, workingFiles, headHash) = try await VCSManager.shared.fetchRepositoryCommitHistoryAndWorkingChanges(
                    context: context,
                    branch: branchFilter,
                    filePath: fileFilter
                )
                let uncommittedCommit = entries.first(where: { $0.commit.isUncommitted })?.commit
                let built = CommitGraphBuilder.buildRows(from: entries)

                await MainActor.run { [weak self] in
                    guard let self = self, self.loadHistoryTaskId == taskId else { return }
                    if uncommittedCommit != nil {
                        self.commitFilesCache[CommitInfo.uncommittedHash] = workingFiles
                    } else {
                        self.commitFilesCache.removeValue(forKey: CommitInfo.uncommittedHash)
                    }
                    self.rawEntries = entries
                    self.allRows = built.rows
                    self.maxGraphLanes = built.maxLanes
                    self.applyFilter()
                    self.currentCheckedOutCommitId = headHash
                    self.hasLoaded = true
                    self.isLoading = false
                    self.isRefreshingInBackground = false

                    // If previously selected commit is no longer in rows, clear selection
                    if let currentId = self.selectedCommitId,
                       !built.rows.contains(where: { $0.id == currentId }) {
                        self.selectCommit(nil)
                    } else if self.selectedCommitId == CommitInfo.uncommittedHash,
                              let uncommittedCommit = uncommittedCommit {
                        self.applyRefreshedWorkingFiles(workingFiles, uncommittedCommit: uncommittedCommit)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self, self.loadHistoryTaskId == taskId else { return }
                    self.rawEntries = []
                    self.allRows = []
                    self.rows = []
                    self.maxGraphLanes = 1
                    self.hasLoaded = true
                    self.isLoading = false
                    self.isRefreshingInBackground = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Optimistically inserts a newly created commit at the top of the history list (if data has already loaded),
    /// updates working directory changes immediately, and triggers a background refresh at the same time.
    public func optimisticInsertCommit(
        message: String,
        changes: [WorkingFileChange],
        remainingWorkingChanges: [WorkingFileChange]? = nil,
        committedCommit: CommitInfo? = nil
    ) {
        guard hasLoaded else {
            loadBranchesAndHistory()
            return
        }

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = trimmedMessage.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmedMessage
        let now = Date()
        let authorName: String
        if let cachedName = cachedCurrentUser?.name, !cachedName.isEmpty {
            authorName = cachedName
        } else if let existingAuthor = rows.first?.commit.author, !existingAuthor.isEmpty {
            authorName = existingAuthor
        } else {
            authorName = "Author"
        }
        let authorEmail = cachedCurrentUser?.email ?? rows.first?.commit.authorEmail ?? ""

        var targetCommit: CommitInfo
        if let committed = committedCommit {
            targetCommit = committed
        } else {
            let optimisticId = "optimistic_\(UUID().uuidString)"
            targetCommit = CommitInfo(
                id: optimisticId,
                displayRevision: "Pending",
                fullRevision: optimisticId,
                author: authorName,
                authorEmail: authorEmail,
                date: now,
                dateFormatted: VCSManager.formatBlameDate(now),
                summary: summary.isEmpty ? "No commit message" : summary,
                fullMessage: trimmedMessage.isEmpty ? summary : trimmedMessage,
                index: 0
            )
        }
        let commitId = targetCommit.id

        let headEntry = rawEntries.first(where: { !$0.commit.isUncommitted })
        let parentIds: [String]
        if let currentHeadId = headEntry?.commit.id ?? rows.first(where: { !$0.commit.isUncommitted })?.commit.id {
            parentIds = [currentHeadId]
        } else {
            parentIds = []
        }

        // Determine which branches move to the new commit
        var targetBranches = targetCommit.branches
        if targetBranches.isEmpty, let headBranches = headEntry?.commit.branches, !headBranches.isEmpty {
            targetBranches = headBranches
            targetCommit.branches = targetBranches
        }

        // Update the display of the previous top commit so that branches moving to the new commit
        // are removed from the previous commit, preventing the branch tag from showing on two lines
        if !targetBranches.isEmpty,
           let headIndex = rawEntries.firstIndex(where: { !$0.commit.isUncommitted }) {
            var updatedHeadCommit = rawEntries[headIndex].commit
            let movingSet = Set(targetBranches)
            updatedHeadCommit.branches.removeAll(where: { movingSet.contains($0) })
            rawEntries[headIndex] = (commit: updatedHeadCommit, parentIds: rawEntries[headIndex].parentIds)
        }

        let existingUncommitted = rawEntries.first(where: { $0.commit.isUncommitted })?.commit
        rawEntries.removeAll(where: { $0.commit.isUncommitted })

        let hasRemainingWorkingChanges: Bool
        if let remaining = remainingWorkingChanges {
            hasRemainingWorkingChanges = !remaining.isEmpty
            if hasRemainingWorkingChanges {
                commitFilesCache[CommitInfo.uncommittedHash] = remaining
            } else {
                commitFilesCache.removeValue(forKey: CommitInfo.uncommittedHash)
            }
        } else {
            hasRemainingWorkingChanges = (tabManager?.hasWorkingCopyChanges == true)
            commitFilesCache.removeValue(forKey: CommitInfo.uncommittedHash)
        }

        rawEntries.insert((commit: targetCommit, parentIds: parentIds), at: 0)
        if hasRemainingWorkingChanges {
            let uncommittedCommit = existingUncommitted ?? CommitInfo(
                id: CommitInfo.uncommittedHash,
                displayRevision: CommitInfo.uncommittedRevision,
                fullRevision: "Working Directory",
                author: authorName,
                authorEmail: authorEmail,
                date: now,
                dateFormatted: VCSManager.formatBlameDate(now),
                summary: "Working Directory Changes",
                fullMessage: "Working Directory Changes",
                index: 0
            )
            rawEntries.insert((commit: uncommittedCommit, parentIds: [commitId]), at: 0)
        }

        let built = CommitGraphBuilder.buildRows(from: rawEntries)
        self.allRows = built.rows
        self.maxGraphLanes = built.maxLanes
        self.applyFilter()
        self.commitFilesCache[commitId] = changes

        // Immediately update the selected working directory changes pane if it was selected
        if self.selectedCommitId == CommitInfo.uncommittedHash {
            if hasRemainingWorkingChanges,
               let uncommittedRow = built.rows.first(where: { $0.id == CommitInfo.uncommittedHash }) {
                if let remaining = remainingWorkingChanges {
                    applyRefreshedWorkingFiles(remaining, uncommittedCommit: uncommittedRow.commit)
                }
            } else {
                selectCommit(nil)
            }
        }

        // If committedCommit was not passed, quickly resolve it in the background to replace "Pending"
        if committedCommit == nil {
            let context = self.repoContext
            Task.detached(priority: .userInitiated) { [weak self] in
                if let resolved = VCSManager.shared.fetchHeadCommit(context: context) {
                    await MainActor.run { [weak self] in
                        self?.updatePendingCommit(with: resolved)
                    }
                }
            }
        }

        refreshInBackground()
    }

    public func updatePendingCommit(with resolved: CommitInfo) {
        guard let pendingIndex = rawEntries.firstIndex(where: { $0.commit.id.hasPrefix("optimistic_") }) else {
            return
        }
        let oldId = rawEntries[pendingIndex].commit.id
        var updated = resolved
        if updated.branches.isEmpty {
            updated.branches = rawEntries[pendingIndex].commit.branches
        }

        let movingBranches = Set(updated.branches)
        if !movingBranches.isEmpty {
            for i in (pendingIndex + 1)..<rawEntries.count {
                if !rawEntries[i].commit.isUncommitted {
                    var prev = rawEntries[i].commit
                    prev.branches.removeAll(where: { movingBranches.contains($0) })
                    rawEntries[i] = (commit: prev, parentIds: rawEntries[i].parentIds)
                    break
                }
            }
        }

        rawEntries[pendingIndex] = (commit: updated, parentIds: rawEntries[pendingIndex].parentIds)
        if let cached = commitFilesCache.removeValue(forKey: oldId) {
            commitFilesCache[resolved.id] = cached
        }
        if selectedCommitId == oldId {
            selectedCommitId = resolved.id
        }

        let built = CommitGraphBuilder.buildRows(from: rawEntries)
        self.allRows = built.rows
        self.maxGraphLanes = built.maxLanes
        self.applyFilter()
    }

    @discardableResult
    public func refreshWorkingDirectoryChanges() -> Task<Void, Never> {
        commitFilesCache.removeValue(forKey: CommitInfo.uncommittedHash)
        return refreshInBackground()
    }

    private func applyRefreshedWorkingFiles(_ workingFiles: [WorkingFileChange], uncommittedCommit: CommitInfo) {
        self.changedFiles = workingFiles
        self.isLoadingFiles = false
        if let currentFile = self.selectedFilePath {
            if let updatedChange = workingFiles.first(where: { $0.relativePath == currentFile }) {
                self.diffViewModel.loadCommitFile(
                    context: self.repoContext,
                    commit: uncommittedCommit,
                    change: updatedChange,
                    quiet: true
                )
            } else {
                self.selectedFilePath = nil
                self.diffViewModel.clear()
            }
        }
    }

    @discardableResult
    public func refreshInBackground() -> Task<Void, Never> {
        isRefreshingInBackground = true
        let taskId = UUID()
        loadHistoryTaskId = taskId
        let context = repoContext
        let branchFilter = (selectedBranch == Self.allBranchesOption) ? nil : selectedBranch
        let fileFilter = filteredFilePath

        return Task.detached(priority: .userInitiated) {
            let repoBranches = VCSManager.shared.fetchRepositoryBranches(context: context)
            do {
                let (entries, workingFiles, headHash) = try await VCSManager.shared.fetchRepositoryCommitHistoryAndWorkingChanges(
                    context: context,
                    branch: branchFilter,
                    filePath: fileFilter
                )
                let uncommittedCommit = entries.first(where: { $0.commit.isUncommitted })?.commit
                let built = CommitGraphBuilder.buildRows(from: entries)

                await MainActor.run { [weak self] in
                    guard let self = self, self.loadHistoryTaskId == taskId else { return }
                    self.branches = repoBranches
                    if uncommittedCommit != nil {
                        self.commitFilesCache[CommitInfo.uncommittedHash] = workingFiles
                    } else {
                        self.commitFilesCache.removeValue(forKey: CommitInfo.uncommittedHash)
                    }
                    let wasOptimisticSelected = self.selectedCommitId?.hasPrefix("optimistic_") == true
                    self.rawEntries = entries
                    self.allRows = built.rows
                    self.maxGraphLanes = built.maxLanes
                    self.applyFilter()
                    self.currentCheckedOutCommitId = headHash
                    self.hasLoaded = true
                    self.isLoading = false
                    self.isRefreshingInBackground = false

                    if wasOptimisticSelected, let firstRealId = built.rows.first(where: { !$0.commit.isUncommitted })?.id {
                        self.selectCommit(firstRealId)
                    } else if let currentId = self.selectedCommitId,
                              !built.rows.contains(where: { $0.id == currentId }) {
                        self.selectCommit(nil)
                    } else if self.selectedCommitId == CommitInfo.uncommittedHash,
                              let uncommittedCommit = uncommittedCommit {
                        self.applyRefreshedWorkingFiles(workingFiles, uncommittedCommit: uncommittedCommit)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self, self.loadHistoryTaskId == taskId else { return }
                    self.isRefreshingInBackground = false
                }
            }
        }
    }

    public func selectCommit(_ commitId: String?) {
        comparisonCommitId = nil
        comparisonBaseCommit = nil
        comparisonTargetCommit = nil

        guard let commitId = commitId,
              let row = rows.first(where: { $0.id == commitId }) else {
            selectedCommitId = nil
            changedFiles = []
            selectedFilePath = nil
            isLoadingFiles = false
            diffViewModel.clear()
            return
        }

        selectedCommitId = commitId
        selectedFilePath = nil
        diffViewModel.clear()

        let commit = row.commit

        if let cached = commitFilesCache[commitId] {
            changedFiles = cached
            isLoadingFiles = false
            if let path = filteredFilePath {
                let prefix = path.hasSuffix("/") ? path : "\(path)/"
                if let match = cached.first(where: { $0.relativePath == path || $0.relativePath.hasPrefix(prefix) }) {
                    selectFile(match.relativePath)
                } else if let firstFile = cached.first {
                    selectFile(firstFile.relativePath)
                }
            } else if let firstFile = cached.first {
                selectFile(firstFile.relativePath)
            }
            return
        }

        changedFiles = []
        isLoadingFiles = true

        let taskId = UUID()
        loadFilesTaskId = taskId
        let context = repoContext

        Task.detached(priority: .userInitiated) {
            let files = VCSManager.shared.fetchChangedFilesInCommit(context: context, commit: commit)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.commitFilesCache[commitId] = files
                guard self.loadFilesTaskId == taskId, self.selectedCommitId == commitId else { return }
                self.changedFiles = files
                self.isLoadingFiles = false
                if let path = self.filteredFilePath {
                    let prefix = path.hasSuffix("/") ? path : "\(path)/"
                    if let match = files.first(where: { $0.relativePath == path || $0.relativePath.hasPrefix(prefix) }) {
                        self.selectFile(match.relativePath)
                    } else if let firstFile = files.first {
                        self.selectFile(firstFile.relativePath)
                    }
                } else if let firstFile = files.first {
                    self.selectFile(firstFile.relativePath)
                }
            }
        }
    }

    public var uncommittedWorkingChanges: [WorkingFileChange] {
        if !changedFiles.isEmpty && selectedCommit?.isUncommitted == true {
            return changedFiles
        }
        return commitFilesCache[CommitInfo.uncommittedHash] ?? changedFiles
    }

    public func openCommitPrompt() {
        if selectedCommit?.isUncommitted == true {
            tabManager?.openCommitTab(
                context: repoContext,
                initialChanges: uncommittedWorkingChanges,
                initialSelectedFilePath: selectedFilePath,
                existingDiffViewModel: diffViewModel
            )
        } else {
            tabManager?.openCommitTab(context: repoContext)
        }
    }

    public func selectFile(_ relativePath: String) {
        if selectedFilePath == relativePath && diffViewModel.fileChange != nil {
            return
        }
        guard let change = changedFiles.first(where: { $0.relativePath == relativePath }) else {
            return
        }
        selectedFilePath = relativePath

        if let base = comparisonBaseCommit, let target = comparisonTargetCommit {
            diffViewModel.loadComparisonFile(
                context: repoContext,
                baseCommit: base,
                targetCommit: target,
                change: change
            )
        } else if let commit = selectedCommit {
            diffViewModel.loadCommitFile(context: repoContext, commit: commit, change: change)
        }
    }

    // MARK: - Checkout Revision
    public func isCurrentlyCheckedOut(_ commit: CommitInfo) -> Bool {
        guard !commit.isUncommitted else { return false }
        guard let currentId = currentCheckedOutCommitId, !currentId.isEmpty else { return false }
        return commit.matches(revision: currentId)
    }

    public func canCheckoutRevision(_ commit: CommitInfo) -> Bool {
        !commit.isUncommitted && !isCurrentlyCheckedOut(commit)
    }

    public func checkoutRevision(_ commit: CommitInfo) {
        guard canCheckoutRevision(commit) else { return }
        let context = repoContext
        let targetRev = commit.id

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try VCSManager.shared.checkoutRevision(context: context, revision: targetRev)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.checkoutErrorMessage = nil
                    self.loadBranchesAndHistory()
                    self.tabManager?.refreshRepositoryFiles()
                    self.tabManager?.updateWorkingCopyChangesStatus()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.checkoutErrorMessage = message
                    if let onCheckoutError = self.onCheckoutError {
                        onCheckoutError(message)
                    } else {
                        self.showCheckoutAlert(message: message)
                    }
                }
            }
        }
    }

    private func showCheckoutAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Checkout Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Compare Range & Compare with Selected
    public func canCompareWithSelected(_ commit: CommitInfo) -> Bool {
        guard let selectedId = selectedCommitId else { return false }
        if !isComparingCommits {
            return selectedId != commit.id
        }
        guard let compId = comparisonCommitId,
              let idx1 = rowIndex(for: selectedId),
              let idx2 = rowIndex(for: compId),
              let targetIdx = rowIndex(for: commit.id) else {
            return false
        }
        let minIdx = min(idx1, idx2)
        let maxIdx = max(idx1, idx2)
        return targetIdx < minIdx || targetIdx > maxIdx
    }

    public func compareRange(earliest: CommitInfo, latest: CommitInfo) {
        guard earliest.id != latest.id else {
            selectCommit(earliest.id)
            return
        }

        comparisonCommitId = earliest.id
        selectedCommitId = latest.id
        comparisonBaseCommit = earliest
        comparisonTargetCommit = latest
        changedFiles = []
        selectedFilePath = nil
        diffViewModel.clear()
        isLoadingFiles = true

        let taskId = UUID()
        loadFilesTaskId = taskId
        let context = repoContext

        Task.detached(priority: .userInitiated) { [weak self] in
            let files = VCSManager.shared.fetchChangedFilesBetweenCommits(
                context: context,
                baseCommit: earliest,
                targetCommit: latest
            )
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard self.loadFilesTaskId == taskId,
                      self.comparisonCommitId == earliest.id,
                      self.selectedCommitId == latest.id else { return }
                self.changedFiles = files
                self.isLoadingFiles = false
                if let path = self.filteredFilePath {
                    let prefix = path.hasSuffix("/") ? path : "\(path)/"
                    if let match = files.first(where: { $0.relativePath == path || $0.relativePath.hasPrefix(prefix) }) {
                        self.selectFile(match.relativePath)
                    } else if let firstFile = files.first {
                        self.selectFile(firstFile.relativePath)
                    }
                } else if let firstFile = files.first {
                    self.selectFile(firstFile.relativePath)
                }
            }
        }
    }

    public func compareWithSelected(_ commit: CommitInfo) {
        guard canCompareWithSelected(commit) else { return }

        var selectedIndices = Set<Int>()
        if let selId = selectedCommitId, let selIdx = rowIndex(for: selId) {
            selectedIndices.insert(selIdx)
        }
        if let compId = comparisonCommitId, let compIdx = rowIndex(for: compId) {
            selectedIndices.insert(compIdx)
        }
        if isComparingCommits, let minIdx = selectedIndices.min(), let maxIdx = selectedIndices.max() {
            for i in minIdx...maxIdx {
                selectedIndices.insert(i)
            }
        }

        guard let targetIndex = rowIndex(for: commit.id) else { return }

        selectedIndices.insert(targetIndex)
        guard let minIdx = selectedIndices.min(), let maxIdx = selectedIndices.max() else { return }

        let latest = rows[minIdx].commit
        let earliest = rows[maxIdx].commit

        compareRange(earliest: earliest, latest: latest)
    }

    public func clearComparison() {
        comparisonCommitId = nil
        comparisonBaseCommit = nil
        comparisonTargetCommit = nil
        if let selected = selectedCommitId {
            selectCommit(selected)
        } else {
            changedFiles = []
            selectedFilePath = nil
            diffViewModel.clear()
        }
    }

    public func openFileInTab(_ relativePath: String) {
        guard let row = selectedRow else { return }
        let commit = row.commit
        let change = changedFiles.first(where: { $0.relativePath == relativePath })

        // Ensure single-click selection state is also updated
        if selectedFilePath != relativePath, change != nil {
            selectFile(relativePath)
        }

        let targetURL = repoContext.repoRoot.appendingPathComponent(relativePath)
        let exactContext = RepoContext(
            vcsType: repoContext.vcsType,
            repoRoot: repoContext.repoRoot,
            relativePath: relativePath,
            fullURL: targetURL
        )

        // If the file was deleted in this commit, open at the parent revision where it last existed
        let targetRevision: String
        if change?.status == .deleted, let firstParent = row.parentIds.first {
            targetRevision = firstParent
        } else {
            targetRevision = commit.id
        }

        tabManager?.openInTab(
            url: targetURL,
            initialRevision: targetRevision,
            preferredVCS: repoContext.vcsType,
            knownContext: exactContext
        )
    }
}
