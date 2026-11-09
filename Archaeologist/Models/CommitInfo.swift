import Foundation

public enum BlockRevertState: Equatable {
    case normal
    case success
    case error(message: String)
}

public enum RevertError: LocalizedError, Equatable {
    case fileNotFound(String)
    case unreadableFile
    case targetLinesNotFound
    case alreadyReverted
    case insertionContextNotFound
    case ambiguousMatch
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File does not exist in working directory: \(path)"
        case .unreadableFile:
            return "Could not read working directory file."
        case .targetLinesNotFound:
            return "Cannot apply cleanly: target lines to revert not found in working directory."
        case .alreadyReverted:
            return "Block is already reverted in working directory."
        case .insertionContextNotFound:
            return "Cannot apply cleanly: surrounding context for deleted block not found in working directory."
        case .ambiguousMatch:
            return "Cannot apply cleanly: multiple ambiguous matches found in working directory."
        case .writeFailed(let msg):
            return "Failed to write reverted changes to file: \(msg)"
        }
    }
}

public enum VCSType: String, Codable, CaseIterable, Identifiable {
    case git = "Git"
    case hg = "Mercurial"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .git: return "arrow.triangle.branch"
        case .hg: return "cube.transparent"
        }
    }
}

public enum LineChangeType: String, Codable {
    case unchanged
    case added
    case removed
}

public struct CommitInfo: Identifiable, Equatable, Hashable {
    public static let uncommittedHash = "uncommitted"
    public static let uncommittedRevision = "Uncommitted"

    public let id: String              // Full hash / node ID
    public let displayRevision: String // Short hash (git) or rev:shortNode (hg)
    public let fullRevision: String
    public let author: String
    public let authorEmail: String
    public let date: Date
    public let dateFormatted: String
    public let summary: String
    public let fullMessage: String
    public var index: Int = 0
    public var filePath: String? = nil
    public var addedCount: Int? = nil
    public var removedCount: Int? = nil
    public var renamedFromPath: String? = nil
    public var branches: [String] = []
    public var tags: [String] = []

    public var isUncommitted: Bool {
        id == CommitInfo.uncommittedHash || id == "0000000000000000000000000000000000000000" || displayRevision == CommitInfo.uncommittedRevision
    }

    public init(
        id: String,
        displayRevision: String,
        fullRevision: String,
        author: String,
        authorEmail: String,
        date: Date,
        dateFormatted: String,
        summary: String,
        fullMessage: String,
        index: Int = 0,
        filePath: String? = nil,
        addedCount: Int? = nil,
        removedCount: Int? = nil,
        renamedFromPath: String? = nil,
        branches: [String] = [],
        tags: [String] = []
    ) {
        self.id = id
        self.displayRevision = displayRevision
        self.fullRevision = fullRevision
        self.author = author
        self.authorEmail = authorEmail
        self.date = date
        self.dateFormatted = dateFormatted
        self.summary = summary
        self.fullMessage = fullMessage
        self.index = index
        self.filePath = filePath
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.renamedFromPath = renamedFromPath
        self.branches = branches
        self.tags = tags
    }

    public var fullAuthor: String {
        let trimmedEmail = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail.isEmpty {
            return author
        }
        if author.contains(trimmedEmail) || author.contains("<") {
            return author
        }
        if author.isEmpty || author == "Unknown" {
            return trimmedEmail
        }
        return "\(author) <\(trimmedEmail)>"
    }

    public static func shortenRevision(_ rev: String) -> String {
        let trimmed = rev.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "uncommitted" {
            return CommitInfo.uncommittedRevision
        }
        if trimmed.contains(":") {
            let parts = trimmed.components(separatedBy: ":")
            let r = parts[0]
            let h = parts[1]
            return "\(r):\(h.prefix(6))"
        } else if trimmed.count > 7 {
            return String(trimmed.prefix(7))
        }
        return trimmed
    }

