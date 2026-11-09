import Foundation

/// Fast streaming diff reconstructor that builds commit revision content and line blame
/// in-memory using a single VCS log/diff process rather than blaming at every revision.
public struct DeltaReconstructor {
    private struct TrackedLine {
        var content: String
        var revision: String
        var author: String
        var authorEmail: String
        var date: Date
        var isChangedInCurrentCommit: Bool
    }

    private struct DiffHunk {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var removedLines: [String]
        var addedLines: [String]
    }

    /// Fetches and reconstructs content for all commits using a single streaming diff command.
    /// Calls `onRevision` as each commit is reconstructed so caller can update caches progressively.
    public static func fetchAllRevisionsStreaming(
        context: RepoContext,
        commits: [CommitInfo],
        onRevision: (@Sendable (String, FileRevisionContent) async -> Void)? = nil
    ) async throws -> [String: FileRevisionContent] {
        guard !commits.isEmpty else { return [:] }

        switch context.vcsType {
        case .git:
            return try await fetchGitAllRevisions(context: context, commits: commits, onRevision: onRevision)
        case .hg:
            return try await fetchHgAllRevisions(context: context, commits: commits, onRevision: onRevision)
        }
    }

    // MARK: - Git Streaming Reconstructor
    private static func fetchGitAllRevisions(
        context: RepoContext,
        commits: [CommitInfo],
        onRevision: (@Sendable (String, FileRevisionContent) async -> Void)?
    ) async throws -> [String: FileRevisionContent] {
        // If file history contains renames, git log --follow --reverse cannot reconstruct
        // from root because Git only follows renames going backwards. Throw to use fallback.
        if commits.contains(where: { $0.filePath != nil && $0.filePath != context.relativePath }) {
            throw NSError(
                domain: "DeltaReconstructor",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "File history contains renames; using individual commit fetching."]
            )
        }

        let recordDelim = "\u{1e}"
        let fieldDelim = "\u{1f}"
        let format = "\(recordDelim)%H\(fieldDelim)%h\(fieldDelim)%an\(fieldDelim)%ae\(fieldDelim)%ad\(fieldDelim)%s\(fieldDelim)"

        let args = [
            "log",
            "--follow",
            "-p",
            "-U0",
            "--reverse",
            "--root",
            "--date=iso-strict",
            "--format=\(format)",
            "--",
            context.relativePath
        ]

