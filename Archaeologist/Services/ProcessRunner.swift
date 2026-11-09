import Foundation

public struct ProcessResult {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data

    public var stdoutString: String {
        String(data: stdoutData, encoding: .utf8) ?? String(decoding: stdoutData, as: UTF8.self)
    }

    public var stderrString: String {
        String(data: stderrData, encoding: .utf8) ?? String(decoding: stderrData, as: UTF8.self)
    }

    public var isSuccess: Bool {
        exitCode == 0
    }
}

public enum ProcessRunner {
    private static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    public static func resolveBinaryPath(named name: String) -> String? {
        if name.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: name) {
            return name
        }

        // Check common PATH locations first
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        // Also check PATH environment variable
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let candidate = (String(dir) as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    /// Drains any data currently available in the file handle's underlying pipe buffer without blocking.
    private static func drainNonBlocking(handle: FileHandle, into data: inout Data) {
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else {
                break
            }
        }
    }

    public static func run(
        binary: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) throws -> ProcessResult {
        guard let binaryPath = resolveBinaryPath(named: binary) else {
            throw NSError(
                domain: "ProcessRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Binary '\(binary)' not found in search paths."]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments

        if let currentDirectory = currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        var env = ProcessInfo.processInfo.environment
        let fullPath = searchPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        env["PATH"] = fullPath
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "echo"
        env["GIT_PAGER"] = "cat"
        env["GIT_FLUSH"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["PAGER"] = "cat"
        env["HGPLAIN"] = "1" // Mercurial plain output for scripts
        env["PYTHONUNBUFFERED"] = "1" // Immediate unbuffered output from Python
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        _ = fcntl(stdoutPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutWriteHandle = stdoutPipe.fileHandleForWriting
        let stderrWriteHandle = stderrPipe.fileHandleForWriting

        var stdoutData = Data()
        var stderrData = Data()
        let ioQueue = DispatchQueue(label: "com.archaeologist.processrunner.io.\(UUID().uuidString)")
        let handlerLock = NSLock()

        defer {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            try? stdoutWriteHandle.close()
            try? stderrWriteHandle.close()
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        stdoutHandle.readabilityHandler = { handle in
            handlerLock.lock()
            defer { handlerLock.unlock() }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                ioQueue.async {
                    stdoutData.append(chunk)
                }
            }
        }

        stderrHandle.readabilityHandler = { handle in
            handlerLock.lock()
            defer { handlerLock.unlock() }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                ioQueue.async {
                    stderrData.append(chunk)
                }
            }
        }

        try process.run()
        // Close parent write ends immediately so child has the only active write descriptors
        try? stdoutWriteHandle.close()
        try? stderrWriteHandle.close()

        // Wait for process with optional timeout
        if let timeout = timeout {
            let semaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                semaphore.signal()
            }
            if !process.isRunning {
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                _ = semaphore.wait(timeout: .now() + 1.0)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                throw NSError(
                    domain: "ProcessRunner",
                    code: 124,
                    userInfo: [NSLocalizedDescriptionKey: "Process '\(binary)' timed out after \(timeout) seconds."]
                )
            }
        } else {
            process.waitUntilExit()
        }

        // Child process has terminated. Detach readability handlers so we do not wait on grandchildren.
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        // Ensure any in-flight readabilityHandler block has completed, then drain remaining buffer
        handlerLock.lock()
        ioQueue.sync {
            drainNonBlocking(handle: stdoutHandle, into: &stdoutData)
            drainNonBlocking(handle: stderrHandle, into: &stderrData)
        }
        handlerLock.unlock()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdoutData: stdoutData,
            stderrData: stderrData
        )
    }

    public static func startLineStream(
        binary: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> (process: Process, lines: AsyncLineSequence<FileHandle.AsyncBytes>) {
        guard let binaryPath = resolveBinaryPath(named: binary) else {
            throw NSError(
                domain: "ProcessRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Binary '\(binary)' not found in search paths."]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments

        if let currentDirectory = currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        var env = ProcessInfo.processInfo.environment
        let fullPath = searchPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        env["PATH"] = fullPath
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "echo"
        env["GIT_PAGER"] = "cat"
        env["GIT_FLUSH"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["PAGER"] = "cat"
        env["HGPLAIN"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        _ = fcntl(stdoutPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { _ in
            stderrHandle.readabilityHandler = nil
            try? stderrHandle.close()
        }

        try process.run()
        // Close parent's copy of write handles so EOF is delivered to readers when the child exits
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        return (process, stdoutPipe.fileHandleForReading.bytes.lines)
    }
}
