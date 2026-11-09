import Foundation
import SwiftUI
import AppKit

extension Color {
    public static let adaptiveYellow = Color(nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua || appearance.name.rawValue.lowercased().contains("dark") {
            return NSColor.systemYellow
        } else {
            return NSColor(srgbRed: 0.70, green: 0.53, blue: 0.0, alpha: 1.0)
        }
    })
}

public enum FileWorkingStatus: String, Sendable, Hashable {
    case clean
    case unknown   // purple
    case new       // green (added)
    case deleted   // red (removed)
    case modified  // orange
    case unknownFolder // yellow

    public var textColor: Color {
        switch self {
        case .unknown:
            return .purple
        case .new:
            return .green
        case .deleted:
            return .red
        case .modified:
            return .orange
        case .clean:
            return .secondary
        case .unknownFolder:
            return .adaptiveYellow
        }
    }

    public var badgeLabel: String {
        switch self {
        case .unknown:
            return "U"
        case .new:
            return "A"
        case .deleted:
            return "D"
        case .modified:
            return "M"
        case .clean:
            return "C"
        case .unknownFolder:
            return "U"
        }
    }

    public var commitSortPriority: Int {
        switch self {
        case .modified:
            return 0  // Modified first
        case .new:
            return 1  // then Added
        case .deleted:
            return 2  // then Removed
        case .unknown, .unknownFolder:
            return 3  // then Untracked
        case .clean:
            return 4
        }
    }
}

public final class FileTreeNode: Identifiable, Hashable {
    public let id: String // Unique relative path within the repository
    public let name: String
    public let fullURL: URL
    public let isDirectory: Bool
    public var status: FileWorkingStatus
    public var children: [FileTreeNode]?
    public let nameLowercased: String
    public internal(set) var totalFileCount: Int

    public init(
        id: String,
        name: String,
        fullURL: URL,
        isDirectory: Bool,
        status: FileWorkingStatus = .clean,
        children: [FileTreeNode]? = nil,
        totalFileCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.fullURL = fullURL
        self.isDirectory = isDirectory
        self.status = status
        self.children = children
        self.nameLowercased = name.lowercased()
        if let count = totalFileCount {
            self.totalFileCount = count
        } else if isDirectory {
            self.totalFileCount = children?.reduce(0) { $0 + $1.totalFileCount } ?? 0
        } else {
            self.totalFileCount = 1
        }
    }

    public var nodeIdentity: String {
        "\(id):\(status.rawValue)"
    }

