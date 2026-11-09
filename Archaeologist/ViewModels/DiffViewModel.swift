import Foundation
import SwiftUI
import AppKit
import Combine

public enum DiffMode: String, CaseIterable, Identifiable {
    case sideBySide = "Side by Side"
    case unified = "Unified"

    public var id: String { rawValue }
}

public enum DiffContextOption: String, CaseIterable, Identifiable {
    case five = "5"
    case ten = "10"
    case twentyFive = "25"
    case wholeFile = "Whole file"

    public var id: String { rawValue }

    public var contextLines: Int? {
        switch self {
        case .five: return 5
        case .ten: return 10
        case .twentyFive: return 25
        case .wholeFile: return nil
        }
    }
}

public enum DiffLineType: Equatable {
    case unchanged
    case deleted
    case added
}

public struct DiffLine: Identifiable, Equatable {
    public let id: String
    public let type: DiffLineType
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    public init(
        id: String = UUID().uuidString,
        type: DiffLineType,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        text: String
    ) {
        self.id = id
        self.type = type
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

public struct SideBySideRow: Identifiable, Equatable {
    public let id: String
    public let left: DiffLine?
    public let right: DiffLine?

    public init(id: String = UUID().uuidString, left: DiffLine?, right: DiffLine?) {
        self.id = id
        self.left = left
        self.right = right
    }
}

public struct DiffChunk: Identifiable, Equatable {
    public let id: String
    public let header: String
    public let lines: [DiffLine]
    public let sideBySideRows: [SideBySideRow]

    public init(
        id: String = UUID().uuidString,
        header: String,
        lines: [DiffLine],
        sideBySideRows: [SideBySideRow]
    ) {
        self.id = id
        self.header = header
        self.lines = lines
        self.sideBySideRows = sideBySideRows
    }
}

@MainActor
public class DiffViewModel: ObservableObject {
    @Published public var repoContext: RepoContext
    @Published public var fileChange: WorkingFileChange?

    @Published public var diffMode: DiffMode = .sideBySide
    @Published public var contextOption: DiffContextOption = .five {
        didSet {
            rebuildChunks()
        }
    }

    @Published public var isLoading: Bool = false
    @Published public var isImage: Bool = false
    @Published public var isBinary: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var revertErrorMessage: String? = nil
    @Published public var revertStates: [String: BlockRevertState] = [:]

    // Text diff data
    @Published public var allDiffLines: [DiffLine] = []
    @Published public var chunks: [DiffChunk] = []
    @Published public var addedCount: Int = 0
    @Published public var removedCount: Int = 0
    @Published public var totalLines: Int = 0
    @Published public var language: SyntaxLanguage = .plain

    // Image diff data
    @Published public var oldImageData: Data? = nil
    @Published public var newImageData: Data? = nil
    @Published public var oldImage: NSImage? = nil
    @Published public var newImage: NSImage? = nil
    @Published public var imageZoom: CGFloat = 1.0

    // Binary file data
    @Published public var binaryDataSize: Int = 0

    private var currentLoadTaskId: UUID?

    public init(repoContext: RepoContext) {
        self.repoContext = repoContext
    }

    public var displayedPath: String {
        fileChange?.relativePath ?? repoContext.relativePath
    }

    public var fileTypeLabel: String {
        if isImage {
            let ext = (displayedPath as NSString).pathExtension.uppercased()
            return ext.isEmpty ? "IMAGE" : ext
        } else if isBinary {
            return "BINARY"
        } else {
            return language.rawValue
        }
    }

    public func clear() {
        self.currentLoadTaskId = nil
        self.fileChange = nil
        self.isLoading = false
        self.errorMessage = nil
        self.revertErrorMessage = nil
        self.revertStates = [:]
        self.isImage = false
        self.isBinary = false
        self.allDiffLines = []
        self.chunks = []
        self.addedCount = 0
        self.removedCount = 0
        self.totalLines = 0
        self.oldImageData = nil
        self.newImageData = nil
        self.oldImage = nil
        self.newImage = nil
        self.imageZoom = 1.0
        self.binaryDataSize = 0
    }

    public func copyState(from other: DiffViewModel) {
        self.currentLoadTaskId = nil
        self.repoContext = other.repoContext
        self.fileChange = other.fileChange
        self.diffMode = other.diffMode
        self.isLoading = other.isLoading
        self.isImage = other.isImage
        self.isBinary = other.isBinary
        self.errorMessage = other.errorMessage
        self.revertErrorMessage = other.revertErrorMessage
        self.revertStates = other.revertStates
        self.allDiffLines = other.allDiffLines
        self.contextOption = other.contextOption
        self.chunks = other.chunks
        self.addedCount = other.addedCount
        self.removedCount = other.removedCount
        self.totalLines = other.totalLines
        self.language = other.language
        self.oldImageData = other.oldImageData
        self.newImageData = other.newImageData
        self.oldImage = other.oldImage
        self.newImage = other.newImage
        self.imageZoom = other.imageZoom
        self.binaryDataSize = other.binaryDataSize
    }

    public func loadCommitFile(context: RepoContext, commit: CommitInfo, change: WorkingFileChange, quiet: Bool = false) {
        if commit.isUncommitted {
            loadFile(context: context, change: change, quiet: quiet)
            return
        }

        self.repoContext = context
        self.fileChange = change
        if !quiet {
            self.isLoading = true
            self.errorMessage = nil
            self.revertErrorMessage = nil
            self.revertStates = [:]
            self.isImage = false
            self.isBinary = false
            self.allDiffLines = []
            self.chunks = []
            self.addedCount = 0
            self.removedCount = 0
            self.totalLines = 0
            self.oldImageData = nil
            self.newImageData = nil
            self.oldImage = nil
            self.newImage = nil
            self.imageZoom = 1.0
            self.binaryDataSize = 0
        }

        let taskId = UUID()
        self.currentLoadTaskId = taskId

        let filename = change.relativePath
        let isImageFile = VCSManager.shared.isImageFile(filename: filename)
        let status = change.status
        let commitId = commit.id

        Task.detached(priority: .userInitiated) {
            // 1. Fetch parent content
            let oldData: Data?
            if status == .new || status == .unknown {
                oldData = nil
            } else {
                oldData = VCSManager.shared.fetchParentFileContent(
                    context: context,
                    commitId: commitId,
                    relativePath: change.relativePath
                )
            }

            // 2. Fetch revision content at commit
            let newData: Data?
            if status == .deleted {
                newData = nil
            } else {
                newData = VCSManager.shared.fetchRevisionFileContent(
                    context: context,
                    commitId: commitId,
                    relativePath: change.relativePath
                )
            }

            // 3. Binary detection (non-image)
            let isOldBinary = oldData.map { VCSManager.isBinaryData($0) } ?? false
            let isNewBinary = newData.map { VCSManager.isBinaryData($0) } ?? false
            let isBinaryFile = !isImageFile && (isOldBinary || isNewBinary)

            if isBinaryFile {
                let size = newData?.count ?? oldData?.count ?? 0
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentLoadTaskId == taskId else { return }
                    self.isBinary = true
                    self.isImage = false
                    self.binaryDataSize = size
                    self.isLoading = false
                }
                return
            }

            if isImageFile {
                let oldImg = oldData.flatMap { NSImage(data: $0) }
                let newImg = newData.flatMap { NSImage(data: $0) }
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentLoadTaskId == taskId else { return }
                    self.isImage = true
                    self.isBinary = false
                    self.oldImageData = oldData
                    self.newImageData = newData
                    self.oldImage = oldImg
                    self.newImage = newImg
                    self.isLoading = false
                }
                return
            }

            // 4. Text Diff
            let oldText = oldData.flatMap {
                String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .ascii)
            } ?? ""
            let newText = newData.flatMap {
                String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .ascii)
            } ?? ""