    public static func cleanAuthorName(_ author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("<") && trimmed.contains(">") {
            let parts = trimmed.components(separatedBy: "<")
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return name
            }
            let email = parts[1].replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            if let user = email.split(separator: "@").first, !user.isEmpty {
                return String(user)
            }
            return email
        }
        return trimmed
    }
}

public struct BlameLine: Identifiable, Equatable {
    public let id: String
    public let lineNumber: Int?
    public let revision: String
    public let author: String
    public let authorEmail: String
    public let date: Date?
    public let dateString: String
    public let content: String
    public var isChangedInCurrentCommit: Bool
    public var changeType: LineChangeType

    public init(
        id: String = UUID().uuidString,
        lineNumber: Int?,
        revision: String,
        author: String,
        authorEmail: String = "",
        date: Date? = nil,
        dateString: String,
        content: String,
        isChangedInCurrentCommit: Bool = false,
        changeType: LineChangeType = .unchanged
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.revision = CommitInfo.shortenRevision(revision)
        self.author = CommitInfo.cleanAuthorName(author)
        self.authorEmail = authorEmail
        self.date = date
        self.dateString = dateString
        self.content = content
        self.isChangedInCurrentCommit = isChangedInCurrentCommit
        self.changeType = changeType
    }

    public func isChanged(in commit: CommitInfo) -> Bool {
        if changeType == .removed || changeType == .added || isChangedInCurrentCommit {
            return true
        }
        return commit.matches(revision: revision)
    }
}

extension BlameLine {
    public static func displayRevision(for line: BlameLine, vcsType: VCSType? = nil) -> String {
        let revLower = line.revision.lowercased()
        if revLower == "uncommitted" || line.revision == CommitInfo.uncommittedRevision || revLower == "pending" {
            return "Pending"
        }
        let isHg = vcsType == .hg || line.revision.contains(":")
        if isHg {
            if let localRev = line.revision.split(separator: ":").first {
                return String(localRev.prefix(7))
            }
        }
        return String(line.revision.prefix(7))
    }

    public static func shouldHideConsecutiveBlame(prev: BlameLine?, current: BlameLine, vcsType: VCSType? = nil) -> Bool {
        guard let prev = prev else { return false }
        guard prev.changeType == current.changeType else { return false }
        if prev.revision == current.revision {
            return true
        }
        return displayRevision(for: prev, vcsType: vcsType) == displayRevision(for: current, vcsType: vcsType)
    }

    public var isChangeLine: Bool {
        changeType == .added || changeType == .removed || isChangedInCurrentCommit
    }

    public static func hasSameCommitInfo(_ a: BlameLine, _ b: BlameLine, vcsType: VCSType? = nil) -> Bool {
        if a.revision == b.revision { return true }
        let dispA = displayRevision(for: a, vcsType: vcsType)
        let dispB = displayRevision(for: b, vcsType: vcsType)
        return !dispA.isEmpty && dispA == dispB
    }

    public static func isFirstLineOfBlock(lines: [BlameLine], index: Int, vcsType: VCSType? = nil) -> Bool {
        guard index >= 0, index < lines.count, lines[index].isChangeLine else { return false }
        if index == 0 { return true }
        let prev = lines[index - 1]
        return !prev.isChangeLine || !hasSameCommitInfo(prev, lines[index], vcsType: vcsType)
    }

    public static func calculateBlockRange(lines: [BlameLine], targetIndex: Int, vcsType: VCSType? = nil) -> Range<Int> {
        guard targetIndex >= 0, targetIndex < lines.count, lines[targetIndex].isChangeLine else {
            return targetIndex..<targetIndex
        }
        let target = lines[targetIndex]
        var start = targetIndex
        while start > 0 {
            let prev = lines[start - 1]
            if prev.isChangeLine && hasSameCommitInfo(prev, target, vcsType: vcsType) {
                start -= 1
            } else {
                break
            }
        }
        var end = targetIndex + 1
        while end < lines.count {
            let next = lines[end]
            if next.isChangeLine && hasSameCommitInfo(next, target, vcsType: vcsType) {
                end += 1
            } else {
                break
            }
        }
        return start..<end
    }