    public static func == (lhs: FileTreeNode, rhs: FileTreeNode) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.children == rhs.children
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(status)
    }

    public var statusTextColor: Color? {
        switch status {
        case .unknown:
            return .purple
        case .new:
            return .green
        case .deleted:
            return .red
        case .modified:
            return .orange
        case .clean:
            return nil
        case .unknownFolder:
            return .adaptiveYellow
        }
    }

    public func hasChanges() -> Bool {
        if isDirectory {
            return children?.contains(where: { $0.hasChanges() }) ?? false
        }
        return status != .clean
    }

    /// Returns true if this directory contains at least one untracked (.unknown) file
    /// and no modified, new (added), or deleted files among any of its descendants.
    public func containsOnlyUntrackedFiles() -> Bool {
        guard isDirectory else { return status == .unknown }
        guard let children = children, !children.isEmpty else { return false }
        var hasUntracked = false
        var hasTrackedChanges = false

        func inspect(_ n: FileTreeNode) {
            if !n.isDirectory {
                if n.status == .unknown {
                    hasUntracked = true
                } else if n.status == .modified || n.status == .new || n.status == .deleted {
                    hasTrackedChanges = true
                }
            } else if let ch = n.children {
                for c in ch {
                    inspect(c)
                }
            }
        }

        inspect(self)
        return hasUntracked && !hasTrackedChanges
    }

    @discardableResult
    public func computeStatus() -> FileWorkingStatus {
        if !isDirectory {
            return status
        }

        guard let children = children, !children.isEmpty else {
            return status
        }

        let childStatuses = children.map { $0.computeStatus() }

        // Rule 5: If a directory has been added, color it green
        if childStatuses.allSatisfy({ $0 == .new }) {
            self.status = .new
            return .new
        }

        // Rule 6: If a directory has been removed, color it red
        if childStatuses.allSatisfy({ $0 == .deleted }) {
            self.status = .deleted
            return .deleted
        }

        // Rule 7: If a directory has any files or directories new, removed or modified, color it orange.
        // This should recurse up the tree.
        if childStatuses.contains(where: { $0 == .new || $0 == .deleted || $0 == .modified }) {
            self.status = .modified
            return .modified
        }

        // If directory has unknown files or subfolders, color it yellow (.unknownFolder)
        if childStatuses.contains(where: { $0 == .unknown || $0 == .unknownFolder }) {
            self.status = .unknownFolder
            return .unknownFolder
        }

        self.status = .clean
        return .clean
    }

    public func clone() -> FileTreeNode {
        let clonedChildren = children?.map { $0.clone() }
        return FileTreeNode(
            id: id,
            name: name,
            fullURL: fullURL,
            isDirectory: isDirectory,
            status: status,
            children: clonedChildren,
            totalFileCount: totalFileCount
        )
    }

    public func findNode(withRelativePath path: String) -> FileTreeNode? {
        let normPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normId = id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normId == normPath {
            return self
        }
        if isDirectory, let children = children {
            for child in children {
                if let found = child.findNode(withRelativePath: normPath) {
                    return found
                }
            }
        }
        return nil
    }

    @discardableResult
    public func updateNodeStatus(targetPath: String, newStatus: FileWorkingStatus) -> Bool {
        let normPath = targetPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normId = id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normId == normPath {
            self.status = newStatus
            return true
        }
        guard isDirectory, let children = children else { return false }
        var found = false
        for child in children {
            if child.updateNodeStatus(targetPath: normPath, newStatus: newStatus) {
                found = true
                break
            }
        }
        if found {
            computeStatus()
        }
        return found
    }

    @discardableResult
    public func removeNode(targetPath: String) -> (removed: Bool, fileCountDelta: Int) {
        let normPath = targetPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard isDirectory, var currentChildren = children else { return (false, 0) }

        if let index = currentChildren.firstIndex(where: {
            $0.id.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normPath
        }) {
            let removedItem = currentChildren.remove(at: index)
            let delta = removedItem.totalFileCount
            self.children = currentChildren
            self.totalFileCount = max(0, self.totalFileCount - delta)
            computeStatus()
            return (true, delta)
        }

        for child in currentChildren {
            let (removed, delta) = child.removeNode(targetPath: normPath)
            if removed {
                self.totalFileCount = max(0, self.totalFileCount - delta)
                if child.isDirectory && (child.children?.isEmpty ?? true) {
                    currentChildren.removeAll { $0 === child }
                    self.children = currentChildren
                }
                computeStatus()
                return (true, delta)
            }
        }
        return (false, 0)
    }

    public var iconName: String {
        if isDirectory {
            return "folder"
        }
        let ext = fullURL.pathExtension.lowercased()
        switch ext {
        case "swift":
            return "swift"
        case "c", "cpp", "cc", "cxx", "h", "hpp", "m", "mm":
            return "curlybraces"
        case "py":
            return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "jsx", "tsx":
            return "applescript"
        case "json", "yaml", "yml", "xml", "plist":
            return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "icns", "pdf":
            return "photo"
        case "md", "markdown", "txt", "rtf":
            return "doc.plaintext"
        case "sh", "zsh", "bash":
            return "terminal"
        default:
            return "doc"
        }
    }

    public var iconColor: Color {
        if isDirectory {
            return Color(NSColor.systemBlue)
        }
        let ext = fullURL.pathExtension.lowercased()
        switch ext {
        case "swift":
            return .orange
        case "c", "cpp", "cc", "cxx", "h", "hpp", "m", "mm":
            return .purple
        case "py":
            return .teal
        case "js", "ts", "jsx", "tsx":
            return .adaptiveYellow
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "icns", "pdf":
            return .green
        case "sh", "zsh", "bash":
            return .pink
        default:
            return .secondary
        }
    }

    public func filter(query: String, onlyModified: Bool = false, showUntracked: Bool = true) -> FileTreeNode? {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.isEmpty && !onlyModified && showUntracked { return self }
        return filter(cleanQuery: clean, onlyModified: onlyModified, showUntracked: showUntracked)
    }

    private func filter(cleanQuery: String, onlyModified: Bool, showUntracked: Bool) -> FileTreeNode? {
        if isDirectory {
            let matchedChildren = children?.compactMap { $0.filter(cleanQuery: cleanQuery, onlyModified: onlyModified, showUntracked: showUntracked) } ?? []
            if !matchedChildren.isEmpty || (!cleanQuery.isEmpty && !onlyModified && showUntracked && nameLowercased.contains(cleanQuery)) {
                let count = matchedChildren.reduce(0) { $0 + $1.totalFileCount }
                return FileTreeNode(
                    id: id,
                    name: name,
                    fullURL: fullURL,
                    isDirectory: true,
                    status: status,
                    children: matchedChildren,
                    totalFileCount: count
                )
            }
            return nil
        } else {
            let matchesQuery = cleanQuery.isEmpty || nameLowercased.contains(cleanQuery)
            let matchesModified = !onlyModified || (status != .clean)
            let matchesUntracked = showUntracked || (status != .unknown)
            return (matchesQuery && matchesModified && matchesUntracked) ? self : nil
        }
    }
}

