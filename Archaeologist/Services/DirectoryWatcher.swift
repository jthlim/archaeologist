import Foundation
import CoreServices

public final class DirectoryWatcher: @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let path: String
    private let onEvent: @Sendable ([String]) -> Void

    public init(url: URL, onEvent: @escaping @Sendable ([String]) -> Void) {
        self.path = url.standardizedFileURL.path
        self.onEvent = onEvent
        start()
    }

    deinit {
        stop()
    }

    private func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            if paths.contains(where: { DirectoryWatcher.isRelevantChange(at: $0) }) {
                watcher.onEvent(paths)
            }
        }

        streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // Latency in seconds
            flags
        )

        if let stream = streamRef {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    public static func isRelevantChange(at path: String) -> Bool {
        if path.hasSuffix(".DS_Store") || path.contains("/.build/") || path.contains("/DerivedData/") {
            return false
        }
        if path.contains("/.git/") || path.hasSuffix("/.git") {
            // Inside .git, only care about commits/branch changes (e.g. refs, HEAD, MERGE_HEAD)
            // Discard index.lock, index, logs, FETCH_HEAD, etc.
            if path.contains("/.git/refs/") || path.hasSuffix("/.git/HEAD") || path.hasSuffix("/.git/MERGE_HEAD") {
                return true
            }
            return false
        }
        if path.contains("/.hg/") || path.hasSuffix("/.hg") {
            // Inside .hg, only care about commits/branch changes (dirstate, branch, 00changelog)
            // Discard lock files like wlock, lock, etc.
            if path.hasSuffix("/.hg/dirstate") || path.hasSuffix("/.hg/branch") || path.contains("/.hg/store/00changelog") {
                return true
            }
            return false
        }
        // Any other file change in the repository working directory is relevant
        return true
    }

    public func stop() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
    }
}