            let oldLines = oldText.isEmpty && (status == .new || status == .unknown || oldData == nil)
                ? []
                : oldText.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
                         .components(separatedBy: "\n")

            let newLines = newText.isEmpty && (status == .deleted || newData == nil)
                ? []
                : newText.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
                         .components(separatedBy: "\n")

            let ops = Self.computeMyersDiff(old: oldLines, new: newLines)
            let diffLines = Self.numberDiffLines(ops: ops)
            let total = newLines.count > 0 ? newLines.count : oldLines.count
            let addCount = diffLines.filter { $0.type == .added }.count
            let remCount = diffLines.filter { $0.type == .deleted }.count
            let firstLine = newLines.first ?? oldLines.first
            let lang = SyntaxLanguage.detect(filename: filename, firstLine: firstLine)

            await MainActor.run { [weak self] in
                guard let self = self, self.currentLoadTaskId == taskId else { return }
                self.isImage = false
                self.isBinary = false
                self.language = lang
                self.allDiffLines = diffLines
                self.totalLines = total
                self.addedCount = addCount
                self.removedCount = remCount
                self.rebuildChunks()
                self.isLoading = false
            }
        }
    }

    public func loadComparisonFile(
        context: RepoContext,
        baseCommit: CommitInfo,
        targetCommit: CommitInfo,
        change: WorkingFileChange,
        quiet: Bool = false
    ) {
        self.repoContext = context
        self.fileChange = change
        if !quiet {
            self.isLoading = true
            self.errorMessage = nil
            self.revertErrorMessage = nil
            self.revertStates = [:]
            self.isImage = false
            self.isBinary = false
            self.allDiffLines = []
            self.chunks = []
            self.addedCount = 0
            self.removedCount = 0
            self.totalLines = 0
            self.oldImageData = nil
            self.newImageData = nil
            self.oldImage = nil
            self.newImage = nil
            self.imageZoom = 1.0
            self.binaryDataSize = 0
        }

        let taskId = UUID()
        self.currentLoadTaskId = taskId

        let filename = change.relativePath
        let isImageFile = VCSManager.shared.isImageFile(filename: filename)
        let status = change.status

        Task.detached(priority: .userInitiated) {
            // 1. Fetch content at baseCommit
            let oldData: Data?
            if status == .new {
                oldData = nil
            } else if baseCommit.isUncommitted {
                oldData = VCSManager.shared.fetchWorkingCopyFileContent(context: context, relativePath: change.relativePath)
            } else {
                oldData = VCSManager.shared.fetchRevisionFileContent(
                    context: context,
                    commitId: baseCommit.id,
                    relativePath: change.relativePath
                )
            }

            // 2. Fetch content at targetCommit
            let newData: Data?
            if status == .deleted {
                newData = nil
            } else if targetCommit.isUncommitted {
                newData = VCSManager.shared.fetchWorkingCopyFileContent(context: context, relativePath: change.relativePath)
            } else {
                newData = VCSManager.shared.fetchRevisionFileContent(
                    context: context,
                    commitId: targetCommit.id,
                    relativePath: change.relativePath
                )
            }

            // 3. Binary detection (non-image)
            let isOldBinary = oldData.map { VCSManager.isBinaryData($0) } ?? false
            let isNewBinary = newData.map { VCSManager.isBinaryData($0) } ?? false
            let isBinaryFile = !isImageFile && (isOldBinary || isNewBinary)

            if isBinaryFile {
                let size = newData?.count ?? oldData?.count ?? 0
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentLoadTaskId == taskId else { return }
                    self.isBinary = true
                    self.isImage = false
                    self.binaryDataSize = size
                    self.isLoading = false
                }
                return
            }

            if isImageFile {
                let oldImg = oldData.flatMap { NSImage(data: $0) }
                let newImg = newData.flatMap { NSImage(data: $0) }
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentLoadTaskId == taskId else { return }
                    self.isImage = true
                    self.isBinary = false
                    self.oldImageData = oldData
                    self.newImageData = newData
                    self.oldImage = oldImg
                    self.newImage = newImg
                    self.isLoading = false
                }
                return
            }

            // 4. Text Diff
            let oldText = oldData.flatMap {
                String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .ascii)
            } ?? ""
            let newText = newData.flatMap {
                String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .ascii)
            } ?? ""

            let oldLines = oldText.isEmpty && (status == .new || oldData == nil)
                ? []
                : oldText.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
                         .components(separatedBy: "\n")

            let newLines = newText.isEmpty && (status == .deleted || newData == nil)
                ? []
                : newText.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
                         .components(separatedBy: "\n")

            let ops = Self.computeMyersDiff(old: oldLines, new: newLines)
            let diffLines = Self.numberDiffLines(ops: ops)
            let total = newLines.count > 0 ? newLines.count : oldLines.count
            let addCount = diffLines.filter { $0.type == .added }.count
            let remCount = diffLines.filter { $0.type == .deleted }.count
            let firstLine = newLines.first ?? oldLines.first
            let lang = SyntaxLanguage.detect(filename: filename, firstLine: firstLine)

            await MainActor.run { [weak self] in
                guard let self = self, self.currentLoadTaskId == taskId else { return }
                self.isImage = false
                self.isBinary = false
                self.language = lang
                self.allDiffLines = diffLines
                self.totalLines = total
                self.addedCount = addCount
                self.removedCount = remCount
                self.rebuildChunks()
                self.isLoading = false
            }
        }
    }

    public func loadFile(context: RepoContext, change: WorkingFileChange, quiet: Bool = false) {
        self.repoContext = context
        self.fileChange = change
        if !quiet {
            self.isLoading = true
            self.errorMessage = nil
            self.revertErrorMessage = nil
            self.revertStates = [:]
            self.isImage = false
            self.isBinary = false
            self.allDiffLines = []
            self.chunks = []
            self.addedCount = 0
            self.removedCount = 0
            self.totalLines = 0
            self.oldImageData = nil
            self.newImageData = nil
            self.oldImage = nil
            self.newImage = nil
            self.imageZoom = 1.0
            self.binaryDataSize = 0
        }

        let taskId = UUID()
        self.currentLoadTaskId = taskId

        let filename = change.relativePath
        let isImageFile = VCSManager.shared.isImageFile(filename: filename)
        let status = change.status

        Task.detached(priority: .userInitiated) {
            // 1. Fetch base content
            let oldData: Data?
            if status == .new || status == .unknown {
                oldData = nil
            } else {
                oldData = VCSManager.shared.fetchBaseFileContent(context: context, relativePath: change.relativePath)
            }

            // 2. Fetch working copy content
            let newData: Data?
            if status == .deleted {
                newData = nil
            } else {
                newData = VCSManager.shared.fetchWorkingCopyFileContent(context: context, relativePath: change.relativePath)
            }

            // 3. Binary detection (non-image)
            let isOldBinary = oldData.map { VCSManager.isBinaryData($0) } ?? false
            let isNewBinary = newData.map { VCSManager.isBinaryData($0) } ?? false
            let isBinaryFile = !isImageFile && (isOldBinary || isNewBinary)

            if isBinaryFile {
                let size = newData?.count ?? oldData?.count ?? 0
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentLoadTaskId == taskId else { return }
                    self.isBinary = true
                    self.isImage = false
                    self.binaryDataSize = size
                    self.isLoading = false
                    self.errorMessage = nil
                }
                return
            }

            if isImageFile {
                let oldImg = oldData.flatMap { NSImage(data: $0) }
                let newImg = newData.flatMap { NSImage(data: $0) }
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentLoadTaskId == taskId else { return }
                    self.isImage = true
                    self.isBinary = false
                    self.oldImageData = oldData
                    self.newImageData = newData
                    self.oldImage = oldImg
                    self.newImage = newImg
                    self.isLoading = false
                    self.errorMessage = nil
                }
                return
            }

            // 4. Text Diff
            let oldText = oldData.flatMap {
                String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .ascii)
            } ?? ""
            let newText = newData.flatMap {
                String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .ascii)
            } ?? ""

            let oldLines = oldText.isEmpty && (status == .new || status == .unknown)
                ? []
                : oldText.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
                         .components(separatedBy: "\n")

            let newLines = newText.isEmpty && status == .deleted
                ? []
                : newText.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
                         .components(separatedBy: "\n")

            let ops = Self.computeMyersDiff(old: oldLines, new: newLines)
            let diffLines = Self.numberDiffLines(ops: ops)
            let total = newLines.count > 0 ? newLines.count : oldLines.count
            let addCount = diffLines.filter { $0.type == .added }.count
            let remCount = diffLines.filter { $0.type == .deleted }.count
            let firstLine = newLines.first ?? oldLines.first
            let lang = SyntaxLanguage.detect(filename: filename, firstLine: firstLine)

            await MainActor.run { [weak self] in
                guard let self = self, self.currentLoadTaskId == taskId else { return }
                self.isImage = false
                self.isBinary = false
                self.language = lang
                self.allDiffLines = diffLines
                self.totalLines = total
                self.addedCount = addCount
                self.removedCount = remCount
                self.errorMessage = nil
                self.rebuildChunks()
                self.isLoading = false
            }
        }
    }

    public func rebuildChunks() {
        guard !allDiffLines.isEmpty else {
            self.chunks = []
            return
        }
        self.chunks = Self.buildChunks(allLines: allDiffLines, context: contextOption.contextLines)
    }

    // MARK: - Diff Algorithms & Chunking
    public nonisolated static func computeMyersDiff(old: [String], new: [String]) -> [(type: DiffLineType, text: String)] {
        let n = old.count
        let m = new.count

        // 1. Common prefix trimming
        var prefixCount = 0
        while prefixCount < n && prefixCount < m && old[prefixCount] == new[prefixCount] {
            prefixCount += 1
        }

        // 2. Common suffix trimming
        var suffixCount = 0
        while suffixCount < (n - prefixCount) && suffixCount < (m - prefixCount) && old[n - 1 - suffixCount] == new[m - 1 - suffixCount] {
            suffixCount += 1
        }

        var result: [(type: DiffLineType, text: String)] = []
        for i in 0..<prefixCount {
            result.append((.unchanged, old[i]))
        }

        let midOld = Array(old[prefixCount..<(n - suffixCount)])
        let midNew = Array(new[prefixCount..<(m - suffixCount)])

        if midOld.isEmpty {
            for s in midNew {
                result.append((.added, s))
            }
        } else if midNew.isEmpty {
            for s in midOld {
                result.append((.deleted, s))
            }
        } else {
            let nMid = midOld.count
            let mMid = midNew.count
            let maxD = nMid + mMid
            var v = [Int: Int]()
            v[1] = 0
            var trace = [[Int: Int]]()

            outer: for d in 0...maxD {
                trace.append(v)
                for k in stride(from: -d, through: d, by: 2) {
                    var x: Int
                    if k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0)) {
                        x = v[k + 1] ?? 0
                    } else {
                        x = (v[k - 1] ?? 0) + 1
                    }
                    var y = x - k
                    while x < nMid && y < mMid && midOld[x] == midNew[y] {
                        x += 1
                        y += 1
                    }
                    v[k] = x
                    if x >= nMid && y >= mMid {
                        break outer
                    }
                }
            }

            var midOps: [(type: DiffLineType, text: String)] = []
            var x = nMid
            var y = mMid
            for d in stride(from: trace.count - 1, through: 0, by: -1) {
                let v = trace[d]
                let k = x - y
                let prevK = (k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0))) ? k + 1 : k - 1
                let prevX = v[prevK] ?? 0
                let prevY = prevX - prevK

                while x > prevX && y > prevY {
                    x -= 1
                    y -= 1
                    midOps.append((.unchanged, midOld[x]))
                }
                if d > 0 {
                    if x == prevX {
                        y -= 1
                        midOps.append((.added, midNew[y]))
                    } else if y == prevY {
                        x -= 1
                        midOps.append((.deleted, midOld[x]))
                    }
                }
            }
            result.append(contentsOf: midOps.reversed())
        }

        for i in (n - suffixCount)..<n {
            result.append((.unchanged, old[i]))
        }
        return result
    }

    public nonisolated static func numberDiffLines(ops: [(type: DiffLineType, text: String)]) -> [DiffLine] {
        var diffLines: [DiffLine] = []
        diffLines.reserveCapacity(ops.count)
        var oldLine = 1
        var newLine = 1

        for (idx, op) in ops.enumerated() {
            switch op.type {
            case .unchanged:
                diffLines.append(DiffLine(
                    id: "u_\(idx)_\(oldLine)_\(newLine)",
                    type: .unchanged,
                    oldLineNumber: oldLine,
                    newLineNumber: newLine,
                    text: op.text
                ))
                oldLine += 1
                newLine += 1
            case .deleted:
                diffLines.append(DiffLine(
                    id: "d_\(idx)_\(oldLine)",
                    type: .deleted,
                    oldLineNumber: oldLine,
                    newLineNumber: nil,
                    text: op.text
                ))
                oldLine += 1
            case .added:
                diffLines.append(DiffLine(
                    id: "a_\(idx)_\(newLine)",
                    type: .added,
                    oldLineNumber: nil,
                    newLineNumber: newLine,
                    text: op.text
                ))
                newLine += 1
            }
        }
        return diffLines
    }

    public nonisolated static func buildChunks(allLines: [DiffLine], context: Int?) -> [DiffChunk] {
        let changedIndices = allLines.indices.filter { allLines[$0].type != .unchanged }
        if changedIndices.isEmpty {
            // No changes: if there are lines and context is wholeFile, return all lines, otherwise empty
            if context == nil && !allLines.isEmpty {
                let rows = buildSideBySideRows(slice: allLines)
                return [DiffChunk(id: "chunk_0", header: "@@ -1,\(allLines.count) +1,\(allLines.count) @@", lines: allLines, sideBySideRows: rows)]
            }
            return []
        }

        let ranges: [ClosedRange<Int>]
        if let context = context {
            var rawRanges = [ClosedRange<Int>]()
            for idx in changedIndices {
                let s = max(0, idx - context)
                let e = min(allLines.count - 1, idx + context)
                rawRanges.append(s...e)
            }
            var merged = [ClosedRange<Int>]()
            for r in rawRanges {
                if let last = merged.last {
                    if r.lowerBound <= last.upperBound + 1 {
                        merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
                    } else {
                        merged.append(r)
                    }
                } else {
                    merged.append(r)
                }
            }
            ranges = merged
        } else {
            ranges = [0...(allLines.count - 1)]
        }

        return ranges.enumerated().map { (chunkIdx, r) in
            let slice = Array(allLines[r])
            let oldStart = slice.compactMap(\.oldLineNumber).first ?? 1
            let oldCount = slice.filter { $0.type == .unchanged || $0.type == .deleted }.count
            let newStart = slice.compactMap(\.newLineNumber).first ?? 1
            let newCount = slice.filter { $0.type == .unchanged || $0.type == .added }.count
            let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
            let rows = buildSideBySideRows(slice: slice)
            return DiffChunk(id: "chunk_\(chunkIdx)", header: header, lines: slice, sideBySideRows: rows)
        }
    }

    public nonisolated static func buildSideBySideRows(slice: [DiffLine]) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        rows.reserveCapacity(slice.count)
        var i = 0
        var rowIdx = 0
        while i < slice.count {
            if slice[i].type == .unchanged {
                rows.append(SideBySideRow(id: "sbs_\(rowIdx)", left: slice[i], right: slice[i]))
                i += 1
                rowIdx += 1
            } else {
                var dels: [DiffLine] = []
                var adds: [DiffLine] = []
                while i < slice.count && slice[i].type != .unchanged {
                    if slice[i].type == .deleted {
                        dels.append(slice[i])
                    } else if slice[i].type == .added {
                        adds.append(slice[i])
                    }
                    i += 1
                }
                let count = max(dels.count, adds.count)
                for k in 0..<count {
                    let l = k < dels.count ? dels[k] : nil
                    let r = k < adds.count ? adds[k] : nil
                    rows.append(SideBySideRow(id: "sbs_\(rowIdx)", left: l, right: r))
                    rowIdx += 1
                }
            }
        }
        return rows
    }

    public func revertBlock(
        keys: [String],
        removedLines: [String],
        addedLines: [String],
        contextBefore: [String],
        contextAfter: [String]
    ) {
        let fileURL = repoContext.repoRoot.appendingPathComponent(displayedPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let errorMsg = RevertError.fileNotFound(displayedPath).localizedDescription
            self.revertErrorMessage = errorMsg
            for k in keys {
                self.revertStates[k] = .error(message: errorMsg)
            }
            return
        }

        guard let rawData = try? Data(contentsOf: fileURL) else {
            let errorMsg = RevertError.unreadableFile.localizedDescription
            self.revertErrorMessage = errorMsg
            for k in keys {
                self.revertStates[k] = .error(message: errorMsg)
            }
            return
        }

        let workingText = String(data: rawData, encoding: .utf8)
            ?? String(data: rawData, encoding: .ascii)
            ?? String(decoding: rawData, as: UTF8.self)

        let result = RevertEngine.apply(
            workingContent: workingText,
            removedLines: removedLines,
            addedLines: addedLines,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )

        switch result {
        case .success(let updatedContent):
            do {
                try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
                self.revertErrorMessage = nil
                for k in keys {
                    self.revertStates[k] = .success
                }
            } catch {
                let errorMsg = RevertError.writeFailed(error.localizedDescription).localizedDescription
                self.revertErrorMessage = errorMsg
                for k in keys {
                    self.revertStates[k] = .error(message: errorMsg)
                }
            }
        case .failure(let error):
            let errorMsg = error.localizedDescription
            self.revertErrorMessage = errorMsg
            for k in keys {
                self.revertStates[k] = .error(message: errorMsg)
            }
        }
    }
}