extension FileTreeNode {
    public static func buildTree(
        from statusMap: [String: FileWorkingStatus],
        repoRoot: URL
    ) -> [FileTreeNode] {
        class TempDir {
            let name: String
            let relPath: String
            var subdirs: [String: TempDir] = [:]
            var files: [String: (relPath: String, status: FileWorkingStatus)] = [:]

            init(name: String, relPath: String) {
                self.name = name
                self.relPath = relPath
            }

            func toNode(repoRoot: URL) -> FileTreeNode {
                let sortedSubdirs = subdirs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let sortedFiles = files.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

                let childNodes = sortedSubdirs.map { $0.toNode(repoRoot: repoRoot) } +
                    sortedFiles.map { (fileName, fileInfo) in
                        FileTreeNode(
                            id: fileInfo.relPath,
                            name: fileName,
                            fullURL: repoRoot.appendingPathComponent(fileInfo.relPath),
                            isDirectory: false,
                            status: fileInfo.status,
                            children: nil
                        )
                    }

                let fullURL = relPath.isEmpty ? repoRoot : repoRoot.appendingPathComponent(relPath)
                let dirNode = FileTreeNode(
                    id: relPath.isEmpty ? "/" : relPath,
                    name: name,
                    fullURL: fullURL,
                    isDirectory: true,
                    status: .clean,
                    children: childNodes
                )
                dirNode.computeStatus()
                return dirNode
            }
        }

        let root = TempDir(name: "", relPath: "")

        for (path, status) in statusMap {
            let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty else { continue }
            let components = normalized.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            var current = root
            var currentRel = ""

            for i in 0..<(components.count - 1) {
                let comp = components[i]
                currentRel = currentRel.isEmpty ? comp : "\(currentRel)/\(comp)"
                if let next = current.subdirs[comp] {
                    current = next
                } else {
                    let newDir = TempDir(name: comp, relPath: currentRel)
                    current.subdirs[comp] = newDir
                    current = newDir
                }
            }

            let fileName = components.last!
            let fileRel = currentRel.isEmpty ? fileName : "\(currentRel)/\(fileName)"
            current.files[fileName] = (fileRel, status)
        }

        let sortedSubdirs = root.subdirs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let sortedFiles = root.files.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        let topNodes = sortedSubdirs.map { $0.toNode(repoRoot: repoRoot) } +
            sortedFiles.map { (fileName, fileInfo) in
                FileTreeNode(
                    id: fileInfo.relPath,
                    name: fileName,
                    fullURL: repoRoot.appendingPathComponent(fileInfo.relPath),
                    isDirectory: false,
                    status: fileInfo.status,
                    children: nil
                )
            }

        topNodes.forEach { $0.computeStatus() }
        return topNodes
    }

    public static func buildTree(from relativePaths: [String], repoRoot: URL) -> [FileTreeNode] {
        var map: [String: FileWorkingStatus] = [:]
        for path in relativePaths {
            map[path] = .clean
        }
        return buildTree(from: map, repoRoot: repoRoot)
    }
}

extension Array where Element == FileTreeNode {
    public func clone() -> [FileTreeNode] {
        self.map { $0.clone() }
    }

    public func findNode(withRelativePath path: String) -> FileTreeNode? {
        let normPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for node in self {
            if let found = node.findNode(withRelativePath: normPath) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    public mutating func updateNodeStatus(targetPath: String, newStatus: FileWorkingStatus) -> Bool {
        let normPath = targetPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for node in self {
            let normId = node.id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if normId == normPath {
                node.status = newStatus
                return true
            }
            if node.updateNodeStatus(targetPath: normPath, newStatus: newStatus) {
                return true
            }
        }
        return false
    }

    @discardableResult
    public mutating func removeNode(targetPath: String) -> Bool {
        let normPath = targetPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let idx = self.firstIndex(where: { $0.id.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normPath }) {
            self.remove(at: idx)
            return true
        }
        for node in self {
            let (removed, _) = node.removeNode(targetPath: normPath)
            if removed {
                if node.isDirectory && (node.children?.isEmpty ?? true) {
                    self.removeAll { $0 === node }
                }
                return true
            }
        }
        return false
    }

    /// Collects the IDs of all directory nodes in this tree that contain only untracked files.
    public func defaultCollapsedUntrackedNodeIds() -> Set<String> {
        var collapsed = Set<String>()
        func scan(_ node: FileTreeNode) {
            if node.isDirectory {
                if node.containsOnlyUntrackedFiles() {
                    collapsed.insert(node.id)
                }
                node.children?.forEach(scan)
            }
        }
        self.forEach(scan)
        return collapsed
    }
}