    public static func applyRevert(
        workingContent: String,
        blockLines: [BlameLine],
        contextBefore: [String],
        contextAfter: [String]
    ) -> Result<String, RevertError> {
        func clean(_ str: String) -> String {
            str.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        }

        let removedLines = blockLines.filter { $0.changeType == .removed }.map { clean($0.content) }
        let addedLines = blockLines.filter { $0.changeType != .removed }.map { clean($0.content) }

        return RevertEngine.apply(
            workingContent: workingContent,
            removedLines: removedLines,
            addedLines: addedLines,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )
    }
}

public enum RevertEngine {
    public static func apply(
        workingContent: String,
        removedLines: [String],
        addedLines: [String],
        contextBefore: [String],
        contextAfter: [String]
    ) -> Result<String, RevertError> {
        let lineEnding = workingContent.contains("\r\n") ? "\r\n" : "\n"
        let hasTrailingNewline = workingContent.hasSuffix("\n") || workingContent.hasSuffix("\r")

        func clean(_ str: String) -> String {
            str.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        }

        let workingLinesRaw = workingContent.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        var workingLines = workingLinesRaw
        if hasTrailingNewline && workingLines.last == "" {
            workingLines.removeLast()
        }

        let cleanedRemoved = removedLines.map { clean($0) }
        let cleanedAdded = addedLines.map { clean($0) }
        let cleanedContextBefore = contextBefore.map { clean($0) }
        let cleanedContextAfter = contextAfter.map { clean($0) }

        if !cleanedAdded.isEmpty {
            let M = cleanedAdded.count
            let N = workingLines.count

            // Check if already reverted
            if !cleanedRemoved.isEmpty && N >= cleanedRemoved.count {
                for k in 0...(N - cleanedRemoved.count) {
                    if Array(workingLines[k..<(k + cleanedRemoved.count)]) == cleanedRemoved {
                        var hasAdded = false
                        if N >= M {
                            for j in 0...(N - M) {
                                if Array(workingLines[j..<(j + M)]) == cleanedAdded {
                                    hasAdded = true
                                    break
                                }
                            }
                        }
                        if !hasAdded {
                            return .failure(.alreadyReverted)
                        }
                    }
                }
            }

            guard N >= M else {
                return .failure(.targetLinesNotFound)
            }

            var matchIndices: [Int] = []
            for k in 0...(N - M) {
                if Array(workingLines[k..<(k + M)]) == cleanedAdded {
                    matchIndices.append(k)
                }
            }

            if matchIndices.isEmpty {
                // Try trimmed comparison as fallback
                let trimmedAdded = cleanedAdded.map { $0.trimmingCharacters(in: .whitespaces) }
                for k in 0...(N - M) {
                    let slice = workingLines[k..<(k + M)].map { $0.trimmingCharacters(in: .whitespaces) }
                    if slice == trimmedAdded {
                        matchIndices.append(k)
                    }
                }
            }

            guard !matchIndices.isEmpty else {
                return .failure(.targetLinesNotFound)
            }

            let bestIndex: Int
            if matchIndices.count == 1 {
                bestIndex = matchIndices[0]
            } else {
                var scored: [(index: Int, score: Int)] = []
                for idx in matchIndices {
                    var score = 0
                    for (offset, ctxLine) in cleanedContextBefore.reversed().enumerated() {
                        let checkIdx = idx - 1 - offset
                        if checkIdx >= 0 && clean(workingLines[checkIdx]) == ctxLine {
                            score += 1
                        } else {
                            break
                        }
                    }
                    for (offset, ctxLine) in cleanedContextAfter.enumerated() {
                        let checkIdx = idx + M + offset
                        if checkIdx < workingLines.count && clean(workingLines[checkIdx]) == ctxLine {
                            score += 1
                        } else {
                            break
                        }
                    }
                    scored.append((index: idx, score: score))
                }

                scored.sort { $0.score > $1.score }
                if scored.count > 1 && scored[0].score == scored[1].score && scored[0].score == 0 {
                    return .failure(.ambiguousMatch)
                }
                bestIndex = scored[0].index
            }

            workingLines.replaceSubrange(bestIndex..<(bestIndex + M), with: cleanedRemoved)
        } else {
            // Pure deletion: insert removedLines back into workingLines
            guard !cleanedRemoved.isEmpty else {
                return .failure(.targetLinesNotFound)
            }

            let remCount = cleanedRemoved.count
            if workingLines.count >= remCount {
                for k in 0...(workingLines.count - remCount) {
                    if Array(workingLines[k..<(k + remCount)]) == cleanedRemoved {
                        return .failure(.alreadyReverted)
                    }
                }
            }

            var candidates: [Int] = []
            for k in 0...workingLines.count {
                var matchesBefore = true
                for (offset, ctxLine) in cleanedContextBefore.reversed().enumerated() {
                    let checkIdx = k - 1 - offset
                    if checkIdx < 0 || clean(workingLines[checkIdx]) != ctxLine {
                        matchesBefore = false
                        break
                    }
                }
                var matchesAfter = true
                for (offset, ctxLine) in cleanedContextAfter.enumerated() {
                    let checkIdx = k + offset
                    if checkIdx >= workingLines.count || clean(workingLines[checkIdx]) != ctxLine {
                        matchesAfter = false
                        break
                    }
                }
                if matchesBefore && matchesAfter {
                    candidates.append(k)
                }
            }

            if candidates.isEmpty && (!cleanedContextBefore.isEmpty || !cleanedContextAfter.isEmpty) {
                let singleBefore = cleanedContextBefore.last
                let singleAfter = cleanedContextAfter.first
                for k in 0...workingLines.count {
                    let beforeMatch = singleBefore == nil || (k > 0 && clean(workingLines[k - 1]) == singleBefore!)
                    let afterMatch = singleAfter == nil || (k < workingLines.count && clean(workingLines[k]) == singleAfter!)
                    if beforeMatch && afterMatch {
                        candidates.append(k)
                    }
                }
            }

            guard !candidates.isEmpty else {
                return .failure(.insertionContextNotFound)
            }

            if candidates.count > 1 {
                return .failure(.ambiguousMatch)
            }

            workingLines.insert(contentsOf: cleanedRemoved, at: candidates[0])
        }

        var result = workingLines.joined(separator: lineEnding)
        if hasTrailingNewline {
            result += lineEnding
        }
        return .success(result)
    }
}

