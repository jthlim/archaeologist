import Foundation
import AppKit

public struct RepoContext {
    public let vcsType: VCSType
    public let repoRoot: URL
    public let relativePath: String
    public let fullURL: URL
    public let hgBinary: String

    public var filename: String {
        fullURL.lastPathComponent
    }

    public init(
        vcsType: VCSType,
        repoRoot: URL,
        relativePath: String,
        fullURL: URL,
        hgBinary: String? = nil
    ) {
        self.vcsType = vcsType
        self.repoRoot = repoRoot.standardizedFileURL
        self.relativePath = relativePath
        self.fullURL = fullURL.standardizedFileURL
        if let hgBinary = hgBinary {
            self.hgBinary = hgBinary
        } else if vcsType == .hg {
            self.hgBinary = VCSManager.shared.hgBinary(for: repoRoot)
        } else {
            self.hgBinary = "hg"
        }
    }
}

public final class VCSManager: @unchecked Sendable {
    public static let shared = VCSManager()

    private let hgBinaryLock = NSLock()
    private var hgBinaryByRepo: [URL: String] = [:]

    public static func runHg(arguments: [String], currentDirectory: URL?, timeout: TimeInterval? = nil) -> ProcessResult? {
        let binary = currentDirectory.map { VCSManager.shared.hgBinary(for: $0) } ?? (ProcessRunner.resolveBinaryPath(named: "chg") != nil ? "chg" : "hg")
        return try? ProcessRunner.run(binary: binary, arguments: arguments, currentDirectory: currentDirectory, timeout: timeout)
    }

    public nonisolated func hgBinary(for repoRoot: URL) -> String {
        hgBinaryLock.lock()
        defer { hgBinaryLock.unlock() }
        let standardRoot = repoRoot.standardizedFileURL
        if let existing = hgBinaryByRepo[standardRoot] {
            return existing
        }
        let binary = ProcessRunner.resolveBinaryPath(named: "chg") != nil ? "chg" : "hg"
        hgBinaryByRepo[standardRoot] = binary
        return binary
    }

    public nonisolated func setHgBinary(_ binary: String, for repoRoot: URL) {
        hgBinaryLock.lock()
        defer { hgBinaryLock.unlock() }
        hgBinaryByRepo[repoRoot.standardizedFileURL] = binary
    }

    public nonisolated func clearHgBinaryCache() {
        hgBinaryLock.lock()
        defer { hgBinaryLock.unlock() }
        hgBinaryByRepo.removeAll()
    }