        var results: [String: FileRevisionContent] = [:]
        var activeLines: [TrackedLine] = []
        let commitMap = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })
        var currentSectionLines: [String] = []

        func processCurrentSection() async throws {
            guard !currentSectionLines.isEmpty else { return }
            let sectionText = currentSectionLines.joined(separator: "\n")
            let parts = sectionText.components(separatedBy: fieldDelim)
            guard parts.count >= 7 else { return }

            let commitHash = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let commit = commitMap[commitHash] else { return }

            let diffText = parts[6]
            let hunks = parseUnifiedDiffHunks(diffText)

            var deletionsMap: [Int: [String]] = [:]
            var newActiveLines = activeLines

            for i in 0..<newActiveLines.count {
                newActiveLines[i].isChangedInCurrentCommit = false
            }

            // Collect deletions in original hunk order
            for hunk in hunks {
                let targetLine = (hunk.newCount == 0) ? hunk.newStart + 1 : hunk.newStart
                if !hunk.removedLines.isEmpty {
                    var list = deletionsMap[targetLine] ?? []
                    list.append(contentsOf: hunk.removedLines)
                    deletionsMap[targetLine] = list
                }
            }

            // Apply modifications to activeLines in descending order of oldStart
            let sortedHunksDesc = hunks.sorted { $0.oldStart > $1.oldStart }
            for hunk in sortedHunksDesc {
                let replaceRangeStart = hunk.oldCount == 0 ? hunk.oldStart : max(0, hunk.oldStart - 1)
                guard replaceRangeStart <= newActiveLines.count else {
                    throw NSError(
                        domain: "DeltaReconstructor",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Diff hunk out of bounds: start \(replaceRangeStart) > count \(newActiveLines.count)"]
                    )
                }
                let replaceRangeCount = min(hunk.oldCount, max(0, newActiveLines.count - replaceRangeStart))
                let end = min(newActiveLines.count, replaceRangeStart + replaceRangeCount)
                guard replaceRangeStart <= end else { continue }

                let newLines: [TrackedLine] = hunk.addedLines.map { addedContent in
                    TrackedLine(
                        content: addedContent,
                        revision: String(commit.id.prefix(7)),
                        author: commit.author,
                        authorEmail: commit.authorEmail,
                        date: commit.date,
                        isChangedInCurrentCommit: true
                    )
                }

                newActiveLines.replaceSubrange(replaceRangeStart..<end, with: newLines)
            }

            activeLines = newActiveLines

            let commitDateStr = VCSManager.formatBlameDate(commit.date)
            let commitShortRev = String(commit.id.prefix(7))
            var interleaved: [BlameLine] = []

            for (idx, line) in activeLines.enumerated() {
                let lineNum = idx + 1
                if let removedList = deletionsMap[lineNum] {
                    for (remIdx, removed) in removedList.enumerated() {
                        interleaved.append(BlameLine(
                            id: "rem_\(commit.id)_\(lineNum)_\(remIdx)",
                            lineNumber: nil,
                            revision: commitShortRev,
                            author: commit.author,
                            authorEmail: commit.authorEmail,
                            date: commit.date,
                            dateString: commitDateStr,
                            content: removed,
                            isChangedInCurrentCommit: true,
                            changeType: .removed
                        ))
                    }
                }

                interleaved.append(BlameLine(
                    id: "\(commit.id)_\(lineNum)",
                    lineNumber: lineNum,
                    revision: line.revision,
                    author: line.author,
                    authorEmail: line.authorEmail,
                    date: line.date,
                    dateString: VCSManager.formatBlameDate(line.date),
                    content: line.content,
                    isChangedInCurrentCommit: line.isChangedInCurrentCommit,
                    changeType: line.isChangedInCurrentCommit ? .added : .unchanged
                ))
            }

            let pastEndLine = activeLines.count + 1
            if let removedList = deletionsMap[pastEndLine] {
                for (remIdx, removed) in removedList.enumerated() {
                    interleaved.append(BlameLine(
                        id: "rem_tail_\(commit.id)_\(remIdx)",
                        lineNumber: nil,
                        revision: commitShortRev,
                        author: commit.author,
                        authorEmail: commit.authorEmail,
                        date: commit.date,
                        dateString: commitDateStr,
                        content: removed,
                        isChangedInCurrentCommit: true,
                        changeType: .removed
                    ))
                }
            }

            let rawText = activeLines.map(\.content).joined(separator: "\n")
            let content = FileRevisionContent(
                isImage: false,
                binaryData: nil,
                textLines: interleaved,
                rawText: rawText
            )

            results[commit.id] = content
            await onRevision?(commit.id, content)
        }

        let result = try ProcessRunner.run(
            binary: "git",
            arguments: args,
            currentDirectory: context.repoRoot
        )
        guard result.isSuccess else {
            throw NSError(
                domain: "DeltaReconstructor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: result.stderrString]
            )
        }

        let lines = result.stdoutString.components(separatedBy: .newlines)
        for line in lines {
            if Task.isCancelled { break }
            if line.hasPrefix(recordDelim) {
                try await processCurrentSection()
                currentSectionLines = [String(line.dropFirst(recordDelim.count))]
            } else {
                currentSectionLines.append(line)
            }
        }

        try await processCurrentSection()
        return results
    }

    // MARK: - Mercurial Streaming Reconstructor
    private static func fetchHgAllRevisions(
        context: RepoContext,
        commits: [CommitInfo],
        onRevision: (@Sendable (String, FileRevisionContent) async -> Void)?
    ) async throws -> [String: FileRevisionContent] {
        let recordDelim = "===HG_COMMIT_RECORD==="
        let fieldDelim = "\u{1f}"
        let template = "\(recordDelim){node}\(fieldDelim){rev}:{node|short}\(fieldDelim){author|person}\(fieldDelim){author|email}\(fieldDelim){date|isodate}\(fieldDelim){desc|firstline}\(fieldDelim)\n"

        let escapedPath = context.relativePath.replacingOccurrences(of: "\"", with: "\\\"")
        let args = [
            "log",
            "-p",
            "--config", "diff.unified=0",
            "-r", "file(\"\(escapedPath)\")",
            "--template", template,
            context.relativePath
        ]

        var results: [String: FileRevisionContent] = [:]
        var activeLines: [TrackedLine] = []
        let commitMap = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })
        var currentSectionLines: [String] = []

        func processCurrentSection() async throws {
            guard !currentSectionLines.isEmpty else { return }
            let sectionText = currentSectionLines.joined(separator: "\n")
            let parts = sectionText.components(separatedBy: fieldDelim)
            guard parts.count >= 7 else { return }

            let commitHash = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let commit = commitMap[commitHash] else { return }

            let diffText = parts[6]
            let hunks = parseUnifiedDiffHunks(diffText)

            var deletionsMap: [Int: [String]] = [:]
            var newActiveLines = activeLines

            for i in 0..<newActiveLines.count {
                newActiveLines[i].isChangedInCurrentCommit = false
            }

            // Collect deletions in original hunk order
            for hunk in hunks {
                let targetLine = (hunk.newCount == 0) ? hunk.newStart + 1 : hunk.newStart
                if !hunk.removedLines.isEmpty {
                    var list = deletionsMap[targetLine] ?? []
                    list.append(contentsOf: hunk.removedLines)
                    deletionsMap[targetLine] = list
                }
            }

            // Apply modifications to activeLines in descending order of oldStart
            let sortedHunksDesc = hunks.sorted { $0.oldStart > $1.oldStart }
            for hunk in sortedHunksDesc {
                let replaceRangeStart = hunk.oldCount == 0 ? hunk.oldStart : max(0, hunk.oldStart - 1)
                guard replaceRangeStart <= newActiveLines.count else {
                    throw NSError(
                        domain: "DeltaReconstructor",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Diff hunk out of bounds: start \(replaceRangeStart) > count \(newActiveLines.count)"]
                    )
                }
                let replaceRangeCount = min(hunk.oldCount, max(0, newActiveLines.count - replaceRangeStart))
                let end = min(newActiveLines.count, replaceRangeStart + replaceRangeCount)
                guard replaceRangeStart <= end else { continue }

                let commitRev = commit.displayRevision.split(separator: ":").first.map(String.init) ?? commit.displayRevision
                let newLines: [TrackedLine] = hunk.addedLines.map { addedContent in
                    TrackedLine(
                        content: addedContent,
                        revision: commitRev,
                        author: commit.author,
                        authorEmail: commit.authorEmail,
                        date: commit.date,
                        isChangedInCurrentCommit: true
                    )
                }

                newActiveLines.replaceSubrange(replaceRangeStart..<end, with: newLines)
            }

            activeLines = newActiveLines

            let commitDateStr = VCSManager.formatBlameDate(commit.date)
            let commitRev = commit.displayRevision.split(separator: ":").first.map(String.init) ?? commit.displayRevision
            var interleaved: [BlameLine] = []

            for (idx, line) in activeLines.enumerated() {
                let lineNum = idx + 1
                if let removedList = deletionsMap[lineNum] {
                    for (remIdx, removed) in removedList.enumerated() {
                        interleaved.append(BlameLine(
                            id: "rem_\(commit.id)_\(lineNum)_\(remIdx)",
                            lineNumber: nil,
                            revision: commitRev,
                            author: commit.author,
                            authorEmail: commit.authorEmail,
                            date: commit.date,
                            dateString: commitDateStr,
                            content: removed,
                            isChangedInCurrentCommit: true,
                            changeType: .removed
                        ))
                    }
                }

                interleaved.append(BlameLine(
                    id: "\(commit.id)_\(lineNum)",
                    lineNumber: lineNum,
                    revision: line.revision,
                    author: line.author,
                    authorEmail: line.authorEmail,
                    date: line.date,
                    dateString: VCSManager.formatBlameDate(line.date),
                    content: line.content,
                    isChangedInCurrentCommit: line.isChangedInCurrentCommit,
                    changeType: line.isChangedInCurrentCommit ? .added : .unchanged
                ))
            }

            let pastEndLine = activeLines.count + 1
            if let removedList = deletionsMap[pastEndLine] {
                for (remIdx, removed) in removedList.enumerated() {
                    interleaved.append(BlameLine(
                        id: "rem_tail_\(commit.id)_\(remIdx)",
                        lineNumber: nil,
                        revision: commitRev,
                        author: commit.author,
                        authorEmail: commit.authorEmail,
                        date: commit.date,
                        dateString: commitDateStr,
                        content: removed,
                        isChangedInCurrentCommit: true,
                        changeType: .removed
                    ))
                }
            }

            let rawText = activeLines.map(\.content).joined(separator: "\n")
            let content = FileRevisionContent(
                isImage: false,
                binaryData: nil,
                textLines: interleaved,
                rawText: rawText
            )

            results[commit.id] = content
            await onRevision?(commit.id, content)
        }

        let result = try ProcessRunner.run(
            binary: context.hgBinary,
            arguments: args,
            currentDirectory: context.repoRoot
        )
        guard result.isSuccess else {
            throw NSError(
                domain: "DeltaReconstructor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: result.stderrString]
            )
        }

        let lines = result.stdoutString.components(separatedBy: .newlines)
        for line in lines {
            if Task.isCancelled { break }
            if line.hasPrefix(recordDelim) {
                try await processCurrentSection()
                currentSectionLines = [String(line.dropFirst(recordDelim.count))]
            } else {
                currentSectionLines.append(line)
            }
        }

        try await processCurrentSection()
        return results
    }

    // MARK: - Diff Parser
    private static func parseUnifiedDiffHunks(_ diffText: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        let lines = diffText.components(separatedBy: "\n")

        var currentHunk: DiffHunk? = nil
        let hunkRegex = try! NSRegularExpression(pattern: #"^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@"#)

        for line in lines {
            let nsLine = line as NSString
            if line.hasPrefix("@@") {
                if let h = currentHunk {
                    hunks.append(h)
                    currentHunk = nil
                }
                if let match = hunkRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                    let oldStart = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
                    let oldCount = match.range(at: 2).location != NSNotFound ? (Int(nsLine.substring(with: match.range(at: 2))) ?? 0) : 1
                    let newStart = Int(nsLine.substring(with: match.range(at: 3))) ?? 0
                    let newCount = match.range(at: 4).location != NSNotFound ? (Int(nsLine.substring(with: match.range(at: 4))) ?? 0) : 1

                    currentHunk = DiffHunk(
                        oldStart: oldStart,
                        oldCount: oldCount,
                        newStart: newStart,
                        newCount: newCount,
                        removedLines: [],
                        addedLines: []
                    )
                }
            } else if var h = currentHunk {
                if line.hasPrefix("-") && !line.hasPrefix("---") {
                    h.removedLines.append(String(line.dropFirst()))
                    currentHunk = h
                } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    h.addedLines.append(String(line.dropFirst()))
                    currentHunk = h
                }
            }
        }

        if let h = currentHunk {
            hunks.append(h)
        }

        return hunks
    }
}