extension CommitInfo {
    public func matches(revision query: String) -> Bool {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanQuery.isEmpty else { return false }

        if isUncommitted {
            if cleanQuery == "uncommitted" ||
               cleanQuery == "pending" ||
               cleanQuery == "working directory" ||
               cleanQuery == "working copy" ||
               cleanQuery.hasPrefix("000000") ||
               cleanQuery == "not committed yet" {
                return true
            }
        }

        let cid = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let disp = displayRevision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let full = fullRevision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if cid == cleanQuery || disp == cleanQuery || full == cleanQuery {
            return true
        }

        if cid.hasPrefix(cleanQuery) || cleanQuery.hasPrefix(cid) || full.hasPrefix(cleanQuery) {
            return true
        }

        let queryParts = cleanQuery.split(separator: ":").map(String.init)
        let dispParts = disp.split(separator: ":").map(String.init)

        if queryParts.count >= 2 {
            let qRev = queryParts[0]
            let qNode = queryParts[1]

            if dispParts.count >= 2 {
                let dRev = dispParts[0]
                let dNode = dispParts[1]

                if qRev == dRev {
                    if qNode.isEmpty || dNode.hasPrefix(qNode) || qNode.hasPrefix(dNode) || cid.hasPrefix(qNode) {
                        return true
                    }
                }
            }

            if !qNode.isEmpty && qNode.count >= 4 {
                if cid.hasPrefix(qNode) || full.hasPrefix(qNode) {
                    return true
                }
                if dispParts.count >= 2 && (dispParts[1].hasPrefix(qNode) || qNode.hasPrefix(dispParts[1])) {
                    return true
                }
            }
        } else {
            let part = queryParts[0]
            if let _ = Int(part), dispParts.count >= 2, dispParts[0] == part {
                return true
            }

            if part.count >= 4 {
                if cid.hasPrefix(part) || full.hasPrefix(part) {
                    return true
                }
                if dispParts.count >= 2 && dispParts[1].hasPrefix(part) {
                    return true
                }
            }
        }

        return false
    }