    private let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let hgIsoDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm Z"
        return df
    }()

    private static let hgIsoSecDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return df
    }()

    public init() {}

    // MARK: - Detect Repository & Context
    public nonisolated func detectContext(for fileURL: URL, preferredVCS: VCSType? = nil) -> RepoContext? {
        let standardURL = fileURL.standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: standardURL.path, isDirectory: &isDir)
        var currentDir = (exists && isDir.boolValue) ? standardURL : (standardURL.hasDirectoryPath ? standardURL : standardURL.deletingLastPathComponent())

        var fallbackOtherContext: RepoContext? = nil

        // Traverse upwards looking for .git or .hg
        while currentDir.path != "/" && !currentDir.path.isEmpty {
            let gitPath = currentDir.appendingPathComponent(".git")
            let hgPath = currentDir.appendingPathComponent(".hg")

            var isGitDir: ObjCBool = false
            var isHgDir: ObjCBool = false
            let hasGit = FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isGitDir)
            let hasHg = FileManager.default.fileExists(atPath: hgPath.path, isDirectory: &isHgDir) && isHgDir.boolValue

            if let preferred = preferredVCS {
                switch preferred {
                case .hg:
                    if hasHg {
                        let relative = relativePath(from: currentDir, to: standardURL)
                        return RepoContext(vcsType: .hg, repoRoot: currentDir, relativePath: relative, fullURL: standardURL)
                    }
                    if hasGit && fallbackOtherContext == nil {
                        let relative = relativePath(from: currentDir, to: standardURL)
                        fallbackOtherContext = RepoContext(vcsType: .git, repoRoot: currentDir, relativePath: relative, fullURL: standardURL)
                    }
                case .git:
                    if hasGit {
                        let relative = relativePath(from: currentDir, to: standardURL)
                        return RepoContext(vcsType: .git, repoRoot: currentDir, relativePath: relative, fullURL: standardURL)
                    }
                    if hasHg && fallbackOtherContext == nil {
                        let relative = relativePath(from: currentDir, to: standardURL)
                        fallbackOtherContext = RepoContext(vcsType: .hg, repoRoot: currentDir, relativePath: relative, fullURL: standardURL)
                    }
                }
            } else {
                // Default: closest repo wins (if both present at same level, prefer git)
                if hasGit {
                    let relative = relativePath(from: currentDir, to: standardURL)
                    return RepoContext(vcsType: .git, repoRoot: currentDir, relativePath: relative, fullURL: standardURL)
                }
                if hasHg {
                    let relative = relativePath(from: currentDir, to: standardURL)
                    return RepoContext(vcsType: .hg, repoRoot: currentDir, relativePath: relative, fullURL: standardURL)
                }
            }

            let parent = currentDir.deletingLastPathComponent()
            if parent.path == currentDir.path { break }
            currentDir = parent
        }

        // If we found a non-preferred repo during upward search, and no preferred repo was found in entire parent tree
        if let fallback = fallbackOtherContext {
            return fallback
        }

        // Fallbacks using CLI commands
        let dir = standardURL.hasDirectoryPath ? standardURL : standardURL.deletingLastPathComponent()
        let tryGit = { () -> RepoContext? in
            if let result = try? ProcessRunner.run(binary: "git", arguments: ["rev-parse", "--show-toplevel"], currentDirectory: dir),
               result.isSuccess {
                let rootPath = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rootPath.isEmpty {
                    let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
                    let relative = self.relativePath(from: rootURL, to: standardURL)
                    return RepoContext(vcsType: .git, repoRoot: rootURL, relativePath: relative, fullURL: standardURL)
                }
            }
            return nil
        }

        let tryHg = { () -> RepoContext? in
            if let result = VCSManager.runHg(arguments: ["root"], currentDirectory: dir, timeout: 5.0),
               result.isSuccess {
                let rootPath = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rootPath.isEmpty {
                    let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
                    let relative = self.relativePath(from: rootURL, to: standardURL)
                    return RepoContext(vcsType: .hg, repoRoot: rootURL, relativePath: relative, fullURL: standardURL)
                }
            }
            return nil
        }

        if preferredVCS == .hg {
            if let ctx = tryHg() { return ctx }
            if let ctx = tryGit() { return ctx }
        } else {
            if let ctx = tryGit() { return ctx }
            if let ctx = tryHg() { return ctx }
        }

        return nil
    }

    private func relativePath(from base: URL, to target: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        if targetPath.hasPrefix(basePath) {
            var rel = String(targetPath.dropFirst(basePath.count))
            if rel.hasPrefix("/") {
                rel = String(rel.dropFirst())
            }
            return rel
        }
        return target.lastPathComponent
    }

    // MARK: - Commit History
    public nonisolated func fetchCommits(for context: RepoContext) throws -> [CommitInfo] {
        var commits: [CommitInfo]
        switch context.vcsType {
        case .git:
            commits = try fetchGitCommits(context: context)
        case .hg:
            commits = try fetchHgCommits(context: context)
        }

        if hasWorkingCopyChanges(context: context) {
            let uncommitted = createUncommittedCommit(context: context, index: commits.count)
            commits.append(uncommitted)
        }

        return reindexCommits(commits)
    }

    public nonisolated func hasWorkingCopyChanges(context: RepoContext) -> Bool {
        switch context.vcsType {
        case .git:
            let args = ["--no-optional-locks", "status", "--porcelain", "--", context.relativePath]
            guard let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return false
            }
            return !result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .hg:
            let args = ["status", context.relativePath]
            guard let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return false
            }
            return !result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public nonisolated func hasRepositoryWorkingCopyChanges(context: RepoContext) -> Bool {
        return !fetchWorkingCopyChanges(context: context).isEmpty
    }

    public nonisolated func fetchCurrentUser(context: RepoContext) -> (name: String, email: String) {
        switch context.vcsType {
        case .git:
            let nameResult = try? ProcessRunner.run(binary: "git", arguments: ["config", "user.name"], currentDirectory: context.repoRoot)
            let emailResult = try? ProcessRunner.run(binary: "git", arguments: ["config", "user.email"], currentDirectory: context.repoRoot)
            let name = nameResult?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let email = emailResult?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (CommitInfo.cleanAuthorName(name), email)
        case .hg:
            let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: ["showconfig", "ui.username"], currentDirectory: context.repoRoot, timeout: 5.0)
            let raw = result?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.contains("<") && raw.contains(">") {
                let parts = raw.components(separatedBy: "<")
                let name = CommitInfo.cleanAuthorName(parts[0])
                let email = parts[1].replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
                return (name, email)
            }
            return (CommitInfo.cleanAuthorName(raw), "")
        }
    }

    public nonisolated func fetchWorkingCopyDelta(context: RepoContext) -> (added: Int, removed: Int) {
        switch context.vcsType {
        case .git:
            var totalAdded = 0
            var totalRemoved = 0
            let diffArgs = ["--no-optional-locks", "diff", "--numstat", "--", context.relativePath]
            if let result = try? ProcessRunner.run(binary: "git", arguments: diffArgs, currentDirectory: context.repoRoot),
               result.isSuccess {
                for line in result.stdoutString.components(separatedBy: "\n") {
                    let parts = line.components(separatedBy: "\t")
                    if parts.count >= 2 {
                        totalAdded += Int(parts[0]) ?? 0
                        totalRemoved += Int(parts[1]) ?? 0
                    }
                }
            }
            let cachedArgs = ["--no-optional-locks", "diff", "--cached", "--numstat", "--", context.relativePath]
            if let result = try? ProcessRunner.run(binary: "git", arguments: cachedArgs, currentDirectory: context.repoRoot),
               result.isSuccess {
                for line in result.stdoutString.components(separatedBy: "\n") {
                    let parts = line.components(separatedBy: "\t")
                    if parts.count >= 2 {
                        totalAdded += Int(parts[0]) ?? 0
                        totalRemoved += Int(parts[1]) ?? 0
                    }
                }
            }
            return (totalAdded, totalRemoved)
        case .hg:
            let args = ["diff", "--stat", context.relativePath]
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                let out = result.stdoutString
                var added = 0
                var removed = 0
                if let insRange = out.range(of: " insertions(+)") {
                    let before = out[..<insRange.lowerBound]
                    if let numStr = before.split(separator: " ").last {
                        added = Int(numStr) ?? 0
                    }
                } else if let insRange = out.range(of: " insertion(+)") {
                    let before = out[..<insRange.lowerBound]
                    if let numStr = before.split(separator: " ").last {
                        added = Int(numStr) ?? 0
                    }
                }
                if let delRange = out.range(of: " deletions(-)") {
                    let before = out[..<delRange.lowerBound]
                    if let numStr = before.split(separator: " ").last {
                        removed = Int(numStr) ?? 0
                    }
                } else if let delRange = out.range(of: " deletion(-)") {
                    let before = out[..<delRange.lowerBound]
                    if let numStr = before.split(separator: " ").last {
                        removed = Int(numStr) ?? 0
                    }
                }
                return (added, removed)
            }
            return (0, 0)
        }
    }

    public static func parseGitNumstatPath(_ raw: String) -> (oldPath: String?, newPath: String) {
        if let openBrace = raw.range(of: "{"),
           let closeBrace = raw.range(of: "}", range: openBrace.upperBound..<raw.endIndex),
           let arrow = raw.range(of: " => ", range: openBrace.upperBound..<closeBrace.lowerBound) {
            let prefix = String(raw[..<openBrace.lowerBound])
            let suffix = String(raw[closeBrace.upperBound...])
            let oldPart = String(raw[openBrace.upperBound..<arrow.lowerBound])
            let newPart = String(raw[arrow.upperBound..<closeBrace.lowerBound])
            let oldPath = prefix + oldPart + suffix
            let newPath = prefix + newPart + suffix
            return (oldPath, newPath)
        } else if let arrow = raw.range(of: " => ") {
            let oldPath = String(raw[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let newPath = String(raw[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (oldPath, newPath)
        } else {
            return (nil, raw.trimmingCharacters(in: .whitespaces))
        }
    }

    public nonisolated func createUncommittedCommit(context: RepoContext, index: Int = 0) -> CommitInfo {
        let fileModDate: Date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: context.fullURL.path),
           let mod = attrs[.modificationDate] as? Date {
            fileModDate = mod
        } else {
            fileModDate = Date()
        }

        let (user, email) = fetchCurrentUser(context: context)
        let author = user.isEmpty ? "Working Directory" : user
        let delta = fetchWorkingCopyDelta(context: context)

        return CommitInfo(
            id: CommitInfo.uncommittedHash,
            displayRevision: CommitInfo.uncommittedRevision,
            fullRevision: "Working Directory",
            author: author,
            authorEmail: email,
            date: fileModDate,
            dateFormatted: displayDateFormatter.string(from: fileModDate),
            summary: "Uncommitted changes",
            fullMessage: "Uncommitted changes in working directory",
            index: index,
            filePath: context.relativePath,
            addedCount: delta.added,
            removedCount: delta.removed
        )
    }

    private func fetchGitCommits(context: RepoContext) throws -> [CommitInfo] {
        // Delimiter \x1e at record start, \x1f between fields
        let format = "\u{1e}%H\u{1f}%h\u{1f}%an\u{1f}%ae\u{1f}%ad\u{1f}%s\u{1f}%B\u{1f}"
        let args = [
            "log",
            "-m",
            "--follow",
            "-M",
            "--name-status",
            "--format=\(format)",
            "--date=iso-strict",
            "--",
            context.relativePath
        ]

        let result = try ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot)
        guard result.isSuccess else {
            throw NSError(
                domain: "VCSManager",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderrString.isEmpty ? "Failed to fetch Git log" : result.stderrString]
            )
        }

        let output = result.stdoutString
        let parsed = parseDelimitedCommits(output: output, isHg: false, startPath: context.relativePath)
        // Reverse newest-first output into chronological order (oldest to newest)
        return reindexCommits(Array(parsed.reversed()))
    }

    private func fetchHgCommits(context: RepoContext) throws -> [CommitInfo] {
        // -f / --follow follows file history across copies and renames
        let template = "\u{1e}{node}\u{1f}{rev}:{node|short}\u{1f}{author|person}\u{1f}{author|email}\u{1f}{date|hgdate}\u{1f}{desc|firstline}\u{1f}{desc}\u{1f}{file_copies % '{name}===>{source}\\n'}\u{1f}"
        let args = [
            "log",
            "-f",
            "--template", template,
            context.relativePath
        ]

        let result = try ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot)
        guard result.isSuccess else {
            throw NSError(
                domain: "VCSManager",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderrString.isEmpty ? "Failed to fetch Mercurial log" : result.stderrString]
            )
        }

        let output = result.stdoutString
        let parsed = parseDelimitedCommits(output: output, isHg: true, startPath: context.relativePath)
        // Reverse newest-first output into chronological order (oldest to newest)
        return reindexCommits(Array(parsed.reversed()))
    }

    private func reindexCommits(_ list: [CommitInfo]) -> [CommitInfo] {
        return list.enumerated().map { (idx, c) in
            var renameSrc = c.renamedFromPath
            if renameSrc == nil && idx > 0 {
                if let prevPath = list[idx - 1].filePath, let curPath = c.filePath, prevPath != curPath {
                    renameSrc = prevPath
                }
            }
            return CommitInfo(
                id: c.id,
                displayRevision: c.displayRevision,
                fullRevision: c.fullRevision,
                author: c.author,
                authorEmail: c.authorEmail,
                date: c.date,
                dateFormatted: c.dateFormatted,
                summary: c.summary,
                fullMessage: c.fullMessage,
                index: idx,
                filePath: c.filePath,
                addedCount: c.addedCount,
                removedCount: c.removedCount,
                renamedFromPath: renameSrc
            )
        }
    }

    private func parseDelimitedCommits(output: String, isHg: Bool, startPath: String) -> [CommitInfo] {
        let records = output.components(separatedBy: "\u{1e}")
        var commits: [CommitInfo] = []
        var seenHashes = Set<String>()
        var currentPath = startPath

        for record in records {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let fields = record.components(separatedBy: "\u{1f}")
            guard fields.count >= 7 else { continue }

            let fullHash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if seenHashes.contains(fullHash) {
                continue
            }
            seenHashes.insert(fullHash)
            var displayRev = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if isHg {
                displayRev = CommitInfo.shortenRevision(displayRev)
            }
            let rawAuthor = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let author = CommitInfo.cleanAuthorName(rawAuthor)
            let authorEmail = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawDate = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
            let fullMsg = fields[6].trimmingCharacters(in: .whitespacesAndNewlines)

            let parsedDate = parseDateString(rawDate)
            let formattedDate = displayDateFormatter.string(from: parsedDate)

            var commitAdded: Int? = nil
            var commitRemoved: Int? = nil

            var nextPath = currentPath
            var renameSource: String? = nil

            // Follow rename backwards to source path and extract deltas
            if isHg {
                if fields.count >= 8 {
                    let copiesText = fields[7]
                    for copyLine in copiesText.components(separatedBy: "\n") {
                        let parts = copyLine.components(separatedBy: "===>")
                        if parts.count == 2 {
                            let target = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            let source = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            if target == currentPath || currentPath.hasSuffix("/" + target) || target.hasSuffix("/" + currentPath) {
                                nextPath = source
                                renameSource = source
                                break
                            }
                        }
                    }
                }
                if fields.count >= 9 {
                    let diffstat = fields[8].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let plusRange = diffstat.range(of: "+"),
                       let slashRange = diffstat.range(of: "/-", range: plusRange.upperBound..<diffstat.endIndex) {
                        let addedStr = diffstat[plusRange.upperBound..<slashRange.lowerBound]
                        let removedStr = diffstat[slashRange.upperBound...]
                        commitAdded = Int(addedStr)
                        commitRemoved = Int(removedStr.split(whereSeparator: { !$0.isNumber }).first ?? "")
                    }
                }
            } else if !isHg && fields.count >= 8 {
                let statusText = fields[7]
                for line in statusText.components(separatedBy: "\n") {
                    let parts = line.components(separatedBy: "\t")
                    if parts.count >= 3 && parts[0].hasPrefix("R") {
                        let oldPath = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        let newPath = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        if newPath == currentPath || currentPath.hasSuffix("/" + newPath) || newPath.hasSuffix("/" + currentPath) {
                            nextPath = oldPath
                            renameSource = oldPath
                            break
                        }
                    } else if parts.count >= 3 {
                        if let add = Int(parts[0]), let rem = Int(parts[1]) {
                            commitAdded = add
                            commitRemoved = rem
                        }
                        let pathRaw = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        let (maybeOld, maybeNew) = VCSManager.parseGitNumstatPath(pathRaw)
                        if let old = maybeOld {
                            if maybeNew == currentPath || currentPath.hasSuffix("/" + maybeNew) || maybeNew.hasSuffix("/" + currentPath) {
                                nextPath = old
                                renameSource = old
                                break
                            }
                        }
                    }
                }
            }

            let commit = CommitInfo(
                id: fullHash,
                displayRevision: displayRev,
                fullRevision: fullHash,
                author: author.isEmpty ? "Unknown" : author,
                authorEmail: authorEmail,
                date: parsedDate,
                dateFormatted: formattedDate,
                summary: summary.isEmpty ? "No commit message" : summary,
                fullMessage: fullMsg.isEmpty ? summary : fullMsg,
                index: commits.count,
                filePath: currentPath,
                addedCount: commitAdded,
                removedCount: commitRemoved,
                renamedFromPath: renameSource
            )
            commits.append(commit)
            currentPath = nextPath
        }

        return commits
    }

    private func parseDateString(_ raw: String) -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Date() }

        // Fast path for Mercurial hgdate format: "<unix_timestamp> <tz_offset_seconds>"
        if let spaceIdx = trimmed.firstIndex(of: " ") {
            let firstPart = trimmed[..<spaceIdx]
            if let sec = Double(firstPart) {
                return Date(timeIntervalSince1970: sec)
            }
        } else if let sec = Double(trimmed) {
            return Date(timeIntervalSince1970: sec)
        }

        // Fast path for ISO8601 (Git iso-strict)
        if let d = isoDateFormatter.date(from: trimmed) ?? fallbackDateFormatter.date(from: trimmed) {
            return d
        }

        // Static cached formatters for legacy Mercurial isodate ("yyyy-MM-dd HH:mm Z")
        if let d = Self.hgIsoDateFormatter.date(from: trimmed) ?? Self.hgIsoSecDateFormatter.date(from: trimmed) {
            return d
        }

        return Date()
    }

    // MARK: - File Content at Revision
    public func isImageFile(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "bmp",
            "tiff", "tif", "ico", "icns", "heic", "heif", "svg"
        ]
        return imageExts.contains(ext)
    }

    /// Checks up to the first 4KB for a nul byte (0x00). If present, the file is tagged as binary.
    public static func isBinaryFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 4096)
        return header.contains(0)
    }

    /// Checks up to the first 4KB of data for a nul byte (0x00).
    public static func isBinaryData(_ data: Data) -> Bool {
        data.prefix(4096).contains(0)
    }

    public nonisolated func fetchFileContent(
        context: RepoContext,
        commit: CommitInfo
    ) throws -> FileRevisionContent {
        let isImage = isImageFile(filename: context.filename)
        let filePath = commit.filePath ?? context.relativePath

        let data: Data
        if commit.isUncommitted {
            do {
                data = try Data(contentsOf: context.fullURL)
            } catch {
                return FileRevisionContent(
                    isImage: isImage,
                    binaryData: nil,
                    textLines: [],
                    rawText: "",
                    errorMessage: "File not present in working directory: \(error.localizedDescription)"
                )
            }
        } else {
            switch context.vcsType {
            case .git:
                // git show <commit>:<filePath>
                let spec = "\(commit.id):\(filePath)"
                let result = try ProcessRunner.run(binary: "git", arguments: ["show", spec], currentDirectory: context.repoRoot)
                if !result.isSuccess {
                    return FileRevisionContent(
                        isImage: isImage,
                        binaryData: nil,
                        textLines: [],
                        rawText: "",
                        errorMessage: "File not present or deleted in this revision: \(result.stderrString)"
                    )
                }
                data = result.stdoutData

            case .hg:
                // hg cat -r <rev> <filePath>
                let result = try ProcessRunner.run(binary: context.hgBinary, arguments: ["cat", "-r", commit.id, filePath], currentDirectory: context.repoRoot)
                if !result.isSuccess {
                    return FileRevisionContent(
                        isImage: isImage,
                        binaryData: nil,
                        textLines: [],
                        rawText: "",
                        errorMessage: "File not present or deleted in this revision: \(result.stderrString)"
                    )
                }
                data = result.stdoutData
            }
        }

        if isImage {
            return FileRevisionContent(
                isImage: true,
                isBinary: true,
                binaryData: data,
                textLines: [],
                rawText: ""
            )
        }

        // Check up to the first 4KB for a nul byte
        let isBinary = data.prefix(4096).contains(0)
        if isBinary {
            return FileRevisionContent(
                isImage: false,
                isBinary: true,
                binaryData: data,
                textLines: [],
                rawText: ""
            )
        }

        // Text file
        let rawText = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? String(decoding: data, as: UTF8.self)

        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let cleanLines = normalized.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        }

        // Fetch blame lines
        let blameLines = (try? fetchBlame(context: context, commit: commit, cleanLines: cleanLines)) ?? fallbackBlameLines(cleanLines: cleanLines, commit: commit)

        // Interleave removed lines and detect added lines from commit diff
        let diffChanges = fetchDiffChanges(context: context, commit: commit)
        let deletionsMap = diffChanges.deletions
        let addedLinesSet = diffChanges.addedLines

        // Determine consistent revision, author, and date for deleted lines
        let commitShortRev: String
        if commit.isUncommitted {
            commitShortRev = CommitInfo.uncommittedRevision
        } else {
            switch context.vcsType {
            case .git:
                commitShortRev = String(commit.id.prefix(7))
            case .hg:
                let parts = commit.displayRevision.split(separator: ":").map(String.init)
                commitShortRev = parts.first ?? commit.displayRevision
            }
        }

        let commitAuthor: String
        if let matching = blameLines.first(where: { $0.isChangedInCurrentCommit && !$0.author.isEmpty })?.author {
            commitAuthor = matching
        } else {
            commitAuthor = CommitInfo.cleanAuthorName(commit.author)
        }

        let commitDateStr: String = VCSManager.formatBlameDate(commit.date)

        var interleavedLines: [BlameLine] = []

        for (idx, line) in blameLines.enumerated() {
            let lineNum = idx + 1
            if let removedList = deletionsMap[lineNum] {
                for (remIdx, removedContent) in removedList.enumerated() {
                    interleavedLines.append(BlameLine(
                        id: "rem_\(commit.id)_\(lineNum)_\(remIdx)",
                        lineNumber: nil,
                        revision: commitShortRev,
                        author: commitAuthor,
                        authorEmail: commit.authorEmail,
                        date: commit.date,
                        dateString: commitDateStr,
                        content: removedContent,
                        isChangedInCurrentCommit: true,
                        changeType: .removed
                    ))
                }
            }

            var updatedLine = line
            let isAddedInDiff = addedLinesSet.contains(lineNum)
            if isAddedInDiff {
                updatedLine.isChangedInCurrentCommit = true
                updatedLine.changeType = .added
            } else if commit.renamedFromPath != nil || !addedLinesSet.isEmpty || !deletionsMap.isEmpty {
                updatedLine.isChangedInCurrentCommit = false
                updatedLine.changeType = .unchanged
            } else if updatedLine.isChangedInCurrentCommit {
                updatedLine.changeType = .added
            }
            interleavedLines.append(updatedLine)
        }

        // Trailing deletions after the last line
        let trailingKey = blameLines.count + 1
        if let trailingList = deletionsMap[trailingKey] {
            for (remIdx, removedContent) in trailingList.enumerated() {
                interleavedLines.append(BlameLine(
                    id: "rem_tail_\(commit.id)_\(remIdx)",
                    lineNumber: nil,
                    revision: commitShortRev,
                    author: commitAuthor,
                    authorEmail: commit.authorEmail,
                    date: commit.date,
                    dateString: commitDateStr,
                    content: removedContent,
                    isChangedInCurrentCommit: true,
                    changeType: .removed
                ))
            }
        }

        return FileRevisionContent(
            isImage: false,
            binaryData: data,
            textLines: interleavedLines,
            rawText: normalized
        )
    }

    // MARK: - Files in Commit
    public nonisolated func fetchFilesInCommit(context: RepoContext, commit: CommitInfo) -> [String] {
        if commit.isUncommitted {
            return fetchUncommittedFiles(context: context)
        }
        switch context.vcsType {
        case .git:
            let args = ["diff-tree", "-m", "--no-commit-id", "--name-only", "-r", "--root", commit.id]
            guard let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return []
            }
            let lines = result.stdoutString
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(Set(lines)).sorted()

        case .hg:
            let args = ["status", "--change", commit.id, "-n"]
            guard let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return []
            }
            let lines = result.stdoutString
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(Set(lines)).sorted()
        }
    }

    public nonisolated func fetchUncommittedFiles(context: RepoContext) -> [String] {
        switch context.vcsType {
        case .git:
            let args = ["status", "--porcelain"]
            guard let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return []
            }
            var files: [String] = []
            for line in result.stdoutString.components(separatedBy: .newlines) {
                guard line.count >= 3 else { continue }
                let pathPart = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !pathPart.isEmpty {
                    if pathPart.contains(" -> ") {
                        let target = pathPart.components(separatedBy: " -> ").last ?? pathPart
                        files.append(target.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                    } else {
                        files.append(pathPart.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                    }
                }
            }
            return Array(Set(files)).sorted()
        case .hg:
            let args = ["status", "-m", "-a", "-r", "-n"]
            guard let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return []
            }
            let lines = result.stdoutString
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(Set(lines)).sorted()
        }
    }

    // MARK: - Repository Working Directory Files & Statuses
    public nonisolated func fetchRepositoryFileStatuses(context: RepoContext) -> [String: FileWorkingStatus] {
        var statuses: [String: FileWorkingStatus] = [:]
        switch context.vcsType {
        case .git:
            // 1. Get all tracked files (clean by default)
            let lsArgs = ["--no-optional-locks", "ls-files", "--cached"]
            if let result = try? ProcessRunner.run(binary: "git", arguments: lsArgs, currentDirectory: context.repoRoot),
               result.isSuccess {
                for line in result.stdoutString.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        statuses[trimmed] = .clean
                    }
                }
            }

            // 2. Query status for modified, added, deleted, unknown
            let statusArgs = ["--no-optional-locks", "status", "--porcelain=v1", "-uall"]
            if let result = try? ProcessRunner.run(binary: "git", arguments: statusArgs, currentDirectory: context.repoRoot),
               result.isSuccess {
                for rawLine in result.stdoutString.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .newlines)
                    guard line.count >= 3 else { continue }
                    let code = String(line.prefix(2))
                    var filePath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if filePath.hasPrefix("\"") && filePath.hasSuffix("\"") && filePath.count >= 2 {
                        filePath = String(filePath.dropFirst().dropLast())
                    }

                    if code.contains("R") || line.contains(" -> ") {
                        if let arrowRange = filePath.range(of: " -> ") {
                            let oldPath = String(filePath[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                            let newPath = String(filePath[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                            statuses[oldPath] = .deleted
                            statuses[newPath] = .new
                            continue
                        }
                    }

                    let x = code.first ?? " "
                    let y = code.last ?? " "

                    if code == "??" {
                        statuses[filePath] = .unknown
                    } else if x == "A" || y == "A" {
                        statuses[filePath] = .new
                    } else if x == "D" || y == "D" {
                        statuses[filePath] = .deleted
                    } else if x == "M" || y == "M" || x == "U" || y == "U" {
                        statuses[filePath] = .modified
                    }
                }
            }

        case .hg:
            // 1. Get all tracked files (clean by default) via hg files
            let filesArgs = ["files"]
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: filesArgs, currentDirectory: context.repoRoot),
               result.isSuccess {
                for line in result.stdoutString.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        statuses[trimmed] = .clean
                    }
                }
            }

            // 2. Query status for modified, added, removed, missing, unknown via hg status
            let statusArgs = ["status"]
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: statusArgs, currentDirectory: context.repoRoot),
               result.isSuccess {
                for rawLine in result.stdoutString.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .newlines)
                    guard line.count >= 2 else { continue }
                    let code = line.first!
                    let filePath = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    guard !filePath.isEmpty else { continue }
                    switch code {
                    case "?":
                        statuses[filePath] = .unknown
                    case "A":
                        statuses[filePath] = .new
                    case "R", "!":
                        statuses[filePath] = .deleted
                    case "M":
                        statuses[filePath] = .modified
                    case "C":
                        statuses[filePath] = .clean
                    default:
                        break
                    }
                }
            }
        }

        // If VCS returned nothing or failed, fallback to filesystem enumeration as clean
        if statuses.isEmpty {
            for rel in enumerateFilesOnDisk(at: context.repoRoot) {
                statuses[rel] = .clean
            }
        }

        return statuses
    }

    // MARK: - File Operations (Add, Discard Changes, Delete)
    public nonisolated func addFile(context: RepoContext, relativePath: String) throws {
        switch context.vcsType {
        case .git:
            let res = try ProcessRunner.run(binary: "git", arguments: ["add", relativePath], currentDirectory: context.repoRoot)
            if !res.isSuccess {
                throw NSError(domain: "VCSManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to add \(relativePath): \(res.stderrString)"])
            }
        case .hg:
            let res = try ProcessRunner.run(binary: context.hgBinary, arguments: ["add", relativePath], currentDirectory: context.repoRoot)
            if !res.isSuccess {
                throw NSError(domain: "VCSManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to add \(relativePath): \(res.stderrString)"])
            }
        }
    }

    public nonisolated func discardChanges(context: RepoContext, relativePath: String, status: FileWorkingStatus) throws {
        switch context.vcsType {
        case .git:
            if status == .new {
                // If it was a newly added file, unstage it (remove from index) so it becomes untracked again.
                // Do NOT delete the file from disk!
                _ = try? ProcessRunner.run(binary: "git", arguments: ["reset", "HEAD", "--", relativePath], currentDirectory: context.repoRoot)
                _ = try? ProcessRunner.run(binary: "git", arguments: ["rm", "--cached", "-f", "--", relativePath], currentDirectory: context.repoRoot)
            } else {
                // Unstage if staged
                _ = try? ProcessRunner.run(binary: "git", arguments: ["reset", "HEAD", "--", relativePath], currentDirectory: context.repoRoot)
                // Revert working tree to HEAD
                let res = try ProcessRunner.run(binary: "git", arguments: ["checkout", "HEAD", "--", relativePath], currentDirectory: context.repoRoot)
                if !res.isSuccess {
                    throw NSError(domain: "VCSManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to checkout \(relativePath): \(res.stderrString)"])
                }
            }
        case .hg:
            if status == .new {
                // For a newly added file in hg, forget it so it returns to untracked state without deleting it from disk.
                _ = try? ProcessRunner.run(binary: context.hgBinary, arguments: ["forget", relativePath], currentDirectory: context.repoRoot)
            } else {
                let res = try ProcessRunner.run(binary: context.hgBinary, arguments: ["revert", "--no-backup", relativePath], currentDirectory: context.repoRoot)
                if !res.isSuccess {
                    throw NSError(domain: "VCSManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to revert \(relativePath): \(res.stderrString)"])
                }
            }
        }
    }

    public nonisolated func deleteFile(context: RepoContext, relativePath: String, status: FileWorkingStatus) throws {
        let fullPath = context.repoRoot.appendingPathComponent(relativePath).standardizedFileURL
        if status == .unknown {
            if FileManager.default.fileExists(atPath: fullPath.path) {
                try FileManager.default.removeItem(at: fullPath)
            }
            return
        }

        switch context.vcsType {
        case .git:
            let res = try ProcessRunner.run(binary: "git", arguments: ["rm", "-f", "--", relativePath], currentDirectory: context.repoRoot)
            if !res.isSuccess {
                if FileManager.default.fileExists(atPath: fullPath.path) {
                    try? FileManager.default.removeItem(at: fullPath)
                }
                _ = try? ProcessRunner.run(binary: "git", arguments: ["rm", "--", relativePath], currentDirectory: context.repoRoot)
            }
        case .hg:
            let res = try ProcessRunner.run(binary: context.hgBinary, arguments: ["rm", "-f", relativePath], currentDirectory: context.repoRoot)
            if !res.isSuccess {
                if FileManager.default.fileExists(atPath: fullPath.path) {
                    try? FileManager.default.removeItem(at: fullPath)
                }
                _ = try? ProcessRunner.run(binary: context.hgBinary, arguments: ["rm", relativePath], currentDirectory: context.repoRoot)
            }
        }
    }

    @discardableResult
    public nonisolated func commit(context: RepoContext, files: [String], message: String) throws -> CommitInfo? {
        guard !files.isEmpty else {
            throw NSError(domain: "VCSManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "No files selected for commit"])
        }
        let trimmedMsg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMsg.isEmpty else {
            throw NSError(domain: "VCSManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Commit message cannot be empty"])
        }

        switch context.vcsType {
        case .git:
            // 1. Stage selected files (handles new, modified, deleted)
            var existingFiles: [String] = []
            var missingFiles: [String] = []
            for file in files {
                let fileURL = context.repoRoot.appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    existingFiles.append(file)
                } else {
                    missingFiles.append(file)
                }
            }

            if !existingFiles.isEmpty {
                let addArgs = ["add", "-A", "--"] + existingFiles
                let addRes = try ProcessRunner.run(binary: "git", arguments: addArgs, currentDirectory: context.repoRoot)
                if !addRes.isSuccess {
                    throw NSError(domain: "VCSManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to stage files: \(addRes.stderrString)"])
                }
            }

            if !missingFiles.isEmpty {
                let rmArgs = ["rm", "--ignore-unmatch", "--"] + missingFiles
                let rmRes = try ProcessRunner.run(binary: "git", arguments: rmArgs, currentDirectory: context.repoRoot)
                if !rmRes.isSuccess {
                    throw NSError(domain: "VCSManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to stage removed files: \(rmRes.stderrString)"])
                }
            }

            // 2. Commit selected files
            let commitArgs = ["commit", "-m", trimmedMsg, "--"] + files
            let commitRes = try ProcessRunner.run(binary: "git", arguments: commitArgs, currentDirectory: context.repoRoot)
            if !commitRes.isSuccess {
                throw NSError(domain: "VCSManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to commit: \(commitRes.stderrString)"])
            }

        case .hg:
            // 1. Addremove on selected files to track newly created or mark removed files
            let addremoveArgs = ["addremove"] + files
            _ = try? ProcessRunner.run(binary: context.hgBinary, arguments: addremoveArgs, currentDirectory: context.repoRoot)

            // 2. Commit selected files
            let commitArgs = ["commit", "-m", trimmedMsg] + files
            let commitRes = try ProcessRunner.run(binary: context.hgBinary, arguments: commitArgs, currentDirectory: context.repoRoot)
            if !commitRes.isSuccess {
                throw NSError(domain: "VCSManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to commit: \(commitRes.stderrString)"])
            }
        }

        return fetchHeadCommit(context: context)
    }

    public nonisolated func fetchHeadCommit(context: RepoContext) -> CommitInfo? {
        let activeBranch = fetchActiveBranch(context: context)
        switch context.vcsType {
        case .git:
            let format = "\u{1e}%H\u{1f}%h\u{1f}%P\u{1f}%an\u{1f}%ae\u{1f}%ad\u{1f}%s\u{1f}%B\u{1f}"
            let args = ["--no-optional-locks", "log", "-1", "--date=iso-strict", "--format=\(format)", "HEAD"]
            guard let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return nil
            }
            if let entry = parseRepositoryCommits(output: result.stdoutString, isHg: false).first {
                var c = entry.commit
                if let b = activeBranch, !b.isEmpty {
                    c.branches = [b]
                }
                return c
            }
            return nil

        case .hg:
            let template = "\u{1e}{node}\u{1f}{rev}:{node|short}\u{1f}{p1node} {p2node}\u{1f}{author|person}\u{1f}{author|email}\u{1f}{date|hgdate}\u{1f}{desc|firstline}\u{1f}{desc}\u{1f}"
            let args = ["log", "-r", ".", "--template", template]
            guard let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return nil
            }
            if let entry = parseRepositoryCommits(output: result.stdoutString, isHg: true).first {
                var c = entry.commit
                if let b = activeBranch, !b.isEmpty {
                    c.branches = [b]
                }
                return c
            }
            return nil
        }
    }

    public nonisolated func fetchActiveBranch(context: RepoContext) -> String? {
        switch context.vcsType {
        case .git:
            if let res = try? ProcessRunner.run(
                binary: "git",
                arguments: ["--no-optional-locks", "branch", "--show-current"],
                currentDirectory: context.repoRoot
            ), res.isSuccess {
                let b = res.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !b.isEmpty { return b }
            }
            return nil
        case .hg:
            // Check active bookmark first
            if let res = try? ProcessRunner.run(
                binary: context.hgBinary,
                arguments: ["id", "-B"],
                currentDirectory: context.repoRoot
            ), res.isSuccess {
                let bm = res.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !bm.isEmpty { return bm }
            }
            // Fall back to named branch
            if let res = try? ProcessRunner.run(
                binary: context.hgBinary,
                arguments: ["branch"],
                currentDirectory: context.repoRoot
            ), res.isSuccess {
                let b = res.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !b.isEmpty { return b }
            }
            return nil
        }
    }

    public nonisolated func fetchRepositoryWorkingFiles(context: RepoContext) -> [String] {
        return Array(fetchRepositoryFileStatuses(context: context).keys).sorted()
    }

    // MARK: - Base File Content (HEAD / Parent Revision)
    public nonisolated func fetchBaseFileContent(context: RepoContext, relativePath: String) -> Data? {
        switch context.vcsType {
        case .git:
            let spec = "HEAD:\(relativePath)"
            let args = ["--no-optional-locks", "show", spec]
            if let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                return result.stdoutData
            }
            return nil
        case .hg:
            let args = ["cat", "-r", ".", relativePath]
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                return result.stdoutData
            }
            return nil
        }
    }

    public nonisolated func fetchWorkingCopyFileContent(context: RepoContext, relativePath: String) -> Data? {
        let fullURL = context.repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fullURL.path) else { return nil }
        return try? Data(contentsOf: fullURL)
    }

    private nonisolated func enumerateFilesOnDisk(at rootURL: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var relPaths: [String] = []
        let rootPath = rootURL.standardizedFileURL.path
        let rootLen = rootPath.count

        for case let fileURL as URL in enumerator {
            let path = fileURL.standardizedFileURL.path
            if path.contains("/.git/") || path.contains("/.hg/") || path.hasSuffix("/.git") || path.hasSuffix("/.hg") || path.contains("/.build/") || path.contains("/DerivedData/") {
                enumerator.skipDescendants()
                continue
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                if path.hasPrefix(rootPath) {
                    var rel = String(path.dropFirst(rootLen))
                    if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
                    if !rel.isEmpty {
                        relPaths.append(rel)
                    }
                }
            }
        }
        return relPaths
    }

    // MARK: - Diff Changes (Additions and Deletions)
    public nonisolated func fetchDiffChanges(
        context: RepoContext,
        commit: CommitInfo
    ) -> (deletions: [Int: [String]], addedLines: Set<Int>) {
        let diffOutput: String
        let filePath = commit.filePath ?? context.relativePath
        switch context.vcsType {
        case .git:
            var diffText = ""
            if commit.isUncommitted {
                let args = ["diff", "-U0", "HEAD", "--", context.relativePath]
                if let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
                   result.isSuccess {
                    diffText = result.stdoutString
                }
            } else if let oldPath = commit.renamedFromPath, !oldPath.isEmpty, oldPath != filePath {
                // When there is a rename, diff the predecessor file against this revision's file
                let renameArgs = ["diff", "-U0", "\(commit.id)^:\(oldPath)", "\(commit.id):\(filePath)"]
                if let result = try? ProcessRunner.run(binary: "git", arguments: renameArgs, currentDirectory: context.repoRoot),
                   result.isSuccess {
                    diffText = result.stdoutString
                } else {
                    let fallbackArgs = ["show", "--first-parent", "--format=", "-U0", commit.id, "--", filePath]
                    if let result = try? ProcessRunner.run(binary: "git", arguments: fallbackArgs, currentDirectory: context.repoRoot),
                       result.isSuccess {
                        diffText = result.stdoutString
                    }
                }
            } else {
                let args = ["show", "--first-parent", "--format=", "-U0", commit.id, "--", filePath]
                guard let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
                      result.isSuccess else {
                    return ([:], [])
                }
                diffText = result.stdoutString
            }
            diffOutput = diffText

        case .hg:
            var diffText = ""
            if commit.isUncommitted {
                let args = ["diff", "--git", "-U", "0", context.relativePath]
                if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
                   result.isSuccess {
                    diffText = result.stdoutString
                }
            } else if let oldPath = commit.renamedFromPath, !oldPath.isEmpty, oldPath != filePath {
                let renameArgs = ["diff", "--git", "-U", "0", "-c", commit.id, oldPath, filePath]
                if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: renameArgs, currentDirectory: context.repoRoot),
                   result.isSuccess {
                    diffText = result.stdoutString
                } else {
                    let fallbackArgs = ["diff", "--git", "-U", "0", "-c", commit.id, filePath]
                    if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: fallbackArgs, currentDirectory: context.repoRoot),
                       result.isSuccess {
                        diffText = result.stdoutString
                    }
                }
            } else {
                let args = ["diff", "--git", "-U", "0", "-c", commit.id, filePath]
                guard let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
                      result.isSuccess else {
                    return ([:], [])
                }
                diffText = result.stdoutString
            }
            diffOutput = diffText
        }

        let normalized = diffOutput
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var deletionsMap: [Int: [String]] = [:]
        var addedLines = Set<Int>()
        let hunkRegex = try? NSRegularExpression(pattern: #"^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@"#)

        var currentTargetLine = 0
        var inHunk = false

        for rawLine in normalized.components(separatedBy: "\n") {
            let nsStr = rawLine as NSString
            let fullRange = NSRange(location: 0, length: nsStr.length)

            if let match = hunkRegex?.firstMatch(in: rawLine, range: fullRange) {
                let newStartStr = match.range(at: 3).location != NSNotFound ? nsStr.substring(with: match.range(at: 3)) : "0"
                let newCountStr = match.range(at: 4).location != NSNotFound ? nsStr.substring(with: match.range(at: 4)) : nil

                let newStart = Int(newStartStr) ?? 0
                let newCount = newCountStr != nil ? Int(newCountStr!) : 1

                if newCount == 0 {
                    currentTargetLine = newStart + 1
                } else {
                    currentTargetLine = newStart
                }
                inHunk = true
                continue
            }

            if !inHunk { continue }

            if rawLine.hasPrefix("-") && !rawLine.hasPrefix("---") {
                let deleted = String(rawLine.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                var list = deletionsMap[currentTargetLine] ?? []
                list.append(deleted)
                deletionsMap[currentTargetLine] = list
            } else if rawLine.hasPrefix("+") && !rawLine.hasPrefix("+++") {
                addedLines.insert(currentTargetLine)
                currentTargetLine += 1
            } else if rawLine.hasPrefix(" ") {
                currentTargetLine += 1
            }
        }

        return (deletionsMap, addedLines)
    }

    public nonisolated func fetchDiffDeletions(context: RepoContext, commit: CommitInfo) -> [Int: [String]] {
        return fetchDiffChanges(context: context, commit: commit).deletions
    }

    // MARK: - Blame Date Formatting
    private static let blameDateLock = NSLock()
    private static let blameTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm"
        return df
    }()
    private static let blameWeekdayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE HH:mm"
        return df
    }()
    private static let blameStandardFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yy/MM/dd HH:mm"
        return df
    }()

    public static func formatBlameDate(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "" }
        let calendar = Calendar.current
        blameDateLock.lock()
        defer { blameDateLock.unlock() }

        if calendar.isDate(date, inSameDayAs: now) {
            return "Today " + blameTimeFormatter.string(from: date)
        }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfCommit = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: startOfCommit, to: startOfToday).day ?? 0

        if dayDiff > 0 && dayDiff < 7 {
            return blameWeekdayFormatter.string(from: date)
        } else {
            return blameStandardFormatter.string(from: date)
        }
    }

    public static func parseHgAnnotateDate(_ raw: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        // "Sat Oct 21 04:44:30 2023 +0800"
        df.dateFormat = "EEE MMM d HH:mm:ss yyyy Z"
        if let d = df.date(from: raw) {
            return d
        }
        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        if let d = df.date(from: raw) {
            return d
        }
        df.dateFormat = "yyyy-MM-dd HH:mm Z"
        if let d = df.date(from: raw) {
            return d
        }
        return nil
    }

    // MARK: - Blame
    public func fetchBlame(context: RepoContext, commit: CommitInfo, cleanLines: [String]) throws -> [BlameLine] {
        switch context.vcsType {
        case .git:
            return try fetchGitBlame(context: context, commit: commit, cleanLines: cleanLines)
        case .hg:
            return try fetchHgBlame(context: context, commit: commit, cleanLines: cleanLines)
        }
    }

    private func fetchGitBlame(context: RepoContext, commit: CommitInfo, cleanLines: [String]) throws -> [BlameLine] {
        let filePath = commit.filePath ?? context.relativePath
        let args: [String]
        if commit.isUncommitted {
            args = ["blame", "--line-porcelain", "--", context.relativePath]
        } else {
            args = ["blame", "--line-porcelain", commit.id, "--", filePath]
        }
        let result = try ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot)
        guard result.isSuccess else {
            return fallbackBlameLines(cleanLines: cleanLines, commit: commit)
        }

        let normalizedOutput = result.stdoutString
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedOutput.components(separatedBy: "\n")
        var blameLines: [BlameLine] = []

        let commitShortId = String(commit.id.prefix(7)).lowercased()
        let commitDisplay = commit.displayRevision.lowercased()

        var i = 0
        while i < lines.count {
            let header = lines[i].components(separatedBy: " ")
            if header.count < 3 || header[0].count < 7 {
                i += 1
                continue
            }

            let commitHash = String(header[0].prefix(7))
            guard let lineNum = Int(header[2]) else {
                i += 1
                continue
            }

            var author = ""
            var authorEmail = ""
            var authorTimeStr = ""
            i += 1

            while i < lines.count {
                let current = lines[i]
                if current.hasPrefix("\t") {
                    let fallbackContent = String(current.dropFirst())
                    let lineContent = (lineNum <= cleanLines.count) ? cleanLines[lineNum - 1] : fallbackContent

                    let lineDate: Date?
                    if let ts = Double(authorTimeStr) {
                        lineDate = Date(timeIntervalSince1970: ts)
                    } else {
                        lineDate = nil
                    }
                    let dateStr = VCSManager.formatBlameDate(lineDate)

                    let rawHash = commitHash.lowercased()
                    let isZeroHash = rawHash.hasPrefix("0000000") || rawHash == "0000000"

                    let lineRev: String
                    let lineAuthor: String
                    let lineDateFinal: Date?
                    let dateStrFinal: String
                    let isCurrent: Bool

                    if commit.isUncommitted {
                        if isZeroHash {
                            isCurrent = true
                            lineRev = CommitInfo.uncommittedRevision
                            lineAuthor = (author.isEmpty || author == "Not Committed Yet") ? commit.author : author
                            lineDateFinal = lineDate ?? commit.date
                            dateStrFinal = VCSManager.formatBlameDate(lineDateFinal)
                        } else {
                            isCurrent = false
                            lineRev = commitHash
                            lineAuthor = author
                            lineDateFinal = lineDate
                            dateStrFinal = VCSManager.formatBlameDate(lineDateFinal)
                        }
                    } else {
                        isCurrent = (rawHash == commitShortId)
                            || commit.id.lowercased().hasPrefix(rawHash)
                            || (rawHash == commitDisplay)
                        lineRev = commitHash
                        lineAuthor = author
                        lineDateFinal = lineDate
                        dateStrFinal = dateStr
                    }

                    blameLines.append(BlameLine(
                        lineNumber: lineNum,
                        revision: lineRev,
                        author: lineAuthor,
                        authorEmail: authorEmail,
                        date: lineDateFinal,
                        dateString: dateStrFinal,
                        content: lineContent,
                        isChangedInCurrentCommit: isCurrent
                    ))
                    i += 1
                    break
                } else if current.hasPrefix("author ") {
                    author = String(current.dropFirst(7))
                } else if current.hasPrefix("author-mail ") {
                    var email = String(current.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                    if email.hasPrefix("<") && email.hasSuffix(">") {
                        email = String(email.dropFirst().dropLast())
                    }
                    authorEmail = email
                } else if current.hasPrefix("author-time ") {
                    authorTimeStr = String(current.dropFirst(12))
                }
                i += 1
            }
        }

        if blameLines.isEmpty {
            return fallbackBlameLines(cleanLines: cleanLines, commit: commit)
        }
        return blameLines
    }

    private func fetchHgBlame(context: RepoContext, commit: CommitInfo, cleanLines: [String]) throws -> [BlameLine] {
        let filePath = commit.filePath ?? context.relativePath
        let args: [String]
        if commit.isUncommitted {
            args = ["annotate", "-u", "-v", "-c", "-d", "-n", "-r", "wdir()", context.relativePath]
        } else {
            args = ["annotate", "-u", "-v", "-c", "-d", "-n", "-r", commit.id, filePath]
        }
        let result = try ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot)
        guard result.isSuccess else {
            return fallbackBlameLines(cleanLines: cleanLines, commit: commit)
        }

        // Hg annotate format with -v:
        //   Jeffrey Lim <jeff@lim.com.au> 8413 06065f9b8b1b Sat Oct 21 04:44:30 2023 +0800: <content>
        let normalizedOutput = result.stdoutString
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalizedOutput.components(separatedBy: "\n")
        var blameLines: [BlameLine] = []

        // Extract commit revision number for comparison
        let commitRevNum = commit.displayRevision.split(separator: ":").first.map(String.init) ?? commit.displayRevision
        let commitNodePrefix = String(commit.id.prefix(6)).lowercased()

        // Regex parsing: allows leading spaces, author, rev number, node hash (with optional +), date ending before ': '
        let regex = try? NSRegularExpression(
            pattern: #"^\s*(.*?)\s+(\d+)\s+([0-9a-fA-F]{6,40})(\+?)\s+(.*?(?:[+-]\d{4}|\b\d{4}\b|\w{3})):\s?(.*)$"#
        )

        var lineIndex = 1
        for rawLine in rawLines {
            if rawLine.isEmpty && lineIndex > 1 && lineIndex >= rawLines.count {
                continue
            }

            let pureContent = (lineIndex <= cleanLines.count) ? cleanLines[lineIndex - 1] : ""
            let nsStr = rawLine as NSString
            let range = NSRange(location: 0, length: nsStr.length)

            if let match = regex?.firstMatch(in: rawLine, range: range) {
                let author = match.range(at: 1).location != NSNotFound ? nsStr.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces) : ""
                let rev = match.range(at: 2).location != NSNotFound ? nsStr.substring(with: match.range(at: 2)) : ""
                let shortNode = match.range(at: 3).location != NSNotFound ? nsStr.substring(with: match.range(at: 3)) : ""
                let hasPlus = match.range(at: 4).location != NSNotFound && !nsStr.substring(with: match.range(at: 4)).isEmpty
                let dateRaw = match.range(at: 5).location != NSNotFound ? nsStr.substring(with: match.range(at: 5)).trimmingCharacters(in: .whitespaces) : ""

                let parsedDate = VCSManager.parseHgAnnotateDate(dateRaw)
                let dateStr = VCSManager.formatBlameDate(parsedDate)

                var authorName = CommitInfo.cleanAuthorName(author)
                var authorEmail = ""
                if author.contains("<") && author.contains(">") {
                    let parts = author.components(separatedBy: "<")
                    authorName = CommitInfo.cleanAuthorName(parts[0])
                    authorEmail = parts[1].replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
                }

                let isCurrent: Bool
                let displayRev: String

                if commit.isUncommitted {
                    if hasPlus {
                        isCurrent = true
                        displayRev = CommitInfo.uncommittedRevision
                        authorName = commit.author
                    } else {
                        isCurrent = false
                        displayRev = rev.isEmpty ? String(shortNode.prefix(6)) : rev
                    }
                } else {
                    displayRev = rev.isEmpty ? String(shortNode.prefix(6)) : rev
                    let nodeLower = shortNode.lowercased()
                    isCurrent = (rev == commitRevNum)
                        || (!nodeLower.isEmpty && commit.id.lowercased().hasPrefix(nodeLower))
                        || (!nodeLower.isEmpty && nodeLower.hasPrefix(commitNodePrefix))
                }

                blameLines.append(BlameLine(
                    lineNumber: lineIndex,
                    revision: displayRev,
                    author: authorName,
                    authorEmail: authorEmail,
                    date: parsedDate,
                    dateString: dateStr,
                    content: pureContent,
                    isChangedInCurrentCommit: isCurrent
                ))
            } else {
                // If line didn't match annotate format, still use pureContent from cleanLines!
                // Never leak the rawLine annotation into content!
                let revDisplay = commit.displayRevision.split(separator: ":").first.map(String.init) ?? commit.displayRevision
                blameLines.append(BlameLine(
                    lineNumber: lineIndex,
                    revision: revDisplay,
                    author: commit.author,
                    authorEmail: commit.authorEmail,
                    date: commit.date,
                    dateString: VCSManager.formatBlameDate(commit.date),
                    content: pureContent,
                    isChangedInCurrentCommit: commit.isUncommitted
                ))
            }
            lineIndex += 1
        }

        if blameLines.isEmpty {
            return fallbackBlameLines(cleanLines: cleanLines, commit: commit)
        }
        return blameLines
    }

    private func fallbackBlameLines(cleanLines: [String], commit: CommitInfo) -> [BlameLine] {
        let dateStr = VCSManager.formatBlameDate(commit.date)
        let revDisplay = commit.displayRevision.split(separator: ":").first.map(String.init) ?? commit.displayRevision
        return cleanLines.enumerated().map { index, line in
            BlameLine(
                lineNumber: index + 1,
                revision: revDisplay,
                author: commit.author,
                authorEmail: commit.authorEmail,
                date: commit.date,
                dateString: dateStr,
                content: line,
                isChangedInCurrentCommit: true
            )
        }
    }
  
    // MARK: - Repository-Wide Commit History & Branches
    public nonisolated func fetchRepositoryBranches(context: RepoContext) -> [String] {
        switch context.vcsType {
        case .git:
            let args = ["--no-optional-locks", "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"]
            guard let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return []
            }
            var seen = Set<String>()
            var branches: [String] = []
            for line in result.stdoutString.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed != "HEAD",
                      !trimmed.hasSuffix("/HEAD"),
                      trimmed != "origin" else { continue }
                if !seen.contains(trimmed) {
                    seen.insert(trimmed)
                    branches.append(trimmed)
                }
            }
            return branches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        case .hg:
            var seen = Set<String>()
            var branches: [String] = []
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: ["branches", "-T", "{branch}\n"], currentDirectory: context.repoRoot),
               result.isSuccess {
                for line in result.stdoutString.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !seen.contains(trimmed) {
                        seen.insert(trimmed)
                        branches.append(trimmed)
                    }
                }
            }
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: ["bookmarks", "-T", "{bookmark}\n"], currentDirectory: context.repoRoot),
               result.isSuccess {
                for line in result.stdoutString.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !seen.contains(trimmed) {
                        seen.insert(trimmed)
                        branches.append(trimmed)
                    }
                }
            }
            return branches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private nonisolated func fetchRepositoryBookmarks(context: RepoContext) -> Set<String> {
        guard let result = try? ProcessRunner.run(
            binary: context.hgBinary,
            arguments: ["bookmarks", "-T", "{bookmark}\n"],
            currentDirectory: context.repoRoot
        ), result.isSuccess else {
            return []
        }
        var bookmarks = Set<String>()
        for line in result.stdoutString.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                bookmarks.insert(trimmed)
            }
        }
        return bookmarks
    }

    public nonisolated func fetchWorkingCopyParentHash(context: RepoContext) -> String? {
        switch context.vcsType {
        case .git:
            if let result = try? ProcessRunner.run(
                binary: "git",
                arguments: ["--no-optional-locks", "rev-parse", "HEAD"],
                currentDirectory: context.repoRoot
            ), result.isSuccess {
                let hash = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !hash.isEmpty {
                    return hash
                }
            }
            return nil
        case .hg:
            // Fast path: read 20-byte parent hash directly from .hg/dirstate
            let dirstateURL = context.repoRoot.appendingPathComponent(".hg/dirstate")
            if let handle = try? FileHandle(forReadingFrom: dirstateURL) {
                defer { try? handle.close() }
                if let data = try? handle.read(upToCount: 20), data.count == 20 {
                    let hex = data.map { String(format: "%02x", $0) }.joined()
                    if !hex.allSatisfy({ $0 == "0" }) {
                        return hex
                    }
                }
            }

            if let result = try? ProcessRunner.run(
                binary: context.hgBinary,
                arguments: ["log", "-r", ".", "-T", "{node}"],
                currentDirectory: context.repoRoot
            ), result.isSuccess {
                let hash = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !hash.isEmpty && !hash.allSatisfy({ $0 == "0" }) {
                    return hash
                }
            }
            return nil
        }
    }

    public nonisolated func fetchRepositoryLogEntries(
        context: RepoContext,
        branch: String? = nil,
        filePath: String? = nil
    ) throws -> [(commit: CommitInfo, parentIds: [String])] {
        let filterBranch: String?
        if let b = branch?.trimmingCharacters(in: .whitespacesAndNewlines),
           !b.isEmpty,
           b != "All Branches" {
            filterBranch = b
        } else {
            filterBranch = nil
        }

        switch context.vcsType {
        case .git:
            let format = "\u{1e}%H\u{1f}%h\u{1f}%P\u{1f}%an\u{1f}%ae\u{1f}%ad\u{1f}%s\u{1f}%B\u{1f}"
            var args = ["--no-optional-locks", "log", "--topo-order"]
            if let b = filterBranch {
                args.append(b)
            } else {
                args.append(contentsOf: ["HEAD", "--all"])
            }
            args.append(contentsOf: ["--date=iso-strict", "--format=\(format)"])
            if let path = filePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                args.append(contentsOf: ["--", path])
            }

            let result = try ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot)
            guard result.isSuccess else {
                throw NSError(
                    domain: "VCSManager",
                    code: Int(result.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: result.stderrString.isEmpty ? "Failed to fetch Git repository commit history" : result.stderrString]
                )
            }
            return parseRepositoryCommits(output: result.stdoutString, isHg: false)

        case .hg:
            let template = "\u{1e}{node}\u{1f}{rev}:{node|short}\u{1f}{p1node} {p2node}\u{1f}{author|person}\u{1f}{author|email}\u{1f}{date|hgdate}\u{1f}{desc|firstline}\u{1f}{desc}\u{1f}"
            var args = ["log"]
            if let b = filterBranch {
                let escaped = b.replacingOccurrences(of: "\"", with: "\\\"")
                let bookmarks = fetchRepositoryBookmarks(context: context)
                if bookmarks.contains(b) {
                    args.append(contentsOf: ["-r", "reverse(::bookmark(\"\(escaped)\"))"])
                } else {
                    args.append(contentsOf: ["-r", "reverse(::branch(\"\(escaped)\"))"])
                }
            }
            args.append(contentsOf: ["--template", template])
            if let path = filePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                args.append(path)
            }

            var result = try ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot)
            if !result.isSuccess, let b = filterBranch {
                let escaped = b.replacingOccurrences(of: "\"", with: "\\\"")
                var fallbackArgs = ["log", "-r", "reverse(::\"\(escaped)\")", "--template", template]
                if let path = filePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    fallbackArgs.append(path)
                }
                if let fallbackResult = try? ProcessRunner.run(binary: context.hgBinary, arguments: fallbackArgs, currentDirectory: context.repoRoot),
                   fallbackResult.isSuccess {
                    result = fallbackResult
                }
            }
            guard result.isSuccess else {
                throw NSError(
                    domain: "VCSManager",
                    code: Int(result.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: result.stderrString.isEmpty ? "Failed to fetch Mercurial repository commit history" : result.stderrString]
                )
            }
            return parseRepositoryCommits(output: result.stdoutString, isHg: true)
        }
    }

    public nonisolated func fetchRepositoryCommitHistoryAndWorkingChanges(
        context: RepoContext,
        branch: String? = nil,
        filePath: String? = nil
    ) async throws -> (entries: [(commit: CommitInfo, parentIds: [String])], workingChanges: [WorkingFileChange], currentCheckedOutHash: String?) {
        async let logEntriesTask = Task.detached(priority: .userInitiated) { () throws -> [(commit: CommitInfo, parentIds: [String])] in
            try self.fetchRepositoryLogEntries(context: context, branch: branch, filePath: filePath)
        }.value

        async let refsTask = Task.detached(priority: .userInitiated) {
            self.fetchRepositoryRefs(context: context)
        }.value

        async let workingChangesTask = Task.detached(priority: .userInitiated) {
            self.fetchWorkingCopyChanges(context: context)
        }.value

        async let parentHashTask = Task.detached(priority: .userInitiated) {
            self.fetchWorkingCopyParentHash(context: context)
        }.value

        let (rawEntries, (branchesByCommit, tagsByCommit), allWorkingChanges, headHash) = try await (logEntriesTask, refsTask, workingChangesTask, parentHashTask)

        var items = rawEntries
        if !branchesByCommit.isEmpty || !tagsByCommit.isEmpty {
            items = items.map { entry in
                var c = entry.commit
                c.branches = findRefs(for: c, in: branchesByCommit)
                c.tags = findRefs(for: c, in: tagsByCommit)
                return (commit: c, parentIds: entry.parentIds)
            }
        }

        let workingChanges: [WorkingFileChange]
        if let path = filePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let prefix = path.hasSuffix("/") ? path : "\(path)/"
            workingChanges = allWorkingChanges.filter { $0.relativePath == path || $0.relativePath.hasPrefix(prefix) }
        } else {
            workingChanges = allWorkingChanges
        }

        if !workingChanges.isEmpty {
            let now = Date()
            let (user, email) = fetchCurrentUser(context: context)
            let author = user.isEmpty ? "Working Directory" : user
            let fallbackHeadHash = headHash ?? items.first?.commit.id
            let parentIds: [String]
            if let fallbackHeadHash = fallbackHeadHash, items.contains(where: { $0.commit.id == fallbackHeadHash }) {
                parentIds = [fallbackHeadHash]
            } else if let firstId = items.first?.commit.id {
                parentIds = [firstId]
            } else {
                parentIds = []
            }

            let uncommitted = CommitInfo(
                id: CommitInfo.uncommittedHash,
                displayRevision: CommitInfo.uncommittedRevision,
                fullRevision: "Working Directory",
                author: author,
                authorEmail: email,
                date: now,
                dateFormatted: VCSManager.formatBlameDate(now),
                summary: "Working Directory Changes",
                fullMessage: "Working Directory Changes",
                index: 0
            )

            var updatedItems: [(commit: CommitInfo, parentIds: [String])] = []
            updatedItems.reserveCapacity(items.count + 1)
            updatedItems.append((commit: uncommitted, parentIds: parentIds))
            for (idx, entry) in items.enumerated() {
                var c = entry.commit
                c.index = idx + 1
                updatedItems.append((commit: c, parentIds: entry.parentIds))
            }
            items = updatedItems
        }

        return (items, workingChanges, headHash)
    }

    public nonisolated func fetchRepositoryCommitHistory(
        context: RepoContext,
        branch: String? = nil,
        filePath: String? = nil
    ) throws -> [(commit: CommitInfo, parentIds: [String])] {
        let rawEntries = try fetchRepositoryLogEntries(context: context, branch: branch, filePath: filePath)
        var items = rawEntries
        let (branchesByCommit, tagsByCommit) = fetchRepositoryRefs(context: context)
        if !branchesByCommit.isEmpty || !tagsByCommit.isEmpty {
            items = items.map { entry in
                var c = entry.commit
                c.branches = findRefs(for: c, in: branchesByCommit)
                c.tags = findRefs(for: c, in: tagsByCommit)
                return (commit: c, parentIds: entry.parentIds)
            }
        }

        let workingChanges = fetchWorkingCopyChanges(context: context)
        if !workingChanges.isEmpty {
            let now = Date()
            let (user, email) = fetchCurrentUser(context: context)
            let author = user.isEmpty ? "Working Directory" : user
            let headHash = fetchWorkingCopyParentHash(context: context) ?? items.first?.commit.id
            let parentIds: [String]
            if let headHash = headHash, items.contains(where: { $0.commit.id == headHash }) {
                parentIds = [headHash]
            } else if let firstId = items.first?.commit.id {
                parentIds = [firstId]
            } else {
                parentIds = []
            }

            let uncommitted = CommitInfo(
                id: CommitInfo.uncommittedHash,
                displayRevision: CommitInfo.uncommittedRevision,
                fullRevision: "Working Directory",
                author: author,
                authorEmail: email,
                date: now,
                dateFormatted: VCSManager.formatBlameDate(now),
                summary: "Working Directory Changes",
                fullMessage: "Working Directory Changes",
                index: 0
            )

            var updatedItems: [(commit: CommitInfo, parentIds: [String])] = []
            updatedItems.reserveCapacity(items.count + 1)
            updatedItems.append((commit: uncommitted, parentIds: parentIds))
            for (idx, entry) in items.enumerated() {
                var c = entry.commit
                c.index = idx + 1
                updatedItems.append((commit: c, parentIds: entry.parentIds))
            }
            items = updatedItems
        }

        return items
    }

    // MARK: - Repository Tags & Branches by Commit
    public nonisolated func fetchRepositoryRefs(
        context: RepoContext
    ) -> (branchesByCommit: [String: [String]], tagsByCommit: [String: [String]]) {
        var branchesByCommit: [String: [String]] = [:]
        var tagsByCommit: [String: [String]] = [:]

        switch context.vcsType {
        case .git:
            let args = [
                "--no-optional-locks",
                "for-each-ref",
                "--format=%(objectname)%09%(*objectname)%09%(refname)",
                "refs/heads",
                "refs/remotes",
                "refs/tags"
            ]
            guard let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return (branchesByCommit, tagsByCommit)
            }

            for line in result.stdoutString.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let fields = trimmed.components(separatedBy: "\t")
                guard fields.count >= 3 else { continue }

                let obj = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let peeled = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let refname = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)

                if refname.hasPrefix("refs/tags/") {
                    let tag = String(refname.dropFirst("refs/tags/".count))
                    let commitId = peeled.isEmpty ? obj : peeled
                    guard !tag.isEmpty, !commitId.isEmpty else { continue }
                    if !(tagsByCommit[commitId]?.contains(tag) ?? false) {
                        tagsByCommit[commitId, default: []].append(tag)
                    }
                } else if refname.hasPrefix("refs/heads/") {
                    let branch = String(refname.dropFirst("refs/heads/".count))
                    guard !branch.isEmpty, branch != "HEAD", !obj.isEmpty else { continue }
                    if !(branchesByCommit[obj]?.contains(branch) ?? false) {
                        branchesByCommit[obj, default: []].append(branch)
                    }
                } else if refname.hasPrefix("refs/remotes/") {
                    let branch = String(refname.dropFirst("refs/remotes/".count))
                    guard !branch.isEmpty, !branch.hasSuffix("/HEAD"), branch != "HEAD", branch != "origin", !obj.isEmpty else { continue }
                    if !(branchesByCommit[obj]?.contains(branch) ?? false) {
                        branchesByCommit[obj, default: []].append(branch)
                    }
                }
            }

        case .hg:
            // 1. Branches (heads of named branches)
            if let result = try? ProcessRunner.run(
                binary: context.hgBinary,
                arguments: ["branches", "-T", "{branch}\t{node}\n"],
                currentDirectory: context.repoRoot
            ), result.isSuccess {
                for line in result.stdoutString.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    let parts = trimmed.components(separatedBy: "\t")
                    let branch = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let node = (parts.count > 1) ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    guard !branch.isEmpty, !node.isEmpty, !node.allSatisfy({ $0 == "0" }) else { continue }
                    if !(branchesByCommit[node]?.contains(branch) ?? false) {
                        branchesByCommit[node, default: []].append(branch)
                    }
                }
            }

            // 2. Bookmarks (heads of bookmarks)
            if let result = try? ProcessRunner.run(
                binary: context.hgBinary,
                arguments: ["bookmarks", "-T", "{bookmark}\t{node}\n"],
                currentDirectory: context.repoRoot
            ), result.isSuccess {
                for line in result.stdoutString.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    let parts = trimmed.components(separatedBy: "\t")
                    let bookmark = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let node = (parts.count > 1) ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    guard !bookmark.isEmpty, !node.isEmpty, !node.allSatisfy({ $0 == "0" }) else { continue }
                    if !(branchesByCommit[node]?.contains(bookmark) ?? false) {
                        branchesByCommit[node, default: []].append(bookmark)
                    }
                }
            }

            // 3. Tags
            if let result = try? ProcessRunner.run(
                binary: context.hgBinary,
                arguments: ["tags", "-T", "{tag}\t{node}\n"],
                currentDirectory: context.repoRoot
            ), result.isSuccess {
                for line in result.stdoutString.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    let parts = trimmed.components(separatedBy: "\t")
                    let tag = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let node = (parts.count > 1) ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    guard !tag.isEmpty, tag != "tip", !node.isEmpty, !node.allSatisfy({ $0 == "0" }) else { continue }
                    if !(tagsByCommit[node]?.contains(tag) ?? false) {
                        tagsByCommit[node, default: []].append(tag)
                    }
                }
            }
        }

        return (branchesByCommit, tagsByCommit)
    }

    private nonisolated func findRefs(for commit: CommitInfo, in map: [String: [String]]) -> [String] {
        if let exact = map[commit.id] {
            return exact
        }
        let full = commit.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return [] }
        for (key, list) in map {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty && (full.hasPrefix(trimmedKey) || trimmedKey.hasPrefix(full)) {
                return list
            }
        }
        return []
    }

    private func parseRepositoryCommits(output: String, isHg: Bool) -> [(commit: CommitInfo, parentIds: [String])] {
        let records = output.components(separatedBy: "\u{1e}")
        var items: [(commit: CommitInfo, parentIds: [String])] = []
        var seenHashes = Set<String>()

        for record in records {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let fields = record.components(separatedBy: "\u{1f}")
            guard fields.count >= 8 else { continue }

            let fullHash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fullHash.isEmpty, !seenHashes.contains(fullHash) else { continue }
            seenHashes.insert(fullHash)

            var displayRev = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if isHg {
                displayRev = CommitInfo.shortenRevision(displayRev)
            }

            let rawParents = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let parentIds = rawParents
                .split(separator: " ")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.allSatisfy({ $0 == "0" }) }

            let rawAuthor = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let author = CommitInfo.cleanAuthorName(rawAuthor)
            let authorEmail = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawDate = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
            let fullMsg = fields[7].trimmingCharacters(in: .whitespacesAndNewlines)

            let parsedDate = parseDateString(rawDate)
            let formattedDate = VCSManager.formatBlameDate(parsedDate)

            let commit = CommitInfo(
                id: fullHash,
                displayRevision: displayRev,
                fullRevision: fullHash,
                author: author.isEmpty ? "Unknown" : author,
                authorEmail: authorEmail,
                date: parsedDate,
                dateFormatted: formattedDate,
                summary: summary.isEmpty ? "No commit message" : summary,
                fullMessage: fullMsg.isEmpty ? summary : fullMsg,
                index: items.count
            )
            items.append((commit: commit, parentIds: parentIds))
        }

        return items
    }

    // MARK: - Working Copy Changed Files
    public nonisolated func fetchWorkingCopyChanges(context: RepoContext) -> [WorkingFileChange] {
        var changes: [WorkingFileChange] = []

        switch context.vcsType {
        case .git:
            let args = ["--no-optional-locks", "status", "--porcelain=v1", "-uall"]
            guard let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return []
            }
            for rawLine in result.stdoutString.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .newlines)
                guard line.count >= 3 else { continue }
                let code = String(line.prefix(2))
                var filePath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if filePath.hasPrefix("\"") && filePath.hasSuffix("\"") && filePath.count >= 2 {
                    filePath = String(filePath.dropFirst().dropLast())
                }

                if code.contains("R") || line.contains(" -> ") {
                    if let arrowRange = filePath.range(of: " -> ") {
                        let oldPath = String(filePath[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let newPath = String(filePath[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                        changes.append(WorkingFileChange(relativePath: oldPath, fullURL: context.repoRoot.appendingPathComponent(oldPath), status: .deleted))
                        changes.append(WorkingFileChange(relativePath: newPath, fullURL: context.repoRoot.appendingPathComponent(newPath), status: .new))
                        continue
                    }
                }

                let x = code.first ?? " "
                let y = code.last ?? " "
                let status: FileWorkingStatus
                if code == "??" {
                    status = .unknown
                } else if x == "A" || y == "A" {
                    status = .new
                } else if x == "D" || y == "D" {
                    status = .deleted
                } else if x == "M" || y == "M" || x == "U" || y == "U" {
                    status = .modified
                } else {
                    continue
                }
                changes.append(WorkingFileChange(relativePath: filePath, fullURL: context.repoRoot.appendingPathComponent(filePath), status: status))
            }

        case .hg:
            let args = ["status"]
            guard let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
                  result.isSuccess else {
                return []
            }
            for rawLine in result.stdoutString.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .newlines)
                guard line.count >= 2 else { continue }
                let code = line.first!
                let filePath = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard !filePath.isEmpty else { continue }
                let status: FileWorkingStatus
                switch code {
                case "?":
                    status = .unknown
                case "A":
                    status = .new
                case "R", "!":
                    status = .deleted
                case "M":
                    status = .modified
                default:
                    continue
                }
                changes.append(WorkingFileChange(relativePath: filePath, fullURL: context.repoRoot.appendingPathComponent(filePath), status: status))
            }
        }

        changes.sort { a, b in
            if a.status.commitSortPriority != b.status.commitSortPriority {
                return a.status.commitSortPriority < b.status.commitSortPriority
            }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }
        return changes
    }

    public nonisolated func fetchChangedFilesInCommit(
        context: RepoContext,
        commit: CommitInfo
    ) -> [WorkingFileChange] {
        if commit.isUncommitted {
            return fetchWorkingCopyChanges(context: context)
        }

        var fileStatusMap: [String: FileWorkingStatus] = [:]

        switch context.vcsType {
        case .git:
            let args = ["--no-optional-locks", "diff-tree", "-m", "--first-parent", "--no-commit-id", "--name-status", "-r", "--root", commit.id]
            if let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                for rawLine in result.stdoutString.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    let parts = line.components(separatedBy: "\t")
                    guard parts.count >= 2 else { continue }
                    let code = parts[0].trimmingCharacters(in: .whitespaces)
                    let relPath: String
                    let status: FileWorkingStatus
                    if code.hasPrefix("R") || code.hasPrefix("C") {
                        relPath = (parts.count >= 3 ? parts[2] : parts[1]).trimmingCharacters(in: .whitespaces)
                        status = .modified
                    } else if code.hasPrefix("A") {
                        relPath = parts[1].trimmingCharacters(in: .whitespaces)
                        status = .new
                    } else if code.hasPrefix("D") {
                        relPath = parts[1].trimmingCharacters(in: .whitespaces)
                        status = .deleted
                    } else {
                        relPath = parts[1].trimmingCharacters(in: .whitespaces)
                        status = .modified
                    }
                    if !relPath.isEmpty {
                        fileStatusMap[relPath] = status
                    }
                }
            }

        case .hg:
            let args = ["status", "--change", commit.id]
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                for rawLine in result.stdoutString.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .newlines)
                    guard line.count >= 2 else { continue }
                    let code = line.first!
                    let relPath = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    guard !relPath.isEmpty else { continue }
                    let status: FileWorkingStatus
                    switch code {
                    case "A":
                        status = .new
                    case "R", "!":
                        status = .deleted
                    default:
                        status = .modified
                    }
                    fileStatusMap[relPath] = status
                }
            }
        }

        var changes: [WorkingFileChange] = fileStatusMap.map { (relPath, status) in
            WorkingFileChange(
                relativePath: relPath,
                fullURL: context.repoRoot.appendingPathComponent(relPath),
                status: status
            )
        }

        changes.sort { a, b in
            if a.status.commitSortPriority != b.status.commitSortPriority {
                return a.status.commitSortPriority < b.status.commitSortPriority
            }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }

        return changes
    }

    public nonisolated func fetchRevisionFileContent(
        context: RepoContext,
        commitId: String,
        relativePath: String
    ) -> Data? {
        switch context.vcsType {
        case .git:
            let spec = "\(commitId):\(relativePath)"
            let args = ["--no-optional-locks", "show", spec]
            if let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                return result.stdoutData
            }
            return nil
        case .hg:
            let args = ["cat", "-r", commitId, relativePath]
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                return result.stdoutData
            }
            return nil
        }
    }

    public nonisolated func fetchParentFileContent(
        context: RepoContext,
        commitId: String,
        relativePath: String
    ) -> Data? {
        switch context.vcsType {
        case .git:
            let spec = "\(commitId)^:\(relativePath)"
            let args = ["--no-optional-locks", "show", spec]
            if let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                return result.stdoutData
            }
            return nil
        case .hg:
            let args = ["cat", "-r", "p1(\(commitId))", relativePath]
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                return result.stdoutData
            }
            return nil
        }
    }

    // MARK: - Checkout Revision
    public nonisolated func checkoutRevision(context: RepoContext, revision: String) throws {
        switch context.vcsType {
        case .git:
            let args = ["checkout", revision]
            let result = try ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot)
            if !result.isSuccess {
                var msg = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.isEmpty {
                    msg = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if msg.isEmpty {
                    msg = "Git checkout failed with exit code \(result.exitCode)."
                }
                throw NSError(domain: "VCSManager", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: msg])
            }

        case .hg:
            let args = ["update", "-r", revision]
            let result = try ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot)
            if !result.isSuccess {
                var msg = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.isEmpty {
                    msg = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if msg.isEmpty {
                    msg = "Mercurial update failed with exit code \(result.exitCode)."
                }
                throw NSError(domain: "VCSManager", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
    }

    // MARK: - Compare Commits
    public nonisolated func fetchChangedFilesBetweenCommits(
        context: RepoContext,
        baseCommit: CommitInfo,
        targetCommit: CommitInfo
    ) -> [WorkingFileChange] {
        if baseCommit.id == targetCommit.id {
            return []
        }

        var fileStatusMap: [String: FileWorkingStatus] = [:]

        switch context.vcsType {
        case .git:
            let args: [String]
            if baseCommit.isUncommitted && targetCommit.isUncommitted {
                return []
            } else if targetCommit.isUncommitted {
                args = ["--no-optional-locks", "diff", "--name-status", baseCommit.id]
            } else if baseCommit.isUncommitted {
                args = ["--no-optional-locks", "diff", "--name-status", "-R", targetCommit.id]
            } else {
                args = ["--no-optional-locks", "diff", "--name-status", baseCommit.id, targetCommit.id]
            }

            if let result = try? ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                for rawLine in result.stdoutString.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    let parts = line.components(separatedBy: "\t")
                    guard parts.count >= 2 else { continue }
                    let code = parts[0].trimmingCharacters(in: .whitespaces)
                    let relPath: String
                    let status: FileWorkingStatus
                    if code.hasPrefix("R") || code.hasPrefix("C") {
                        relPath = (parts.count >= 3 ? parts[2] : parts[1]).trimmingCharacters(in: .whitespaces)
                        status = .modified
                    } else if code.hasPrefix("A") {
                        relPath = parts[1].trimmingCharacters(in: .whitespaces)
                        status = .new
                    } else if code.hasPrefix("D") {
                        relPath = parts[1].trimmingCharacters(in: .whitespaces)
                        status = .deleted
                    } else {
                        relPath = parts[1].trimmingCharacters(in: .whitespaces)
                        status = .modified
                    }
                    if !relPath.isEmpty {
                        fileStatusMap[relPath] = status
                    }
                }
            }

        case .hg:
            let args: [String]
            if baseCommit.isUncommitted && targetCommit.isUncommitted {
                return []
            } else if targetCommit.isUncommitted {
                args = ["status", "--rev", baseCommit.id]
            } else if baseCommit.isUncommitted {
                args = ["status", "--rev", targetCommit.id]
            } else {
                args = ["status", "--rev", baseCommit.id, "--rev", targetCommit.id]
            }

            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: args, currentDirectory: context.repoRoot),
               result.isSuccess {
                for rawLine in result.stdoutString.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .newlines)
                    guard line.count >= 2 else { continue }
                    let code = line.first!
                    let relPath = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    guard !relPath.isEmpty else { continue }
                    var status: FileWorkingStatus
                    switch code {
                    case "A":
                        status = .new
                    case "R", "!":
                        status = .deleted
                    default:
                        status = .modified
                    }
                    if baseCommit.isUncommitted {
                        if status == .new { status = .deleted }
                        else if status == .deleted { status = .new }
                    }
                    fileStatusMap[relPath] = status
                }
            }
        }

        var changes: [WorkingFileChange] = fileStatusMap.map { (relPath, status) in
            WorkingFileChange(
                relativePath: relPath,
                fullURL: context.repoRoot.appendingPathComponent(relPath),
                status: status
            )
        }

        changes.sort { a, b in
            if a.status.commitSortPriority != b.status.commitSortPriority {
                return a.status.commitSortPriority < b.status.commitSortPriority
            }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }

        return changes
    }

    // MARK: - Remotes & Remote Operations
    public nonisolated func fetchRemotes(context: RepoContext) -> [RemoteRepository] {
        switch context.vcsType {
        case .git:
            if let result = try? ProcessRunner.run(binary: "git", arguments: ["remote", "-v"], currentDirectory: context.repoRoot, timeout: 5.0),
               result.isSuccess {
                var remotes: [RemoteRepository] = []
                var seen = Set<String>()
                let lines = result.stdoutString.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    guard parts.count >= 2 else { continue }
                    let name = parts[0]
                    let url = parts[1]
                    if !seen.contains(name) {
                        seen.insert(name)
                        remotes.append(RemoteRepository(name: name, urlString: url))
                    }
                }
                if !remotes.isEmpty {
                    return remotes
                }
            }

            if let result = try? ProcessRunner.run(binary: "git", arguments: ["remote"], currentDirectory: context.repoRoot, timeout: 5.0),
               result.isSuccess {
                var remotes: [RemoteRepository] = []
                var seen = Set<String>()
                let lines = result.stdoutString.components(separatedBy: .newlines)
                for line in lines {
                    let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty && !seen.contains(name) {
                        seen.insert(name)
                        remotes.append(RemoteRepository(name: name, urlString: nil))
                    }
                }
                return remotes
            }
            return []

        case .hg:
            if let result = try? ProcessRunner.run(binary: context.hgBinary, arguments: ["paths"], currentDirectory: context.repoRoot, timeout: 5.0),
               result.isSuccess {
                var remotes: [RemoteRepository] = []
                var seen = Set<String>()
                let lines = result.stdoutString.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let parts = trimmed.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                    guard parts.count >= 1 else { continue }
                    let name = parts[0]
                    guard !name.isEmpty else { continue }
                    let url = parts.count > 1 ? parts[1] : nil
                    if !seen.contains(name) {
                        seen.insert(name)
                        remotes.append(RemoteRepository(name: name, urlString: url))
                    }
                }
                return remotes
            }
            return []
        }
    }

    /// Performs a default (non-force) push to the specified remote repository.
    /// Under NO circumstances will this force push.
    public nonisolated func push(context: RepoContext, remote: String) throws {
        switch context.vcsType {
        case .git:
            let args = ["push", remote]
            let result = try ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot, timeout: 60.0)
            guard result.isSuccess else {
                let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "git push failed with exit code \(result.exitCode)")
                throw NSError(domain: "VCSManager.push", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: msg])
            }

        case .hg:
            // Ensure we use the path alias (e.g. "sin", "adl", "default"), never the full URL or path.
            var alias = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            if alias.contains("://") || alias.hasPrefix("/") {
                let remotes = fetchRemotes(context: context)
                if let matched = remotes.first(where: { $0.urlString == alias || $0.name == alias }) {
                    alias = matched.name
                }
            }

            // Always use the standalone 'hg' binary directly for network remote operations,
            // avoiding the background 'chg' daemon which can inherit stale process environments or SSH state.
            let hgBinary = ProcessRunner.resolveBinaryPath(named: "hg") ?? context.hgBinary
            let args = ["push", alias]
            let result = try ProcessRunner.run(binary: hgBinary, arguments: args, currentDirectory: context.repoRoot, timeout: 60.0)
            guard result.isSuccess else {
                let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                // In Mercurial, "no changes found" (exit code 1) indicates the remote is already up to date and is not an error.
                if result.exitCode == 1 && (stdout.localizedCaseInsensitiveContains("no changes found") || stderr.localizedCaseInsensitiveContains("no changes found")) {
                    return
                }
                let msg = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "hg push failed with exit code \(result.exitCode)")
                throw NSError(domain: "VCSManager.push", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
    }

    /// Pulls changes from the specified remote repository.
    public nonisolated func pull(context: RepoContext, remote: String) throws {
        switch context.vcsType {
        case .git:
            let args = ["pull", remote]
            let result = try ProcessRunner.run(binary: "git", arguments: args, currentDirectory: context.repoRoot, timeout: 60.0)
            guard result.isSuccess else {
                let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "git pull failed with exit code \(result.exitCode)")
                throw NSError(domain: "VCSManager.pull", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: msg])
            }

        case .hg:
            // Ensure we use the path alias (e.g. "sin", "adl", "default"), never the full URL or path.
            var alias = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            if alias.contains("://") || alias.hasPrefix("/") {
                let remotes = fetchRemotes(context: context)
                if let matched = remotes.first(where: { $0.urlString == alias || $0.name == alias }) {
                    alias = matched.name
                }
            }

            let hgBinary = ProcessRunner.resolveBinaryPath(named: "hg") ?? context.hgBinary
            let args = ["pull", alias]
            let result = try ProcessRunner.run(binary: hgBinary, arguments: args, currentDirectory: context.repoRoot, timeout: 60.0)
            guard result.isSuccess else {
                let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                // In Mercurial, "no changes found" indicates already up to date.
                if result.exitCode == 1 && (stdout.localizedCaseInsensitiveContains("no changes found") || stderr.localizedCaseInsensitiveContains("no changes found")) {
                    return
                }
                let msg = !stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "hg pull failed with exit code \(result.exitCode)")
                throw NSError(domain: "VCSManager.pull", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
    }
}