    public func matchesFilter(query: String, vcsType: VCSType) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let trimmedLower = trimmed.lowercased()

        // 1. Description contains listed text (case insensitively)
        if summary.localizedCaseInsensitiveContains(query) ||
           fullMessage.localizedCaseInsensitiveContains(query) ||
           summary.localizedCaseInsensitiveContains(trimmed) ||
           fullMessage.localizedCaseInsensitiveContains(trimmed) {
            return true
        }

        // 2. Author contains listed text (case insensitively)
        if author.localizedCaseInsensitiveContains(query) ||
           authorEmail.localizedCaseInsensitiveContains(query) ||
           fullAuthor.localizedCaseInsensitiveContains(query) ||
           author.localizedCaseInsensitiveContains(trimmed) ||
           authorEmail.localizedCaseInsensitiveContains(trimmed) ||
           fullAuthor.localizedCaseInsensitiveContains(trimmed) {
            return true
        }

        // 3. Local revision (for mercurial) starts with the text (case insensitively)
        if vcsType == .hg && !isUncommitted {
            let localRev: String
            if let colonIdx = displayRevision.firstIndex(of: ":") {
                localRev = String(displayRevision[..<colonIdx])
            } else {
                localRev = displayRevision
            }
            if localRev.lowercased().hasPrefix(trimmedLower) {
                return true
            }
        }

        // 4. Commit hash starts with the text (case insensitively)
        if id.lowercased().hasPrefix(trimmedLower) ||
           fullRevision.lowercased().hasPrefix(trimmedLower) ||
           displayRevision.lowercased().hasPrefix(trimmedLower) {
            return true
        }

        return false
    }
}

public struct FileRevisionContent {
    public let isImage: Bool
    public let isBinary: Bool
    public let binaryData: Data?
    public let textLines: [BlameLine]
    public let rawText: String
    public let errorMessage: String?

    public let addedLinesCount: Int
    public let removedLinesCount: Int
    public let changedLinesCount: Int
    public let nonRemovedLines: [BlameLine]

    public init(
        isImage: Bool,
        isBinary: Bool = false,
        binaryData: Data?,
        textLines: [BlameLine],
        rawText: String,
        errorMessage: String? = nil
    ) {
        self.isImage = isImage
        self.isBinary = isBinary
        self.binaryData = binaryData
        self.textLines = textLines
        self.rawText = rawText
        self.errorMessage = errorMessage

        var added = 0
        var removed = 0
        var nonRemoved: [BlameLine] = []
        nonRemoved.reserveCapacity(textLines.count)
        for line in textLines {
            if line.changeType == .removed {
                removed += 1
            } else {
                nonRemoved.append(line)
                if line.changeType == .added || (line.changeType == .unchanged && line.isChangedInCurrentCommit) {
                    added += 1
                }
            }
        }
        self.addedLinesCount = added
        self.removedLinesCount = removed
        self.changedLinesCount = added + removed
        self.nonRemovedLines = nonRemoved
    }

    public static var empty: FileRevisionContent {
        FileRevisionContent(isImage: false, isBinary: false, binaryData: nil, textLines: [], rawText: "")
    }
}
