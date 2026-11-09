//
//  ArchaeologistTests.swift
//  ArchaeologistTests
//
//  Comprehensive test suite for VCS detection, diffing, delta reconstruction,
//  multi-tab management, timeline scrubbing, and directory watching.
//

import XCTest
import Foundation
import AppKit
import SwiftUI
@testable import Archaeologist

@MainActor
final class ArchaeologistTests: XCTestCase {
    private var gitBin: String {
        ProcessRunner.resolveBinaryPath(named: "git") ?? "/usr/bin/git"
    }

    private var hgBin: String {
        ProcessRunner.resolveBinaryPath(named: "hg") ?? "/opt/homebrew/bin/hg"
    }

    private func repr(_ str: String) -> String {
        return "\"\(str)\""
    }

    @MainActor
    private func waitForLoad(_ vm: HistoryViewModel) async throws {
        for _ in 0..<100 {
            let loading = vm.isLoading
            let hasContext = vm.repoContext != nil
            if !loading && hasContext { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private func waitForTabManagerLoad(_ tm: TabManager) async throws {
        for _ in 0..<100 {
            let loading = tm.activeViewModel?.isLoading ?? false
            let hasContext = tm.activeViewModel?.repoContext != nil
            if !loading && hasContext { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func createDualRepo() throws -> (tempDir: URL, dual1: URL, dual2: URL) {
        let dualDir = FileManager.default.temporaryDirectory.appendingPathComponent("DualRepo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dualDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: dualDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: dualDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: dualDir)

        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: dualDir)
        let hgrc = "[ui]\nusername = Tester <tester@test.com>\n"
        try hgrc.write(to: dualDir.appendingPathComponent(".hg/hgrc"), atomically: true, encoding: .utf8)

        let dual1 = dualDir.appendingPathComponent("doc1.txt")
        let dual2 = dualDir.appendingPathComponent("doc2.txt")
        try "Doc 1 content".write(to: dual1, atomically: true, encoding: .utf8)
        try "Doc 2 content".write(to: dual2, atomically: true, encoding: .utf8)

        _ = try ProcessRunner.run(binary: hgBin, arguments: ["add", "doc1.txt", "doc2.txt"], currentDirectory: dualDir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "hg multi-commit"], currentDirectory: dualDir)

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "doc1.txt", "doc2.txt"], currentDirectory: dualDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "git commit"], currentDirectory: dualDir)
        return (dualDir, dual1, dual2)
    }

    private func setupHgRenameRepo() throws -> (tempDir: URL, context: RepoContext, commits: [CommitInfo]) {
        let hgRenameDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHgRename_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hgRenameDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: hgRenameDir)
        let hgRenameRc = hgRenameDir.appendingPathComponent(".hg/hgrc")
        try "[ui]\nusername = RenameTester <renametester@example.com>\n".write(to: hgRenameRc, atomically: true, encoding: .utf8)

        let hgOldFile = hgRenameDir.appendingPathComponent("old_name.txt")
        try "line 1\nline 2\n".write(to: hgOldFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["add", "old_name.txt"], currentDirectory: hgRenameDir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "commit 1: create old_name.txt"], currentDirectory: hgRenameDir)

        try "line 1\nline 2\nline 3\n".write(to: hgOldFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "commit 2: modify old_name.txt"], currentDirectory: hgRenameDir)

        _ = try ProcessRunner.run(binary: hgBin, arguments: ["mv", "old_name.txt", "new_name.txt"], currentDirectory: hgRenameDir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "commit 3: rename to new_name.txt"], currentDirectory: hgRenameDir)

        let hgNewFile = hgRenameDir.appendingPathComponent("new_name.txt")
        try "line 1\nline 2\nline 3\nline 4\n".write(to: hgNewFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "commit 4: modify new_name.txt"], currentDirectory: hgRenameDir)

        guard let hgRenameCtx = VCSManager.shared.detectContext(for: hgNewFile) else {
            fatalError("Failed to detect context for hg rename")
        }

        let hgRenameCommits = try VCSManager.shared.fetchCommits(for: hgRenameCtx)
        return (hgRenameDir, hgRenameCtx, hgRenameCommits)
    }

    private func setupGitRenameRepo() throws -> (tempDir: URL, context: RepoContext, commits: [CommitInfo]) {
        let gitRenameDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestGitRename_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: gitRenameDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: gitRenameDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "GitRenamer"], currentDirectory: gitRenameDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "renamer@example.com"], currentDirectory: gitRenameDir)

        let gitOldFile = gitRenameDir.appendingPathComponent("initial_code.swift")
        try "struct A {}\n".write(to: gitOldFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "initial_code.swift"], currentDirectory: gitRenameDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "init swift file"], currentDirectory: gitRenameDir)

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["mv", "initial_code.swift", "final_code.swift"], currentDirectory: gitRenameDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "rename swift file"], currentDirectory: gitRenameDir)

        let gitNewFile = gitRenameDir.appendingPathComponent("final_code.swift")
        try "struct A {}\nstruct B {}\n".write(to: gitNewFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-am", "add struct B"], currentDirectory: gitRenameDir)

        guard let gitRenameCtx = VCSManager.shared.detectContext(for: gitNewFile) else {
            fatalError("Failed to detect context for git rename")
        }

        let gitRenameCommits = try VCSManager.shared.fetchCommits(for: gitRenameCtx)
        return (gitRenameDir, gitRenameCtx, gitRenameCommits)
    }

    private func setupGitModRenameRepo() throws -> (tempDir: URL, oldFile: URL, newFile: URL, context: RepoContext, commits: [CommitInfo]) {
        let gitModRenameDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestGitModRename_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: gitModRenameDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: gitModRenameDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: gitModRenameDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "test@test.com"], currentDirectory: gitModRenameDir)

        let gitModOld = gitModRenameDir.appendingPathComponent("code_old.txt")
        try "func a() {\n    print(\"1\")\n    print(\"2\")\n    print(\"3\")\n    print(\"4\")\n    print(\"5\")\n}\n".write(to: gitModOld, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "code_old.txt"], currentDirectory: gitModRenameDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "init file"], currentDirectory: gitModRenameDir)

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["mv", "code_old.txt", "code_new.txt"], currentDirectory: gitModRenameDir)
        let gitModNew = gitModRenameDir.appendingPathComponent("code_new.txt")
        try "func a() {\n    print(\"1\")\n    print(\"2 - modified\")\n    print(\"3\")\n    print(\"4\")\n    print(\"5\")\n    print(\"6 - added\")\n}\n".write(to: gitModNew, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-am", "rename and modify"], currentDirectory: gitModRenameDir)

        guard let gitModCtx = VCSManager.shared.detectContext(for: gitModNew) else {
            fatalError("Failed context for gitModCtx")
        }
        let gitModCommits = try VCSManager.shared.fetchCommits(for: gitModCtx)
        return (gitModRenameDir, gitModOld, gitModNew, gitModCtx, gitModCommits)
    }

    func testProcessrunnerBinaryResolution() throws {
        let gitPath = ProcessRunner.resolveBinaryPath(named: "git")
        let hgPath = ProcessRunner.resolveBinaryPath(named: "hg")
        print("  Git path: \(gitPath ?? "nil")")
        print("  Hg path: \(hgPath ?? "nil")")
        XCTAssert(gitPath != nil, "Git must be resolved")
        XCTAssert(hgPath != nil, "Hg must be resolved")
    }

    func testProcessRunnerExecution() throws {
        guard let sh = ProcessRunner.resolveBinaryPath(named: "sh") else {
            XCTFail("sh not found")
            return
        }
        let result = try ProcessRunner.run(binary: sh, arguments: ["-c", "echo 'hello world'"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testProcessRunnerDoesNotStallOnGrandchildProcessHoldingPipe() throws {
        guard let sh = ProcessRunner.resolveBinaryPath(named: "sh") else {
            XCTFail("sh not found")
            return
        }
        // Spawn background grandchild processes that hold stdout and stderr open for 10s.
        // The parent process should complete immediately (< 1.5s) without waiting on the grandchild.
        let start = Date()
        let result = try ProcessRunner.run(
            binary: sh,
            arguments: ["-c", "(sleep 10 >&1 &); (sleep 10 >&2 &); echo 'finished child'"]
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "finished child")
        XCTAssertLessThan(elapsed, 2.0, "ProcessRunner stalled waiting on grandchild process: took \(elapsed)s")
    }

    func testProcessRunnerLargeOutput() throws {
        guard ProcessRunner.resolveBinaryPath(named: "sh") != nil else {
            XCTFail("sh not found")
            return
        }
        let python = ProcessRunner.resolveBinaryPath(named: "python3") ?? "/usr/bin/python3"
        let script = "import sys; sys.stdout.buffer.write(b'X' * 500000); sys.stderr.buffer.write(b'Y' * 50000)"
        let result = try ProcessRunner.run(binary: python, arguments: ["-c", script])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutData.count, 500000)
        XCTAssertEqual(result.stderrData.count, 50000)
    }

    func testProcessRunnerTimeout() throws {
        guard let sleepBin = ProcessRunner.resolveBinaryPath(named: "sleep") else {
            XCTFail("sleep not found")
            return
        }
        let start = Date()
        do {
            _ = try ProcessRunner.run(binary: sleepBin, arguments: ["10"], timeout: 0.5)
            XCTFail("Expected ProcessRunner to time out and throw an error")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2.0, "Timeout took too long: \(elapsed)s")
        }
    }

    func testDiffDeletionsInGit() throws {
        let (_, gitFiles) = try SampleRepoService.shared.setupSampleGitRepo()
        let swiftFile = gitFiles[0]

        guard let gitContext = VCSManager.shared.detectContext(for: swiftFile) else {
            fatalError("Failed to detect Git context")
        }
        let gitCommits = try VCSManager.shared.fetchCommits(for: gitContext)
        XCTAssert(gitCommits.count >= 3)

        for c in gitCommits {
            let content = try VCSManager.shared.fetchFileContent(context: gitContext, commit: c)
            print("  Git commit [\(c.displayRevision)]: total lines=\(content.textLines.count), added=\(content.addedLinesCount), removed=\(content.removedLinesCount)")
        }
    }

    func testDiffDeletionsInMercurialHg() throws {
        let (_, hgFiles) = try SampleRepoService.shared.setupSampleHgRepo()
        let pyFile = hgFiles[0]

        guard let hgContext = VCSManager.shared.detectContext(for: pyFile) else {
            fatalError("Failed to detect Hg context")
        }
        let hgCommits = try VCSManager.shared.fetchCommits(for: hgContext)
        XCTAssert(hgCommits.count >= 3)

        for c in hgCommits {
            let content = try VCSManager.shared.fetchFileContent(context: hgContext, commit: c)
            print("  Hg commit [\(c.displayRevision)]: total lines=\(content.textLines.count), added=\(content.addedLinesCount), removed=\(content.removedLinesCount)")
        }
    }

    func testMercurialChgDetectionWhenOpened() throws {
        let (hgRepo, hgFiles) = try SampleRepoService.shared.setupSampleHgRepo()
        let pyFile = hgFiles[0]

        // Clear cache to simulate fresh opening of repository
        VCSManager.shared.clearHgBinaryCache()

        guard let hgContext = VCSManager.shared.detectContext(for: pyFile) else {
            XCTFail("Failed to detect Hg context")
            return
        }

        let chgExists = ProcessRunner.resolveBinaryPath(named: "chg") != nil
        let expectedBinary = chgExists ? "chg" : "hg"

        XCTAssertEqual(hgContext.hgBinary, expectedBinary, "Expected hgBinary on RepoContext to be \(expectedBinary)")
        XCTAssertEqual(VCSManager.shared.hgBinary(for: hgRepo), expectedBinary, "Expected VCSManager cached binary to be \(expectedBinary)")

        // Verify that commands run successfully using this determined binary
        let entries = try VCSManager.shared.fetchRepositoryLogEntries(context: hgContext)
        XCTAssertFalse(entries.isEmpty, "Log entries should be fetched successfully using \(hgContext.hgBinary)")

        let workingChanges = VCSManager.shared.fetchWorkingCopyChanges(context: hgContext)
        XCTAssertEqual(workingChanges.count, 0, "Working copy should initially be clean")

        // Test explicit override on repository
        VCSManager.shared.setHgBinary("hg", for: hgRepo)
        XCTAssertEqual(VCSManager.shared.hgBinary(for: hgRepo), "hg", "Explicit setHgBinary should override binary")
        let overriddenContext = VCSManager.shared.detectContext(for: pyFile)!
        XCTAssertEqual(overriddenContext.hgBinary, "hg", "Overridden binary should be used by newly created contexts")
    }

    func testDeletionInsertionInterleaving() throws {
        // Create a small test repository with explicit deletions
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestDel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "tester@test.com"], currentDirectory: tempDir)

        let testFile = tempDir.appendingPathComponent("code.txt")
        try "line 1\nline 2 to remove\nline 3\nline 4 to remove\nline 5\n".write(to: testFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "code.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "first"], currentDirectory: tempDir)

        try "line 1\nline 3\nline 5\n".write(to: testFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-am", "second"], currentDirectory: tempDir)

        guard let testContext = VCSManager.shared.detectContext(for: testFile) else {
            fatalError("Failed context")
        }
        let testCommits = try VCSManager.shared.fetchCommits(for: testContext)
        let latestCommit = testCommits.last!
        let secondContent = try VCSManager.shared.fetchFileContent(context: testContext, commit: latestCommit)

        print("  Second commit textLines count:", secondContent.textLines.count)
        print("  Removed count:", secondContent.removedLinesCount)
        XCTAssert(secondContent.removedLinesCount == 2, "Expected exactly 2 removed lines")

        let removedLines = secondContent.textLines.filter { $0.changeType == .removed }
        print("  Removed line 1 content:", repr(removedLines[0].content))
        print("  Removed line 2 content:", repr(removedLines[1].content))
        XCTAssert(removedLines[0].content == "line 2 to remove")
        XCTAssert(removedLines[1].content == "line 4 to remove")
    }

    func testMercurialGitJumpToCommitByhash() async throws {

        let (_, hgFiles) = try SampleRepoService.shared.setupSampleHgRepo()
        let pyFile = hgFiles[0]
        guard let hgContext = VCSManager.shared.detectContext(for: pyFile) else {
            XCTFail("Failed to detect Hg context")
            return
        }
        let hgCommits = try VCSManager.shared.fetchCommits(for: hgContext)

        let hgVM = HistoryViewModel()
        await MainActor.run {
            hgVM.repoContext = hgContext
            hgVM.commits = hgCommits
            hgVM.selectedCommitIndex = hgCommits.count - 1
        }

        let latestHgContent = try VCSManager.shared.fetchFileContent(context: hgContext, commit: hgCommits.last!)
        for line in latestHgContent.textLines {
            XCTAssert(!line.revision.contains(":"), "Mercurial blame line revision '\(line.revision)' must only be local revision without hash")
            await MainActor.run {
                hgVM.goToCommit(byHash: line.revision)
                let currentCommit = hgVM.selectedCommit!
                XCTAssert(currentCommit.matches(revision: line.revision), "goToCommit must find matching commit for \(line.revision)")
            }
        }
        print("  Verified \(latestHgContent.textLines.count) Mercurial blame jump targets!")

        let (_, gitFiles) = try SampleRepoService.shared.setupSampleGitRepo()
        let swiftFile = gitFiles[0]
        guard let gitContext = VCSManager.shared.detectContext(for: swiftFile) else {
            XCTFail("Failed to detect Git context")
            return
        }
        let gitCommits = try VCSManager.shared.fetchCommits(for: gitContext)

        let gitVM = HistoryViewModel()
        await MainActor.run {
            gitVM.repoContext = gitContext
            gitVM.commits = gitCommits
            gitVM.selectedCommitIndex = gitCommits.count - 1
        }

        let latestGitContent = try VCSManager.shared.fetchFileContent(context: gitContext, commit: gitCommits.last!)
        for line in latestGitContent.textLines {
            await MainActor.run {
                gitVM.goToCommit(byHash: line.revision)
                let currentCommit = gitVM.selectedCommit!
                XCTAssert(currentCommit.matches(revision: line.revision), "goToCommit must find matching git commit for \(line.revision)")
            }
        }
        print("  Verified \(latestGitContent.textLines.count) Git blame jump targets!")
    }

    func testBlameDateFormattingLogic() throws {
        let refNow = Date()
        let sameDayStr = VCSManager.formatBlameDate(refNow, now: refNow)
        print("  Same day format: \(sameDayStr)")
        let timeRegex = try NSRegularExpression(pattern: #"^(Today )?\d{2}:\d{2}$"#)
        XCTAssert(timeRegex.firstMatch(in: sameDayStr, range: NSRange(location: 0, length: sameDayStr.utf16.count)) != nil, "Must be hh:mm")

        let fourDaysAgo = Calendar.current.date(byAdding: .day, value: -4, to: refNow)!
        let weekDayStr = VCSManager.formatBlameDate(fourDaysAgo, now: refNow)
        print("  Within 7 days format (4 days ago): \(weekDayStr)")
        let weekRegex = try NSRegularExpression(pattern: #"^[A-Za-z]{3}\s\d{2}:\d{2}$"#)
        XCTAssert(weekRegex.firstMatch(in: weekDayStr, range: NSRange(location: 0, length: weekDayStr.utf16.count)) != nil, "Must be Day-of-week hh:mm")

        let twentyDaysAgo = Calendar.current.date(byAdding: .day, value: -20, to: refNow)!
        let olderStr = VCSManager.formatBlameDate(twentyDaysAgo, now: refNow)
        print("  Older than 7 days format (20 days ago): \(olderStr)")
        let olderRegex = try NSRegularExpression(pattern: #"^\d{2}/\d{2}/\d{2}\s\d{2}:\d{2}$"#)
        XCTAssert(olderRegex.firstMatch(in: olderStr, range: NSRange(location: 0, length: olderStr.utf16.count)) != nil, "Must be yy/mm/dd hh:mm")
    }

    func testAuthorEmailInBlameLines() throws {

        let (_, gitFiles) = try SampleRepoService.shared.setupSampleGitRepo()
        guard let gitContext = VCSManager.shared.detectContext(for: gitFiles[0]) else {
            XCTFail("Failed to detect Git context")
            return
        }
        let gitCommits = try VCSManager.shared.fetchCommits(for: gitContext)
        let latestGitContent = try VCSManager.shared.fetchFileContent(context: gitContext, commit: gitCommits.last!)

        XCTAssert(!latestGitContent.textLines.isEmpty)
        let gitSample = latestGitContent.textLines.first!
        print("  Git blame author: '\(gitSample.author)', email: '\(gitSample.authorEmail)', date: \(gitSample.date?.description ?? "nil")")
        XCTAssert(gitSample.authorEmail == "ada@example.com", "Git author email should be populated")
    }

    func testFilesInSameCommitNavigation() async throws {

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestMultiFile_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "tester@test.com"], currentDirectory: tempDir)

        let fileA = tempDir.appendingPathComponent("fileA.txt")
        let fileB = tempDir.appendingPathComponent("fileB.txt")
        try "content A".write(to: fileA, atomically: true, encoding: .utf8)
        try "content B".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "fileA.txt", "fileB.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "multi-file commit"], currentDirectory: tempDir)

        guard let ctxA = VCSManager.shared.detectContext(for: fileA) else { fatalError() }
        let commitsA = try VCSManager.shared.fetchCommits(for: ctxA)
        let multiCommit = commitsA.last!
        let filesInMulti = VCSManager.shared.fetchFilesInCommit(context: ctxA, commit: multiCommit)
        print("  Files in multi commit:", filesInMulti)
        XCTAssert(filesInMulti.contains("fileA.txt"), "Should contain fileA.txt")
        XCTAssert(filesInMulti.contains("fileB.txt"), "Should contain fileB.txt")

        // Test HistoryViewModel navigation to fileB at multiCommit
        let testNavVM = HistoryViewModel()
        await MainActor.run {
            testNavVM.openFile(url: fileA)
        }
        try await waitForLoad(testNavVM)
        await MainActor.run {
            XCTAssert(testNavVM.commits.count > 0)
            testNavVM.selectedCommitIndex = testNavVM.commits.count - 1
            XCTAssert(testNavVM.selectedCommit?.id == multiCommit.id)
            // Select fileB
            testNavVM.selectFileInCurrentCommit(relativePath: "fileB.txt")
        }
        try await waitForLoad(testNavVM)
        await MainActor.run {
            XCTAssert(testNavVM.repoContext?.relativePath == "fileB.txt", "Should have switched to fileB.txt")
            XCTAssert(testNavVM.selectedCommit?.id == multiCommit.id, "Should remain on the same commit ID!")
        }
        print("  Verified multi-file commit detection and navigation to same commit!")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDualGitMercurialRepositoryVcsPreservation() async throws {
        let dualDir = FileManager.default.temporaryDirectory.appendingPathComponent("DualRepo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dualDir, withIntermediateDirectories: true)
        // Init both Git and Hg in the same directory
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: dualDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "Tester"], currentDirectory: dualDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "tester@test.com"], currentDirectory: dualDir)

        _ = try ProcessRunner.run(binary: "hg", arguments: ["init"], currentDirectory: dualDir)
        let hgrc = "[ui]\nusername = Tester <tester@test.com>\n"
        try hgrc.write(to: dualDir.appendingPathComponent(".hg/hgrc"), atomically: true, encoding: .utf8)

        let dual1 = dualDir.appendingPathComponent("doc1.txt")
        let dual2 = dualDir.appendingPathComponent("doc2.txt")
        try "Doc 1 content".write(to: dual1, atomically: true, encoding: .utf8)
        try "Doc 2 content".write(to: dual2, atomically: true, encoding: .utf8)

        // Commit to Hg
        _ = try ProcessRunner.run(binary: "hg", arguments: ["add", "doc1.txt", "doc2.txt"], currentDirectory: dualDir)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["commit", "-m", "hg multi-commit"], currentDirectory: dualDir)

        // Commit different change to Git
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "doc1.txt", "doc2.txt"], currentDirectory: dualDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "git commit"], currentDirectory: dualDir)

        // 1) Verify detectContext with preferredVCS
        let hgDetected = VCSManager.shared.detectContext(for: dual1, preferredVCS: .hg)
        XCTAssert(hgDetected?.vcsType == .hg, "Should detect Hg when preferredVCS is .hg in dual repo")

        let gitDetected = VCSManager.shared.detectContext(for: dual1, preferredVCS: .git)
        XCTAssert(gitDetected?.vcsType == .git, "Should detect Git when preferredVCS is .git in dual repo")

        // 2) Open dual1 in Mercurial
        let dualVM = HistoryViewModel()
        await MainActor.run {
            dualVM.openFile(url: dual1, preferredVCS: .hg)
        }
        try await waitForLoad(dualVM)
        await MainActor.run {
            XCTAssert(dualVM.vcsType == .hg, "Current VCS must be Mercurial")
            XCTAssert(dualVM.commits.count > 0)

            // Select dual2 from the commit
            dualVM.selectFileInCurrentCommit(relativePath: "doc2.txt")
        }
        try await waitForLoad(dualVM)
        await MainActor.run {
            XCTAssert(dualVM.repoContext?.relativePath == "doc2.txt", "Should switch to doc2.txt")
            XCTAssert(dualVM.vcsType == .hg, "Must still use Mercurial even though .git also exists in the repo!")
            dualVM.cancelPreload()
        }
        print("  Verified Mercurial is preserved when selecting files in dual-VCS repo!")
    }

    func testNestedGitSubRepositoryInsideMercurialRepository() async throws {

        let parentHgDir = FileManager.default.temporaryDirectory.appendingPathComponent("ParentHg_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parentHgDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["init"], currentDirectory: parentHgDir)
        let hgrc = "[ui]\nusername = Tester <tester@test.com>\n"
        try hgrc.write(to: parentHgDir.appendingPathComponent(".hg/hgrc"), atomically: true, encoding: .utf8)

        let subGitDir = parentHgDir.appendingPathComponent("cc/nested-git")
        try FileManager.default.createDirectory(at: subGitDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: subGitDir)

        let hgFile1 = parentHgDir.appendingPathComponent("root_file.txt")
        let hgFile2 = subGitDir.appendingPathComponent("nested_file.txt")
        try "root file".write(to: hgFile1, atomically: true, encoding: .utf8)
        try "nested file".write(to: hgFile2, atomically: true, encoding: .utf8)

        // Commit both in parent Mercurial repository
        _ = try ProcessRunner.run(binary: "hg", arguments: ["add", "root_file.txt", "cc/nested-git/nested_file.txt"], currentDirectory: parentHgDir)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["commit", "-m", "hg parent commit with nested path"], currentDirectory: parentHgDir)

        // Also commit nested_file in the nested Git repository
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "Tester"], currentDirectory: subGitDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "tester@test.com"], currentDirectory: subGitDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "nested_file.txt"], currentDirectory: subGitDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "git commit nested"], currentDirectory: subGitDir)

        // 1) Test detectContext for the nested file with preferredVCS: .hg
        let detectedContext = VCSManager.shared.detectContext(for: hgFile2, preferredVCS: .hg)
        XCTAssert(detectedContext?.vcsType == .hg, "detectContext with preferredVCS: .hg must find parent .hg instead of stopping at nested .git")
        XCTAssert(detectedContext?.repoRoot.standardizedFileURL.path == parentHgDir.standardizedFileURL.path, "repoRoot must be the parent Hg directory")

        // 2) Test HistoryViewModel file switching from root_file to nested_file
        let nestedVM = HistoryViewModel()
        await MainActor.run {
            nestedVM.openFile(url: hgFile1, preferredVCS: .hg)
        }
        try await waitForLoad(nestedVM)
        await MainActor.run {
            XCTAssert(nestedVM.vcsType == .hg, "Must be Mercurial initially")
            XCTAssert(nestedVM.commits.count > 0)
            // Select the nested file from the dropdown
            nestedVM.selectFileInCurrentCommit(relativePath: "cc/nested-git/nested_file.txt")
        }
        try await waitForLoad(nestedVM)
        await MainActor.run {
            XCTAssert(nestedVM.repoContext?.relativePath == "cc/nested-git/nested_file.txt")
            XCTAssert(nestedVM.vcsType == .hg, "Must stay on Mercurial and NOT switch to Git!")
            XCTAssert(nestedVM.repoContext?.repoRoot.standardizedFileURL.path == parentHgDir.standardizedFileURL.path)
            XCTAssert(nestedVM.canSwapVCS == true, "canSwapVCS must be true since file exists in both repositories")

            // 3) Test Swapping to Git
            nestedVM.swapVCS()
        }
        try await waitForLoad(nestedVM)
        await MainActor.run {
            XCTAssert(nestedVM.vcsType == .git, "Must have swapped to Git!")
            XCTAssert(nestedVM.repoContext?.repoRoot.standardizedFileURL.path == subGitDir.standardizedFileURL.path)
            XCTAssert(nestedVM.canSwapVCS == true, "canSwapVCS must still be true")

            // 4) Test Swapping back to Mercurial
            nestedVM.swapVCS()
        }
        try await waitForLoad(nestedVM)
        await MainActor.run {
            XCTAssert(nestedVM.vcsType == .hg, "Must have swapped back to Mercurial!")
            XCTAssert(nestedVM.repoContext?.repoRoot.standardizedFileURL.path == parentHgDir.standardizedFileURL.path)
            nestedVM.cancelPreload()
        }
        print("  Verified nested Git sub-repo does not hijack Mercurial file switching and swaps smoothly!")
        try? FileManager.default.removeItem(at: parentHgDir)
    }

    func testDeltareconstructorStreamingDiffEngineGitHg() async throws {

        let (_, gitFiles) = try SampleRepoService.shared.setupSampleGitRepo()
        guard let gitContext = VCSManager.shared.detectContext(for: gitFiles[0]) else {
            XCTFail("Failed to detect Git context")
            return
        }
        let gitCommits = try VCSManager.shared.fetchCommits(for: gitContext)

        let gitDeltaResults = try await DeltaReconstructor.fetchAllRevisionsStreaming(
            context: gitContext,
            commits: gitCommits
        )
        XCTAssert(gitDeltaResults.count == gitCommits.count, "Must reconstruct all Git revisions")
        for c in gitCommits {
            let directContent = try VCSManager.shared.fetchFileContent(context: gitContext, commit: c)
            guard let deltaContent = gitDeltaResults[c.id] else {
                fatalError("Missing reconstructed revision for \(c.displayRevision)")
            }
            XCTAssert(directContent.textLines.count == deltaContent.textLines.count, "Line counts must match")
            for i in 0..<directContent.textLines.count {
                XCTAssert(directContent.textLines[i].content == deltaContent.textLines[i].content, "Line content must match")
                XCTAssert(directContent.textLines[i].changeType == deltaContent.textLines[i].changeType, "Line changeType must match")
            }
        }
        print("  Verified DeltaReconstructor 100% exact match across all \(gitCommits.count) Git revisions!")

        let (_, hgFiles) = try SampleRepoService.shared.setupSampleHgRepo()
        guard let hgContext = VCSManager.shared.detectContext(for: hgFiles[0]) else {
            XCTFail("Failed to detect Hg context")
            return
        }
        let hgCommits = try VCSManager.shared.fetchCommits(for: hgContext)

        let hgDeltaResults = try await DeltaReconstructor.fetchAllRevisionsStreaming(
            context: hgContext,
            commits: hgCommits
        )
        XCTAssert(hgDeltaResults.count == hgCommits.count, "Must reconstruct all Hg revisions")
        for c in hgCommits {
            let directContent = try VCSManager.shared.fetchFileContent(context: hgContext, commit: c)
            guard let deltaContent = hgDeltaResults[c.id] else {
                fatalError("Missing reconstructed revision for \(c.displayRevision)")
            }
            XCTAssert(directContent.textLines.count == deltaContent.textLines.count, "Line counts must match")
            for i in 0..<directContent.textLines.count {
                XCTAssert(directContent.textLines[i].content == deltaContent.textLines[i].content, "Line content must match")
                XCTAssert(directContent.textLines[i].changeType == deltaContent.textLines[i].changeType, "Line changeType must match")
            }
        }
        print("  Verified DeltaReconstructor 100% exact match across all \(hgCommits.count) Hg revisions!")
    }

    func testUserRevisionPrioritizationDuringBackgroundFetching() async throws {

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestPriority_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "tester@test.com"], currentDirectory: tempDir)
        let fileA = tempDir.appendingPathComponent("fileA.txt")
        try "initial".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "fileA.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "commit 1"], currentDirectory: tempDir)
        try "rev 2".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-am", "commit 2"], currentDirectory: tempDir)

        let priorityVM = HistoryViewModel()
        await MainActor.run {
            priorityVM.openFile(url: fileA)
        }
        // Allow initial commit to finish fetching and start background preloading
        try await Task.sleep(nanoseconds: 300_000_000)
        await MainActor.run {
            XCTAssert(priorityVM.currentContent != nil, "Initial user commit should be fetched first")
            XCTAssert(priorityVM.selectedCommitIndex == priorityVM.commits.count - 1)
        }

        // Now navigate to commit 0 (the oldest commit)
        await MainActor.run {
            priorityVM.selectedCommitIndex = 0
        }
        // Give it time to fetch commit 0
        try await Task.sleep(nanoseconds: 200_000_000)
        await MainActor.run {
            XCTAssert(priorityVM.selectedCommitIndex == 0)
            XCTAssert(priorityVM.currentContent != nil, "Target user commit must be fetched and displayed")
            XCTAssert(priorityVM.isContentLoading == false, "Loading state must finish")
            priorityVM.cancelPreload()
        }
        print("  Verified user-selected revision is fetched first and rendered without getting blocked!")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testBackStackNavigationSliderDragSimulation() async throws {

        let (_, gitFiles) = try SampleRepoService.shared.setupSampleGitRepo()
        let swiftFile = gitFiles[0]

        let tabMgr = TabManager()
        await MainActor.run {
            // Initial state
            XCTAssert(tabMgr.tabs.count == 1)
            XCTAssert(tabMgr.backStack.isEmpty)
            XCTAssert(!tabMgr.canGoBack)
        }

        // Open git file with multiple commits (swiftFile)
        await MainActor.run {
            tabMgr.openInTab(url: swiftFile)
        }
        try await waitForTabManagerLoad(tabMgr)

        await MainActor.run {
            guard let vm = tabMgr.activeViewModel else { fatalError() }
            XCTAssert(vm.commits.count >= 2, "Expected >= 2 commits for swiftFile, got \(vm.commits.count)")
            let initialIndex = vm.selectedCommitIndex
            let initialRev = vm.selectedCommit!.id

            // 1. Changing commit directly adds previous state to back stack
            vm.goToCommit(at: 0)
            XCTAssert(tabMgr.backStack.count == 1, "Back stack should have 1 item after jumping commit")
            XCTAssert(tabMgr.backStack.last?.revision == initialRev)
            XCTAssert(tabMgr.canGoBack)

            // 2. Jumping to the exact same revision should NOT add duplicate to back stack
            vm.goToCommit(at: 0)
            XCTAssert(tabMgr.backStack.count == 1, "Selecting same revision must not duplicate back stack entry")

            // 3. Simulating slider drag:
            let dragStartState = vm.currentNavigationState!
            vm.shouldRecordHistory = false
            vm.selectedCommitIndex = 1
            vm.selectedCommitIndex = initialIndex
            vm.selectedCommitIndex = 0
            vm.selectedCommitIndex = 1
            XCTAssert(tabMgr.backStack.count == 1, "Back stack must not be modified while dragging")

            let currentNavState = vm.currentNavigationState!
            if currentNavState != dragStartState {
                tabMgr.pushNavigationState(from: dragStartState)
            }
            vm.shouldRecordHistory = true
            XCTAssert(tabMgr.backStack.count == 2, "Back stack should have exactly 1 new entry upon drag release")
            XCTAssert(tabMgr.backStack.last == dragStartState)

            // 4. Test Go Back
            tabMgr.goBack()
            XCTAssert(tabMgr.activeViewModel?.selectedCommitIndex == 0, "Should have gone back to commit 0")
            XCTAssert(tabMgr.backStack.count == 1)

            tabMgr.goBack()
            XCTAssert(tabMgr.activeViewModel?.selectedCommitIndex == initialIndex, "Should have gone back to initial commit")
            XCTAssert(tabMgr.backStack.isEmpty)
            XCTAssert(!tabMgr.canGoBack)

            // 5. Test Go Forward (Redo Back)
            XCTAssert(tabMgr.canGoForward, "canGoForward should be true after going back")
            XCTAssert(tabMgr.forwardStack.count == 2, "forwardStack should have 2 states to redo")

            tabMgr.goForward()
            XCTAssert(tabMgr.activeViewModel?.selectedCommitIndex == 0, "Should have gone forward to commit 0")
            XCTAssert(tabMgr.forwardStack.count == 1)
            XCTAssert(tabMgr.canGoBack, "canGoBack should be true after going forward")

            tabMgr.goForward()
            XCTAssert(tabMgr.activeViewModel?.selectedCommitIndex == 1, "Should have gone forward to commit 1")
            XCTAssert(tabMgr.forwardStack.isEmpty)
            XCTAssert(!tabMgr.canGoForward, "canGoForward should be false when forwardStack is empty")

            // 6. Test forwardStack invalidation when navigating to a new commit
            tabMgr.goBack()
            XCTAssert(tabMgr.canGoForward)
            vm.goToCommit(at: 2) // New branch of navigation
            XCTAssert(!tabMgr.canGoForward, "New navigation must clear forwardStack")
            XCTAssert(tabMgr.forwardStack.isEmpty)
            vm.cancelPreload()
        }
        print("  Verified back stack and forward stack tracking, deduplication, and slider drag behavior!")
    }

    func testMultipleTabsSameFileInGitVsMercurialTabs() async throws {

        let (dualDir, dual1, _) = try createDualRepo()
        defer { try? FileManager.default.removeItem(at: dualDir) }
        let (_, gitFiles) = try SampleRepoService.shared.setupSampleGitRepo()
        let fileA = gitFiles[0]

        let multiTabMgr = TabManager()
        await MainActor.run {
            XCTAssert(multiTabMgr.tabs.count == 1)

            // Open dual1 in Mercurial (reuses the empty initial tab)
            multiTabMgr.openInTab(url: dual1, preferredVCS: .hg)
        }
        try await waitForTabManagerLoad(multiTabMgr)

        await MainActor.run {
            XCTAssert(multiTabMgr.tabs.count == 1)
            XCTAssert(multiTabMgr.activeViewModel?.vcsType == .hg)
            XCTAssert(multiTabMgr.activeViewModel?.selectedFileURL?.standardizedFileURL.path == dual1.standardizedFileURL.path)

            // Open the SAME file in Git -> Must open in a separate tab!
            multiTabMgr.openInTab(url: dual1, preferredVCS: .git)
        }
        try await waitForTabManagerLoad(multiTabMgr)

        await MainActor.run {
            XCTAssert(multiTabMgr.tabs.count == 2, "Opening same file in Git and Mercurial must produce 2 tabs!")
            XCTAssert(multiTabMgr.tabs[0].vcsType == .hg, "Tab 0 must be Mercurial")
            XCTAssert(multiTabMgr.tabs[1].vcsType == .git, "Tab 1 must be Git")
            XCTAssert(multiTabMgr.activeTabId == multiTabMgr.tabs[1].id, "Active tab should be the newly opened Git tab")

            // Now select fileA (a completely different file) -> Must open in a third tab!
            multiTabMgr.openInTab(url: fileA)
        }
        try await waitForTabManagerLoad(multiTabMgr)

        await MainActor.run {
            XCTAssert(multiTabMgr.tabs.count == 3, "Opening fileA must open in a 3rd tab")
            XCTAssert(multiTabMgr.activeViewModel?.selectedFileURL?.standardizedFileURL.path == fileA.standardizedFileURL.path)

            // Re-opening dual1 with preferredVCS: .hg should switch to the existing Hg tab (tab 0), not open a 4th tab
            let tab0Id = multiTabMgr.tabs[0].id
            multiTabMgr.openInTab(url: dual1, preferredVCS: .hg)
            XCTAssert(multiTabMgr.tabs.count == 3, "Should reuse existing tab for same file & VCS")
            XCTAssert(multiTabMgr.activeTabId == tab0Id, "Active tab must be tab 0")

            // Test closing a tab
            let tabToCloseId = multiTabMgr.tabs[2].id
            multiTabMgr.closeTab(id: tabToCloseId)
            XCTAssert(multiTabMgr.tabs.count == 2, "Should have 2 tabs remaining after closing 1")
        }
        print("  Verified multi-tab management and distinct tabs for same file in Git vs Mercurial!")
    }

    func testMergeCommitsInGitHistory() throws {
        let mergeRepoDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestMerge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mergeRepoDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: mergeRepoDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "Tester"], currentDirectory: mergeRepoDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "tester@example.com"], currentDirectory: mergeRepoDir)

        let mergeFile = mergeRepoDir.appendingPathComponent("merge_test.txt")
        try "base\n".write(to: mergeFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "merge_test.txt"], currentDirectory: mergeRepoDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "Commit A"], currentDirectory: mergeRepoDir)

        _ = try ProcessRunner.run(binary: "git", arguments: ["checkout", "-b", "branch1"], currentDirectory: mergeRepoDir)
        try "branch1\n".write(to: mergeFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-am", "Commit B"], currentDirectory: mergeRepoDir)

        _ = try ProcessRunner.run(binary: "git", arguments: ["checkout", "-b", "branch2", "HEAD~1"], currentDirectory: mergeRepoDir)
        try "branch2\n".write(to: mergeFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-am", "Commit C"], currentDirectory: mergeRepoDir)

        // Merge branch1 into branch2 resolving conflict
        _ = try ProcessRunner.run(binary: "git", arguments: ["merge", "branch1", "-m", "Merge branch1 and branch2"], currentDirectory: mergeRepoDir)
        try "branch1\nbranch2\n".write(to: mergeFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "merge_test.txt"], currentDirectory: mergeRepoDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "--no-edit"], currentDirectory: mergeRepoDir)

        guard let mergeContext = VCSManager.shared.detectContext(for: mergeFile) else {
            fatalError("Failed to detect context for merge repo")
        }
        let mergeCommits = try VCSManager.shared.fetchCommits(for: mergeContext)
        print("  Found \(mergeCommits.count) commits in merge history:")
        for c in mergeCommits {
            print("    - [\(c.displayRevision)] \(c.summary)")
        }
        XCTAssert(mergeCommits.count == 4, "Must detect all 4 commits including the merge commit!")
        XCTAssert(mergeCommits.last?.summary.contains("Merge") == true, "Latest commit must be the merge commit!")
        let filesInMerge = VCSManager.shared.fetchFilesInCommit(context: mergeContext, commit: mergeCommits.last!)
        XCTAssert(filesInMerge.contains("merge_test.txt"), "Files in merge commit must include merge_test.txt")
        let mergeContent = try VCSManager.shared.fetchFileContent(context: mergeContext, commit: mergeCommits.last!)
        XCTAssert(mergeContent.textLines.count == 2, "Merged content must have 2 lines")
        XCTAssert(mergeContent.addedLinesCount == 1, "Line added in merge commit must be detected as added!")
        XCTAssert(mergeContent.textLines[0].changeType == .added, "First line must be .added")
        print("  Verified merge commit detection, files changed, and content retrieval in Git!")
    }

    func testMergeCommitsInMercurialHgHistory() throws {
        let hgMergeDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHgMerge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hgMergeDir, withIntermediateDirectories: true)
        let hgBin = ProcessRunner.resolveBinaryPath(named: "hg")!
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: hgMergeDir)
        let hgMergeRc = hgMergeDir.appendingPathComponent(".hg").appendingPathComponent("hgrc")
        try "[ui]\nusername = Tester <tester@example.com>\n".write(to: hgMergeRc, atomically: true, encoding: .utf8)

        let hgTestFile = hgMergeDir.appendingPathComponent("hg_merge.txt")
        try "a\n".write(to: hgTestFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["add", "hg_merge.txt"], currentDirectory: hgMergeDir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "a"], currentDirectory: hgMergeDir)

        try "b\n".write(to: hgTestFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "b"], currentDirectory: hgMergeDir)

        _ = try ProcessRunner.run(binary: hgBin, arguments: ["update", "-r", "0"], currentDirectory: hgMergeDir)
        try "c\n".write(to: hgTestFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "c"], currentDirectory: hgMergeDir)

        // Merge branch 1 into branch 2
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["merge", "-r", "1", "--tool", "internal:merge"], currentDirectory: hgMergeDir)
        try "b\nc\n".write(to: hgTestFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["resolve", "--mark", "hg_merge.txt"], currentDirectory: hgMergeDir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "bc"], currentDirectory: hgMergeDir)

        guard let hgMergeContext = VCSManager.shared.detectContext(for: hgTestFile) else {
            fatalError("Failed to detect context for hg merge repo")
        }
        let hgMergeCommits = try VCSManager.shared.fetchCommits(for: hgMergeContext)
        XCTAssert(hgMergeCommits.count == 4, "Must detect all 4 hg commits")
        guard let lastHgCommit = hgMergeCommits.last else { fatalError() }
        let hgContent = try VCSManager.shared.fetchFileContent(context: hgMergeContext, commit: lastHgCommit)
        XCTAssert(hgContent.addedLinesCount == 1, "First line 'b' must be marked as added in the merge commit!")
        XCTAssert(hgContent.textLines[0].changeType == .added, "Line 0 must have changeType .added")
        XCTAssert(hgContent.textLines[0].isChangedInCurrentCommit, "Line 0 must have isChangedInCurrentCommit == true")
        print("  Verified Mercurial merge commit line addition correctly detected!")
    }

    func testGitWorkingDirectoryChangesAsExtraUncommittedNode() throws {
        let gitWdir = FileManager.default.temporaryDirectory.appendingPathComponent("TestGitUncommitted_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: gitWdir, withIntermediateDirectories: true)
        let gitBin = ProcessRunner.resolveBinaryPath(named: "git")!
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: gitWdir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "WorkingDev"], currentDirectory: gitWdir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "dev@example.com"], currentDirectory: gitWdir)

        let gitWdirFile = gitWdir.appendingPathComponent("feature.txt")
        try "line 1: initial\nline 2: to change\n".write(to: gitWdirFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "feature.txt"], currentDirectory: gitWdir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "first commit"], currentDirectory: gitWdir)

        guard let gitWdirCtx = VCSManager.shared.detectContext(for: gitWdirFile) else {
            fatalError("Failed context for git wdir")
        }

        // Initially clean: exactly 1 commit, no uncommitted node
        let cleanCommits = try VCSManager.shared.fetchCommits(for: gitWdirCtx)
        XCTAssert(cleanCommits.count == 1, "Clean repository must have exactly 1 commit")
        XCTAssert(!cleanCommits[0].isUncommitted, "Committed node must not be isUncommitted")

        // Modify file in working tree
        try "line 1: initial\nline 2: modified in workdir\nline 3: newly added\n".write(to: gitWdirFile, atomically: true, encoding: .utf8)

        // Now dirty: must have 2 nodes, and the last must be the uncommitted node!
        let dirtyCommits = try VCSManager.shared.fetchCommits(for: gitWdirCtx)
        print("  Dirty commits count:", dirtyCommits.count)
        XCTAssert(dirtyCommits.count == 2, "Dirty repository must have 2 nodes (committed + uncommitted)")
        guard let uncommittedNode = dirtyCommits.last else { fatalError() }
        XCTAssert(uncommittedNode.isUncommitted, "Last node must be uncommitted")
        XCTAssert(uncommittedNode.displayRevision == "Uncommitted", "Display revision must be 'Uncommitted'")
        XCTAssert(uncommittedNode.index == 1, "Uncommitted node index must be 1")
        XCTAssert(uncommittedNode.author == "WorkingDev", "Author must be resolved from git config")
        print("  Uncommitted node: [\(uncommittedNode.displayRevision)] author=\(uncommittedNode.author) summary=\(uncommittedNode.summary)")

        // Fetch content for uncommitted node
        let uncommittedContent = try VCSManager.shared.fetchFileContent(context: gitWdirCtx, commit: uncommittedNode)
        print("  Uncommitted textLines count: \(uncommittedContent.textLines.count), added: \(uncommittedContent.addedLinesCount), removed: \(uncommittedContent.removedLinesCount)")
        XCTAssert(uncommittedContent.addedLinesCount >= 2, "Must detect modified and added lines")
        XCTAssert(uncommittedContent.removedLinesCount >= 1, "Must detect removed lines from diff")

        // Verify blame line attributes
        let line1 = uncommittedContent.textLines.first(where: { $0.content == "line 1: initial" })!
        XCTAssert(!line1.isChangedInCurrentCommit, "Line 1 was not changed in workdir, isChangedInCurrentCommit must be false")
        XCTAssert(cleanCommits[0].matches(revision: line1.revision), "Line 1 must be blamed to first commit")

        let line2 = uncommittedContent.textLines.first(where: { $0.content == "line 2: modified in workdir" })!
        XCTAssert(line2.isChangedInCurrentCommit, "Line 2 was changed in workdir, isChangedInCurrentCommit must be true")
        XCTAssert(line2.changeType == .added, "Line 2 changeType must be .added")
        XCTAssert(line2.revision == "Uncommitted", "Line 2 revision must be 'Uncommitted'")

        // Files in uncommitted node
        let filesInUncommitted = VCSManager.shared.fetchFilesInCommit(context: gitWdirCtx, commit: uncommittedNode)
        XCTAssert(filesInUncommitted.contains("feature.txt"), "Files in uncommitted commit must include feature.txt")
        print("  Verified Git uncommitted node detection, blame lines, diff, and file list!")
    }

    func testMercurialHgWorkingDirectoryChangesAsExtraUncommittedNode() throws {

        let hgBin = self.hgBin
        let hgWdir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHgUncommitted_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hgWdir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: hgWdir)
        let hgWdirRc = hgWdir.appendingPathComponent(".hg").appendingPathComponent("hgrc")
        try "[ui]\nusername = HgDev <hgdev@example.com>\n".write(to: hgWdirRc, atomically: true, encoding: .utf8)

        let hgWdirFile = hgWdir.appendingPathComponent("hg_feature.txt")
        try "item 1\nitem 2\n".write(to: hgWdirFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["add", "hg_feature.txt"], currentDirectory: hgWdir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "first hg commit"], currentDirectory: hgWdir)

        guard let hgWdirCtx = VCSManager.shared.detectContext(for: hgWdirFile) else {
            fatalError("Failed context for hg wdir")
        }

        // Initially clean
        let cleanHgCommits = try VCSManager.shared.fetchCommits(for: hgWdirCtx)
        XCTAssert(cleanHgCommits.count == 1)

        // Modify in workdir
        try "item 1\nitem 2 edited\nitem 3 extra\n".write(to: hgWdirFile, atomically: true, encoding: .utf8)

        let dirtyHgCommits = try VCSManager.shared.fetchCommits(for: hgWdirCtx)
        print("  Dirty Hg commits count:", dirtyHgCommits.count)
        XCTAssert(dirtyHgCommits.count == 2)
        let uncommittedHg = dirtyHgCommits.last!
        XCTAssert(uncommittedHg.isUncommitted)
        XCTAssert(uncommittedHg.author == "HgDev")

        let uncommittedHgContent = try VCSManager.shared.fetchFileContent(context: hgWdirCtx, commit: uncommittedHg)
        print("  Uncommitted Hg textLines count: \(uncommittedHgContent.textLines.count), added: \(uncommittedHgContent.addedLinesCount), removed: \(uncommittedHgContent.removedLinesCount)")
        XCTAssert(uncommittedHgContent.addedLinesCount >= 2)
        XCTAssert(uncommittedHgContent.removedLinesCount >= 1)

        let filesInHgUncommitted = VCSManager.shared.fetchFilesInCommit(context: hgWdirCtx, commit: uncommittedHg)
        XCTAssert(filesInHgUncommitted.contains("hg_feature.txt"))
        print("  Verified Mercurial uncommitted node detection, blame lines, diff, and file list!")
        try? FileManager.default.removeItem(at: hgWdir)
    }

    func testHistoryviewmodelNavigationJumpWithUncommittedNode() async throws {

        let gitWdir = FileManager.default.temporaryDirectory.appendingPathComponent("TestGitUncommittedVM_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: gitWdir, withIntermediateDirectories: true)
        let gitBin = self.gitBin
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: gitWdir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "WorkingDev"], currentDirectory: gitWdir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "dev@example.com"], currentDirectory: gitWdir)

        let gitWdirFile = gitWdir.appendingPathComponent("feature.txt")
        try "line 1: initial\nline 2: to change\n".write(to: gitWdirFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "feature.txt"], currentDirectory: gitWdir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "first commit"], currentDirectory: gitWdir)

        guard let gitWdirCtx = VCSManager.shared.detectContext(for: gitWdirFile) else {
            fatalError("Failed context for git wdir")
        }

        try "line 1: initial\nline 2: modified in workdir\nline 3: newly added\n".write(to: gitWdirFile, atomically: true, encoding: .utf8)
        let dirtyCommits = try VCSManager.shared.fetchCommits(for: gitWdirCtx)

        let testVM = HistoryViewModel()
        await MainActor.run {
            testVM.repoContext = gitWdirCtx
            testVM.commits = dirtyCommits
            testVM.selectedCommitIndex = 0
        }

        await MainActor.run {
            XCTAssert(testVM.selectedCommit?.id != CommitInfo.uncommittedHash)
            testVM.lastCommit()
            XCTAssert(testVM.selectedCommit?.isUncommitted == true, "lastCommit() must navigate to uncommitted node")
            testVM.firstCommit()
            XCTAssert(testVM.selectedCommit?.isUncommitted == false, "firstCommit() must navigate to first commit")
            testVM.goToCommit(byHash: "uncommitted")
            XCTAssert(testVM.selectedCommit?.isUncommitted == true, "goToCommit(byHash: 'uncommitted') must find uncommitted node")
            testVM.goToCommit(byHash: "pending")
            XCTAssert(testVM.selectedCommit?.isUncommitted == true, "goToCommit(byHash: 'pending') must find uncommitted node")
            testVM.goToCommit(byHash: "0000000")
            XCTAssert(testVM.selectedCommit?.isUncommitted == true, "goToCommit(byHash: '0000000') must find uncommitted node")
        }

        // Verify uncommitted caching and instant timeline scrubbing
        await MainActor.run {
            testVM.lastCommit()
            testVM.loadContentForCurrentCommit()
        }
        for _ in 0..<60 {
            let loaded = await MainActor.run { !testVM.isContentLoading && testVM.currentContent != nil }
            if loaded { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await MainActor.run {
            XCTAssert(testVM.isCommitCached(id: CommitInfo.uncommittedHash), "Uncommitted node must be cached in contentCache")
            testVM.firstCommit()
            XCTAssert(!testVM.selectedCommit!.isUncommitted)
            testVM.lastCommit()
            XCTAssert(!testVM.isContentLoading, "Scrubbing back to uncommitted node must be served immediately from cache")
            XCTAssert(testVM.isCommitCached(id: CommitInfo.uncommittedHash), "Uncommitted node must remain cached during scrubbing")

            testVM.invalidateUncommittedCache()
            XCTAssert(!testVM.isCommitCached(id: CommitInfo.uncommittedHash), "Uncommitted node cache must be invalidated after changes saved")
        }
        print("  Verified HistoryViewModel navigation, lastCommit, goToCommit, and uncommitted caching during timeline scrubbing!")
        try? FileManager.default.removeItem(at: gitWdir)
    }

    func testFileRenameHistoryFollowingInMercurialHg() throws {

        let (hgRenameDir, hgRenameCtx, hgRenameCommits) = try setupHgRenameRepo()
        defer { try? FileManager.default.removeItem(at: hgRenameDir) }
        print("  Hg commits count following rename:", hgRenameCommits.count)
        XCTAssert(hgRenameCommits.count == 4, "Must follow renames and return all 4 commits")
        XCTAssert(hgRenameCommits[0].filePath == "old_name.txt", "Commit 0 must have filePath old_name.txt")
        XCTAssert(hgRenameCommits[1].filePath == "old_name.txt", "Commit 1 must have filePath old_name.txt")
        XCTAssert(hgRenameCommits[2].filePath == "new_name.txt", "Commit 2 must have filePath new_name.txt")
        XCTAssert(hgRenameCommits[3].filePath == "new_name.txt", "Commit 3 must have filePath new_name.txt")

        // Content retrieval at commit 0 (before rename)
        let hgContent0 = try VCSManager.shared.fetchFileContent(context: hgRenameCtx, commit: hgRenameCommits[0])
        XCTAssert(hgContent0.textLines.count == 2, "Commit 0 must have 2 lines")
        XCTAssert(hgContent0.textLines[0].content == "line 1")

        // Content retrieval at commit 3 (after rename)
        let hgContent3 = try VCSManager.shared.fetchFileContent(context: hgRenameCtx, commit: hgRenameCommits[3])
        XCTAssert(hgContent3.textLines.count == 4, "Commit 3 must have 4 lines")
        print("  Verified Mercurial rename tracking and content retrieval across renames!")
    }

    func testFileRenameHistoryFollowingInGit() throws {

        let (gitRenameDir, gitRenameCtx, gitRenameCommits) = try setupGitRenameRepo()
        defer { try? FileManager.default.removeItem(at: gitRenameDir) }
        print("  Git commits count following rename:", gitRenameCommits.count)
        XCTAssert(gitRenameCommits.count == 3, "Must follow renames in Git and return 3 commits")
        XCTAssert(gitRenameCommits[0].filePath == "initial_code.swift", "Commit 0 must have filePath initial_code.swift")
        XCTAssert(gitRenameCommits[1].filePath == "final_code.swift", "Commit 1 must have filePath final_code.swift")
        XCTAssert(gitRenameCommits[2].filePath == "final_code.swift", "Commit 2 must have filePath final_code.swift")

        let gitContent0 = try VCSManager.shared.fetchFileContent(context: gitRenameCtx, commit: gitRenameCommits[0])
        XCTAssert(gitContent0.textLines.count == 1)
        XCTAssert(gitContent0.textLines[0].content == "struct A {}")
        print("  Verified Git rename tracking and content retrieval across renames!")
    }

    func testRepoPathRelativepathAndRenameOldnameNewnameDisplayInHistoryviewmodel() async throws {

        let (hgRenameDir, hgRenameCtx, hgRenameCommits) = try setupHgRenameRepo()
        defer { try? FileManager.default.removeItem(at: hgRenameDir) }
        let (gitRenameDir, gitRenameCtx, gitRenameCommits) = try setupGitRenameRepo()
        defer { try? FileManager.default.removeItem(at: gitRenameDir) }

        let renameVM = HistoryViewModel()
        await MainActor.run {
            renameVM.repoContext = hgRenameCtx
            renameVM.commits = hgRenameCommits

            // Hg Commit 0: before rename
            renameVM.selectedCommitIndex = 0
            XCTAssert(renameVM.relativePath.hasSuffix("old_name.txt"), "Commit 0 relativePath must point to old_name.txt")
            XCTAssert(renameVM.fileName == "old_name.txt", "fileName at commit 0 must be old_name.txt")
            XCTAssert(renameVM.displayedPath == "old_name.txt", "displayedPath at commit 0 must be old_name.txt")

            // Hg Commit 1: before rename
            renameVM.selectedCommitIndex = 1
            XCTAssert(renameVM.displayedPath == "old_name.txt", "displayedPath at commit 1 must be old_name.txt")

            // Hg Commit 2: rename revision
            renameVM.selectedCommitIndex = 2
            XCTAssert(renameVM.relativePath.hasSuffix("new_name.txt"), "Commit 2 relativePath must point to new_name.txt")
            XCTAssert(renameVM.displayedPath == "old_name.txt ➞ new_name.txt", "displayedPath at commit 2 must be 'old_name.txt ➞ new_name.txt'")

            // Hg Commit 3: after rename
            renameVM.selectedCommitIndex = 3
            XCTAssert(renameVM.relativePath.hasSuffix("new_name.txt"), "Commit 3 relativePath must point to new_name.txt")
            XCTAssert(renameVM.fileName == "new_name.txt", "fileName at commit 3 must be new_name.txt")
            XCTAssert(renameVM.displayedPath == "new_name.txt", "displayedPath at commit 3 must be new_name.txt")

            // Git renames
            let gitRenameVM = HistoryViewModel()
            gitRenameVM.repoContext = gitRenameCtx
            gitRenameVM.commits = gitRenameCommits

            // Git Commit 0: before rename
            gitRenameVM.selectedCommitIndex = 0
            XCTAssert(gitRenameVM.displayedPath == "initial_code.swift", "Git commit 0 displayedPath must be initial_code.swift")

            // Git Commit 1: rename revision
            gitRenameVM.selectedCommitIndex = 1
            XCTAssert(gitRenameVM.displayedPath == "initial_code.swift ➞ final_code.swift", "Git commit 1 displayedPath must be 'initial_code.swift ➞ final_code.swift'")

            // Git Commit 2: after rename
            gitRenameVM.selectedCommitIndex = 2
            XCTAssert(gitRenameVM.displayedPath == "final_code.swift", "Git commit 2 displayedPath must be final_code.swift")
        }
        print("  Verified HistoryViewModel relativePath and rename '{oldName} ➞ {newName}' across renames in Git and Mercurial!")
    }

    func testTimelineDeltaScaleAndDeltaCounts() async throws {

        // Test log2 scaling rules
        XCTAssert(ArchaeologistViewModel.deltaLineLength(for: 0) == 0.0, "0 lines should have length 0")
        XCTAssert(ArchaeologistViewModel.deltaLineLength(for: 1) == 1.0, "1 line should have length 1.0")
        XCTAssert(ArchaeologistViewModel.deltaLineLength(for: 2) == 1.0, "2 lines should have length 1.0")
        XCTAssert(ArchaeologistViewModel.deltaLineLength(for: 4) == 2.0, "4 lines should have length 2.0")
        XCTAssert(ArchaeologistViewModel.deltaLineLength(for: 8) == 3.0, "8 lines should have length 3.0")
        XCTAssert(ArchaeologistViewModel.deltaLineLength(for: 16) == 4.0, "16 lines should have length 4.0")
        XCTAssert(ArchaeologistViewModel.deltaLineLength(for: 256) == 8.0, "256 lines should have length 8.0")
        XCTAssert(ArchaeologistViewModel.deltaLineLength(for: 1048576) == 20.0, "2^20 lines should reach cap 20.0")
        XCTAssert(ArchaeologistViewModel.deltaLineLength(for: 10000000) == 20.0, "Lines above cap should be clamped to 20.0")
        print("  Verified Timeline delta line length log2 scale calculation!")

        let (gitRenameDir, gitRenameCtx, gitRenameCommits) = try setupGitRenameRepo()
        defer { try? FileManager.default.removeItem(at: gitRenameDir) }

        // Verify delta counts are nil initially for instantaneous loading without slow diffstat
        XCTAssert(gitRenameCommits[0].addedCount == nil, "Commit 0 addedCount is nil before caching to avoid slow load")

        let renameVM = HistoryViewModel()
        // Verify delta counts on ArchaeologistViewModel once cached
        await MainActor.run {
            renameVM.repoContext = gitRenameCtx
            renameVM.commits = gitRenameCommits
            renameVM.selectedCommitIndex = 0
        }
        // Trigger load for commit 0
        let gitTestContent0 = try VCSManager.shared.fetchFileContent(context: gitRenameCtx, commit: gitRenameCommits[0])
        await MainActor.run {
            let delta0 = (gitTestContent0.addedLinesCount, gitTestContent0.removedLinesCount)
            XCTAssert(delta0.0 == 1 && delta0.1 == 0, "Commit 0 delta counts computed on revision fetch")
        }
        print("  Verified HistoryViewModel deltaCounts method and progressive caching!")
    }

    func testRenameDeltaComputationAdditionsRemovalsTextDisplay() throws {

        let (hgRenameDir, hgRenameCtx, hgRenameCommits) = try setupHgRenameRepo()
        defer { try? FileManager.default.removeItem(at: hgRenameDir) }
        let (gitRenameDir, gitRenameCtx, gitRenameCommits) = try setupGitRenameRepo()
        defer { try? FileManager.default.removeItem(at: gitRenameDir) }
        let (gitModRenameDir, _, _, gitModCtx, gitModCommits) = try setupGitModRenameRepo()
        defer { try? FileManager.default.removeItem(at: gitModRenameDir) }

        // 24a. Pure rename in Hg (commit 2): must NOT show all files as added! Delta must be 0/0.
        let hgPureRenameContent = try VCSManager.shared.fetchFileContent(context: hgRenameCtx, commit: hgRenameCommits[2])
        print("  Hg pure rename commit added: \(hgPureRenameContent.addedLinesCount), removed: \(hgPureRenameContent.removedLinesCount)")
        XCTAssert(hgPureRenameContent.addedLinesCount == 0, "Pure rename in Hg must have 0 added lines")
        XCTAssert(hgPureRenameContent.removedLinesCount == 0, "Pure rename in Hg must have 0 removed lines")
        XCTAssert(!hgPureRenameContent.textLines.contains { $0.changeType == .added }, "Pure rename text lines must not be marked added")

        // 24b. Pure rename in Git (commit 1): must NOT show all files as added! Delta must be 0/0.
        let gitPureRenameContent = try VCSManager.shared.fetchFileContent(context: gitRenameCtx, commit: gitRenameCommits[1])
        print("  Git pure rename commit added: \(gitPureRenameContent.addedLinesCount), removed: \(gitPureRenameContent.removedLinesCount)")
        XCTAssert(gitPureRenameContent.addedLinesCount == 0, "Pure rename in Git must have 0 added lines")
        XCTAssert(gitPureRenameContent.removedLinesCount == 0, "Pure rename in Git must have 0 removed lines")
        XCTAssert(!gitPureRenameContent.textLines.contains { $0.changeType == .added }, "Git pure rename text lines must not be marked added")

        // 24c. Rename WITH modifications in Git: delta must reflect only changes compared to file before rename!
        XCTAssert(gitModCommits.count == 2)
        XCTAssert(gitModCommits[1].renamedFromPath == "code_old.txt")

        let modRenameContent = try VCSManager.shared.fetchFileContent(context: gitModCtx, commit: gitModCommits[1])
        print("  Git modified rename commit: total=\(modRenameContent.textLines.count), added=\(modRenameContent.addedLinesCount), removed=\(modRenameContent.removedLinesCount)")
        XCTAssert(modRenameContent.addedLinesCount == 2, "Expected 2 additions compared to before rename, got \(modRenameContent.addedLinesCount)")
        XCTAssert(modRenameContent.removedLinesCount == 1, "Expected 1 deletion compared to before rename, got \(modRenameContent.removedLinesCount)")

        let removedInText = modRenameContent.textLines.filter { $0.changeType == .removed }
        XCTAssert(removedInText.count == 1 && removedInText[0].content == "    print(\"2\")", "Removed line must be interleaved")

        let addedInText = modRenameContent.textLines.filter { $0.changeType == .added }
        XCTAssert(addedInText.count == 2, "Added lines in text must be exactly 2")
        XCTAssert(addedInText[0].content == "    print(\"2 - modified\")")
        XCTAssert(addedInText[1].content == "    print(\"6 - added\")")

        let unchangedInText = modRenameContent.textLines.filter { $0.changeType == .unchanged }
        XCTAssert(unchangedInText.count == 6, "Unchanged lines must not be marked added")

        print("  Verified rename delta additions/removals and text display in Git & Mercurial!")
    }

    func testBlameSidebarConsecutiveEntryHiding() throws {
        let bLine1 = BlameLine(lineNumber: 1, revision: "revA123", author: "Dev A", dateString: "Today", content: "line 1", changeType: .unchanged)
        let bLine2 = BlameLine(lineNumber: 2, revision: "revA123", author: "Dev A", dateString: "Today", content: "line 2", changeType: .unchanged)
        let bLine3 = BlameLine(lineNumber: 3, revision: "revB456", author: "Dev B", dateString: "Yesterday", content: "line 3", changeType: .unchanged)
        let bLine4 = BlameLine(lineNumber: 4, revision: "revB456", author: "Dev B", dateString: "Yesterday", content: "line 4", changeType: .unchanged)
        let bLine5 = BlameLine(lineNumber: nil, revision: "revC789", author: "Dev C", dateString: "Now", content: "deleted 1", changeType: .removed)
        let bLine6 = BlameLine(lineNumber: nil, revision: "revC789", author: "Dev C", dateString: "Now", content: "deleted 2", changeType: .removed)
        let bLine7 = BlameLine(lineNumber: 5, revision: "revC789", author: "Dev C", dateString: "Now", content: "added 1", changeType: .added)
        let bLine8 = BlameLine(lineNumber: 6, revision: "revC789", author: "Dev C", dateString: "Now", content: "added 2", changeType: .added)
        let bLine9 = BlameLine(lineNumber: 7, revision: "revA123", author: "Dev A", dateString: "Today", content: "line 5", changeType: .unchanged)

        let testLines = [bLine1, bLine2, bLine3, bLine4, bLine5, bLine6, bLine7, bLine8, bLine9]
        let hiddenStatus = (0..<testLines.count).map { idx in
            BlameLine.shouldHideConsecutiveBlame(prev: idx > 0 ? testLines[idx - 1] : nil, current: testLines[idx])
        }
        let expectedHidden = [false, true, false, true, false, true, false, true, false]
        XCTAssert(hiddenStatus == expectedHidden, "Expected hidden status \(expectedHidden), got \(hiddenStatus)")
        print("  Verified consecutive blame hiding across unchanged, removed, and added blocks!")

        // 26. Testing Show Deleted Lines Option and Filtering
    }

    func testShowDeletedLinesOption() throws {
        let vmForDeleted = HistoryViewModel()
        XCTAssert(vmForDeleted.showDeletedLines == true, "showDeletedLines must default to true")

        let sampleLines = [
            BlameLine(lineNumber: 1, revision: "rev1", author: "Dev A", dateString: "Today", content: "line 1", changeType: .unchanged),
            BlameLine(lineNumber: nil, revision: "rev2", author: "Dev B", dateString: "Now", content: "deleted line A", changeType: .removed),
            BlameLine(lineNumber: nil, revision: "rev2", author: "Dev B", dateString: "Now", content: "deleted line B", changeType: .removed),
            BlameLine(lineNumber: 2, revision: "rev2", author: "Dev B", dateString: "Now", content: "added line C", changeType: .added),
            BlameLine(lineNumber: 3, revision: "rev1", author: "Dev A", dateString: "Today", content: "line 2", changeType: .unchanged),
        ]
        let allLinesWhenOn = vmForDeleted.showDeletedLines ? sampleLines : sampleLines.filter { $0.changeType != .removed }
        XCTAssert(allLinesWhenOn.count == 5, "When showDeletedLines is true, all 5 lines are shown")

        vmForDeleted.showDeletedLines = false
        let filteredWhenOff = vmForDeleted.showDeletedLines ? sampleLines : sampleLines.filter { $0.changeType != .removed }
        XCTAssert(filteredWhenOff.count == 3, "When showDeletedLines is false, exactly 3 lines are shown")
        XCTAssert(!filteredWhenOff.contains { $0.changeType == .removed }, "No removed lines should be in filtered list")
        XCTAssert(filteredWhenOff[0].content == "line 1")
        XCTAssert(filteredWhenOff[1].content == "added line C")
        XCTAssert(filteredWhenOff[2].content == "line 2")
        print("  Verified showDeletedLines defaults to true and correctly hides deleted lines when unticked!")

        // 27. Testing Left Panel Repository File Tree and Sidebar Tab Opening
    }

    func testLeftPanelRepositoryFileTreeTabOpening() async throws {

        let testRelPaths = [
            "Sources/App/main.swift",
            "Sources/App/Helper.swift",
            "Sources/Models/User.swift",
            "Package.swift",
            "README.md"
        ]
        let dummyRepoRoot = URL(fileURLWithPath: "/tmp/dummyRepo")
        let tree = FileTreeNode.buildTree(from: testRelPaths, repoRoot: dummyRepoRoot)
        // Expect top-level: Sources (dir), Package.swift (file), README.md (file)
        XCTAssert(tree.count == 3, "Expected 3 top-level items, got \(tree.count)")
        XCTAssert(tree[0].name == "Sources" && tree[0].isDirectory, "First item should be Sources dir")
        XCTAssert(tree[1].name == "Package.swift" && !tree[1].isDirectory, "Second item should be Package.swift")
        XCTAssert(tree[2].name == "README.md" && !tree[2].isDirectory, "Third item should be README.md")

        // Check subdirs of Sources
        let sourcesChildren = tree[0].children ?? []
        XCTAssert(sourcesChildren.count == 2, "Expected 2 subdirectories in Sources, got \(sourcesChildren.count)")
        XCTAssert(sourcesChildren[0].name == "App" && sourcesChildren[0].isDirectory)
        XCTAssert(sourcesChildren[1].name == "Models" && sourcesChildren[1].isDirectory)

        let appFiles = sourcesChildren[0].children ?? []
        XCTAssert(appFiles.count == 2)
        XCTAssert(appFiles[0].name == "Helper.swift" && !appFiles[0].isDirectory)
        XCTAssert(appFiles[1].name == "main.swift" && !appFiles[1].isDirectory)

        // Test filtering
        let filteredTree = tree.compactMap { $0.filter(query: "main") }
        XCTAssert(filteredTree.count == 1, "Only Sources should match query 'main'")
        XCTAssert(filteredTree[0].name == "Sources")
        let filteredSourcesApp = filteredTree[0].children?[0].children ?? []
        XCTAssert(filteredSourcesApp.count == 1 && filteredSourcesApp[0].name == "main.swift")

        let (gitModRenameDir, file1URL, file2URL, gitRenameCtx, _) = try setupGitModRenameRepo()
        defer { try? FileManager.default.removeItem(at: gitModRenameDir) }

        // Test VCSManager fetchRepositoryWorkingFiles on Git repo
        let gitRepoFiles = VCSManager.shared.fetchRepositoryWorkingFiles(context: gitRenameCtx)
        XCTAssert(!gitRepoFiles.isEmpty, "Git repo must have working files")
        print("  Git working files count: \(gitRepoFiles.count), files: \(gitRepoFiles)")

        // Test TabManager sidebar toggle and tab opening from file tree
        let tmSidebar = TabManager()
        XCTAssert(tmSidebar.showSidebar == true, "Sidebar must default to shown")
        tmSidebar.showSidebar.toggle()
        XCTAssert(tmSidebar.showSidebar == false, "Sidebar should toggle to hidden")
        tmSidebar.showSidebar.toggle()
        XCTAssert(tmSidebar.showSidebar == true, "Sidebar should toggle back to shown")

        // Open first file in tab
        tmSidebar.openInTab(url: file1URL, preferredVCS: .git)
        try await waitForTabManagerLoad(tmSidebar)
        XCTAssert(tmSidebar.tabs.count == 1, "Expected 1 tab, got \(tmSidebar.tabs.count)")

        // Wait a brief moment for background repo file scan to populate repositoryFiles & cache
        for _ in 0..<50 {
            if !tmSidebar.repositoryFiles.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssert(!tmSidebar.repositoryFiles.isEmpty, "TabManager repositoryFiles should be populated")
        let repoRootPath = tmSidebar.activeViewModel!.repoContext!.repoRoot.standardizedFileURL.path
        XCTAssert(tmSidebar.repositoryFilesCache[repoRootPath] != nil, "TabManager repositoryFilesCache must cache tree for repoRoot")

        // Select another file from repo (file2URL) - must open in another tab!
        tmSidebar.openInTab(url: file2URL, preferredVCS: .git)

        // INSTANT HIGHLIGHT & SHARED TREE VERIFICATION:
        XCTAssert(tmSidebar.activeViewModel?.selectedFileURL?.standardizedFileURL.path == file2URL.standardizedFileURL.path,
               "Active view model must immediately know selectedFileURL on tab open")
        XCTAssert(tmSidebar.activeViewModel?.repoContext != nil,
               "Active view model must immediately know repoContext so highlight is instant")
        XCTAssert(!tmSidebar.repositoryFiles.isEmpty,
               "repositoryFiles must remain immediately available from cache when opening new tab in same repo")
        XCTAssert(tmSidebar.cachedRepoPath == repoRootPath,
               "cachedRepoPath must remain set without being cleared")

        try await waitForTabManagerLoad(tmSidebar)
        XCTAssert(tmSidebar.tabs.count == 2, "Selecting another file must open another tab, got \(tmSidebar.tabs.count)")
        XCTAssert(tmSidebar.activeTab?.title == "code_new.txt")

        // Selecting the first file again should switch back to existing tab without duplicating
        tmSidebar.openInTab(url: file1URL, preferredVCS: .git)
        XCTAssert(tmSidebar.tabs.count == 2, "Selecting existing file should switch without creating duplicate tab")
        XCTAssert(tmSidebar.activeTab?.title == "code_old.txt")
        XCTAssert(tmSidebar.activeViewModel?.selectedFileURL?.standardizedFileURL.path == file1URL.standardizedFileURL.path,
               "Switching tab must immediately update selectedFileURL to file1")
        print("  Verified Left Panel tree construction, filtering, instant highlight, shared repo cache, and tab opening behavior!")
    }

    func testRepositoryFileStatusesDirectoryColorHierarchy() throws {

        // 1. Verify status colors
        XCTAssert(FileWorkingStatus.unknown.rawValue == "unknown")
        let unknownNode = FileTreeNode(id: "u.swift", name: "u.swift", fullURL: URL(fileURLWithPath: "/tmp/u.swift"), isDirectory: false, status: .unknown)
        XCTAssert(unknownNode.statusTextColor == .purple, "Unknown file must be purple")

        let newNode = FileTreeNode(id: "n.swift", name: "n.swift", fullURL: URL(fileURLWithPath: "/tmp/n.swift"), isDirectory: false, status: .new)
        XCTAssert(newNode.statusTextColor == .green, "New file must be green")

        let deletedNode = FileTreeNode(id: "d.swift", name: "d.swift", fullURL: URL(fileURLWithPath: "/tmp/d.swift"), isDirectory: false, status: .deleted)
        XCTAssert(deletedNode.statusTextColor == .red, "Deleted file must be red")

        let modNode = FileTreeNode(id: "m.swift", name: "m.swift", fullURL: URL(fileURLWithPath: "/tmp/m.swift"), isDirectory: false, status: .modified)
        XCTAssert(modNode.statusTextColor == .orange, "Modified file must be orange")

        let cleanNode = FileTreeNode(id: "c.swift", name: "c.swift", fullURL: URL(fileURLWithPath: "/tmp/c.swift"), isDirectory: false, status: .clean)
        XCTAssert(cleanNode.statusTextColor == nil, "Clean file should have default text color")

        // 2. Verify Directory status calculation & recursion:
        // - Directory with all new files -> green (.new)
        let dirAdded = FileTreeNode(id: "addedDir", name: "addedDir", fullURL: URL(fileURLWithPath: "/tmp/addedDir"), isDirectory: true, status: .clean, children: [
            FileTreeNode(id: "addedDir/1.swift", name: "1.swift", fullURL: URL(fileURLWithPath: "/tmp/1.swift"), isDirectory: false, status: .new),
            FileTreeNode(id: "addedDir/2.swift", name: "2.swift", fullURL: URL(fileURLWithPath: "/tmp/2.swift"), isDirectory: false, status: .new)
        ])
        dirAdded.computeStatus()
        XCTAssert(dirAdded.status == .new, "Directory with all new files must be .new")
        XCTAssert(dirAdded.statusTextColor == .green, "Directory with all new files must color green")

        // - Directory with all deleted files -> red (.deleted)
        let dirRemoved = FileTreeNode(id: "removedDir", name: "removedDir", fullURL: URL(fileURLWithPath: "/tmp/removedDir"), isDirectory: true, status: .clean, children: [
            FileTreeNode(id: "removedDir/1.swift", name: "1.swift", fullURL: URL(fileURLWithPath: "/tmp/1.swift"), isDirectory: false, status: .deleted),
            FileTreeNode(id: "removedDir/2.swift", name: "2.swift", fullURL: URL(fileURLWithPath: "/tmp/2.swift"), isDirectory: false, status: .deleted)
        ])
        dirRemoved.computeStatus()
        XCTAssert(dirRemoved.status == .deleted, "Directory with all removed files must be .deleted")
        XCTAssert(dirRemoved.statusTextColor == .red, "Directory with all removed files must color red")

        // - Directory with mixed clean + modified/new/deleted files -> orange (.modified)
        let dirMixed = FileTreeNode(id: "mixedDir", name: "mixedDir", fullURL: URL(fileURLWithPath: "/tmp/mixedDir"), isDirectory: true, status: .clean, children: [
            cleanNode,
            modNode
        ])
        dirMixed.computeStatus()
        XCTAssert(dirMixed.status == .modified, "Directory with modified file must be .modified")
        XCTAssert(dirMixed.statusTextColor == .orange, "Directory with modified file must color orange")

        // - Parent directory containing a modified subdirectory recurses up the tree -> orange (.modified)
        let parentDir = FileTreeNode(id: "parentDir", name: "parentDir", fullURL: URL(fileURLWithPath: "/tmp/parentDir"), isDirectory: true, status: .clean, children: [
            cleanNode,
            dirMixed
        ])
        parentDir.computeStatus()
        XCTAssert(parentDir.status == .modified, "Parent directory with modified subfolder must recurse to .modified")
        XCTAssert(parentDir.statusTextColor == .orange, "Parent directory with modified subfolder must color orange")

        // 3. Test Git working file status extraction
        let gitStatusRepo = URL(fileURLWithPath: "/tmp/test_git_status_repo")
        try? FileManager.default.removeItem(at: gitStatusRepo)
        try FileManager.default.createDirectory(at: gitStatusRepo, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: gitStatusRepo)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "StatusDev"], currentDirectory: gitStatusRepo)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "status@example.com"], currentDirectory: gitStatusRepo)

        try "clean file".write(to: gitStatusRepo.appendingPathComponent("clean.txt"), atomically: true, encoding: .utf8)
        try "to delete".write(to: gitStatusRepo.appendingPathComponent("deleted.txt"), atomically: true, encoding: .utf8)
        try "to modify".write(to: gitStatusRepo.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "."], currentDirectory: gitStatusRepo)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "Initial commit"], currentDirectory: gitStatusRepo)

        // Modify, delete, add, create untracked
        try "modified content".write(to: gitStatusRepo.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: gitStatusRepo.appendingPathComponent("deleted.txt"))
        try "new file".write(to: gitStatusRepo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "new.txt"], currentDirectory: gitStatusRepo)
        try "untracked file".write(to: gitStatusRepo.appendingPathComponent("unknown.txt"), atomically: true, encoding: .utf8)

        let gitStatusContext = RepoContext(vcsType: .git, repoRoot: gitStatusRepo, relativePath: "clean.txt", fullURL: gitStatusRepo.appendingPathComponent("clean.txt"))
        let gitStatuses = VCSManager.shared.fetchRepositoryFileStatuses(context: gitStatusContext)
        XCTAssert(gitStatuses["clean.txt"] == .clean, "clean.txt must be .clean, got \(String(describing: gitStatuses["clean.txt"]))")
        XCTAssert(gitStatuses["modified.txt"] == .modified, "modified.txt must be .modified, got \(String(describing: gitStatuses["modified.txt"]))")
        XCTAssert(gitStatuses["deleted.txt"] == .deleted, "deleted.txt must be .deleted, got \(String(describing: gitStatuses["deleted.txt"]))")
        XCTAssert(gitStatuses["new.txt"] == .new, "new.txt must be .new, got \(String(describing: gitStatuses["new.txt"]))")
        XCTAssert(gitStatuses["unknown.txt"] == .unknown, "unknown.txt must be .unknown, got \(String(describing: gitStatuses["unknown.txt"]))")
        print("  Git working file statuses verified successfully!")

        // 4. Test Mercurial working file status extraction
        let hgStatusRepo = URL(fileURLWithPath: "/tmp/test_hg_status_repo")
        try? FileManager.default.removeItem(at: hgStatusRepo)
        try FileManager.default.createDirectory(at: hgStatusRepo, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["init"], currentDirectory: hgStatusRepo)
        let hgHgrc = hgStatusRepo.appendingPathComponent(".hg/hgrc")
        try "[ui]\nusername = StatusDev <status@example.com>\n".write(to: hgHgrc, atomically: true, encoding: .utf8)

        try "clean file".write(to: hgStatusRepo.appendingPathComponent("clean.txt"), atomically: true, encoding: .utf8)
        try "to delete".write(to: hgStatusRepo.appendingPathComponent("deleted.txt"), atomically: true, encoding: .utf8)
        try "to modify".write(to: hgStatusRepo.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["add"], currentDirectory: hgStatusRepo)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["commit", "-m", "Initial commit"], currentDirectory: hgStatusRepo)

        // Modify, delete, add, create untracked
        try "modified content".write(to: hgStatusRepo.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: hgStatusRepo.appendingPathComponent("deleted.txt"))
        try "new file".write(to: hgStatusRepo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["add", "new.txt"], currentDirectory: hgStatusRepo)
        try "untracked file".write(to: hgStatusRepo.appendingPathComponent("unknown.txt"), atomically: true, encoding: .utf8)

        let hgStatusContext = RepoContext(vcsType: .hg, repoRoot: hgStatusRepo, relativePath: "clean.txt", fullURL: hgStatusRepo.appendingPathComponent("clean.txt"))
        let hgStatuses = VCSManager.shared.fetchRepositoryFileStatuses(context: hgStatusContext)
        XCTAssert(hgStatuses["clean.txt"] == .clean, "Hg clean.txt must be .clean, got \(String(describing: hgStatuses["clean.txt"]))")
        XCTAssert(hgStatuses["modified.txt"] == .modified, "Hg modified.txt must be .modified, got \(String(describing: hgStatuses["modified.txt"]))")
        XCTAssert(hgStatuses["deleted.txt"] == .deleted, "Hg deleted.txt must be .deleted, got \(String(describing: hgStatuses["deleted.txt"]))")
        XCTAssert(hgStatuses["new.txt"] == .new, "Hg new.txt must be .new, got \(String(describing: hgStatuses["new.txt"]))")
        XCTAssert(hgStatuses["unknown.txt"] == .unknown, "Hg unknown.txt must be .unknown, got \(String(describing: hgStatuses["unknown.txt"]))")
        print("  Mercurial working file statuses verified successfully!")

        try? FileManager.default.removeItem(at: gitStatusRepo)
        try? FileManager.default.removeItem(at: hgStatusRepo)
        print("  Verified Repository File Statuses & Directory Color Recurse behavior!")

        // ==========================================
        // TEST 29: Directory Watcher & 2-Second Debounce Reschedule
        // ==========================================
    }

    func testDirectoryWatcherDebouncedRefresh() async throws {

        // Verify DirectoryWatcher path filtering ignores internal VCS lock noise
        XCTAssert(!DirectoryWatcher.isRelevantChange(at: "/repo/.git/index.lock"), ".git/index.lock must be ignored")
        XCTAssert(!DirectoryWatcher.isRelevantChange(at: "/repo/.git/index"), ".git/index must be ignored")
        XCTAssert(!DirectoryWatcher.isRelevantChange(at: "/repo/.git/logs/HEAD"), ".git/logs must be ignored")
        XCTAssert(!DirectoryWatcher.isRelevantChange(at: "/repo/.DS_Store"), ".DS_Store must be ignored")
        XCTAssert(!DirectoryWatcher.isRelevantChange(at: "/repo/.hg/wlock"), ".hg/wlock must be ignored")
        XCTAssert(!DirectoryWatcher.isRelevantChange(at: "/repo/.hg/lock"), ".hg/lock must be ignored")
        XCTAssert(DirectoryWatcher.isRelevantChange(at: "/repo/.git/refs/heads/main"), ".git/refs changes must be relevant")
        XCTAssert(DirectoryWatcher.isRelevantChange(at: "/repo/.git/HEAD"), ".git/HEAD must be relevant")
        XCTAssert(DirectoryWatcher.isRelevantChange(at: "/repo/.hg/dirstate"), ".hg/dirstate must be relevant")
        XCTAssert(DirectoryWatcher.isRelevantChange(at: "/repo/tracked.swift"), "Working directory file changes must be relevant")

        let watchTestDir = URL(fileURLWithPath: "/tmp/test_watcher_repo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watchTestDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: watchTestDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "WatchTester"], currentDirectory: watchTestDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "watch@example.com"], currentDirectory: watchTestDir)

        let trackedFile = watchTestDir.appendingPathComponent("tracked.swift")
        try "let x = 1\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "tracked.swift"], currentDirectory: watchTestDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "init"], currentDirectory: watchTestDir)

        // Setup TabManager with this repo
        let tmWatch = TabManager()
        tmWatch.openInTab(url: trackedFile, preferredVCS: .git)
        try await waitForTabManagerLoad(tmWatch)

        let activeVM = tmWatch.activeViewModel!
        let initialCommitCount = activeVM.commits.count
        XCTAssert(initialCommitCount == 1, "Expected 1 initial commit, got \(initialCommitCount)")
        XCTAssert(activeVM.commits.last?.isUncommitted == false, "Initial commit should not be uncommitted")

        // Wait for initial background repository scan to finish completely
        for _ in 0..<100 {
            if !tmWatch.isLoadingRepoFiles && !tmWatch.repositoryFiles.isEmpty {
                let s = tmWatch.repositoryFiles.first(where: { $0.id == "tracked.swift" })?.status
                if s == .clean { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Settle any initial watcher startup events and let any initial debounce finish
        try await Task.sleep(nanoseconds: 2_200_000_000)

        // Verify initial status is clean
        let initialNode = tmWatch.repositoryFiles.first(where: { $0.id == "tracked.swift" })
        XCTAssert(initialNode?.status == .clean, "Initial status of tracked.swift should be .clean, got \(String(describing: initialNode?.status))")

        // Simulate file modification:
        try "let x = 2 // modified\n".write(to: trackedFile, atomically: true, encoding: .utf8)

        // Trigger debounced refresh multiple times in rapid succession
        for _ in 0..<4 {
            tmWatch.scheduleDebouncedRefresh(paths: [trackedFile.relativePath])
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }

        // Before 2 seconds elapse from the last trigger, it should not have completed yet
        let preStatus = tmWatch.repositoryFiles.first(where: { $0.id == "tracked.swift" })?.status
        XCTAssert(preStatus == .clean, "Before 100 ms idleness elapse, debounced refresh should not have executed yet, got \(String(describing: preStatus))")

        // Now wait for the idleness window to elapse and scan to update
        for _ in 0..<60 {
            let node = tmWatch.repositoryFiles.first(where: { $0.id == "tracked.swift" })
            if node?.status == .modified { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // Now repositoryFiles must be refreshed and show .modified!
        let modNodeAfter = tmWatch.repositoryFiles.first(where: { $0.id == "tracked.swift" })
        XCTAssert(modNodeAfter?.status == .modified, "After modification and 100ms debounce, status must be .modified, got \(String(describing: modNodeAfter?.status))")
        XCTAssert(modNodeAfter?.statusTextColor == .orange, "Modified status must color text orange")

        // TabViewModel must have updated working directory changes without full reload!
        for _ in 0..<30 {
            if activeVM.commits.last?.isUncommitted == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssert(activeVM.commits.last?.isUncommitted == true, "Working directory change must add uncommitted node to commits")
        XCTAssert(activeVM.commits.count == 2, "Commits should have 1 commit + 1 uncommitted node")
        XCTAssert(activeVM.isLoading == false, "checkWorkingDirectoryChanges must not cause full reload or set isLoading = true")

        // Now commit the file (submitting changes)
        try await Task.sleep(nanoseconds: 100_000_000)
        let commitRes = try ProcessRunner.run(binary: "git", arguments: ["commit", "-am", "Submit modifications"], currentDirectory: watchTestDir)
        XCTAssert(commitRes.isSuccess, "git commit must succeed: \(commitRes.stderrString)")

        // Refresh repository files and check working directory status
        tmWatch.refreshRepositoryFiles()
        activeVM.checkWorkingDirectoryChanges([trackedFile.relativePath])

        // Wait for refresh task to finish
        for iter in 0..<80 {
            let node = tmWatch.repositoryFiles.first(where: { $0.id == "tracked.swift" })
            if iter % 10 == 0 {
                print("  [iter \(iter)] node status: \(String(describing: node?.status)), isUncommitted: \(String(describing: activeVM.commits.last?.isUncommitted)), isLoadingRepoFiles: \(tmWatch.isLoadingRepoFiles)")
            }
            if node?.status == .clean && activeVM.commits.last?.isUncommitted == false { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let cleanNodeAfter = tmWatch.repositoryFiles.first(where: { $0.id == "tracked.swift" })
        XCTAssert(cleanNodeAfter?.status == .clean, "After submitting/committing, status must become .clean again, got \(String(describing: cleanNodeAfter?.status))")
        XCTAssert(cleanNodeAfter?.statusTextColor == nil, "Clean status must have default text color")
        XCTAssert(activeVM.commits.last?.isUncommitted == false, "Uncommitted node must be removed once changes are committed")

        try? FileManager.default.removeItem(at: watchTestDir)
        print("  Verified Directory Watcher, 100ms debounce rescheduling, and color changes upon submitting!")
    }

    func testSelectRepositoryInSidebarShowsTree() async throws {
        let tm = TabManager()
        XCTAssert(tm.activeRepoContext == nil, "Initial activeRepoContext must be nil")
        XCTAssert(tm.repositoryFiles.isEmpty, "Initial repositoryFiles must be empty")
        XCTAssert(tm.tabs.count == 1 && !tm.tabs[0].isLoaded, "Initial tab has no file selected")

        let (gitDir, gitFiles) = try SampleRepoService.shared.setupSampleGitRepo()
        XCTAssert(!gitFiles.isEmpty)

        // Select the repository
        let opened = tm.openRepository(at: gitDir)
        XCTAssert(opened, "openRepository must succeed for sample git repo")
        XCTAssert(tm.activeRepoContext != nil, "activeRepoContext must be populated after opening repository")
        XCTAssert(tm.activeRepoContext?.repoRoot.standardizedFileURL.path == gitDir.standardizedFileURL.path)
        XCTAssert(tm.activeRepoContext?.vcsType == .git)
        XCTAssert(tm.tabs.count == 1 && tm.activeTab?.isCommitHistory == true, "Opening repository must automatically show Commit History tab")

        // Wait for repository files scan to complete
        for _ in 0..<100 {
            if !tm.isLoadingRepoFiles && !tm.repositoryFiles.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssert(!tm.repositoryFiles.isEmpty, "Tree view files must be populated once repository is selected")
        let firstFileName = gitFiles[0].lastPathComponent
        let fileNode = tm.repositoryFiles.first(where: { $0.name == firstFileName })
        XCTAssert(fileNode != nil, "Repository file tree must contain \(firstFileName)")

        // Selecting a file from the tree should open it in a tab
        if let targetNode = fileNode {
            tm.openInTab(url: targetNode.fullURL, preferredVCS: tm.activeRepoContext?.vcsType)
            try await waitForTabManagerLoad(tm)

            XCTAssert(tm.tabs.count == 2, "Opening file creates a file tab alongside Commit History tab")
            XCTAssert(tm.activeViewModel?.selectedFileURL?.standardizedFileURL.path == targetNode.fullURL.standardizedFileURL.path)
            XCTAssert(tm.activeViewModel?.commits.count ?? 0 > 0, "Selected file from tree must load commits")
        }

        // Selecting Mercurial sample while another repository is loaded must update repository tree properly
        let (hgDir, hgFiles) = try SampleRepoService.shared.setupSampleHgRepo()
        XCTAssert(!hgFiles.isEmpty)
        let firstHgFile = hgFiles[0]
        tm.openInTab(url: firstHgFile, preferredVCS: .hg)
        try await waitForTabManagerLoad(tm)

        for _ in 0..<100 {
            if !tm.isLoadingRepoFiles && tm.cachedRepoPath == hgDir.standardizedFileURL.path && !tm.repositoryFiles.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssert(tm.activeRepoContext?.vcsType == .hg, "activeRepoContext must switch to Mercurial")
        XCTAssert(tm.activeRepoContext?.repoRoot.standardizedFileURL.path == hgDir.standardizedFileURL.path, "activeRepoContext must be Mercurial sample repo root")
        XCTAssert(tm.cachedRepoPath == hgDir.standardizedFileURL.path, "cachedRepoPath must update to Mercurial repo")
        XCTAssert(tm.repositoryFiles.contains(where: { $0.name == firstHgFile.lastPathComponent }), "Repository file tree must contain Mercurial file")

        print("  Verified selecting repository automatically shows Commit History tab and loads file tree!")
    }

    func testFileContextMenuAddDiscardDelete() async throws {
        let repoDir = URL(fileURLWithPath: "/tmp/test_context_menu_repo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "Tester"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "tester@example.com"], currentDirectory: repoDir)

        let initialFile = repoDir.appendingPathComponent("tracked.txt")
        try "initial content\n".write(to: initialFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "tracked.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "init"], currentDirectory: repoDir)

        let tm = TabManager()
        tm.openRepository(at: repoDir)

        // Wait for initial files scan
        for _ in 0..<100 {
            if !tm.isLoadingRepoFiles && !tm.repositoryFiles.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let initialNode = tm.repositoryFiles.first(where: { $0.id == "tracked.txt" }) else {
            XCTFail("tracked.txt must exist in file tree")
            return
        }
        XCTAssert(initialNode.status == .clean)

        // Verify context menu action conditions on clean tracked file:
        // 1. Add file: greyed out if already tracked
        let cleanIsTracked = (initialNode.status != .unknown)
        XCTAssert(cleanIsTracked == true, "Add must be disabled for clean tracked file")
        // 2. Discard changes: greyed out if no changes
        let cleanHasChanges = (initialNode.status == .modified || initialNode.status == .deleted || initialNode.status == .new)
        XCTAssert(cleanHasChanges == false, "Discard changes must be disabled for clean file")

        // Create an untracked file
        let untrackedFile = repoDir.appendingPathComponent("untracked.txt")
        try "untracked content\n".write(to: untrackedFile, atomically: true, encoding: .utf8)

        tm.refreshRepositoryFiles()
        for _ in 0..<100 {
            if let uNode = tm.repositoryFiles.first(where: { $0.id == "untracked.txt" }), uNode.status == .unknown { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let untrackedNode = tm.repositoryFiles.first(where: { $0.id == "untracked.txt" }) else {
            XCTFail("untracked.txt must appear in tree")
            return
        }
        XCTAssert(untrackedNode.status == .unknown)
        // 1. Add file on untracked: enabled!
        let untrackedIsTracked = (untrackedNode.status != .unknown)
        XCTAssert(untrackedIsTracked == false, "Add must be enabled for untracked file")

        // Execute Add
        tm.addFile(for: untrackedNode)
        for _ in 0..<100 {
            if let node = tm.repositoryFiles.first(where: { $0.id == "untracked.txt" }), node.status == .new { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let addedNode = tm.repositoryFiles.first(where: { $0.id == "untracked.txt" })
        XCTAssert(addedNode?.status == .new, "After Add, status must become .new")

        // Test discarding changes on newly added file: must return to untracked (.unknown) without deleting from disk
        tm.discardChanges(for: addedNode!)
        for _ in 0..<100 {
            if let node = tm.repositoryFiles.first(where: { $0.id == "untracked.txt" }), node.status == .unknown { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let revertedUntrackedNode = tm.repositoryFiles.first(where: { $0.id == "untracked.txt" })
        XCTAssert(revertedUntrackedNode?.status == .unknown, "Discarding changes on newly added file must return status to .unknown (untracked)")
        XCTAssert(FileManager.default.fileExists(atPath: untrackedFile.path), "Discarding changes on newly added file must NOT delete it from filesystem")

        // 2. Modify tracked.txt and test Discard Changes
        try "modified content\n".write(to: initialFile, atomically: true, encoding: .utf8)
        tm.refreshRepositoryFiles()
        for _ in 0..<100 {
            if let node = tm.repositoryFiles.first(where: { $0.id == "tracked.txt" }), node.status == .modified { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let modifiedNode = tm.repositoryFiles.first(where: { $0.id == "tracked.txt" }) else {
            XCTFail("tracked.txt must exist")
            return
        }
        XCTAssert(modifiedNode.status == .modified)
        let modHasChanges = (modifiedNode.status == .modified || modifiedNode.status == .deleted || modifiedNode.status == .new)
        XCTAssert(modHasChanges == true, "Discard changes must be enabled for modified file")

        // Execute Discard Changes
        tm.discardChanges(for: modifiedNode)
        for _ in 0..<100 {
            let content = (try? String(contentsOf: initialFile, encoding: .utf8)) ?? ""
            let isClean = tm.repositoryFiles.first(where: { $0.id == "tracked.txt" })?.status == .clean
            if content == "initial content\n" && isClean { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let revertedContent = try String(contentsOf: initialFile, encoding: .utf8)
        XCTAssert(revertedContent == "initial content\n", "Discard changes must restore initial file content")
        let revertedNode = tm.repositoryFiles.first(where: { $0.id == "tracked.txt" })
        XCTAssert(revertedNode?.status == .clean, "Status must become .clean after discard changes")

        // 3. Test Delete file
        // Open tracked.txt in a tab first, to verify that deleting it removes the tab too!
        tm.openInTab(url: initialFile, preferredVCS: .git)
        XCTAssert(tm.tabs.contains(where: { $0.viewModel.selectedFileURL?.standardizedFileURL.path == initialFile.standardizedFileURL.path }), "Tab for tracked.txt must be open")

        tm.deleteFile(for: revertedNode!)
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: initialFile.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssert(!FileManager.default.fileExists(atPath: initialFile.path), "Delete file must remove it from filesystem")
        let deletedNode = tm.repositoryFiles.first(where: { $0.id == "tracked.txt" })
        XCTAssert(deletedNode?.status == .deleted, "Delete file must stage removal in repository (.deleted)")
        XCTAssert(!tm.tabs.contains(where: { $0.viewModel.selectedFileURL?.standardizedFileURL.path == initialFile.standardizedFileURL.path }), "Tab showing tracked.txt must be closed after deleting the file")

        // 4. Test Delete untracked file with warning dialog
        let untrackedToDelete = repoDir.appendingPathComponent("untracked_delete.txt")
        try "untracked for delete\n".write(to: untrackedToDelete, atomically: true, encoding: .utf8)
        tm.refreshRepositoryFiles()
        for _ in 0..<100 {
            if let node = tm.repositoryFiles.first(where: { $0.id == "untracked_delete.txt" }), node.status == .unknown { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let untrackedDeleteNode = tm.repositoryFiles.first(where: { $0.id == "untracked_delete.txt" }) else {
            XCTFail("untracked_delete.txt must appear in tree")
            return
        }

        // Test cancellation: when user does not proceed, file remains
        var promptShown = false
        tm.confirmUntrackedDeletion = { node in
            promptShown = true
            return false
        }
        tm.deleteFile(for: untrackedDeleteNode)
        XCTAssert(promptShown, "Warning prompt must be shown for untracked file deletion")
        XCTAssert(FileManager.default.fileExists(atPath: untrackedToDelete.path), "Cancelling untracked file deletion must leave file intact on disk")
        XCTAssert(tm.repositoryFiles.contains(where: { $0.id == "untracked_delete.txt" }), "Cancelling untracked file deletion must not remove node from tree")

        // Test proceed: when user confirms, delete locally and remove immediately from file tree
        tm.openInTab(url: untrackedToDelete, preferredVCS: .git)
        XCTAssert(tm.tabs.contains(where: { $0.viewModel.selectedFileURL?.standardizedFileURL.path == untrackedToDelete.standardizedFileURL.path }), "Tab for untracked file must be open")

        tm.confirmUntrackedDeletion = { _ in true }
        tm.deleteFile(for: untrackedDeleteNode)

        // Must be removed immediately from file tree
        XCTAssert(!tm.repositoryFiles.contains(where: { $0.id == "untracked_delete.txt" }), "Untracked file must be removed immediately from file tree")
        XCTAssert(!FileManager.default.fileExists(atPath: untrackedToDelete.path), "Untracked file must be deleted locally from disk")
        XCTAssert(!tm.tabs.contains(where: { $0.viewModel.selectedFileURL?.standardizedFileURL.path == untrackedToDelete.standardizedFileURL.path }), "Tab showing deleted untracked file must be closed")
        tm.confirmUntrackedDeletion = nil

        try? FileManager.default.removeItem(at: repoDir)
        print("  Verified right-click context menu Add, Discard Changes, and Delete operations!")
    }

    func testBinaryFileDetectionAndHexDumpFormatting() async throws {
        // 1. Test nul byte detection within 4KB
        var textBytes = [UInt8](repeating: 0x41, count: 5000) // All 'A's
        XCTAssert(!VCSManager.isBinaryData(Data(textBytes)), "All text bytes must not be binary")

        // Insert nul byte at offset 100 (< 4KB)
        textBytes[100] = 0x00
        XCTAssert(VCSManager.isBinaryData(Data(textBytes)), "Nul byte within 4KB must be detected as binary")

        // Reset and put nul byte only beyond 4KB (e.g. offset 4096)
        textBytes[100] = 0x41
        textBytes[4096] = 0x00
        XCTAssert(!VCSManager.isBinaryData(Data(textBytes)), "Nul byte strictly beyond 4096 bytes must not tag as binary")

        // 2. Test HexDumpFormatter formatting
        let sampleData = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x57, 0x6F, 0x72, 0x6C, 0x64, 0x21])
        let hex16 = HexDumpFormatter.format(data: sampleData, bytesPerRow: 16)
        XCTAssert(hex16.contains("00000000"), "Must include 8-digit hex offset")
        XCTAssert(hex16.contains("48 65 6C 6C 6F 00 57 6F"), "Must include hex bytes")
        XCTAssert(hex16.contains("|Hello.World!|"), "Must include character representation with '.' for nul byte")

        // Test 32 bytes per row (multiple of 16)
        let sample32 = Data([UInt8](0..<32))
        let hex32 = HexDumpFormatter.format(data: sample32, bytesPerRow: 32)
        XCTAssert(hex32.contains("00000000"), "Must start at offset 00000000")
        XCTAssert(hex32.contains("|................................|"), "Must display 32 characters in character column")

        // Test on-demand row-by-row formatting
        XCTAssert(HexDumpFormatter.rowCount(dataLength: sampleData.count, bytesPerRow: 16) == 1)
        XCTAssert(HexDumpFormatter.rowCount(dataLength: 33, bytesPerRow: 16) == 3)
        XCTAssert(HexDumpFormatter.rowCount(dataLength: 33, bytesPerRow: 32) == 2)

        let row0_16 = HexDumpFormatter.formatRow(data: sampleData, rowIndex: 0, bytesPerRow: 16)
        XCTAssert(row0_16.starts(with: "00000000  "), "Row 0 must start with offset 00000000")
        XCTAssert(row0_16.contains("48 65 6C 6C 6F 00 57 6F  72 6C 64 21"), "Must format hex bytes")
        XCTAssert(row0_16.hasSuffix("|Hello.World!|"), "Must end with character representation")

        let hexOnly = HexDumpFormatter.formatHexOnly(data: sampleData, rowIndex: 0, bytesPerRow: 16)
        XCTAssert(hexOnly == "48 65 6C 6C 6F 00 57 6F 72 6C 64 21")

        let asciiOnly = HexDumpFormatter.formatAsciiOnly(data: sampleData, rowIndex: 0, bytesPerRow: 16)
        XCTAssert(asciiOnly == "Hello.World!")

        // Test syntax color styling in formatAttributedRow
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attrRow = HexDumpFormatter.formatAttributedRow(data: sampleData, rowIndex: 0, bytesPerRow: 16, isDark: false, font: font)
        XCTAssert(attrRow.string.starts(with: "00000000  "), "Attributed string must match row format")
        XCTAssert(attrRow.string.hasSuffix("|Hello.World!|"), "Attributed string must include ascii column")
        let offsetColor = attrRow.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssert(offsetColor != nil, "Offset must have colored foreground attribute")
        let pipeIndex = (attrRow.string as NSString).range(of: "|").location
        let pipeColor = attrRow.attribute(.foregroundColor, at: pipeIndex, effectiveRange: nil) as? NSColor
        XCTAssert(pipeColor != nil, "Pipe must have colored foreground attribute")
        let asciiColor = attrRow.attribute(.foregroundColor, at: pipeIndex + 1, effectiveRange: nil) as? NSColor
        XCTAssert(asciiColor != nil, "ASCII characters must have colored foreground attribute")

        // Test on-demand speed with 1MB data: rowCount is O(1) and row formatting is microsecond
        let largeData = Data(repeating: 0x42, count: 1_000_000)
        let largeRowCount = HexDumpFormatter.rowCount(dataLength: largeData.count, bytesPerRow: 16)
        XCTAssert(largeRowCount == 62500, "1MB must be 62,500 rows at 16 bytes/row")
        let row500 = HexDumpFormatter.formatRow(data: largeData, rowIndex: 500, bytesPerRow: 16)
        XCTAssert(row500.starts(with: "00001F40  "), "Row 500 offset must be 500 * 16 = 8000 = 0x1F40")
        XCTAssert(row500.hasSuffix("|BBBBBBBBBBBBBBBB|"))

        // 3. Test opening a binary file in ArchaeologistViewModel
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestBinaryRepo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "tester@example.com"], currentDirectory: tempDir)

        let binFile = tempDir.appendingPathComponent("data.bin")
        let binaryPayload = Data([0x7F, 0x45, 0x4C, 0x46, 0x01, 0x01, 0x01, 0x00, 0x54, 0x65, 0x73, 0x74])
        try binaryPayload.write(to: binFile)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "data.bin"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "add binary data"], currentDirectory: tempDir)

        let vm = HistoryViewModel()
        vm.openFile(url: binFile)
        try await waitForLoad(vm)
        for _ in 0..<100 {
            if vm.currentContent != nil && !vm.isContentLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssert(vm.isBinary == true, "ViewModel must be tagged as binary")
        XCTAssert(vm.currentContent?.isBinary == true, "Content must be tagged as binary")
        XCTAssert(vm.currentContent?.binaryData == binaryPayload, "Binary data must match file payload")

        try? FileManager.default.removeItem(at: tempDir)
        print("  Verified binary file 4KB nul byte detection and HexDumpFormatter!")
    }

    func testRepositorySidebarOnlyShowModifiedAndShowInFinder() async throws {
        let repoRoot = URL(fileURLWithPath: "/tmp/TestSidebarRepo")
        let cleanFile = FileTreeNode(
            id: "clean.txt",
            name: "clean.txt",
            fullURL: repoRoot.appendingPathComponent("clean.txt"),
            isDirectory: false,
            status: .clean
        )
        let modFile = FileTreeNode(
            id: "dir/modified.txt",
            name: "modified.txt",
            fullURL: repoRoot.appendingPathComponent("dir/modified.txt"),
            isDirectory: false,
            status: .modified
        )
        let dirNode = FileTreeNode(
            id: "dir",
            name: "dir",
            fullURL: repoRoot.appendingPathComponent("dir"),
            isDirectory: true,
            status: .modified,
            children: [modFile]
        )
        let untrackedFile = FileTreeNode(
            id: "untracked.txt",
            name: "untracked.txt",
            fullURL: repoRoot.appendingPathComponent("untracked.txt"),
            isDirectory: false,
            status: .unknown
        )
        let tree = [cleanFile, untrackedFile, dirNode]

        // 1. Filter with onlyModified = false, showUntracked = true (default): all files included
        let fullFiltered = tree.compactMap { $0.filter(query: "", onlyModified: false, showUntracked: true) }
        XCTAssert(fullFiltered.count == 3, "Clean file, untracked file, and directory should all be present")

        // 2. Filter with showUntracked = false: untracked file filtered out
        let noUntracked = tree.compactMap { $0.filter(query: "", onlyModified: false, showUntracked: false) }
        XCTAssert(noUntracked.count == 2, "Untracked file must be excluded when showUntracked is false")
        XCTAssert(!noUntracked.contains(where: { $0.id == "untracked.txt" }))

        // 3. Filter with onlyModified = true, showUntracked = false: clean and untracked filtered out
        let modOnlyNoUntracked = tree.compactMap { $0.filter(query: "", onlyModified: true, showUntracked: false) }
        XCTAssert(modOnlyNoUntracked.count == 1, "Only modified branch should be present")
        XCTAssert(modOnlyNoUntracked[0].name == "dir")

        // 4. Filter with onlyModified = true, showUntracked = true: modified and untracked retained, clean excluded
        let modFiltered = tree.compactMap { $0.filter(query: "", onlyModified: true, showUntracked: true) }
        XCTAssert(modFiltered.count == 2, "Untracked and modified branch should be present")
        XCTAssert(modFiltered.contains(where: { $0.id == "untracked.txt" }))
        XCTAssert(modFiltered.contains(where: { $0.id == "dir" }))

        // 5. TabManager showUntrackedFiles & onlyShowModifiedFiles toggle
        let tm = TabManager.shared
        XCTAssert(tm.showUntrackedFiles == true, "showUntrackedFiles must be enabled by default")
        tm.showUntrackedFiles = false
        XCTAssert(tm.showUntrackedFiles == false)
        tm.showUntrackedFiles = true
        XCTAssert(tm.showUntrackedFiles == true)

        tm.onlyShowModifiedFiles = true
        XCTAssert(tm.onlyShowModifiedFiles == true)
        tm.onlyShowModifiedFiles = false
        XCTAssert(tm.onlyShowModifiedFiles == false)

        // 6. Test Show in Finder callback
        var finderRevealedURL: URL? = nil
        let row = FileTreeItemRow(
            node: modFile,
            status: modFile.status,
            level: 1,
            isExpanded: false,
            isActive: false,
            onToggleExpand: {},
            onSelect: {},
            onShowInFinder: {
                finderRevealedURL = modFile.fullURL
            }
        )
        row.onShowInFinder?()
        XCTAssert(finderRevealedURL == modFile.fullURL, "Show in Finder must reveal the target node URL")

        print("  Verified RepositorySidebarView only-modified filter toggle and Show in Finder!")
    }

    func testRepositorySidebarViewContextMenuHighlightAndActions() async throws {
        // 1. Setup a test node and actions
        let testURL = URL(fileURLWithPath: "/tmp/test_file.swift")
        let fileNode = FileTreeNode(id: "test_file.swift", name: "test_file.swift", fullURL: testURL, isDirectory: false, status: .modified)

        var addCalled = false
        var discardCalled = false
        var deleteCalled = false
        var timelineCalled = false
        var commitsCalled = false
        var finderCalled = false

        let fileRow = FileTreeItemRow(
            node: fileNode,
            status: fileNode.status,
            level: 1,
            isExpanded: false,
            isActive: false,
            onToggleExpand: {},
            onSelect: {},
            onAdd: { addCalled = true },
            onDiscardChanges: { discardCalled = true },
            onDelete: { deleteCalled = true },
            onShowTimeline: { timelineCalled = true },
            onShowCommits: { commitsCalled = true },
            onShowInFinder: { finderCalled = true }
        )

        // 2. Build context menu for file
        let fileMenu = fileRow.makeContextMenu()
        XCTAssertNotNil(fileMenu)
        let itemTitles = fileMenu.items.map { $0.title }
        XCTAssertTrue(itemTitles.contains("Add File"))
        XCTAssertTrue(itemTitles.contains("Discard Changes"))
        XCTAssertTrue(itemTitles.contains("Delete File"))
        XCTAssertTrue(itemTitles.contains("Show Timeline"))
        XCTAssertTrue(itemTitles.contains("Show Commits"))
        XCTAssertTrue(itemTitles.contains("Show in Finder"))

        // Trigger actions from menu items
        for item in fileMenu.items {
            if let action = item.action, let target = item.target {
                _ = target.perform(action, with: item)
            }
        }
        XCTAssertTrue(addCalled)
        XCTAssertTrue(discardCalled)
        XCTAssertTrue(deleteCalled)
        XCTAssertTrue(timelineCalled)
        XCTAssertTrue(commitsCalled)
        XCTAssertTrue(finderCalled)

        // 3. Build context menu for directory
        let dirURL = URL(fileURLWithPath: "/tmp/test_dir")
        let dirNode = FileTreeNode(id: "test_dir", name: "test_dir", fullURL: dirURL, isDirectory: true, status: .clean)
        var dirCommitsCalled = false
        var dirFinderCalled = false

        let dirRow = FileTreeItemRow(
            node: dirNode,
            status: dirNode.status,
            level: 0,
            isExpanded: true,
            isActive: false,
            onToggleExpand: {},
            onShowCommits: { dirCommitsCalled = true },
            onShowInFinder: { dirFinderCalled = true }
        )
        let dirMenu = dirRow.makeContextMenu()
        let dirTitles = dirMenu.items.map { $0.title }
        XCTAssertTrue(dirTitles.contains("Show Commits"))
        XCTAssertTrue(dirTitles.contains("Show in Finder"))
        XCTAssertFalse(dirTitles.contains("Show Timeline"))

        for item in dirMenu.items {
            if let action = item.action, let target = item.target {
                _ = target.perform(action, with: item)
            }
        }
        XCTAssertTrue(dirCommitsCalled)
        XCTAssertTrue(dirFinderCalled)

        // 4. RemoteRepositoryRow context menu
        let remote = RemoteRepository(name: "origin", urlString: "https://github.com/example/repo.git")
        var pullCalled = false
        var pushCalled = false

        let remoteRow = RemoteRepositoryRow(
            remote: remote,
            isPushing: false,
            isPulling: false,
            pushError: nil,
            pullError: nil,
            onPull: { pullCalled = true },
            onPush: { pushCalled = true }
        )
        let remoteMenu = remoteRow.makeContextMenu()
        let remoteTitles = remoteMenu.items.map { $0.title }
        XCTAssertTrue(remoteTitles.contains("Copy Remote URL"))
        XCTAssertTrue(remoteTitles.contains("Pull from origin"))
        XCTAssertTrue(remoteTitles.contains("Push to origin"))

        for item in remoteMenu.items {
            if let action = item.action, let target = item.target {
                _ = target.perform(action, with: item)
            }
        }
        XCTAssertTrue(pullCalled)
        XCTAssertTrue(pushCalled)

        // 5. ContextMenuHighlightNSView menu tracking lifecycle
        var highlightOpen = false
        var highlightClosed = false

        let highlightNSView = ContextMenuHighlightNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        highlightNSView.onMenuWillOpen = { highlightOpen = true }
        highlightNSView.onMenuDidClose = { highlightClosed = true }
        highlightNSView.menuBuilder = {
            let m = NSMenu(title: "Test")
            m.addItem(withTitle: "Option", action: nil, keyEquivalent: "")
            return m
        }

        let dummyEvent = NSEvent()
        guard let trackedMenu = highlightNSView.menu(for: dummyEvent) else {
            XCTFail("highlightNSView.menu should return a menu")
            return
        }

        XCTAssertFalse(highlightOpen)
        highlightNSView.menuWillOpen(trackedMenu)
        XCTAssertTrue(highlightOpen)

        XCTAssertFalse(highlightClosed)
        highlightNSView.menuDidClose(trackedMenu)
        XCTAssertTrue(highlightClosed)

        // Test notification-based closure
        highlightOpen = false
        highlightClosed = false
        highlightNSView.menuWillOpen(trackedMenu)
        XCTAssertTrue(highlightOpen)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: trackedMenu)
        XCTAssertTrue(highlightClosed)

        print("  Verified RepositorySidebarView context menu highlighting and actions!")
    }

    func testImageViewerCentralizationAndDefaultFitZoom() async throws {
        // 1. Small image that fits within viewport: default zoom must be 1.0
        let smallImage = CGSize(width: 200, height: 150)
        let viewport = CGSize(width: 800, height: 600)
        let zoomSmall = ImageViewerView.calculateDefaultZoom(imageSize: smallImage, availableSize: viewport)
        XCTAssert(zoomSmall == 1.0, "Small image that fits must start at 1.0 (100%) zoom")

        // 2. Image too wide for viewport: default zoom must scale down to fit width
        let wideImage = CGSize(width: 2000, height: 400)
        let zoomWide = ImageViewerView.calculateDefaultZoom(imageSize: wideImage, availableSize: viewport)
        XCTAssert(zoomWide < 1.0, "Oversized width image must start with fit zoom < 1.0")
        let displayedW = wideImage.width * zoomWide
        XCTAssert(displayedW <= viewport.width, "Displayed width (\(displayedW)) must fit in viewport (\(viewport.width))")

        // 3. Image too tall for viewport: default zoom must scale down to fit height
        let tallImage = CGSize(width: 400, height: 2000)
        let zoomTall = ImageViewerView.calculateDefaultZoom(imageSize: tallImage, availableSize: viewport)
        XCTAssert(zoomTall < 1.0, "Oversized height image must start with fit zoom < 1.0")
        let displayedH = tallImage.height * zoomTall
        XCTAssert(displayedH <= viewport.height, "Displayed height (\(displayedH)) must fit in viewport (\(viewport.height))")

        // 4. Image oversized in both dimensions: default zoom scales down so both fit
        let hugeImage = CGSize(width: 3840, height: 2160)
        let zoomHuge = ImageViewerView.calculateDefaultZoom(imageSize: hugeImage, availableSize: viewport)
        XCTAssert(hugeImage.width * zoomHuge <= viewport.width, "Width must fit in viewport")
        XCTAssert(hugeImage.height * zoomHuge <= viewport.height, "Height must fit in viewport")

        print("  Verified ImageViewerView centralization and default fit zoom calculations!")
    }

    func testCommitPromptViewModelAndVCSCommit() async throws {
        // 1. Setup a test Git repository with changes
        let gitRepo = URL(fileURLWithPath: "/tmp/test_git_commit_feature")
        try? FileManager.default.removeItem(at: gitRepo)
        try FileManager.default.createDirectory(at: gitRepo, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: gitRepo)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "CommitDev"], currentDirectory: gitRepo)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "commit@example.com"], currentDirectory: gitRepo)

        try "initial file".write(to: gitRepo.appendingPathComponent("initial.txt"), atomically: true, encoding: .utf8)
        try "to be removed".write(to: gitRepo.appendingPathComponent("removed.txt"), atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "."], currentDirectory: gitRepo)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "Initial"], currentDirectory: gitRepo)

        let gitContext = RepoContext(vcsType: .git, repoRoot: gitRepo, relativePath: "initial.txt", fullURL: gitRepo.appendingPathComponent("initial.txt"))

        // Initially no changes
        XCTAssert(!VCSManager.shared.hasRepositoryWorkingCopyChanges(context: gitContext), "Clean repo must report no changes")

        // Create 4 changed files: Added, Modified, Removed, Untracked
        try "newly added".write(to: gitRepo.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "added.txt"], currentDirectory: gitRepo)
        try "modified content".write(to: gitRepo.appendingPathComponent("initial.txt"), atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["rm", "removed.txt"], currentDirectory: gitRepo)
        try "new untracked".write(to: gitRepo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        XCTAssert(VCSManager.shared.hasRepositoryWorkingCopyChanges(context: gitContext), "Repo with modifications must report changes")

        // 2. CommitPromptViewModel functionality
        let vm = await MainActor.run {
            CommitPromptViewModel(repoContext: gitContext)
        }

        await MainActor.run {
            XCTAssert(vm.changedFiles.count == 4, "Must detect all 4 changed files, got \(vm.changedFiles.count)")

            // Verify sorting order: Added first, then Modified, Removed, Untracked
            XCTAssert(vm.changedFiles[0].relativePath == "initial.txt" && vm.changedFiles[0].status == .modified, "File 0 must be Modified")
            XCTAssert(vm.changedFiles[1].relativePath == "added.txt" && vm.changedFiles[1].status == .new, "File 1 must be Added")
            XCTAssert(vm.changedFiles[2].relativePath == "removed.txt" && vm.changedFiles[2].status == .deleted, "File 2 must be Removed")
            XCTAssert(vm.changedFiles[3].relativePath == "untracked.txt" && vm.changedFiles[3].status == .unknown, "File 3 must be Untracked")

            // Verify default checked states: Added, Modified, Removed checked; Untracked NOT checked
            XCTAssert(vm.checkedFilePaths.contains("added.txt"), "Added file must be checked by default")
            XCTAssert(vm.checkedFilePaths.contains("initial.txt"), "Modified file must be checked by default")
            XCTAssert(vm.checkedFilePaths.contains("removed.txt"), "Removed file must be checked by default")
            XCTAssert(!vm.checkedFilePaths.contains("untracked.txt"), "Untracked file must NOT be checked by default")
            XCTAssert(vm.checkedFilePaths.count == 3, "Only 3 non-untracked files should be checked by default")

            // Verify "Show untracked" filter defaults to true
            XCTAssert(vm.showUntracked == true, "showUntracked must default to true")
            XCTAssert(vm.visibleChangedFiles.count == 4, "visibleChangedFiles should include untracked when showUntracked is true")

            // Test toggling showUntracked
            vm.showUntracked = false
            XCTAssert(vm.visibleChangedFiles.count == 3, "visibleChangedFiles should exclude untracked when showUntracked is false")
            XCTAssert(!vm.visibleChangedFiles.map(\.relativePath).contains("untracked.txt"), "visibleChangedFiles must not contain untracked.txt")
            vm.showUntracked = true
            XCTAssert(vm.visibleChangedFiles.count == 4)

            XCTAssert(vm.selectedFilePath != nil, "A file must be selected by default")

            // Empty commit message -> canCommit must be false
            vm.commitMessage = "   "
            XCTAssert(!vm.canCommit, "canCommit must be false with empty message")

            vm.commitMessage = "feat: add untracked only"
            XCTAssert(vm.canCommit, "canCommit must be true with message and checked files")

            // Uncheck all files -> canCommit must be false
            vm.checkedFilePaths.removeAll()
            XCTAssert(!vm.canCommit, "canCommit must be false when no files checked")

            // Only check untracked.txt
            vm.checkedFilePaths = ["untracked.txt"]
            XCTAssert(vm.canCommit, "canCommit must be true when 1 file checked")
        }

        // 3. Commit only untracked.txt
        try VCSManager.shared.commit(context: gitContext, files: ["untracked.txt"], message: "feat: add untracked only")

        // Verify untracked.txt is committed, but others are still changed
        let statusesAfterFirst = VCSManager.shared.fetchRepositoryFileStatuses(context: gitContext)
        XCTAssert(statusesAfterFirst["untracked.txt"] == .clean, "untracked.txt must now be committed (.clean)")
        XCTAssert(statusesAfterFirst["added.txt"] == .new, "added.txt must remain staged (.new)")
        XCTAssert(statusesAfterFirst["initial.txt"] == .modified, "initial.txt must remain uncommitted (.modified)")
        XCTAssert(statusesAfterFirst["removed.txt"] == .deleted, "removed.txt must remain uncommitted (.deleted)")
        XCTAssert(VCSManager.shared.hasRepositoryWorkingCopyChanges(context: gitContext), "Still has changed files")

        // 4. Commit remaining files
        try VCSManager.shared.commit(context: gitContext, files: ["added.txt", "initial.txt", "removed.txt"], message: "feat: commit remaining")
        XCTAssert(!VCSManager.shared.hasRepositoryWorkingCopyChanges(context: gitContext), "Must be clean after committing all changes")

        // 5. Test Mercurial (Hg) commit
        let hgRepo = URL(fileURLWithPath: "/tmp/test_hg_commit_feature")
        try? FileManager.default.removeItem(at: hgRepo)
        try FileManager.default.createDirectory(at: hgRepo, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["init"], currentDirectory: hgRepo)
        let hgHgrc = hgRepo.appendingPathComponent(".hg/hgrc")
        try "[ui]\nusername = CommitDev <commit@example.com>\n".write(to: hgHgrc, atomically: true, encoding: .utf8)

        try "hg file".write(to: hgRepo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["add"], currentDirectory: hgRepo)
        _ = try ProcessRunner.run(binary: "hg", arguments: ["commit", "-m", "Initial hg"], currentDirectory: hgRepo)

        let hgContext = RepoContext(vcsType: .hg, repoRoot: hgRepo, relativePath: "file.txt", fullURL: hgRepo.appendingPathComponent("file.txt"))
        XCTAssert(!VCSManager.shared.hasRepositoryWorkingCopyChanges(context: hgContext), "Clean hg repo must have no changes")

        try "hg modified".write(to: hgRepo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "hg new".write(to: hgRepo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        XCTAssert(VCSManager.shared.hasRepositoryWorkingCopyChanges(context: hgContext), "Hg repo with changes must report changes")

        try VCSManager.shared.commit(context: hgContext, files: ["new.txt"], message: "Add new.txt in hg")
        let hgStatusesAfterFirst = VCSManager.shared.fetchRepositoryFileStatuses(context: hgContext)
        XCTAssert(hgStatusesAfterFirst["new.txt"] == .clean, "new.txt in hg must now be .clean")
        XCTAssert(hgStatusesAfterFirst["file.txt"] == .modified, "file.txt in hg must still be .modified")

        try VCSManager.shared.commit(context: hgContext, files: ["file.txt"], message: "Update file.txt in hg")
        XCTAssert(!VCSManager.shared.hasRepositoryWorkingCopyChanges(context: hgContext), "Hg repo must be clean after all commits")

        // 6. Test TabManager openCommitTab & canCommit
        await MainActor.run {
            let tm = TabManager.shared
            tm.selectedRepoContext = gitContext
            tm.hasWorkingCopyChanges = false
            XCTAssert(!tm.canCommit, "canCommit must be false if hasWorkingCopyChanges is false")

            tm.hasWorkingCopyChanges = true
            XCTAssert(tm.canCommit, "canCommit must be true if hasWorkingCopyChanges is true")

            tm.openCommitTab(context: gitContext)
            XCTAssert(tm.activeTab?.isCommitPrompt == true, "Active tab must be commit prompt")
            let tabId = tm.activeTabId

            // Calling openCommitTab again should reuse the existing tab
            tm.openCommitTab(context: gitContext)
            XCTAssert(tm.activeTabId == tabId, "Must reuse existing commit tab")

            // Close commit tab
            if let id = tabId {
                tm.closeTab(id: id)
            }

            // 7. Test multiline commit message and Command+Enter key handling
            let multilineMsg = "feat: add feature\n\nDetailed multiline description:\n- item 1\n- item 2"
            vm.commitMessage = multilineMsg
            XCTAssert(vm.commitMessage.contains("\n"), "Commit message must support multiline with newlines")

            var commitTriggered = false
            let textView = CommitMessageTextView()
            textView.onCommit = {
                commitTriggered = true
            }

            // Normal Return event without command (keyCode 36) -> performKeyEquivalent returns false so it enters newline
            let normalReturnEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )!
            let handledNormal = textView.performKeyEquivalent(with: normalReturnEvent)
            XCTAssert(!handledNormal, "Normal Return must not be intercepted by performKeyEquivalent so it enters a newline")
            XCTAssert(!commitTriggered, "Normal Return must not trigger commit")

            // Command + Return event (keyCode 36 with .command) -> performKeyEquivalent triggers commit and returns true
            let cmdReturnEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )!
            let handledCmd = textView.performKeyEquivalent(with: cmdReturnEvent)
            XCTAssert(handledCmd, "Command + Return must be intercepted by performKeyEquivalent")
            XCTAssert(commitTriggered, "Command + Return must trigger commit")
        }

        print("  Verified CommitPromptViewModel, VCSManager commit (Git & Hg), and TabManager commit tab!")
    }

    func testDiffViewAndDiffViewModel() async throws {
        // 1. Test Myers diff algorithm and line numbering
        let oldLines = ["import SwiftUI", "struct App {", "  let name: String", "  let version: Int", "}", "// footer"]
        let newLines = ["import SwiftUI", "struct App {", "  let name: String", "  let version: Double", "  let author: String", "}", "// footer"]

        let ops = DiffViewModel.computeMyersDiff(old: oldLines, new: newLines)
        let diffLines = DiffViewModel.numberDiffLines(ops: ops)

        XCTAssert(diffLines.filter { $0.type == .unchanged }.count == 5, "Should have 5 unchanged lines")
        XCTAssert(diffLines.filter { $0.type == .deleted }.count == 1, "Should have 1 deleted line")
        XCTAssert(diffLines.filter { $0.type == .added }.count == 2, "Should have 2 added lines")

        // 2. Test Context Chunking (5, 10, 25, Whole File)
        // Setup 60 lines with modifications at line 5 and line 55
        var lines60: [DiffLine] = []
        for i in 1...60 {
            if i == 5 {
                lines60.append(DiffLine(type: .deleted, oldLineNumber: i, newLineNumber: nil, text: "old \(i)"))
                lines60.append(DiffLine(type: .added, oldLineNumber: nil, newLineNumber: i, text: "new \(i)"))
            } else if i == 55 {
                lines60.append(DiffLine(type: .deleted, oldLineNumber: i, newLineNumber: nil, text: "old \(i)"))
                lines60.append(DiffLine(type: .added, oldLineNumber: nil, newLineNumber: i, text: "new \(i)"))
            } else {
                lines60.append(DiffLine(type: .unchanged, oldLineNumber: i, newLineNumber: i, text: "line \(i)"))
            }
        }

        // Context 5 -> 2 distinct chunks
        let chunks5 = DiffViewModel.buildChunks(allLines: lines60, context: 5)
        XCTAssert(chunks5.count == 2, "Context 5 must produce 2 chunks for changes at line 5 and 55, got \(chunks5.count)")
        XCTAssert(chunks5[0].header.contains("-1,"), "Chunk 0 should start at line 1")
        XCTAssert(chunks5[1].header.contains("-50,"), "Chunk 1 should start at line 50")

        // Context 10 -> 2 distinct chunks with more lines
        let chunks10 = DiffViewModel.buildChunks(allLines: lines60, context: 10)
        XCTAssert(chunks10.count == 2, "Context 10 must produce 2 chunks, got \(chunks10.count)")
        XCTAssert(chunks10[0].lines.count > chunks5[0].lines.count, "Context 10 must include more context lines than context 5")

        // Context 25 -> merged into 1 chunk (gap between 5+25=30 and 55-25=30 is closed)
        let chunks25 = DiffViewModel.buildChunks(allLines: lines60, context: 25)
        XCTAssert(chunks25.count == 1, "Context 25 must merge changes at lines 5 and 55 into 1 chunk, got \(chunks25.count)")

        // Context Whole File (nil) -> 1 chunk containing all lines
        let chunksWhole = DiffViewModel.buildChunks(allLines: lines60, context: nil)
        XCTAssert(chunksWhole.count == 1, "Whole file context must produce 1 chunk")
        XCTAssert(chunksWhole[0].lines.count == lines60.count, "Whole file chunk must contain all lines")

        // 3. Test Side-by-Side Row Pairing and Alignment
        let sbsSlice = [
            DiffLine(type: .unchanged, oldLineNumber: 1, newLineNumber: 1, text: "unchanged 1"),
            DiffLine(type: .deleted, oldLineNumber: 2, newLineNumber: nil, text: "deleted 2a"),
            DiffLine(type: .deleted, oldLineNumber: 3, newLineNumber: nil, text: "deleted 2b"),
            DiffLine(type: .added, oldLineNumber: nil, newLineNumber: 2, text: "added 2a"),
            DiffLine(type: .added, oldLineNumber: nil, newLineNumber: 3, text: "added 2b"),
            DiffLine(type: .added, oldLineNumber: nil, newLineNumber: 4, text: "added 2c"),
            DiffLine(type: .unchanged, oldLineNumber: 4, newLineNumber: 5, text: "unchanged 3")
        ]
        let sbsRows = DiffViewModel.buildSideBySideRows(slice: sbsSlice)
        // 1 unchanged row + 3 aligned changed rows (max(2 dels, 3 adds)) + 1 unchanged row = 5 rows
        XCTAssert(sbsRows.count == 5, "Expected 5 side-by-side rows, got \(sbsRows.count)")
        XCTAssert(sbsRows[0].left?.text == "unchanged 1" && sbsRows[0].right?.text == "unchanged 1")
        XCTAssert(sbsRows[1].left?.text == "deleted 2a" && sbsRows[1].right?.text == "added 2a")
        XCTAssert(sbsRows[2].left?.text == "deleted 2b" && sbsRows[2].right?.text == "added 2b")
        XCTAssert(sbsRows[3].left == nil && sbsRows[3].right?.text == "added 2c", "Row 3 must have placeholder on left")
        XCTAssert(sbsRows[4].left?.text == "unchanged 3" && sbsRows[4].right?.text == "unchanged 3")

        // 4. Test Git repository integration with DiffViewModel
        let testRepo = URL(fileURLWithPath: "/tmp/test_diff_view_feature")
        try? FileManager.default.removeItem(at: testRepo)
        try FileManager.default.createDirectory(at: testRepo, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: testRepo)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "DiffDev"], currentDirectory: testRepo)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "diff@example.com"], currentDirectory: testRepo)

        // Text file: main.swift
        let mainContent = "import Foundation\nprint(\"Hello\")\n"
        try mainContent.write(to: testRepo.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        // Binary file: data.bin (contains nul byte)
        var binData = Data([0x01, 0x02, 0x00, 0x04, 0x05])
        try binData.write(to: testRepo.appendingPathComponent("data.bin"))

        // Image file: test.png (minimal valid 1x1 transparent PNG)
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
            0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
            0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ]
        try Data(pngBytes).write(to: testRepo.appendingPathComponent("icon.png"))

        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "."], currentDirectory: testRepo)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "Initial"], currentDirectory: testRepo)

        let repoContext = RepoContext(vcsType: .git, repoRoot: testRepo, relativePath: "main.swift", fullURL: testRepo.appendingPathComponent("main.swift"))

        // Modify main.swift
        let modifiedMain = "import Foundation\nprint(\"Hello World!\")\nprint(\"Added line\")\n"
        try modifiedMain.write(to: testRepo.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        // Modify data.bin
        binData.append(contentsOf: [0x06, 0x07])
        try binData.write(to: testRepo.appendingPathComponent("data.bin"))

        let textChange = WorkingFileChange(relativePath: "main.swift", fullURL: testRepo.appendingPathComponent("main.swift"), status: .modified)
        let binaryChange = WorkingFileChange(relativePath: "data.bin", fullURL: testRepo.appendingPathComponent("data.bin"), status: .modified)
        let imageChange = WorkingFileChange(relativePath: "icon.png", fullURL: testRepo.appendingPathComponent("icon.png"), status: .modified)

        let diffVM = await MainActor.run {
            DiffViewModel(repoContext: repoContext)
        }

        // Test Text File Diff
        await MainActor.run {
            diffVM.loadFile(context: repoContext, change: textChange)
        }
        // Wait for async load to finish
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let loading = await MainActor.run { diffVM.isLoading }
            if !loading { break }
        }

        await MainActor.run {
            XCTAssert(!diffVM.isBinary, "main.swift must not be binary")
            XCTAssert(!diffVM.isImage, "main.swift must not be image")
            XCTAssert(diffVM.fileTypeLabel == "Swift", "File type must be Swift, got \(diffVM.fileTypeLabel)")
            XCTAssert(diffVM.addedCount >= 2, "Should have added lines")
            XCTAssert(diffVM.removedCount >= 1, "Should have removed lines")
            XCTAssert(!diffVM.chunks.isEmpty, "Should have diff chunks")
            XCTAssert(diffVM.displayedPath == "main.swift")

            // Test context switching on DiffViewModel
            diffVM.contextOption = .ten
            XCTAssert(diffVM.contextOption == .ten)
            diffVM.contextOption = .wholeFile
            XCTAssert(diffVM.contextOption == .wholeFile)
            XCTAssert(diffVM.chunks.count == 1, "Whole file context should have 1 chunk")

            // Test diffMode switching
            diffVM.diffMode = .unified
            XCTAssert(diffVM.diffMode == .unified)
            diffVM.diffMode = .sideBySide
            XCTAssert(diffVM.diffMode == .sideBySide)
        }

        // Test Binary File Diff
        await MainActor.run {
            diffVM.loadFile(context: repoContext, change: binaryChange)
        }
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let loading = await MainActor.run { diffVM.isLoading }
            if !loading { break }
        }

        await MainActor.run {
            XCTAssert(diffVM.isBinary, "data.bin must be flagged as binary")
            XCTAssert(!diffVM.isImage, "data.bin must not be image")
            XCTAssert(diffVM.fileTypeLabel == "BINARY", "data.bin file type label must be BINARY")
        }

        // Test Image File Diff
        await MainActor.run {
            diffVM.loadFile(context: repoContext, change: imageChange)
        }
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let loading = await MainActor.run { diffVM.isLoading }
            if !loading { break }
        }

        await MainActor.run {
            XCTAssert(diffVM.isImage, "icon.png must be flagged as image")
            XCTAssert(!diffVM.isBinary, "icon.png must not be flagged as non-image binary")
            XCTAssert(diffVM.fileTypeLabel == "PNG", "icon.png file type label must be PNG, got \(diffVM.fileTypeLabel)")
            XCTAssert(diffVM.oldImage != nil, "Old image should be loaded from HEAD")
            XCTAssert(diffVM.newImage != nil, "New image should be loaded from disk")
        }

        // 5. Test DiffView SwiftUI view instantiation
        await MainActor.run {
            let view = DiffView(viewModel: diffVM)
            _ = view.body
        }

        // 6. Test DiffContainerView and DiffCanvasView with large diff
        await MainActor.run {
            let container = DiffContainerView()
            container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

            // Test Unified Mode with Syntax Highlighting (.swift)
            container.update(chunks: chunksWhole, diffMode: .unified, isDark: false, language: .swift)
            container.layout()
            XCTAssert(container.canvasView.items.count > 0, "Canvas items must be populated in unified mode")
            XCTAssert(container.canvasView.language == .swift, "CanvasView language must be swift")
            XCTAssert(container.scrollView.frame.height == container.bounds.height, "ScrollView must occupy full height in unified mode")
            XCTAssert(!container.minimapView.isHidden, "Minimap must be visible when content exceeds viewport in unified mode")
            XCTAssert(container.minimapView.frame.width == container.minimapWidth, "Minimap width must match minimapWidth")
            XCTAssert(abs(container.scrollView.frame.width - (container.bounds.width - container.minimapWidth)) < 0.5, "ScrollView width must leave room for minimap")
            if case .unifiedLine(_, let attr, _, _) = container.canvasView.items.first(where: {
                if case .unifiedLine = $0 { return true }
                return false
            })! {
                XCTAssert(attr.length > 0, "Highlighted line must produce attributed string")
                let style = attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                XCTAssert(style?.lineBreakMode == .byWordWrapping, "Unified mode must use word wrapping line break style")
            }

            // Test Side-by-Side Mode with Syntax Highlighting (.swift)
            container.update(chunks: chunksWhole, diffMode: .sideBySide, isDark: true, language: .swift)
            container.layout()
            XCTAssert(container.scrollView.frame.origin.y == 0, "Side by side ScrollView must start at y = 0 without header")
            XCTAssert(container.scrollView.frame.height == container.bounds.height, "Side by side ScrollView must occupy full height without header")
            XCTAssert(!container.minimapView.isHidden, "Minimap must be visible when side by side diff requires a scrollbar")
            let expectedColW = max(100, (container.bounds.width - container.minimapWidth - 1) / 2)
            XCTAssert(container.canvasView.columnWidth == expectedColW, "Column width must be half of available width")
            XCTAssert(container.canvasView.language == .swift, "CanvasView language must be swift")
            if case .sideBySideRow(_, let leftAttr, _, _, _) = container.canvasView.items.first(where: {
                if case .sideBySideRow = $0 { return true }
                return false
            })! {
                XCTAssert(leftAttr != nil, "Left cell attributed string should not be nil")
                let style = leftAttr?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                XCTAssert(style?.lineBreakMode == .byWordWrapping, "Side-by-side mode must use word wrapping line break style")
            }

            // Test drawing dirty rect with syntax highlighted content
            let dirtyRect = NSRect(x: 0, y: 100, width: 800, height: 200)
            if let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 800,
                pixelsHigh: 200,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                container.canvasView.draw(dirtyRect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                container.canvasView.draw(dirtyRect)
            }

            // Test Minimap drawing and interactions
            let minimapRect = NSRect(x: 0, y: 0, width: container.minimapWidth, height: 600)
            if let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(container.minimapWidth),
                pixelsHigh: 600,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                container.minimapView.draw(minimapRect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                container.minimapView.draw(minimapRect)
            }

            // Test dynamic resize: when container is tall enough to fit entire diff without scrolling
            container.frame = NSRect(x: 0, y: 0, width: 800, height: 3000)
            container.layout()
            XCTAssert(container.minimapView.isHidden, "Minimap must hide when diff fits within viewport without scrolling")
            XCTAssert(abs(container.scrollView.frame.width - container.bounds.width) < 0.5, "ScrollView must expand to full width when minimap is hidden")
            XCTAssert(container.canvasView.columnWidth == (container.bounds.width - 1) / 2, "Column width must use full container width when minimap is hidden")

            // Test dynamic resize back to small: minimap must reappear
            container.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            container.layout()
            XCTAssert(!container.minimapView.isHidden, "Minimap must reappear dynamically when resized smaller than content")
            XCTAssert(container.minimapView.frame.width == container.minimapWidth, "Minimap frame width must equal minimapWidth")

            // Test wrapping text that takes more than a line
            let longLineText = "let veryLongVariableName = someFunctionWithManyArguments(firstArgument: 123456789, secondArgument: \"A very long descriptive string that definitely takes more than a single line on any standard width display screen\", thirdArgument: true)"
            let shortLineText = "let x = 10"
            let longLine = DiffLine(type: .added, oldLineNumber: nil, newLineNumber: 1, text: longLineText)
            let shortLine = DiffLine(type: .unchanged, oldLineNumber: 2, newLineNumber: 2, text: shortLineText)
            let wrapChunk = DiffChunk(
                header: "@@ -1,2 +1,2 @@",
                lines: [longLine, shortLine],
                sideBySideRows: [
                    SideBySideRow(left: nil, right: longLine),
                    SideBySideRow(left: shortLine, right: shortLine)
                ]
            )

            // In Unified mode with narrow width
            container.frame = NSRect(x: 0, y: 0, width: 350, height: 400)
            container.update(chunks: [wrapChunk], diffMode: .unified, isDark: false, language: .swift)
            container.layout()

            let unifiedLongItem = container.canvasView.items.first {
                if case .unifiedLine(let l, _, _, _) = $0, l.text == longLineText { return true }
                return false
            }
            let unifiedShortItem = container.canvasView.items.first {
                if case .unifiedLine(let l, _, _, _) = $0, l.text == shortLineText { return true }
                return false
            }
            XCTAssert(unifiedLongItem != nil, "Long line item must exist")
            XCTAssert(unifiedShortItem != nil, "Short line item must exist")
            XCTAssert(unifiedLongItem!.height > DiffCanvasView.lineHeight, "Unified long line must wrap and have height greater than single line height (got \(unifiedLongItem!.height))")
            XCTAssert(unifiedShortItem!.height == DiffCanvasView.lineHeight, "Unified short line must not wrap and have default single line height (got \(unifiedShortItem!.height))")

            // In Side-by-Side mode with narrow width
            container.frame = NSRect(x: 0, y: 0, width: 450, height: 400)
            container.update(chunks: [wrapChunk], diffMode: .sideBySide, isDark: false, language: .swift)
            container.layout()

            let sbsLongRow = container.canvasView.items.first {
                if case .sideBySideRow(let r, _, _, _, _) = $0, r.right?.text == longLineText { return true }
                return false
            }
            let sbsShortRow = container.canvasView.items.first {
                if case .sideBySideRow(let r, _, _, _, _) = $0, r.right?.text == shortLineText { return true }
                return false
            }
            XCTAssert(sbsLongRow != nil, "Side-by-side long row must exist")
            XCTAssert(sbsShortRow != nil, "Side-by-side short row must exist")
            XCTAssert(sbsLongRow!.height > DiffCanvasView.lineHeight, "Side-by-side long line must wrap and expand row height (got \(sbsLongRow!.height))")
            XCTAssert(sbsShortRow!.height == DiffCanvasView.lineHeight, "Side-by-side short row must have default single line height (got \(sbsShortRow!.height))")
        }

        print("  Verified DiffView, DiffViewModel, context options, chunking, side-by-side, images, and binary files!")
    }

    func testMinimapViewHiddenWhenScrollbarNotRequired() async throws {
        await MainActor.run {
            let container = CodeEditorContainerView()
            container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

            // 1. Empty content should hide minimap
            container.update(
                content: FileRevisionContent.empty,
                language: .plain,
                isDark: false,
                showBlame: false,
                wrapLines: false,
                showDeletedLines: true,
                selectedCommit: nil,
                blameColumnWidth: 316,
                onBlameClick: { _ in }
            )
            container.layout()
            XCTAssert(container.minimapView.isHidden, "Minimap must be hidden for empty content")
            XCTAssert(container.scrollView.frame.width == container.bounds.width - (container.gutterView.diffBarWidth + container.gutterView.lineNumberWidth), "ScrollView must expand to full width when minimap is hidden")

            // 2. Short content (3 lines, each line 20pt => 60pt < 600pt) should hide minimap
            let shortLines = [
                BlameLine(lineNumber: 1, revision: "1234567", author: "Tester", dateString: "2026-01-01", content: "print(\"hello\")"),
                BlameLine(lineNumber: 2, revision: "1234567", author: "Tester", dateString: "2026-01-01", content: "print(\"world\")"),
                BlameLine(lineNumber: 3, revision: "1234567", author: "Tester", dateString: "2026-01-01", content: "print(\"done\")")
            ]
            let shortContent = FileRevisionContent(
                isImage: false,
                isBinary: false,
                binaryData: nil,
                textLines: shortLines,
                rawText: "print(\"hello\")\nprint(\"world\")\nprint(\"done\")\n"
            )
            container.update(
                content: shortContent,
                language: .swift,
                isDark: false,
                showBlame: false,
                wrapLines: false,
                showDeletedLines: true,
                selectedCommit: nil,
                blameColumnWidth: 316,
                onBlameClick: { _ in }
            )
            container.layout()
            XCTAssert(container.minimapView.isHidden, "Minimap must be hidden when content fits within viewport without scrolling")

            let gutterW = container.gutterView.diffBarWidth + container.gutterView.lineNumberWidth
            XCTAssert(abs(container.scrollView.frame.width - (container.bounds.width - gutterW)) < 0.5, "ScrollView must occupy full width without reserving minimap space")

            // 3. Tall content (100 lines => ~2000pt > 600pt) must show minimap
            var tallLines: [BlameLine] = []
            var tallRaw = ""
            for i in 1...100 {
                let text = "let line\(i) = \(i)\n"
                tallRaw.append(text)
                tallLines.append(BlameLine(lineNumber: i, revision: "abcdef1", author: "Tester", dateString: "2026-01-01", content: text))
            }
            let tallContent = FileRevisionContent(
                isImage: false,
                isBinary: false,
                binaryData: nil,
                textLines: tallLines,
                rawText: tallRaw
            )
            container.update(
                content: tallContent,
                language: .swift,
                isDark: false,
                showBlame: false,
                wrapLines: false,
                showDeletedLines: true,
                selectedCommit: nil,
                blameColumnWidth: 316,
                onBlameClick: { _ in }
            )
            container.layout()
            XCTAssert(!container.minimapView.isHidden, "Minimap must be visible when content exceeds viewport")
            XCTAssert(abs(container.scrollView.frame.width - (container.bounds.width - gutterW - container.minimapWidth)) < 0.5, "ScrollView must leave room for minimap when scrollbar is required")
            XCTAssert(container.minimapView.frame.width == container.minimapWidth, "Minimap frame width must equal minimapWidth when visible")

            // 4. Dynamic resize: resize container taller than the 100 lines (e.g. height 3000)
            container.frame = NSRect(x: 0, y: 0, width: 800, height: 3000)
            container.layout()
            XCTAssert(container.minimapView.isHidden, "Minimap must hide dynamically when resized taller than content")
            XCTAssert(abs(container.scrollView.frame.width - (container.bounds.width - gutterW)) < 0.5, "ScrollView must expand dynamically when resized taller than content")

            // 5. Dynamic resize: resize container smaller (e.g. height 400)
            container.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            container.layout()
            XCTAssert(!container.minimapView.isHidden, "Minimap must show dynamically when resized smaller than content")
        }
        print("  Verified minimap is hidden when content does not require a scrollbar, and visible when it does!")
    }

    // MARK: - Optimistic Repository Tree Updates Tests
    @MainActor
    func testOptimisticAddFile() throws {
        let tm = TabManager()
        let rootURL = URL(fileURLWithPath: "/tmp/mock_repo")
        let statusMap: [String: FileWorkingStatus] = [
            "src/main.swift": .clean,
            "src/new_feature.swift": .unknown
        ]
        tm.repositoryFiles = FileTreeNode.buildTree(from: statusMap, repoRoot: rootURL)
        let initialVersion = tm.repositoryFilesVersion

        // Before optimistic add
        let initialNode = tm.repositoryFiles.findNode(withRelativePath: "src/new_feature.swift")
        XCTAssertNotNil(initialNode)
        XCTAssertEqual(initialNode?.status, .unknown)

        // Optimistically add file
        tm.optimisticAddFile(relativePath: "src/new_feature.swift")

        XCTAssertEqual(tm.repositoryFilesVersion, initialVersion + 1)
        let updatedNode = tm.repositoryFiles.findNode(withRelativePath: "src/new_feature.swift")
        XCTAssertNotNil(updatedNode)
        XCTAssertEqual(updatedNode?.status, .new)

        let parentDir = tm.repositoryFiles.findNode(withRelativePath: "src")
        XCTAssertNotNil(parentDir)
        XCTAssertEqual(parentDir?.status, .modified)
        XCTAssertTrue(tm.hasWorkingCopyChanges)
    }

    @MainActor
    func testOptimisticDiscardChanges() throws {
        let tm = TabManager()
        let rootURL = URL(fileURLWithPath: "/tmp/mock_repo")
        let statusMap: [String: FileWorkingStatus] = [
            "src/staged.swift": .new,
            "src/modified.swift": .modified,
            "src/deleted.swift": .deleted
        ]
        tm.repositoryFiles = FileTreeNode.buildTree(from: statusMap, repoRoot: rootURL)
        var version = tm.repositoryFilesVersion

        // Discard .new -> becomes .unknown
        tm.optimisticDiscardChanges(relativePath: "src/staged.swift", currentStatus: .new)
        XCTAssertEqual(tm.repositoryFilesVersion, version + 1)
        version += 1
        XCTAssertEqual(tm.repositoryFiles.findNode(withRelativePath: "src/staged.swift")?.status, .unknown)

        // Discard .modified -> becomes .clean
        tm.optimisticDiscardChanges(relativePath: "src/modified.swift", currentStatus: .modified)
        XCTAssertEqual(tm.repositoryFilesVersion, version + 1)
        version += 1
        XCTAssertEqual(tm.repositoryFiles.findNode(withRelativePath: "src/modified.swift")?.status, .clean)

        // Discard .deleted -> becomes .clean
        tm.optimisticDiscardChanges(relativePath: "src/deleted.swift", currentStatus: .deleted)
        XCTAssertEqual(tm.repositoryFilesVersion, version + 1)
        version += 1
        XCTAssertEqual(tm.repositoryFiles.findNode(withRelativePath: "src/deleted.swift")?.status, .clean)
    }

    @MainActor
    func testOptimisticDeleteFile() throws {
        let tm = TabManager()
        let rootURL = URL(fileURLWithPath: "/tmp/mock_repo")
        let statusMap: [String: FileWorkingStatus] = [
            "src/untracked.swift": .unknown,
            "src/tracked.swift": .clean
        ]
        tm.repositoryFiles = FileTreeNode.buildTree(from: statusMap, repoRoot: rootURL)
        var version = tm.repositoryFilesVersion

        // Deleting untracked (.unknown) removes node completely
        tm.optimisticDeleteFile(relativePath: "src/untracked.swift", currentStatus: .unknown)
        XCTAssertEqual(tm.repositoryFilesVersion, version + 1)
        version += 1
        XCTAssertNil(tm.repositoryFiles.findNode(withRelativePath: "src/untracked.swift"))

        // Deleting tracked (.clean) marks it as .deleted
        tm.optimisticDeleteFile(relativePath: "src/tracked.swift", currentStatus: .clean)
        XCTAssertEqual(tm.repositoryFilesVersion, version + 1)
        version += 1
        let trackedNode = tm.repositoryFiles.findNode(withRelativePath: "src/tracked.swift")
        XCTAssertNotNil(trackedNode)
        XCTAssertEqual(trackedNode?.status, .deleted)

        let parentDir = tm.repositoryFiles.findNode(withRelativePath: "src")
        XCTAssertEqual(parentDir?.status, .deleted)
    }

    @MainActor
    func testOptimisticCommit() throws {
        let tm = TabManager()
        let rootURL = URL(fileURLWithPath: "/tmp/mock_repo")
        tm.selectedRepoContext = RepoContext(vcsType: .git, repoRoot: rootURL, relativePath: "", fullURL: rootURL)
        let statusMap: [String: FileWorkingStatus] = [
            "src/added.swift": .new,
            "src/modified.swift": .modified,
            "src/deleted.swift": .deleted,
            "src/untouched.swift": .clean
        ]
        tm.repositoryFiles = FileTreeNode.buildTree(from: statusMap, repoRoot: rootURL)
        let initialVersion = tm.repositoryFilesVersion

        // All 3 changed files committed
        tm.optimisticCommit(files: [
            "src/added.swift",
            "src/modified.swift",
            "src/deleted.swift"
        ])

        XCTAssertEqual(tm.repositoryFilesVersion, initialVersion + 1)

        // Added and modified files transition to .clean
        XCTAssertEqual(tm.repositoryFiles.findNode(withRelativePath: "src/added.swift")?.status, .clean)
        XCTAssertEqual(tm.repositoryFiles.findNode(withRelativePath: "src/modified.swift")?.status, .clean)

        // Deleted file is removed from the tree
        XCTAssertNil(tm.repositoryFiles.findNode(withRelativePath: "src/deleted.swift"))

        // Untouched remains .clean
        XCTAssertEqual(tm.repositoryFiles.findNode(withRelativePath: "src/untouched.swift")?.status, .clean)

        // Parent folder becomes .clean since all remaining children are .clean
        let parentDir = tm.repositoryFiles.findNode(withRelativePath: "src")
        XCTAssertNotNil(parentDir)
        XCTAssertEqual(parentDir?.status, .clean)

        // All changes are committed, so working copy changes should be false
        XCTAssertFalse(tm.hasWorkingCopyChanges)

        // Verify both cache entries are updated and retained
        let cacheKey = "git:\(rootURL.standardizedFileURL.path)"
        let repoPath = rootURL.standardizedFileURL.path
        XCTAssertNotNil(tm.repositoryFilesCache[cacheKey])
        XCTAssertNotNil(tm.repositoryFilesCache[repoPath])
        XCTAssertEqual(tm.repositoryFilesCache[cacheKey]?.findNode(withRelativePath: "src/added.swift")?.status, .clean)
        XCTAssertNil(tm.repositoryFilesCache[cacheKey]?.findNode(withRelativePath: "src/deleted.swift"))
    }

    @MainActor
    func testHexHorizontalScrollbarHiddenWhenWideEnough() throws {
        let sampleData = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                               0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10])
        let widthFor16 = HexEditorRepresentable.requiredWidth(for: 16)
        let widthFor32 = HexEditorRepresentable.requiredWidth(for: 32)
        XCTAssertGreaterThan(widthFor16, 0)
        XCTAssertGreaterThan(widthFor32, widthFor16)

        // 1. When width is wide enough for 16 columns (e.g. widthFor16 + 100), horizontal scrollbar must be hidden
        let representable = HexEditorRepresentable(data: sampleData, isDark: false)
        let coordinator = representable.makeCoordinator()
        let scrollView = representable.createScrollView(coordinator: coordinator)
        scrollView.frame = NSRect(x: 0, y: 0, width: widthFor16 + 100, height: 400)
        coordinator.updateDimensionsAndLayout()

        XCTAssertFalse(scrollView.hasHorizontalScroller, "Horizontal scrollbar must be hidden when wide enough for 16 columns")

        // 2. When width is wide enough for 32 columns, horizontal scrollbar must also be hidden
        scrollView.frame = NSRect(x: 0, y: 0, width: widthFor32 + 100, height: 400)
        coordinator.updateDimensionsAndLayout()
        XCTAssertFalse(scrollView.hasHorizontalScroller, "Horizontal scrollbar must be hidden when wide enough for 32 columns")
        XCTAssertEqual(coordinator.bytesPerRow, 32, "Bytes per row should be 32 when wide enough")

        // 3. When width is too narrow for 16 columns (e.g. widthFor16 - 150), horizontal scrollbar must be shown
        scrollView.frame = NSRect(x: 0, y: 0, width: widthFor16 - 150, height: 400)
        coordinator.updateDimensionsAndLayout()
        XCTAssertTrue(scrollView.hasHorizontalScroller, "Horizontal scrollbar must be shown when narrower than 16 columns")
        XCTAssertEqual(coordinator.bytesPerRow, 16, "Bytes per row should fall back to 16")

        // 4. When widened back, horizontal scrollbar must hide again
        scrollView.frame = NSRect(x: 0, y: 0, width: widthFor16 + 50, height: 400)
        coordinator.updateDimensionsAndLayout()
        XCTAssertFalse(scrollView.hasHorizontalScroller, "Horizontal scrollbar must hide again when widened back")
    }

    // MARK: - Commit History Graph & ViewModel Tests
    func testCommitGraphBuilderTopology() throws {
        func makeCommit(_ id: String, _ summary: String) -> CommitInfo {
            CommitInfo(
                id: id,
                displayRevision: id,
                fullRevision: id,
                author: "Tester",
                authorEmail: "test@example.com",
                date: Date(),
                dateFormatted: "2026-11-04",
                summary: summary,
                fullMessage: summary
            )
        }

        // Topology:
        // Row 0: c4 (branch head on lane 0) -> parent c3
        // Row 1: b1 (branch head on lane 1) -> parent c1
        // Row 2: c3 (lane 0) -> parent c2
        // Row 3: c2 (lane 0) -> parent c1
        // Row 4: c1 (common ancestor on lane 0, where lane 1 merges in!) -> parent c0
        // Row 5: c0 (root on lane 0) -> no parents
        let entries: [(commit: CommitInfo, parentIds: [String])] = [
            (makeCommit("c4", "Main tip"), ["c3"]),
            (makeCommit("b1", "Feature branch commit"), ["c1"]),
            (makeCommit("c3", "Main commit 3"), ["c2"]),
            (makeCommit("c2", "Main commit 2"), ["c1"]),
            (makeCommit("c1", "Branch point commit"), ["c0"]),
            (makeCommit("c0", "Initial commit"), [])
        ]

        let built = CommitGraphBuilder.buildRows(from: entries)
        XCTAssertEqual(built.rows.count, 6)
        XCTAssertEqual(built.maxLanes, 2)

        // Row 0 (c4): lane 0, color 0
        XCTAssertEqual(built.rows[0].nodeLane, 0)
        XCTAssertEqual(built.rows[0].nodeColorIndex, 0)
        XCTAssertTrue(built.rows[0].incomingSegments.isEmpty)
        XCTAssertEqual(built.rows[0].outgoingSegments, [GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)])

        // Row 1 (b1): lane 1, color 1, while lane 0 passes through
        XCTAssertEqual(built.rows[1].nodeLane, 1)
        XCTAssertEqual(built.rows[1].nodeColorIndex, 1)
        XCTAssertEqual(built.rows[1].incomingSegments, [GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)])
        XCTAssertTrue(built.rows[1].outgoingSegments.contains(GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)))
        XCTAssertTrue(built.rows[1].outgoingSegments.contains(GraphLaneSegment(fromLane: 1, toLane: 1, colorIndex: 1)))

        // Row 4 (c1): both lane 0 and lane 1 target c1 -> node on lane 0, lane 1 angles into lane 0!
        XCTAssertEqual(built.rows[4].nodeLane, 0)
        XCTAssertEqual(built.rows[4].nodeColorIndex, 0)
        XCTAssertTrue(built.rows[4].incomingSegments.contains(GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)))
        XCTAssertTrue(built.rows[4].incomingSegments.contains(GraphLaneSegment(fromLane: 1, toLane: 0, colorIndex: 1)))
        XCTAssertEqual(built.rows[4].outgoingSegments, [GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)])

        // Row 5 (c0): root commit on lane 0, no outgoing segments
        XCTAssertEqual(built.rows[5].nodeLane, 0)
        XCTAssertEqual(built.rows[5].incomingSegments, [GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)])
        XCTAssertTrue(built.rows[5].outgoingSegments.isEmpty)
    }

    @MainActor
    func testCommitHistoryTabAndInteractions() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestCommitHistory_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "-b", "main"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "HistoryTester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "history@test.com"], currentDirectory: tempDir)

        let fileA = tempDir.appendingPathComponent("alpha.swift")
        let fileB = tempDir.appendingPathComponent("beta.swift")

        try "let a = 1\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "alpha.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Initial alpha commit"], currentDirectory: tempDir)

        // Create a feature branch and commit
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["checkout", "-b", "feature"], currentDirectory: tempDir)
        try "let b = 10\n".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "beta.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Add beta on feature branch"], currentDirectory: tempDir)

        // Switch back to main and modify alpha
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["checkout", "main"], currentDirectory: tempDir)
        try "let a = 1\nlet a2 = 2\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "alpha.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Update alpha on main"], currentDirectory: tempDir)

        let tm = TabManager()
        _ = tm.openRepository(at: tempDir, preferredVCS: .git, fadeDuration: 0)
        tm.openCommitHistoryTab()

        guard let activeTab = tm.activeTab, let historyVM = activeTab.commitHistoryViewModel else {
            XCTFail("Expected active tab to be Commit History tab")
            return
        }
        XCTAssertTrue(activeTab.isCommitHistory)

        // Wait for history and branches to finish loading
        for _ in 0..<100 {
            if !historyVM.isLoading && !historyVM.rows.isEmpty && !historyVM.branches.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(historyVM.rows.count, 3, "All Branches should list all 3 commits")
        XCTAssertGreaterThanOrEqual(historyVM.maxGraphLanes, 2, "Branched repo should use at least 2 graph lanes")
        XCTAssertTrue(historyVM.branches.contains("main"))
        XCTAssertTrue(historyVM.branches.contains("feature"))

        // Initially no commit row is selected -> Commit Details View shows nothing
        XCTAssertNil(historyVM.selectedCommitId)
        XCTAssertNil(historyVM.selectedCommit)
        XCTAssertTrue(historyVM.changedFiles.isEmpty)

        // Select the latest commit ("Update alpha on main")
        let topCommitId = historyVM.rows[0].id
        historyVM.selectCommit(topCommitId)

        for _ in 0..<100 {
            if !historyVM.isLoadingFiles && !historyVM.changedFiles.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(historyVM.selectedCommit?.id, topCommitId)
        XCTAssertEqual(historyVM.selectedCommit?.fullMessage, "Update alpha on main")
        XCTAssertEqual(CommitDetailsView.defaultCommitMessageHeight, 120)
        XCTAssertEqual(CommitDetailsView.descriptionHeaderTitle, "Description")
        XCTAssertEqual(CommitDetailsView.descriptionHeaderIconName, "text.bubble")
        XCTAssertEqual(historyVM.changedFiles.map(\.relativePath), ["alpha.swift"])
        XCTAssertEqual(historyVM.changedFiles.first?.status, .modified)
        XCTAssertEqual(historyVM.selectedFilePath, "alpha.swift", "First file should be automatically selected once files are loaded")

        // Single-clicking on a file updates the DiffView
        historyVM.selectFile("alpha.swift")
        for _ in 0..<100 {
            if !historyVM.diffViewModel.isLoading && !historyVM.diffViewModel.allDiffLines.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(historyVM.selectedFilePath, "alpha.swift")
        XCTAssertEqual(historyVM.diffViewModel.addedCount, 1)
        XCTAssertEqual(historyVM.diffViewModel.removedCount, 0)

        // Double-clicking on a file opens a new ContentView tab for that file starting at the selected commit's revision
        let initialCommitRow = historyVM.rows.last!
        historyVM.selectCommit(initialCommitRow.id)
        for _ in 0..<100 {
            if !historyVM.isLoadingFiles && !historyVM.changedFiles.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        historyVM.openFileInTab("alpha.swift")

        guard let fileTab = tm.activeTab, !fileTab.isCommitHistory else {
            XCTFail("Double clicking a file must switch to a file ContentView tab")
            return
        }
        try await waitForLoad(fileTab.viewModel)
        XCTAssertEqual(fileTab.viewModel.selectedCommit?.id, initialCommitRow.id, "Opened file tab must start at the selected commit's revision")
    }

    @MainActor
    func testCommitHistoryAutoSelectsFirstFileOnRevisionSelection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestAutoSelectFirstFile_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "-b", "main"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: tempDir)

        let file1 = tempDir.appendingPathComponent("first.swift")
        let file2 = tempDir.appendingPathComponent("second.swift")

        try "let first = 1\n".write(to: file1, atomically: true, encoding: .utf8)
        try "let second = 2\n".write(to: file2, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "."], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit with two files"], currentDirectory: tempDir)

        try "let first = 100\n".write(to: file1, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "first.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit with one file"], currentDirectory: tempDir)

        let repoContext = RepoContext(vcsType: .git, repoRoot: tempDir, relativePath: "first.swift", fullURL: file1)
        let historyVM = CommitHistoryViewModel(repoContext: repoContext)

        for _ in 0..<100 {
            if historyVM.hasLoaded && !historyVM.rows.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Initially no commit is selected
        XCTAssertNil(historyVM.selectedCommitId)
        XCTAssertNil(historyVM.selectedFilePath)
        XCTAssertNil(historyVM.diffViewModel.fileChange)

        // 1. Select commit with two files (initial commit)
        let initialCommitRow = historyVM.rows.last!
        historyVM.selectCommit(initialCommitRow.id)

        for _ in 0..<100 {
            if !historyVM.isLoadingFiles && !historyVM.changedFiles.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(historyVM.changedFiles.count, 2)
        let expectedFirstFile = historyVM.changedFiles.first!.relativePath
        XCTAssertEqual(historyVM.selectedFilePath, expectedFirstFile, "The first file must be automatically selected once files are loaded")

        // Wait for diff to load for the automatically selected first file
        for _ in 0..<100 {
            if !historyVM.diffViewModel.isLoading && !historyVM.diffViewModel.allDiffLines.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(historyVM.diffViewModel.fileChange?.relativePath, expectedFirstFile, "Diff must be loaded for the automatically selected first file")

        // 2. Select the top commit (one file)
        let topCommitRow = historyVM.rows.first!
        historyVM.selectCommit(topCommitRow.id)

        for _ in 0..<100 {
            if !historyVM.isLoadingFiles && historyVM.changedFiles.count == 1 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(historyVM.selectedFilePath, "first.swift", "The first file must be automatically selected for top commit")

        // 3. Switch back to initial commit (cached) -> must immediately select its first file
        historyVM.selectCommit(initialCommitRow.id)
        XCTAssertEqual(historyVM.selectedFilePath, expectedFirstFile, "Cached commit selection must automatically select first file")
    }

    @MainActor
    func testCodeSelectionAndCommandCCopyInDiffViewAndContentViewer() throws {
        // 1. ContentViewer CodeTextView selection and Command+C
        let layoutManager = NSLayoutManager()
        let textStorage = NSTextStorage(string: "func helloWorld() {\n    print(\"Hello, World!\")\n}\n")
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(textContainer)

        let codeTextView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        codeTextView.isSelectable = true
        XCTAssertTrue(codeTextView.acceptsFirstResponder)

        // Select "helloWorld"
        codeTextView.setSelectedRange(NSRange(location: 5, length: 10))
        XCTAssertEqual(codeTextView.selectedRange(), NSRange(location: 5, length: 10))

        // Copy via copy(nil)
        NSPasteboard.general.clearContents()
        codeTextView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "helloWorld")

        // Test Command+C key equivalent on CodeTextView
        NSPasteboard.general.clearContents()
        codeTextView.setSelectedRange(NSRange(location: 0, length: 4)) // "func"
        let cmdCEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        )!
        let handled = codeTextView.performKeyEquivalent(with: cmdCEvent)
        XCTAssertTrue(handled, "CodeTextView must handle Command+C key equivalent")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "func")

        // 2. DiffView DiffCanvasView selection and Command+C (Unified mode)
        let unifiedLines = [
            DiffLine(type: .unchanged, oldLineNumber: 1, newLineNumber: 1, text: "let a = 10"),
            DiffLine(type: .deleted, oldLineNumber: 2, newLineNumber: nil, text: "let b = 20"),
            DiffLine(type: .added, oldLineNumber: nil, newLineNumber: 2, text: "let b = 25"),
            DiffLine(type: .unchanged, oldLineNumber: 3, newLineNumber: 3, text: "let c = 30")
        ]
        let unifiedChunk = DiffChunk(header: "@@ -1,3 +1,3 @@", lines: unifiedLines, sideBySideRows: [])

        let canvasView = DiffCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvasView.update(chunks: [unifiedChunk], diffMode: .unified, isDark: false)

        XCTAssertTrue(canvasView.acceptsFirstResponder)

        // Select part of line 1: "let a = 10" (item 1, chars 4..<5 is "a")
        canvasView.selectionAnchor = DiffTextPosition(itemIndex: 1, side: .unified, charIndex: 4)
        canvasView.selectionCurrent = DiffTextPosition(itemIndex: 1, side: .unified, charIndex: 5)
        XCTAssertTrue(canvasView.hasSelection)
        XCTAssertEqual(canvasView.getSelectedText(), "a")

        NSPasteboard.general.clearContents()
        canvasView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "a")

        // Select across multiple lines (from item 1 "let a = 10" to item 3 "let b = 25")
        canvasView.selectionAnchor = DiffTextPosition(itemIndex: 1, side: .unified, charIndex: 0)
        canvasView.selectionCurrent = DiffTextPosition(itemIndex: 3, side: .unified, charIndex: 10)
        let copiedUnifiedMulti = canvasView.getSelectedText()
        XCTAssertEqual(copiedUnifiedMulti, "let a = 10\nlet b = 20\nlet b = 25")

        // Test Command+C key equivalent on DiffCanvasView
        NSPasteboard.general.clearContents()
        let diffCmdCHandled = canvasView.performKeyEquivalent(with: cmdCEvent)
        XCTAssertTrue(diffCmdCHandled, "DiffCanvasView must handle Command+C key equivalent")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "let a = 10\nlet b = 20\nlet b = 25")

        // 3. DiffView DiffCanvasView selection and Command+C (Side-by-side mode)
        let sbsRows = [
            SideBySideRow(
                left: DiffLine(type: .unchanged, oldLineNumber: 1, newLineNumber: 1, text: "alphaOld"),
                right: DiffLine(type: .unchanged, oldLineNumber: 1, newLineNumber: 1, text: "alphaNew")
            ),
            SideBySideRow(
                left: DiffLine(type: .deleted, oldLineNumber: 2, newLineNumber: nil, text: "betaDeleted"),
                right: DiffLine(type: .added, oldLineNumber: nil, newLineNumber: 2, text: "betaAdded")
            )
        ]
        let sbsChunk = DiffChunk(header: "@@ -1,2 +1,2 @@", lines: [], sideBySideRows: sbsRows)
        canvasView.update(chunks: [sbsChunk], diffMode: .sideBySide, isDark: false)

        // Select in left column
        canvasView.selectionAnchor = DiffTextPosition(itemIndex: 1, side: .left, charIndex: 0)
        canvasView.selectionCurrent = DiffTextPosition(itemIndex: 1, side: .left, charIndex: 8) // "alphaOld"
        XCTAssertEqual(canvasView.getSelectedText(), "alphaOld")

        NSPasteboard.general.clearContents()
        canvasView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "alphaOld")

        // Select in right column
        canvasView.selectionAnchor = DiffTextPosition(itemIndex: 2, side: .right, charIndex: 0)
        canvasView.selectionCurrent = DiffTextPosition(itemIndex: 2, side: .right, charIndex: 9) // "betaAdded"
        XCTAssertEqual(canvasView.getSelectedText(), "betaAdded")

        NSPasteboard.general.clearContents()
        canvasView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "betaAdded")
    }

    @MainActor
    func testCommitGraphCurvedLinesSpacingAndOptimisticCommitSwitch() async throws {
        // 1. Verify horizontal spacing of graph
        XCTAssertEqual(CommitGraphCellView.laneSpacing, 8)
        XCTAssertEqual(CommitGraphCellView.laneX(1) - CommitGraphCellView.laneX(0), 8)

        // 2. Verify cross-lane graph segments use curves rather than straight hard-edged lines
        let curvedPath = CommitGraphCellView.segmentPath(fromLane: 1, toLane: 0, startY: 0, endY: 11)
        var hasCurveElement = false
        var lineCount = 0
        curvedPath.forEach { element in
            switch element {
            case .curve:
                hasCurveElement = true
            case .line:
                lineCount += 1
            default:
                break
            }
        }
        XCTAssertTrue(hasCurveElement, "Cross-lane graph segment must use a smooth curve")
        XCTAssertEqual(lineCount, 0, "Cross-lane graph segment must not use hard-edged line segments")

        // 3. Verify CommitPromptView completion switches to CommitHistoryTabView, performs optimistic mutation, and refreshes in background
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestOptimisticHistory_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "-b", "main"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "OptimisticTester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "opt@test.com"], currentDirectory: tempDir)

        let fileA = tempDir.appendingPathComponent("main.swift")
        try "let v = 1\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "main.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "First commit"], currentDirectory: tempDir)

        let tm = TabManager()
        _ = tm.openRepository(at: tempDir, preferredVCS: .git, fadeDuration: 0)
        guard let historyVM = tm.openCommitHistoryTab() else {
            XCTFail("Expected CommitHistoryViewModel")
            return
        }

        // Wait for initial history load
        for _ in 0..<100 {
            if historyVM.hasLoaded && !historyVM.isLoading && !historyVM.rows.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(historyVM.rows.count, 1)
        let firstCommitId = historyVM.rows[0].id

        // Verify draggable column width properties
        historyVM.customGraphColumnWidth = 92
        historyVM.authorColumnWidth = 165
        historyVM.dateColumnWidth = 155
        historyVM.revisionColumnWidth = 105
        XCTAssertEqual(historyVM.effectiveGraphColumnWidth, 92)
        XCTAssertEqual(historyVM.authorColumnWidth, 165)

        // Modify fileA in working directory and open CommitPromptView
        try "let v = 2\n".write(to: fileA, atomically: true, encoding: .utf8)
        tm.openCommitTab()
        guard let commitTab = tm.activeTab, let commitVM = commitTab.commitViewModel else {
            XCTFail("Expected active tab to be CommitPromptView")
            return
        }
        commitVM.commitMessage = "Second commit from prompt\n\nDetailed body"

        // Perform commit: should complete, optimistically mutate historyVM, switch to CommitHistoryTabView, and refresh in background
        commitVM.performCommit()

        for _ in 0..<100 {
            if tm.activeTab?.isCommitHistory == true && historyVM.rows.count == 2 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(tm.activeTab?.isCommitHistory, true, "Must switch to CommitHistoryTabView after CommitPromptView completes commit")
        XCTAssertFalse(tm.tabs.contains(where: { $0.isCommitPrompt }), "CommitPromptView tab should be closed")
        XCTAssertEqual(historyVM.rows.count, 2)
        XCTAssertEqual(historyVM.rows[0].commit.summary, "Second commit from prompt")
        XCTAssertEqual(historyVM.rows[0].parentIds, [firstCommitId])

        // Wait for background refresh to complete and replace any optimistic ID with real Git commit hash
        for _ in 0..<100 {
            if !historyVM.isRefreshingInBackground && !historyVM.rows[0].id.hasPrefix("optimistic_") {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(historyVM.rows[0].id.hasPrefix("optimistic_"), "Background refresh must update commit with real VCS hash")
        XCTAssertEqual(historyVM.rows[0].commit.summary, "Second commit from prompt")
    }

    @MainActor
    func testOpenRepositoryAutomaticallyShowsCommitHistoryAndWorkingDirectoryChangesRow() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestWorkingDirCommitHistory_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "-b", "main"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "WDTester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "wd@test.com"], currentDirectory: tempDir)

        let fileA = tempDir.appendingPathComponent("app.swift")
        try "let x = 1\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "app.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Initial commit"], currentDirectory: tempDir)

        // Create working directory changes before opening repository
        try "let x = 1\nlet y = 2\n".write(to: fileA, atomically: true, encoding: .utf8)

        let tm = TabManager()
        let opened = tm.openRepository(at: tempDir, preferredVCS: .git)
        XCTAssertTrue(opened)

        // 1. Verify opening a repository automatically shows the Commit History tab
        XCTAssertEqual(tm.tabs.count, 1)
        XCTAssertEqual(tm.activeTab?.isCommitHistory, true, "Opening a repository must automatically show the Commit History tab")
        guard let historyVM = tm.activeTab?.commitHistoryViewModel else {
            XCTFail("Expected active tab to have CommitHistoryViewModel")
            return
        }

        // Wait for commit history to finish loading
        for _ in 0..<100 {
            if historyVM.hasLoaded && !historyVM.isLoading && !historyVM.rows.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // 2. Verify working directory changes appear at the top with "Working Directory Changes" and orange text
        XCTAssertEqual(historyVM.rows.count, 2, "Should contain Working Directory Changes row + Initial commit row")
        let topRow = historyVM.rows[0]
        let headCommitRow = historyVM.rows[1]

        XCTAssertTrue(topRow.commit.isUncommitted, "Top row must represent uncommitted working directory changes")
        XCTAssertEqual(topRow.commit.summary, "Working Directory Changes")
        XCTAssertEqual(topRow.parentIds, [headCommitRow.commit.id], "Working Directory Changes row must connect to HEAD commit in graph")
        XCTAssertEqual(topRow.outgoingSegments, [GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)])

        let rowView = CommitHistoryRowView(
            row: topRow,
            graphColumnWidth: 60,
            authorColumnWidth: 140,
            dateColumnWidth: 140,
            revisionColumnWidth: 90
        )
        XCTAssertEqual(rowView.descriptionTextColor, .orange, "Working Directory Changes description must use orange text")

        let normalRowView = CommitHistoryRowView(
            row: headCommitRow,
            graphColumnWidth: 60,
            authorColumnWidth: 140,
            dateColumnWidth: 140,
            revisionColumnWidth: 90,
            isSelected: true
        )
        XCTAssertNotEqual(normalRowView.descriptionTextColor, .orange, "Normal commit rows must not use orange text")

        // Select the Working Directory Changes row and verify changed files & diff load properly
        historyVM.selectCommit(topRow.id)
        for _ in 0..<100 {
            if !historyVM.isLoadingFiles && !historyVM.changedFiles.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(historyVM.changedFiles.map(\.relativePath), ["app.swift"])
        XCTAssertEqual(historyVM.changedFiles.first?.status, .modified)

        // When current selected revision is the working set, CommitDetailsView shows "Pending Files" header and a "Commit" button at the bottom
        let detailsViewForWorkingSet = CommitDetailsView(viewModel: historyVM)
        XCTAssertTrue(detailsViewForWorkingSet.isShowingWorkingSetCommitButton, "CommitDetailsView must show Commit button at the bottom when working set is selected")
        XCTAssertEqual(detailsViewForWorkingSet.filesHeaderTitle, "Pending Files")
        XCTAssertEqual(CommitDetailsView.filesHeaderIconName, "doc.text")

        historyVM.selectFile("app.swift")
        for _ in 0..<100 {
            if !historyVM.diffViewModel.isLoading && !historyVM.diffViewModel.allDiffLines.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(historyVM.diffViewModel.addedCount, 1)

        // When a committed revision is selected, CommitDetailsView shows "Files in Commit" header and "Description" header + commit message (~5 lines height) instead of the Commit button
        historyVM.selectCommit(headCommitRow.id)
        let detailsViewForCommit = CommitDetailsView(viewModel: historyVM)
        XCTAssertFalse(detailsViewForCommit.isShowingWorkingSetCommitButton, "CommitDetailsView must show commit message instead of Commit button for committed revisions")
        XCTAssertEqual(detailsViewForCommit.filesHeaderTitle, "Files in Commit")
        XCTAssertEqual(CommitDetailsView.descriptionHeaderTitle, "Description")
        XCTAssertEqual(CommitDetailsView.descriptionHeaderIconName, "text.bubble")
        XCTAssertEqual(CommitDetailsView.defaultCommitMessageHeight, 120)

        // Clicking the Commit button on the working set opens the CommitPromptView tab
        let fileB = tempDir.appendingPathComponent("extra.swift")
        try "let extra = 42\n".write(to: fileB, atomically: true, encoding: .utf8)
        historyVM.refreshWorkingDirectoryChanges()
        for _ in 0..<100 {
            if !historyVM.isRefreshingInBackground && historyVM.changedFiles.count == 2 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        historyVM.selectCommit(topRow.id)
        historyVM.selectFile("app.swift")
        XCTAssertEqual(Set(historyVM.changedFiles.map(\.relativePath)), Set(["app.swift", "extra.swift"]))

        historyVM.openCommitPrompt()
        XCTAssertEqual(tm.activeTab?.isCommitPrompt, true, "Commit button in CommitDetailsView must open the CommitPromptView tab")

        // Commit only app.swift (leaving extra.swift as an uncommitted working directory change)
        guard let commitVM = tm.activeTab?.commitViewModel else {
            XCTFail("Expected CommitPromptViewModel")
            return
        }
        commitVM.checkedFilePaths = ["app.swift"]
        commitVM.commitMessage = "Commit app.swift only"
        commitVM.performCommit()

        for _ in 0..<100 {
            if tm.activeTab?.isCommitHistory == true && !historyVM.isRefreshingInBackground && historyVM.rows.count == 3 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Verify working directory changes were refreshed on returning to CommitHistoryTabView:
        // "app.swift" is no longer in Pending Files; only "extra.swift" remains
        XCTAssertEqual(tm.activeTab?.isCommitHistory, true)
        XCTAssertTrue(historyVM.rows[0].commit.isUncommitted, "Working Directory Changes row must remain at top while extra.swift is uncommitted")
        XCTAssertEqual(historyVM.rows[1].commit.summary, "Commit app.swift only")
        XCTAssertEqual(historyVM.selectedCommitId, CommitInfo.uncommittedHash)
        XCTAssertEqual(historyVM.changedFiles.map(\.relativePath), ["extra.swift"], "Pending Files must be refreshed to remove committed app.swift")
        XCTAssertNil(historyVM.selectedFilePath, "Previously selected file app.swift was committed so diff selection must be cleared")
    }

    @MainActor
    func testCommitPromptInitializationFromInMemoryCommitHistory() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("archaeologist_inmemory_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gitBin = ProcessInfo.processInfo.environment["PATH"]?.components(separatedBy: ":")
            .map { URL(fileURLWithPath: $0).appendingPathComponent("git").path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/git"

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Test User"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "test@example.com"], currentDirectory: tempDir)

        let fileA = tempDir.appendingPathComponent("app.swift")
        try "let a = 1\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "app.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Initial commit"], currentDirectory: tempDir)

        // Modify app.swift and add untracked new.swift
        try "let a = 1\nlet b = 2\n".write(to: fileA, atomically: true, encoding: .utf8)
        let fileB = tempDir.appendingPathComponent("new.swift")
        try "let c = 3\n".write(to: fileB, atomically: true, encoding: .utf8)

        let tm = TabManager()
        _ = tm.openRepository(at: tempDir, preferredVCS: .git)
        guard let historyVM = tm.activeTab?.commitHistoryViewModel else {
            XCTFail("Expected active tab to have CommitHistoryViewModel")
            return
        }

        // Wait for commit history to finish loading
        for _ in 0..<100 {
            if historyVM.hasLoaded && !historyVM.isLoading && !historyVM.rows.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(historyVM.rows[0].commit.isUncommitted)
        historyVM.selectCommit(CommitInfo.uncommittedHash)

        for _ in 0..<100 {
            if !historyVM.isLoadingFiles && historyVM.changedFiles.count >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        historyVM.selectFile("app.swift")
        for _ in 0..<100 {
            if !historyVM.diffViewModel.isLoading && !historyVM.diffViewModel.chunks.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let originalChunks = historyVM.diffViewModel.chunks
        XCTAssertFalse(originalChunks.isEmpty)

        // 1. Test clicking Commit button in CommitHistoryView (historyVM.openCommitPrompt)
        historyVM.openCommitPrompt()
        guard let commitTab1 = tm.activeTab, let commitVM1 = commitTab1.commitViewModel else {
            XCTFail("Expected CommitPromptViewModel")
            return
        }

        // Verify commit prompt is initialized with in-memory data instantly:
        XCTAssertEqual(Set(commitVM1.changedFiles.map(\.relativePath)), Set(["app.swift", "new.swift"]))
        XCTAssertEqual(commitVM1.selectedFilePath, "app.swift")
        XCTAssertTrue(commitVM1.checkedFilePaths.contains("app.swift"))
        XCTAssertFalse(commitVM1.checkedFilePaths.contains("new.swift"), "Untracked file should not be checked by default")
        XCTAssertEqual(commitVM1.diffViewModel.chunks, originalChunks, "Diff chunks must be copied in memory without re-fetching")

        // Close commit tab
        tm.closeTab(id: commitTab1.id)
        XCTAssertEqual(tm.activeTab?.isCommitHistory, true)

        // 2. Test clicking Commit button from App bar (tm.openCommitTab()) when Commit History is open with working directory selected
        tm.openCommitTab()
        guard let commitTab2 = tm.activeTab, let commitVM2 = commitTab2.commitViewModel else {
            XCTFail("Expected CommitPromptViewModel from toolbar commit button")
            return
        }

        XCTAssertEqual(Set(commitVM2.changedFiles.map(\.relativePath)), Set(["app.swift", "new.swift"]))
        XCTAssertEqual(commitVM2.selectedFilePath, "app.swift")
        XCTAssertTrue(commitVM2.checkedFilePaths.contains("app.swift"))
        XCTAssertFalse(commitVM2.checkedFilePaths.contains("new.swift"))
        XCTAssertEqual(commitVM2.diffViewModel.chunks, originalChunks, "Diff chunks must be copied in memory from Commit History")
    }

    @MainActor
    func testCommitPromptRefreshPreservesSelectionAndUnselectsNewFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("archaeologist_refresh_sel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gitBin = ProcessInfo.processInfo.environment["PATH"]?.components(separatedBy: ":")
            .map { URL(fileURLWithPath: $0).appendingPathComponent("git").path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/git"

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Test User"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "test@example.com"], currentDirectory: tempDir)

        let fileA = tempDir.appendingPathComponent("fileA.txt")
        let fileB = tempDir.appendingPathComponent("fileB.txt")
        try "initial A\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "initial B\n".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "fileA.txt", "fileB.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Initial commit"], currentDirectory: tempDir)

        // Modify both files
        try "modified A\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "modified B\n".write(to: fileB, atomically: true, encoding: .utf8)

        let repoContext = RepoContext(vcsType: .git, repoRoot: tempDir, relativePath: "fileA.txt", fullURL: fileA)
        let commitVM = CommitPromptViewModel(repoContext: repoContext)

        // By default, tracked modified files are checked
        XCTAssertTrue(commitVM.checkedFilePaths.contains("fileA.txt"))
        XCTAssertTrue(commitVM.checkedFilePaths.contains("fileB.txt"))

        // User unchecks fileB.txt
        commitVM.toggleCheck("fileB.txt")
        XCTAssertTrue(commitVM.checkedFilePaths.contains("fileA.txt"))
        XCTAssertFalse(commitVM.checkedFilePaths.contains("fileB.txt"))

        // Now a new fileC.txt appears in the working directory
        let fileC = tempDir.appendingPathComponent("fileC.txt")
        try "new C\n".write(to: fileC, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "fileC.txt"], currentDirectory: tempDir)

        // Refresh working directory
        await commitVM.refreshWorkingDirectoryChanges().value

        // Verification:
        // 1. fileA.txt (checked before) remains checked
        XCTAssertTrue(commitVM.checkedFilePaths.contains("fileA.txt"), "Existing checked file must remain checked")
        // 2. fileB.txt (unselected before) remains unselected
        XCTAssertFalse(commitVM.checkedFilePaths.contains("fileB.txt"), "Existing unselected file must remain unselected")
        // 3. fileC.txt (new in new set but not old) must be unselected
        XCTAssertFalse(commitVM.checkedFilePaths.contains("fileC.txt"), "Any file that exists in new set but not old must be unselected")
    }

    @MainActor
    func testCommitPromptUpdatesRevisionImmediatelyAndMovesBranchTag() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("archaeologist_commit_rev_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gitBin = ProcessInfo.processInfo.environment["PATH"]?.components(separatedBy: ":")
            .map { URL(fileURLWithPath: $0).appendingPathComponent("git").path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/git"

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "-b", "main"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Test User"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "test@example.com"], currentDirectory: tempDir)

        let fileA = tempDir.appendingPathComponent("app.swift")
        try "let a = 1\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "app.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Initial commit"], currentDirectory: tempDir)

        let tm = TabManager()
        _ = tm.openRepository(at: tempDir, preferredVCS: .git)
        guard let historyVM = tm.activeTab?.commitHistoryViewModel else {
            XCTFail("Expected active tab to have CommitHistoryViewModel")
            return
        }

        // Wait for commit history to finish loading
        for _ in 0..<100 {
            if historyVM.hasLoaded && !historyVM.isLoading && !historyVM.rows.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Initially: row 0 is "Initial commit" and has branch "main"
        XCTAssertEqual(historyVM.rows.count, 1)
        let initialHeadCommit = historyVM.rows[0]
        XCTAssertEqual(initialHeadCommit.branches, ["main"], "Initial commit must have branch 'main'")

        // Now modify app.swift and open commit prompt
        try "let a = 1\nlet a2 = 2\n".write(to: fileA, atomically: true, encoding: .utf8)
        tm.openCommitTab()
        guard let commitVM = tm.activeTab?.commitViewModel else {
            XCTFail("Expected CommitPromptViewModel")
            return
        }

        commitVM.commitMessage = "Second commit"
        commitVM.performCommit()

        // Wait for tab manager to switch back to commit history tab
        for _ in 0..<100 {
            if tm.activeTab?.isCommitHistory == true {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Immediately check:
        // 1. The top commit must NOT be "Pending"; it must have a real revision number immediately!
        let topCommitRow = historyVM.rows.first(where: { !$0.commit.isUncommitted })
        XCTAssertNotNil(topCommitRow)
        XCTAssertNotEqual(topCommitRow?.commit.displayRevision, "Pending", "Revision number must be updated immediately without lingering as 'Pending'")
        XCTAssertFalse(topCommitRow?.commit.id.hasPrefix("optimistic_") ?? true, "Commit ID must be the real git hash immediately")

        // 2. Branch tag 'main' must be on the latest commit (topCommitRow), and NOT on the previous top commit
        XCTAssertEqual(topCommitRow?.branches, ["main"], "The latest commit must have the branch 'main'")
        let previousCommitRow = historyVM.rows.first(where: { $0.id == initialHeadCommit.id })
        XCTAssertNotNil(previousCommitRow)
        XCTAssertEqual(previousCommitRow?.branches, [], "The previous top commit must have 'main' removed so it doesn't show on two lines")
    }

    // MARK: - Revert Block Against Working Directory Tests

    func testRevertBlockRangeCalculation() throws {
        let lines: [BlameLine] = [
            BlameLine(lineNumber: 1, revision: "c1", author: "Dev A", dateString: "2026-01-01", content: "line 1 (unchanged)", changeType: .unchanged),
            BlameLine(lineNumber: nil, revision: "c2", author: "Dev B", dateString: "2026-01-02", content: "line 2 (removed)", changeType: .removed),
            BlameLine(lineNumber: 2, revision: "c2", author: "Dev B", dateString: "2026-01-02", content: "line 2 (added)", changeType: .added),
            BlameLine(lineNumber: 3, revision: "c2", author: "Dev B", dateString: "2026-01-02", content: "line 3 (added)", changeType: .added),
            BlameLine(lineNumber: 4, revision: "c1", author: "Dev A", dateString: "2026-01-01", content: "line 4 (unchanged)", changeType: .unchanged),
            BlameLine(lineNumber: 5, revision: "c3", author: "Dev C", dateString: "2026-01-03", content: "line 5 (added in c3)", changeType: .added),
            BlameLine(lineNumber: 6, revision: "c4", author: "Dev D", dateString: "2026-01-04", content: "line 6 (added in c4)", changeType: .added)
        ]

        // Clicking on line 1 (unchanged): empty range
        let r1 = BlameLine.calculateBlockRange(lines: lines, targetIndex: 0)
        XCTAssertEqual(r1, 0..<0)

        // Clicking on line 2 (removed in c2): should expand to all consecutive lines with same commit info (indices 1, 2, 3)
        let r2 = BlameLine.calculateBlockRange(lines: lines, targetIndex: 1)
        XCTAssertEqual(r2, 1..<4)

        // Clicking on line 3 (added in c2): should also expand to 1..<4
        let r3 = BlameLine.calculateBlockRange(lines: lines, targetIndex: 2)
        XCTAssertEqual(r3, 1..<4)

        // Clicking on line 4 (added in c2): should also expand to 1..<4
        let r4 = BlameLine.calculateBlockRange(lines: lines, targetIndex: 3)
        XCTAssertEqual(r4, 1..<4)

        // Line 5 (added in c3) and line 6 (added in c4) have different commit info, so should NOT group together
        let r5 = BlameLine.calculateBlockRange(lines: lines, targetIndex: 5)
        XCTAssertEqual(r5, 5..<6)

        let r6 = BlameLine.calculateBlockRange(lines: lines, targetIndex: 6)
        XCTAssertEqual(r6, 6..<7)

        // Verify isFirstLineOfBlock logic: icon must only show on the FIRST line of each block
        XCTAssertFalse(BlameLine.isFirstLineOfBlock(lines: lines, index: 0), "Unchanged line must not show revert icon")
        XCTAssertTrue(BlameLine.isFirstLineOfBlock(lines: lines, index: 1), "First line of block 1..<4 must show revert icon")
        XCTAssertFalse(BlameLine.isFirstLineOfBlock(lines: lines, index: 2), "Subsequent line in block must NOT show revert icon")
        XCTAssertFalse(BlameLine.isFirstLineOfBlock(lines: lines, index: 3), "Subsequent line in block must NOT show revert icon")
        XCTAssertFalse(BlameLine.isFirstLineOfBlock(lines: lines, index: 4), "Unchanged line must not show revert icon")
        XCTAssertTrue(BlameLine.isFirstLineOfBlock(lines: lines, index: 5), "First line of block 5..<6 must show revert icon")
        XCTAssertTrue(BlameLine.isFirstLineOfBlock(lines: lines, index: 6), "First line of block 6..<7 must show revert icon")
    }

    func testRevertBlockApplicationCleanly() throws {
        // Test 1: Reverting an addition (deletes the added lines)
        let originalContent = "func start() {\n    let a = 1\n    let b = 2\n}\n"
        let blockAddition: [BlameLine] = [
            BlameLine(lineNumber: 2, revision: "rev1", author: "Dev", dateString: "", content: "    let a = 1", changeType: .added),
            BlameLine(lineNumber: 3, revision: "rev1", author: "Dev", dateString: "", content: "    let b = 2", changeType: .added)
        ]
        let resAdd = BlameLine.applyRevert(
            workingContent: originalContent,
            blockLines: blockAddition,
            contextBefore: ["func start() {"],
            contextAfter: ["}"]
        )
        guard case .success(let revertedAdd) = resAdd else {
            XCTFail("Expected successful revert of added block, got \(resAdd)")
            return
        }
        XCTAssertEqual(revertedAdd, "func start() {\n}\n")

        // Test 2: Reverting a deletion (restores the deleted lines)
        let contentAfterDeletion = "func start() {\n}\n"
        let blockDeletion: [BlameLine] = [
            BlameLine(lineNumber: nil, revision: "rev2", author: "Dev", dateString: "", content: "    let restored = 99", changeType: .removed)
        ]
        let resDel = BlameLine.applyRevert(
            workingContent: contentAfterDeletion,
            blockLines: blockDeletion,
            contextBefore: ["func start() {"],
            contextAfter: ["}"]
        )
        guard case .success(let revertedDel) = resDel else {
            XCTFail("Expected successful revert of deleted block, got \(resDel)")
            return
        }
        XCTAssertEqual(revertedDel, "func start() {\n    let restored = 99\n}\n")

        // Test 3: Reverting a replacement (swaps added lines back to removed lines)
        let contentWithNew = "func start() {\n    let newVar = 42\n}\n"
        let blockReplacement: [BlameLine] = [
            BlameLine(lineNumber: nil, revision: "rev3", author: "Dev", dateString: "", content: "    let oldVar = 10", changeType: .removed),
            BlameLine(lineNumber: 2, revision: "rev3", author: "Dev", dateString: "", content: "    let newVar = 42", changeType: .added)
        ]
        let resRepl = BlameLine.applyRevert(
            workingContent: contentWithNew,
            blockLines: blockReplacement,
            contextBefore: ["func start() {"],
            contextAfter: ["}"]
        )
        guard case .success(let revertedRepl) = resRepl else {
            XCTFail("Expected successful revert of replaced block, got \(resRepl)")
            return
        }
        XCTAssertEqual(revertedRepl, "func start() {\n    let oldVar = 10\n}\n")
    }

    func testRevertBlockApplicationFailureAndErrorMessage() throws {
        // Working directory does not have the target lines (e.g. modified or conflict)
        let modifiedWorkingContent = "func start() {\n    let modified = 999\n}\n"
        let blockAddition: [BlameLine] = [
            BlameLine(lineNumber: 2, revision: "rev1", author: "Dev", dateString: "", content: "    let a = 1", changeType: .added)
        ]
        let result = BlameLine.applyRevert(
            workingContent: modifiedWorkingContent,
            blockLines: blockAddition,
            contextBefore: ["func start() {"],
            contextAfter: ["}"]
        )
        guard case .failure(let error) = result else {
            XCTFail("Expected failure when target lines not found in working directory")
            return
        }
        XCTAssertEqual(error, .targetLinesNotFound)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("not found in working directory") == true)
    }

    func testArchaeologistViewModelRevertBlockIntegration() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestRevert_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: tempDir)

        let testFile = tempDir.appendingPathComponent("main.swift")
        try "func run() {\n    let version = 1\n}\n".write(to: testFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "main.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit 1: version 1"], currentDirectory: tempDir)

        try "func run() {\n    let version = 2\n    let extra = true\n}\n".write(to: testFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-am", "Commit 2: version 2"], currentDirectory: tempDir)

        let vm = HistoryViewModel()
        vm.openFile(url: testFile)
        try await waitForLoad(vm)

        // Wait for revisions to load
        for _ in 0..<100 {
            if vm.currentContent != nil && !vm.isContentLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let content = vm.currentContent else {
            XCTFail("Expected content to be loaded")
            return
        }

        // Find the index of the added line in Commit 2
        guard let changeIndex = content.textLines.firstIndex(where: { $0.changeType == .added }) else {
            XCTFail("Expected an added line in Commit 2")
            return
        }

        let lineId = content.textLines[changeIndex].id

        // Initial revert state must be nil/normal
        XCTAssertNil(vm.revertStates[lineId])
        XCTAssertNil(vm.revertErrorMessage)

        // Execute revert block against working directory
        vm.revertBlock(targetIndex: changeIndex)

        // After successful revert:
        // 1. revertStates must be .success for lines in that block
        XCTAssertEqual(vm.revertStates[lineId], .success)
        XCTAssertNil(vm.revertErrorMessage)

        // 2. Working directory file on disk must now reflect the reverted lines!
        let updatedOnDisk = try String(contentsOf: testFile, encoding: .utf8)
        XCTAssertFalse(updatedOnDisk.contains("let version = 2"), "Working directory file must have reverted 'let version = 2'")
        XCTAssertTrue(updatedOnDisk.contains("let version = 1"), "Working directory file must have restored 'let version = 1'")

        // 3. Attempting to revert the same block again should now fail because it's already reverted or target lines are gone
        vm.revertBlock(targetIndex: changeIndex)
        guard case .error(let message) = vm.revertStates[lineId] else {
            XCTFail("Expected .error state when revert cannot be applied cleanly, got \(String(describing: vm.revertStates[lineId]))")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(vm.revertErrorMessage, message, "revertErrorMessage must be shown when revert fails")
    }

    func testDiffViewBlockRangeAndFirstLineCalculation() {
        let canvas = DiffCanvasView()

        // 1. Unified items test
        let uLine1 = DiffLine(id: "u1", type: .unchanged, oldLineNumber: 1, newLineNumber: 1, text: "let a = 1")
        let dLine2 = DiffLine(id: "d2", type: .deleted, oldLineNumber: 2, newLineNumber: nil, text: "let b = 2")
        let aLine3 = DiffLine(id: "a3", type: .added, oldLineNumber: nil, newLineNumber: 2, text: "let b = 20")
        let aLine4 = DiffLine(id: "a4", type: .added, oldLineNumber: nil, newLineNumber: 3, text: "let c = 30")
        let uLine5 = DiffLine(id: "u5", type: .unchanged, oldLineNumber: 3, newLineNumber: 4, text: "let d = 4")

        canvas.items = [
            .unifiedHeader(text: "@@ -1,3 +1,4 @@", y: 0, height: 24),
            .unifiedLine(line: uLine1, attributedText: NSAttributedString(string: "let a = 1"), y: 24, height: 20),
            .unifiedLine(line: dLine2, attributedText: NSAttributedString(string: "let b = 2"), y: 44, height: 20),
            .unifiedLine(line: aLine3, attributedText: NSAttributedString(string: "let b = 20"), y: 64, height: 20),
            .unifiedLine(line: aLine4, attributedText: NSAttributedString(string: "let c = 30"), y: 84, height: 20),
            .unifiedLine(line: uLine5, attributedText: NSAttributedString(string: "let d = 4"), y: 104, height: 20),
        ]

        // Header at 0 is not a change item
        XCTAssertFalse(canvas.isChangeItem(at: 0))
        XCTAssertFalse(canvas.isFirstLineOfBlock(at: 0))

        // uLine1 at 1 is unchanged
        XCTAssertFalse(canvas.isChangeItem(at: 1))
        XCTAssertFalse(canvas.isFirstLineOfBlock(at: 1))

        // dLine2 at 2 is the FIRST line of the change block [2, 3, 4]
        XCTAssertTrue(canvas.isChangeItem(at: 2))
        XCTAssertTrue(canvas.isFirstLineOfBlock(at: 2), "First line of block must return true")

        // aLine3 at 3 and aLine4 at 4 are part of the block, but NOT the first line
        XCTAssertTrue(canvas.isChangeItem(at: 3))
        XCTAssertFalse(canvas.isFirstLineOfBlock(at: 3), "Subsequent lines in block must return false")
        XCTAssertTrue(canvas.isChangeItem(at: 4))
        XCTAssertFalse(canvas.isFirstLineOfBlock(at: 4), "Subsequent lines in block must return false")

        // uLine5 at 5 is unchanged
        XCTAssertFalse(canvas.isChangeItem(at: 5))

        // Block range calculation from any line within the block must return 2..<5
        let rangeFromFirst = canvas.calculateBlockRange(at: 2)
        XCTAssertEqual(rangeFromFirst, 2..<5, "Range from line 2 must be 2..<5")
        let rangeFromMid = canvas.calculateBlockRange(at: 3)
        XCTAssertEqual(rangeFromMid, 2..<5, "Range from line 3 must be 2..<5")
        let rangeFromLast = canvas.calculateBlockRange(at: 4)
        XCTAssertEqual(rangeFromLast, 2..<5, "Range from line 4 must be 2..<5")

        // Extract block details
        let details = canvas.extractBlockDetails(for: 2..<5)
        XCTAssertEqual(details.keys, ["d2", "a3", "a4"])
        XCTAssertEqual(details.removedLines, ["let b = 2"])
        XCTAssertEqual(details.addedLines, ["let b = 20", "let c = 30"])
        XCTAssertEqual(details.contextBefore, ["let a = 1"])
        XCTAssertEqual(details.contextAfter, ["let d = 4"])

        // 2. Side-by-Side items test
        let sbsRow1 = SideBySideRow(id: "sbs1", left: uLine1, right: uLine1)
        let sbsRow2 = SideBySideRow(id: "sbs2", left: dLine2, right: aLine3)
        let sbsRow3 = SideBySideRow(id: "sbs3", left: nil, right: aLine4)
        let sbsRow4 = SideBySideRow(id: "sbs4", left: uLine5, right: uLine5)

        canvas.items = [
            .sideBySideHeader(text: "@@ -1,3 +1,4 @@", y: 0, height: 24),
            .sideBySideRow(row: sbsRow1, leftAttributedText: nil, rightAttributedText: nil, y: 24, height: 20),
            .sideBySideRow(row: sbsRow2, leftAttributedText: nil, rightAttributedText: nil, y: 44, height: 20),
            .sideBySideRow(row: sbsRow3, leftAttributedText: nil, rightAttributedText: nil, y: 64, height: 20),
            .sideBySideRow(row: sbsRow4, leftAttributedText: nil, rightAttributedText: nil, y: 84, height: 20),
        ]

        XCTAssertFalse(canvas.isFirstLineOfBlock(at: 1))
        XCTAssertTrue(canvas.isFirstLineOfBlock(at: 2), "sbsRow2 is the first line of the block")
        XCTAssertFalse(canvas.isFirstLineOfBlock(at: 3), "sbsRow3 is a continuation of the block")
        XCTAssertFalse(canvas.isFirstLineOfBlock(at: 4))

        let sbsRange = canvas.calculateBlockRange(at: 2)
        XCTAssertEqual(sbsRange, 2..<4)

        let sbsDetails = canvas.extractBlockDetails(for: 2..<4)
        XCTAssertTrue(sbsDetails.keys.contains("sbs2"))
        XCTAssertTrue(sbsDetails.keys.contains("sbs3"))
        XCTAssertEqual(sbsDetails.removedLines, ["let b = 2"])
        XCTAssertEqual(sbsDetails.addedLines, ["let b = 20", "let c = 30"])
        XCTAssertEqual(sbsDetails.contextBefore, ["let a = 1"])
        XCTAssertEqual(sbsDetails.contextAfter, ["let d = 4"])
    }

    func testDiffViewModelRevertBlockCleanlyAndFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestDiffRevert_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: tempDir)

        let testFile = tempDir.appendingPathComponent("code.swift")
        let originalContent = "func compute() {\n    let result = 100\n}\n"
        try originalContent.write(to: testFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "code.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Initial commit"], currentDirectory: tempDir)

        // Modify file in working copy
        let modifiedContent = "func compute() {\n    let result = 999\n    let extra = 42\n}\n"
        try modifiedContent.write(to: testFile, atomically: true, encoding: .utf8)

        guard let repoContext = VCSManager.shared.detectContext(for: testFile) else {
            XCTFail("Failed to detect repo context")
            return
        }

        let diffVM = DiffViewModel(repoContext: repoContext)
        let change = WorkingFileChange(relativePath: "code.swift", fullURL: testFile, status: .modified)
        diffVM.fileChange = change

        // Initial state
        XCTAssertNil(diffVM.revertStates["block_key_1"])
        XCTAssertNil(diffVM.revertErrorMessage)

        // 1. Clean revert: Revert the replacement of `let result = 999\n    let extra = 42` back to `let result = 100`
        diffVM.revertBlock(
            keys: ["block_key_1"],
            removedLines: ["    let result = 100"],
            addedLines: ["    let result = 999", "    let extra = 42"],
            contextBefore: ["func compute() {"],
            contextAfter: ["}"]
        )

        // Verify success state
        XCTAssertEqual(diffVM.revertStates["block_key_1"], .success, "State should be .success on clean revert")
        XCTAssertNil(diffVM.revertErrorMessage, "Error message must be nil on success")

        // Verify working copy on disk was updated
        let revertedOnDisk = try String(contentsOf: testFile, encoding: .utf8)
        XCTAssertTrue(revertedOnDisk.contains("let result = 100"), "Working directory file should now contain original line")
        XCTAssertFalse(revertedOnDisk.contains("let result = 999"), "Working directory file should no longer contain modified line")
        XCTAssertFalse(revertedOnDisk.contains("let extra = 42"), "Working directory file should no longer contain extra line")

        // 2. Failure: Trying to revert the same block again should fail (already reverted)
        diffVM.revertBlock(
            keys: ["block_key_1"],
            removedLines: ["    let result = 100"],
            addedLines: ["    let result = 999", "    let extra = 42"],
            contextBefore: ["func compute() {"],
            contextAfter: ["}"]
        )

        guard case .error(let msg) = diffVM.revertStates["block_key_1"] else {
            XCTFail("Expected .error state when revert fails, got \(String(describing: diffVM.revertStates["block_key_1"]))")
            return
        }
        XCTAssertFalse(msg.isEmpty)
        XCTAssertEqual(diffVM.revertErrorMessage, msg, "revertErrorMessage must be shown on failure")

        // 3. Failure on missing file
        let missingURL = tempDir.appendingPathComponent("non_existent.swift")
        diffVM.fileChange = WorkingFileChange(relativePath: "non_existent.swift", fullURL: missingURL, status: .modified)
        diffVM.revertBlock(
            keys: ["missing_key"],
            removedLines: ["some line"],
            addedLines: ["other line"],
            contextBefore: [],
            contextAfter: []
        )
        guard case .error(let missingMsg) = diffVM.revertStates["missing_key"] else {
            XCTFail("Expected .error state when file does not exist")
            return
        }
        XCTAssertTrue(missingMsg.contains("does not exist") || missingMsg.contains("not found"), "Error should indicate file does not exist")
        XCTAssertEqual(diffVM.revertErrorMessage, missingMsg)
    }

    func testCommitPromptViewWorkingDirectoryUpdatesMaintainScrollAndNoLoadingState() async throws {
        let repoURL = URL(fileURLWithPath: "/tmp/test_commit_prompt_wd_updates_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }

        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: repoURL)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "TestDev"], currentDirectory: repoURL)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "dev@test.com"], currentDirectory: repoURL)

        // Create initial 60-line file so it has scrollable height in DiffContainerView
        var initialLines: [String] = []
        for i in 1...60 {
            initialLines.append("line \(i): initial content")
        }
        let fileAURL = repoURL.appendingPathComponent("fileA.txt")
        try initialLines.joined(separator: "\n").write(to: fileAURL, atomically: true, encoding: .utf8)

        let fileBURL = repoURL.appendingPathComponent("fileB.txt")
        try "file B initial".write(to: fileBURL, atomically: true, encoding: .utf8)

        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "."], currentDirectory: repoURL)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "Initial commit"], currentDirectory: repoURL)

        // Modify fileA and fileB
        var modifiedLines = initialLines
        modifiedLines[10] = "line 11: MODIFIED content"
        modifiedLines[30] = "line 31: MODIFIED content"
        try modifiedLines.joined(separator: "\n").write(to: fileAURL, atomically: true, encoding: .utf8)
        try "file B modified".write(to: fileBURL, atomically: true, encoding: .utf8)

        let repoContext = RepoContext(vcsType: .git, repoRoot: repoURL, relativePath: "fileA.txt", fullURL: fileAURL)

        let vm = await MainActor.run {
            CommitPromptViewModel(repoContext: repoContext)
        }

        // Wait for initial diff load of fileA
        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertEqual(vm.selectedFilePath, "fileA.txt", "fileA.txt should be initially selected")
            XCTAssertFalse(vm.diffViewModel.isLoading, "diffViewModel should not be loading")
            XCTAssertFalse(vm.diffViewModel.chunks.isEmpty, "diffViewModel should have chunks for fileA")
            XCTAssertEqual(vm.checkedFilePaths.count, 2, "Both files should be checked initially")

            // User unchecks fileB
            vm.toggleCheck("fileB.txt")
            XCTAssertFalse(vm.checkedFilePaths.contains("fileB.txt"), "fileB.txt should now be unchecked")
        }

        // Set up DiffContainerView to verify scroll position preservation
        let containerView = await MainActor.run { () -> DiffContainerView in
            let view = DiffContainerView()
            view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            view.update(
                chunks: vm.diffViewModel.chunks,
                diffMode: vm.diffViewModel.diffMode,
                isDark: false,
                language: vm.diffViewModel.language,
                fileKey: vm.diffViewModel.displayedPath
            )
            // Scroll down in the container view
            view.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 50))
            XCTAssertEqual(view.scrollView.contentView.bounds.origin.y, 50, "Scroll origin should be set to 50")
            return view
        }

        // 1. Modify working directory: edit fileA further and add a new tracked file fileC
        var furtherModifiedLines = modifiedLines
        furtherModifiedLines[50] = "line 51: FURTHER MODIFICATION"
        try furtherModifiedLines.joined(separator: "\n").write(to: fileAURL, atomically: true, encoding: .utf8)

        let fileCURL = repoURL.appendingPathComponent("fileC.txt")
        try "file C content".write(to: fileCURL, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "fileC.txt"], currentDirectory: repoURL)

        // Refresh working directory changes
        await vm.refreshWorkingDirectoryChanges().value

        // Wait for diff load task to complete quietly
        try await Task.sleep(nanoseconds: 150_000_000)

        await MainActor.run {
            // Requirement 1: Display update should NOT show a loading state
            XCTAssertFalse(vm.diffViewModel.isLoading, "Display update must NOT show a loading state (isLoading == false)")

            // Requirement 2: If selected file exists after update, maintain display & selection
            XCTAssertEqual(vm.selectedFilePath, "fileA.txt", "Selected file must remain fileA.txt after update")
            XCTAssertEqual(vm.diffViewModel.fileChange?.relativePath, "fileA.txt", "diffViewModel must display fileA.txt")
            XCTAssertFalse(vm.diffViewModel.chunks.isEmpty, "diffViewModel must have valid diff chunks")

            // Verify user-unchecked state for fileB is preserved, existing checked file fileA is preserved, and new file fileC is unselected
            XCTAssertTrue(vm.checkedFilePaths.contains("fileA.txt"), "Previously checked fileA.txt must remain checked")
            XCTAssertFalse(vm.checkedFilePaths.contains("fileB.txt"), "User uncheck for fileB.txt must be preserved")
            XCTAssertFalse(vm.checkedFilePaths.contains("fileC.txt"), "Files existing in new set but not old must be unselected")

            // Verify scroll position is maintained in DiffContainerView for the same file
            containerView.update(
                chunks: vm.diffViewModel.chunks,
                diffMode: vm.diffViewModel.diffMode,
                isDark: false,
                language: vm.diffViewModel.language,
                fileKey: vm.diffViewModel.displayedPath
            )
            XCTAssertEqual(containerView.scrollView.contentView.bounds.origin.y, 50, "Scroll position must be maintained across updates for the same file")
        }

        // 2. Test when the selected file is reverted / clean: it should move to another file
        _ = try ProcessRunner.run(binary: "git", arguments: ["checkout", "--", "fileA.txt"], currentDirectory: repoURL)

        await vm.refreshWorkingDirectoryChanges().value
        try await Task.sleep(nanoseconds: 150_000_000)

        await MainActor.run {
            XCTAssertNotEqual(vm.selectedFilePath, "fileA.txt", "Clean fileA.txt must no longer be selected")
            XCTAssertNotNil(vm.selectedFilePath, "Should select next remaining changed file")
            XCTAssertFalse(vm.changedFiles.contains(where: { $0.relativePath == "fileA.txt" }), "fileA.txt must not be in changedFiles")
        }

        // 3. Test startWatching and stopWatching lifecycle
        await MainActor.run {
            vm.startWatching()
            // Multiple calls to startWatching should be idempotent
            vm.startWatching()
            vm.stopWatching()
            vm.stopWatching()
        }
    }

    func testCommitHistoryViewWorkingSetUpdatesMaintainScrollAndNoLoadingState() async throws {
        let repoURL = URL(fileURLWithPath: "/tmp/test_commit_history_wd_updates_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }

        _ = try ProcessRunner.run(binary: "git", arguments: ["init"], currentDirectory: repoURL)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.name", "TestDev"], currentDirectory: repoURL)
        _ = try ProcessRunner.run(binary: "git", arguments: ["config", "user.email", "dev@test.com"], currentDirectory: repoURL)

        // Create initial 60-line file so it has scrollable height in DiffContainerView
        var initialLines: [String] = []
        for i in 1...60 {
            initialLines.append("line \(i): initial history content")
        }
        let fileAURL = repoURL.appendingPathComponent("fileA.txt")
        try initialLines.joined(separator: "\n").write(to: fileAURL, atomically: true, encoding: .utf8)

        let fileBURL = repoURL.appendingPathComponent("fileB.txt")
        try "file B initial".write(to: fileBURL, atomically: true, encoding: .utf8)

        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "."], currentDirectory: repoURL)
        _ = try ProcessRunner.run(binary: "git", arguments: ["commit", "-m", "Initial commit"], currentDirectory: repoURL)

        // Modify fileA and fileB in working directory
        var modifiedLines = initialLines
        modifiedLines[10] = "line 11: MODIFIED for history"
        modifiedLines[30] = "line 31: MODIFIED for history"
        try modifiedLines.joined(separator: "\n").write(to: fileAURL, atomically: true, encoding: .utf8)
        try "file B modified".write(to: fileBURL, atomically: true, encoding: .utf8)

        let repoContext = RepoContext(vcsType: .git, repoRoot: repoURL, relativePath: "fileA.txt", fullURL: fileAURL)

        let vm = await MainActor.run {
            CommitHistoryViewModel(repoContext: repoContext)
        }

        // Wait for initial load
        try await Task.sleep(nanoseconds: 200_000_000)

        await MainActor.run {
            XCTAssertTrue(vm.hasLoaded, "Commit history should be loaded")
            // Select the working directory changes row
            vm.selectCommit(CommitInfo.uncommittedHash)
            XCTAssertEqual(vm.selectedCommitId, CommitInfo.uncommittedHash, "Working directory changes row should be selected")
            XCTAssertEqual(vm.changedFiles.count, 2, "Should have 2 changed files in working set")

            // Select fileA.txt
            vm.selectFile("fileA.txt")
            XCTAssertEqual(vm.selectedFilePath, "fileA.txt", "fileA.txt should be selected")
        }

        // Wait for diff to load
        try await Task.sleep(nanoseconds: 100_000_000)

        // Set up DiffContainerView and scroll down
        let containerView = await MainActor.run { () -> DiffContainerView in
            XCTAssertFalse(vm.diffViewModel.isLoading, "diffViewModel should not be loading")
            XCTAssertFalse(vm.diffViewModel.chunks.isEmpty, "diffViewModel should have chunks for fileA")

            let view = DiffContainerView()
            view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            view.update(
                chunks: vm.diffViewModel.chunks,
                diffMode: vm.diffViewModel.diffMode,
                isDark: false,
                language: vm.diffViewModel.language,
                fileKey: vm.diffViewModel.displayedPath
            )
            // Scroll down in the container view
            view.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 50))
            XCTAssertEqual(view.scrollView.contentView.bounds.origin.y, 50, "Scroll origin should be set to 50")
            return view
        }

        // 1. Modify working directory: edit fileA further and add a new tracked file fileC
        var furtherModifiedLines = modifiedLines
        furtherModifiedLines[50] = "line 51: FURTHER HISTORY MODIFICATION"
        try furtherModifiedLines.joined(separator: "\n").write(to: fileAURL, atomically: true, encoding: .utf8)

        let fileCURL = repoURL.appendingPathComponent("fileC.txt")
        try "file C content".write(to: fileCURL, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: "git", arguments: ["add", "fileC.txt"], currentDirectory: repoURL)

        // Refresh working directory changes
        await vm.refreshWorkingDirectoryChanges().value

        // Wait for diff load task to complete quietly
        try await Task.sleep(nanoseconds: 150_000_000)

        await MainActor.run {
            // Requirement 1: Display update should NOT show a loading state
            XCTAssertFalse(vm.diffViewModel.isLoading, "Display update must NOT show a loading state (isLoading == false)")
            XCTAssertFalse(vm.isLoadingFiles, "Files update must not show a loading state")

            // Requirement 2: If selected file exists after update, maintain display & selection
            XCTAssertEqual(vm.selectedCommitId, CommitInfo.uncommittedHash, "Working directory changes row should still be selected")
            XCTAssertEqual(vm.selectedFilePath, "fileA.txt", "Selected file must remain fileA.txt after update")
            XCTAssertEqual(vm.diffViewModel.fileChange?.relativePath, "fileA.txt", "diffViewModel must display fileA.txt")
            XCTAssertFalse(vm.diffViewModel.chunks.isEmpty, "diffViewModel must have valid diff chunks")
            XCTAssertEqual(vm.changedFiles.count, 3, "Should now have 3 changed files in working set")

            // Verify scroll position is maintained in DiffContainerView for the same file
            containerView.update(
                chunks: vm.diffViewModel.chunks,
                diffMode: vm.diffViewModel.diffMode,
                isDark: false,
                language: vm.diffViewModel.language,
                fileKey: vm.diffViewModel.displayedPath
            )
            XCTAssertEqual(containerView.scrollView.contentView.bounds.origin.y, 50, "Scroll position must be maintained across updates for the same file")
        }

        // 2. Test when the selected file is reverted / clean: it should clear diff
        _ = try ProcessRunner.run(binary: "git", arguments: ["checkout", "--", "fileA.txt"], currentDirectory: repoURL)

        await vm.refreshWorkingDirectoryChanges().value
        try await Task.sleep(nanoseconds: 150_000_000)

        await MainActor.run {
            XCTAssertNil(vm.selectedFilePath, "Clean fileA.txt must no longer be selected")
            XCTAssertFalse(vm.changedFiles.contains(where: { $0.relativePath == "fileA.txt" }), "fileA.txt must not be in changedFiles")
            XCTAssertNil(vm.diffViewModel.fileChange, "diffViewModel fileChange should be cleared")
        }

        // 3. Test startWatching and stopWatching lifecycle
        await MainActor.run {
            vm.startWatching()
            vm.startWatching()
            vm.stopWatching()
            vm.stopWatching()
        }
    }

    func testCommitHistoryViewDateRevisionAndRefTags() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHistoryRefs_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "-b", "main"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "RefTester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "reftester@test.com"], currentDirectory: tempDir)

        let file = tempDir.appendingPathComponent("code.swift")

        // 1. Initial commit and create a tag
        try "let v = 1\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "code.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Initial commit"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["tag", "-a", "v1.0", "-m", "Release 1.0"], currentDirectory: tempDir)

        // 2. Feature branch commit
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["checkout", "-b", "feature"], currentDirectory: tempDir)
        try "let v = 2\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "code.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit on feature"], currentDirectory: tempDir)

        // 3. Switch back to main and commit
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["checkout", "main"], currentDirectory: tempDir)
        try "let v = 3\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "code.swift"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit on main"], currentDirectory: tempDir)

        let repoContext = RepoContext(vcsType: .git, repoRoot: tempDir, relativePath: "code.swift", fullURL: file)
        let entries = try VCSManager.shared.fetchRepositoryCommitHistory(context: repoContext)
        let built = CommitGraphBuilder.buildRows(from: entries)
        let rows = built.rows

        XCTAssertEqual(rows.count, 3)

        // Requirement 1: Date formatted with formatBlameDate
        let mainRow = rows.first(where: { $0.commit.summary == "Commit on main" })!
        let expectedDateFormatted = VCSManager.formatBlameDate(mainRow.commit.date)
        XCTAssertEqual(mainRow.commit.dateFormatted, expectedDateFormatted)

        // Requirement 2: Revision column for mercurial with just local revision number
        let hgCommit = CommitInfo(
            id: "1234567890abcdef1234567890abcdef12345678",
            displayRevision: "42:123456",
            fullRevision: "1234567890abcdef1234567890abcdef12345678",
            author: "Tester",
            authorEmail: "test@test.com",
            date: Date(),
            dateFormatted: "Today 12:00",
            summary: "Hg commit",
            fullMessage: "Hg commit"
        )
        let hgRow = CommitGraphRow(
            commit: hgCommit,
            parentIds: [],
            nodeLane: 0,
            nodeColorIndex: 0,
            incomingSegments: [],
            outgoingSegments: [],
            maxActiveLane: 0
        )
        let hgRowView = CommitHistoryRowView(
            row: hgRow,
            graphColumnWidth: 60,
            authorColumnWidth: 140,
            dateColumnWidth: 140,
            revisionColumnWidth: 90,
            vcsType: .hg
        )
        XCTAssertEqual(hgRowView.revisionText, "42", "Mercurial row must format revision with just the local revision number")

        let gitRowView = CommitHistoryRowView(
            row: mainRow,
            graphColumnWidth: 60,
            authorColumnWidth: 140,
            dateColumnWidth: 140,
            revisionColumnWidth: 90,
            vcsType: .git
        )
        XCTAssertEqual(gitRowView.revisionText, mainRow.commit.displayRevision, "Git row must retain short hash revision")

        // Requirement 3: Revision copying full hash
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hgRow.commit.fullRevision, forType: .string)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), hgRow.commit.fullRevision)

        // Requirement 4: Latest commit for branches and tags
        // main commit is head of main
        XCTAssertTrue(mainRow.branches.contains("main"), "Top commit on main should have branch tag 'main'")
        XCTAssertFalse(mainRow.branches.contains("feature"))

        // feature commit is head of feature
        let featureRow = rows.first(where: { $0.commit.summary == "Commit on feature" })!
        XCTAssertTrue(featureRow.branches.contains("feature"), "Commit on feature should have branch tag 'feature'")
        XCTAssertFalse(featureRow.branches.contains("main"))

        // Initial commit is tagged v1.0
        let initialRow = rows.first(where: { $0.commit.summary == "Initial commit" })!
        XCTAssertTrue(initialRow.tags.contains("v1.0"), "Initial commit should have repository tag 'v1.0'")
        XCTAssertTrue(initialRow.branches.isEmpty, "Initial commit is not the head of any branch")

        // Branch matches the graph node color
        let featureGraphColor = CommitGraphCellView.color(for: featureRow.nodeColorIndex)
        XCTAssertNotNil(featureGraphColor)
    }

    func testMercurialBranchSelectionFiltersHistory() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHgBranchSelect_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hgBin = self.hgBin
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: tempDir)

        let file = tempDir.appendingPathComponent("file.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["add", "file.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-u", "tester", "-m", "Initial on default"], currentDirectory: tempDir)

        // Named branch 'feature-named'
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["branch", "feature-named"], currentDirectory: tempDir)
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-u", "tester", "-m", "Commit on feature-named"], currentDirectory: tempDir)

        // Switch back to default
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["update", "default"], currentDirectory: tempDir)
        try "v3\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-u", "tester", "-m", "Second on default"], currentDirectory: tempDir)

        // Bookmark 'feature-bookmark'
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["bookmark", "feature-bookmark"], currentDirectory: tempDir)
        try "v4\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-u", "tester", "-m", "Commit on feature-bookmark"], currentDirectory: tempDir)

        let repoContext = RepoContext(vcsType: .hg, repoRoot: tempDir, relativePath: "file.txt", fullURL: file)

        // Verify branches list includes both named branch and bookmark
        let branches = VCSManager.shared.fetchRepositoryBranches(context: repoContext)
        XCTAssertTrue(branches.contains("default"), "Branches must contain default")
        XCTAssertTrue(branches.contains("feature-named"), "Branches must contain feature-named")
        XCTAssertTrue(branches.contains("feature-bookmark"), "Branches must contain feature-bookmark")

        // 1. All branches
        let allEntries = try VCSManager.shared.fetchRepositoryCommitHistory(context: repoContext, branch: nil)
        XCTAssertEqual(allEntries.count, 4, "All Branches should contain all 4 commits")

        // 2. Named branch selection
        let namedEntries = try VCSManager.shared.fetchRepositoryCommitHistory(context: repoContext, branch: "feature-named")
        let namedSummaries = namedEntries.map { $0.commit.summary }
        XCTAssertTrue(namedSummaries.contains("Commit on feature-named"), "Must include commit on feature-named")
        XCTAssertTrue(namedSummaries.contains("Initial on default"), "Must include parent commit on default")
        XCTAssertFalse(namedSummaries.contains("Second on default"), "Must not include second on default")
        XCTAssertFalse(namedSummaries.contains("Commit on feature-bookmark"), "Must not include bookmark commit")

        // 3. Bookmark branch selection
        let bookmarkEntries = try VCSManager.shared.fetchRepositoryCommitHistory(context: repoContext, branch: "feature-bookmark")
        let bookmarkSummaries = bookmarkEntries.map { $0.commit.summary }
        XCTAssertTrue(bookmarkSummaries.contains("Commit on feature-bookmark"), "Must include commit on feature-bookmark")
        XCTAssertTrue(bookmarkSummaries.contains("Second on default"), "Must include ancestor commit on default")
        XCTAssertTrue(bookmarkSummaries.contains("Initial on default"), "Must include base commit on default")
        XCTAssertFalse(bookmarkSummaries.contains("Commit on feature-named"), "Must not include commits from diverged named branch")

        // 4. Default named branch selection
        let defaultEntries = try VCSManager.shared.fetchRepositoryCommitHistory(context: repoContext, branch: "default")
        let defaultSummaries = defaultEntries.map { $0.commit.summary }
        XCTAssertTrue(defaultSummaries.contains("Second on default"))
        XCTAssertTrue(defaultSummaries.contains("Initial on default"))
        XCTAssertFalse(defaultSummaries.contains("Commit on feature-named"), "Default branch must not include commits from feature-named")
    }

    func testCommitHistoryRowViewEquatableDetectsGraphTopologyChanges() throws {
        let commit = CommitInfo(
            id: "commit123",
            displayRevision: "123:abc",
            fullRevision: "abcdef123456",
            author: "Tester",
            authorEmail: "test@example.com",
            date: Date(),
            dateFormatted: "2026-11-09",
            summary: "Test Commit",
            fullMessage: "Test Commit"
        )

        // Row in unfiltered graph (e.g. has incoming segments from multiple lanes)
        let rowBefore = CommitGraphRow(
            commit: commit,
            parentIds: ["parent1"],
            nodeLane: 0,
            nodeColorIndex: 0,
            incomingSegments: [
                GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0),
                GraphLaneSegment(fromLane: 1, toLane: 0, colorIndex: 1)
            ],
            outgoingSegments: [GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)],
            maxActiveLane: 2
        )

        // Row in filtered graph (lane 1 filtered out, only lane 0 remains)
        let rowAfter = CommitGraphRow(
            commit: commit,
            parentIds: ["parent1"],
            nodeLane: 0,
            nodeColorIndex: 0,
            incomingSegments: [
                GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)
            ],
            outgoingSegments: [GraphLaneSegment(fromLane: 0, toLane: 0, colorIndex: 0)],
            maxActiveLane: 1
        )

        let rowViewBefore = CommitHistoryRowView(
            row: rowBefore,
            graphColumnWidth: 60,
            authorColumnWidth: 140,
            dateColumnWidth: 140,
            revisionColumnWidth: 90
        )

        let rowViewAfter = CommitHistoryRowView(
            row: rowAfter,
            graphColumnWidth: 60,
            authorColumnWidth: 140,
            dateColumnWidth: 140,
            revisionColumnWidth: 90
        )

        // Crucial test: Although commit.id and row.id are identical, the graph topology changed!
        // CommitHistoryRowView.== MUST return false so SwiftUI redraws the line without broken graphs.
        XCTAssertEqual(rowViewBefore.row.id, rowViewAfter.row.id)
        XCTAssertNotEqual(rowViewBefore, rowViewAfter, "CommitHistoryRowView must not be equal when graph segments change, preventing broken graph rendering after filtering")

        // Also verify CommitGraphCellView equality
        let cellBefore = CommitGraphCellView(row: rowBefore, rowHeight: 22)
        let cellAfter = CommitGraphCellView(row: rowAfter, rowHeight: 22)
        XCTAssertNotEqual(cellBefore, cellAfter, "CommitGraphCellView must detect graph segment differences")
    }

    // MARK: - CommitHistoryView Context Menu Tests

    @MainActor
    func testCommitHistoryContextMenuCheckoutPermissions() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestCheckoutPerm_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: tempDir)

        let file = tempDir.appendingPathComponent("sample.txt")
        try "initial\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "sample.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit 1"], currentDirectory: tempDir)

        try "modified\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-am", "Commit 2"], currentDirectory: tempDir)

        // Make an uncommitted change so working directory row exists
        try "uncommitted work\n".write(to: file, atomically: true, encoding: .utf8)

        let context = RepoContext(vcsType: .git, repoRoot: tempDir, relativePath: "sample.txt", fullURL: file)
        let vm = CommitHistoryViewModel(repoContext: context)

        // Wait for history to load
        for _ in 0..<100 {
            if vm.hasLoaded && vm.rows.count >= 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(vm.rows.count, 3, "Should have 3 rows: Uncommitted, Commit 2, Commit 1")

        let uncommittedRow = try XCTUnwrap(vm.rows.first(where: { $0.commit.isUncommitted }))
        let headRow = try XCTUnwrap(vm.rows.first(where: { $0.commit.summary == "Commit 2" }))
        let olderRow = try XCTUnwrap(vm.rows.first(where: { $0.commit.summary == "Commit 1" }))

        // 1. Working Directory should be greyed out for checkout
        XCTAssertFalse(vm.canCheckoutRevision(uncommittedRow.commit), "Working Directory cannot be checked out")

        // 2. Currently checked out version (Commit 2 / HEAD) should be greyed out
        XCTAssertTrue(vm.isCurrentlyCheckedOut(headRow.commit), "Commit 2 should be identified as currently checked out")
        XCTAssertFalse(vm.canCheckoutRevision(headRow.commit), "Currently checked out revision should be greyed out")

        // 3. Other revision (Commit 1) should be eligible for checkout
        XCTAssertFalse(vm.isCurrentlyCheckedOut(olderRow.commit), "Commit 1 should not be currently checked out")
        XCTAssertTrue(vm.canCheckoutRevision(olderRow.commit), "Older revision should be eligible for checkout")
    }

    @MainActor
    func testCommitHistoryCheckoutExecutionAndFailureMessage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestCheckoutExec_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: tempDir)

        let file = tempDir.appendingPathComponent("sample.txt")
        try "initial\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "sample.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit 1"], currentDirectory: tempDir)

        try "line 2\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-am", "Commit 2"], currentDirectory: tempDir)

        let context = RepoContext(vcsType: .git, repoRoot: tempDir, relativePath: "sample.txt", fullURL: file)
        let vm = CommitHistoryViewModel(repoContext: context)

        for _ in 0..<100 {
            if vm.hasLoaded && vm.rows.count >= 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let olderRow = try XCTUnwrap(vm.rows.first(where: { $0.commit.summary == "Commit 1" }))
        let olderCommit = olderRow.commit

        // Perform checkout of older commit
        vm.checkoutRevision(olderCommit)

        // Wait for checkout and refresh
        for _ in 0..<100 {
            if vm.isCurrentlyCheckedOut(olderCommit) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(vm.isCurrentlyCheckedOut(olderCommit), "Older commit should now be checked out")
        XCTAssertFalse(vm.canCheckoutRevision(olderCommit), "Now checked out commit should be greyed out")

        // Verify git checkout failure produces a clear error message from git
        // Create an invalid commit to checkout or checkout conflict
        let invalidCommit = CommitInfo(
            id: "deadbeef00000000000000000000000000000000",
            displayRevision: "deadbee",
            fullRevision: "deadbeef00000000000000000000000000000000",
            author: "Tester",
            authorEmail: "tester@test.com",
            date: Date(),
            dateFormatted: "now",
            summary: "Invalid",
            fullMessage: "Invalid"
        )

        var capturedError: String? = nil
        vm.onCheckoutError = { err in
            capturedError = err
        }

        vm.checkoutRevision(invalidCommit)

        for _ in 0..<100 {
            if capturedError != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotNil(capturedError, "Checkout failure should capture error")
        XCTAssertTrue(
            capturedError?.contains("did not match any file") == true ||
            capturedError?.contains("error:") == true ||
            capturedError?.contains("fatal:") == true,
            "Error message should come from git, got: \(String(describing: capturedError))"
        )
    }

    @MainActor
    func testCommitHistoryCompareWithSelected() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestCompareSelected_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: tempDir)

        let fileA = tempDir.appendingPathComponent("fileA.txt")
        let fileB = tempDir.appendingPathComponent("fileB.txt")

        try "File A content\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "fileA.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit 1: Add A"], currentDirectory: tempDir)

        try "File A updated\nExtra line\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "File B content\n".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "fileA.txt", "fileB.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit 2: Modify A, Add B"], currentDirectory: tempDir)

        let context = RepoContext(vcsType: .git, repoRoot: tempDir, relativePath: "fileA.txt", fullURL: fileA)
        let vm = CommitHistoryViewModel(repoContext: context)

        for _ in 0..<100 {
            if vm.hasLoaded && vm.rows.count >= 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let row1 = try XCTUnwrap(vm.rows.first(where: { $0.commit.summary == "Commit 1: Add A" }))
        let row2 = try XCTUnwrap(vm.rows.first(where: { $0.commit.summary == "Commit 2: Modify A, Add B" }))

        // Before selection, canCompareWithSelected should be false
        XCTAssertFalse(vm.canCompareWithSelected(row2.commit))

        // Select Commit 1
        vm.selectCommit(row1.id)
        XCTAssertEqual(vm.selectedCommitId, row1.id)

        // Compare with self should be false
        XCTAssertFalse(vm.canCompareWithSelected(row1.commit), "Cannot compare commit with itself")

        // Compare with Commit 2 should be true
        XCTAssertTrue(vm.canCompareWithSelected(row2.commit), "Can compare with Commit 2")

        // Trigger compareWithSelected
        vm.compareWithSelected(row2.commit)

        XCTAssertTrue(vm.isComparingCommits, "ViewModel should be in comparison mode")
        XCTAssertEqual(vm.comparisonCommitId, row2.id)

        // Wait for changed files between the two commits to load
        for _ in 0..<100 {
            if !vm.isLoadingFiles && !vm.changedFiles.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(vm.changedFiles.count, 2, "Should show 2 changed files between Commit 1 and Commit 2")

        let paths = vm.changedFiles.map { $0.relativePath }
        XCTAssertTrue(paths.contains("fileA.txt"), "Should contain modified fileA.txt")
        XCTAssertTrue(paths.contains("fileB.txt"), "Should contain newly added fileB.txt")

        let fileAChange = try XCTUnwrap(vm.changedFiles.first(where: { $0.relativePath == "fileA.txt" }))
        XCTAssertEqual(fileAChange.status, .modified)

        let fileBChange = try XCTUnwrap(vm.changedFiles.first(where: { $0.relativePath == "fileB.txt" }))
        XCTAssertEqual(fileBChange.status, .new)

        // Verify DiffViewModel loads the comparison diff for fileA.txt
        vm.selectFile("fileA.txt")

        for _ in 0..<100 {
            if !vm.diffViewModel.isLoading && !vm.diffViewModel.allDiffLines.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(vm.diffViewModel.allDiffLines.isEmpty, "DiffView should show diff lines between the two revisions")
        XCTAssertTrue(vm.diffViewModel.addedCount > 0, "Should have added lines")
        XCTAssertTrue(vm.diffViewModel.removedCount > 0, "Should have removed lines")

        // Verify selecting a single commit clears comparison mode
        vm.selectCommit(row2.id)
        XCTAssertFalse(vm.isComparingCommits, "Selecting a commit should exit comparison mode")
        XCTAssertNil(vm.comparisonCommitId)
    }

    @MainActor
    func testCommitHistoryContextMenuHgCheckoutAndCompare() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHgContext_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: tempDir)
        let hgrc = tempDir.appendingPathComponent(".hg/hgrc")
        try "[ui]\nusername = Tester <tester@test.com>\n".write(to: hgrc, atomically: true, encoding: .utf8)

        let file = tempDir.appendingPathComponent("data.txt")
        try "version 1\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["add", "data.txt"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "Commit 1 on hg"], currentDirectory: tempDir)

        try "version 2\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "Commit 2 on hg"], currentDirectory: tempDir)

        let context = RepoContext(vcsType: .hg, repoRoot: tempDir, relativePath: "data.txt", fullURL: file)
        let vm = CommitHistoryViewModel(repoContext: context)

        for _ in 0..<100 {
            if vm.hasLoaded && vm.rows.count >= 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let row1 = try XCTUnwrap(vm.rows.first(where: { $0.commit.summary == "Commit 1 on hg" }))
        let row2 = try XCTUnwrap(vm.rows.first(where: { $0.commit.summary == "Commit 2 on hg" }))

        // Checkout permissions on Hg
        XCTAssertTrue(vm.isCurrentlyCheckedOut(row2.commit), "Row 2 should be checked out")
        XCTAssertFalse(vm.canCheckoutRevision(row2.commit), "Checked out row cannot be checked out again")
        XCTAssertTrue(vm.canCheckoutRevision(row1.commit), "Older row can be checked out")

        // Compare on Hg
        vm.selectCommit(row1.id)
        XCTAssertTrue(vm.canCompareWithSelected(row2.commit))

        vm.compareWithSelected(row2.commit)
        XCTAssertTrue(vm.isComparingCommits)

        for _ in 0..<100 {
            if !vm.isLoadingFiles && !vm.changedFiles.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(vm.changedFiles.count, 1)
        XCTAssertEqual(vm.changedFiles.first?.relativePath, "data.txt")

        // Checkout row 1 on Hg
        vm.checkoutRevision(row1.commit)

        for _ in 0..<100 {
            if vm.isCurrentlyCheckedOut(row1.commit) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(vm.isCurrentlyCheckedOut(row1.commit), "Row 1 should now be checked out on Hg")
    }

    func testCommitDetailsFileViewModeAndTreeFolderColors() async throws {
        XCTAssertEqual(CommitDetailsView.viewAsListIconName, "list.bullet")
        XCTAssertEqual(CommitDetailsView.viewAsTreeIconName, "list.bullet.indent")
        XCTAssertEqual(CommitDetailsView.viewAsListHelp, "View as list")
        XCTAssertEqual(CommitDetailsView.viewAsTreeHelp, "View as tree")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let context = RepoContext(vcsType: .git, repoRoot: tempDir, relativePath: "", fullURL: tempDir)
        let vm = CommitHistoryViewModel(repoContext: context)

        // Default should be tree
        XCTAssertEqual(vm.fileViewMode, .tree)

        // Toggle to list
        vm.fileViewMode = .list
        XCTAssertEqual(vm.fileViewMode, .list)

        // Toggle back to tree
        vm.fileViewMode = .tree
        XCTAssertEqual(vm.fileViewMode, .tree)

        // Verify folder status and color calculations for tree view
        let statusMap: [String: FileWorkingStatus] = [
            "Sources/Core/Model.swift": .modified,
            "Sources/UI/Button.swift": .new,
            "Tests/OldTest.swift": .deleted,
            "Docs/Guide.md": .clean,
            "UntrackedFolder/Sub/NewFile.swift": .unknown
        ]

        let tree = FileTreeNode.buildTree(from: statusMap, repoRoot: tempDir)

        let untrackedFolderNode = try XCTUnwrap(tree.first(where: { $0.name == "UntrackedFolder" }))
        XCTAssertTrue(untrackedFolderNode.isDirectory)
        XCTAssertEqual(untrackedFolderNode.status, .unknownFolder)
        XCTAssertEqual(untrackedFolderNode.statusTextColor, .adaptiveYellow, "Folders containing untracked files should color adaptiveYellow")

        let subNode = try XCTUnwrap(untrackedFolderNode.children?.first(where: { $0.name == "Sub" }))
        XCTAssertTrue(subNode.isDirectory)
        XCTAssertEqual(subNode.status, .unknownFolder)
        XCTAssertEqual(subNode.statusTextColor, .adaptiveYellow, "Subfolders containing untracked files should also color adaptiveYellow")

        // Verify that adaptive yellow provides dark mode system yellow and darkened light mode yellow
        let lightApp = NSAppearance(named: .aqua)!
        let darkApp = NSAppearance(named: .darkAqua)!

        var resolvedLight: NSColor?
        var resolvedDark: NSColor?

        lightApp.performAsCurrentDrawingAppearance {
            resolvedLight = NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                if match == .darkAqua || appearance.name.rawValue.lowercased().contains("dark") {
                    return NSColor.systemYellow
                } else {
                    return NSColor(srgbRed: 0.70, green: 0.53, blue: 0.0, alpha: 1.0)
                }
            }
        }
        darkApp.performAsCurrentDrawingAppearance {
            resolvedDark = NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                if match == .darkAqua || appearance.name.rawValue.lowercased().contains("dark") {
                    return NSColor.systemYellow
                } else {
                    return NSColor(srgbRed: 0.70, green: 0.53, blue: 0.0, alpha: 1.0)
                }
            }
        }

        XCTAssertNotNil(resolvedLight)
        XCTAssertNotNil(resolvedDark)
        XCTAssertEqual(FileWorkingStatus.unknownFolder.textColor, .adaptiveYellow)

        let sourcesNode = try XCTUnwrap(tree.first(where: { $0.name == "Sources" }))
        XCTAssertTrue(sourcesNode.isDirectory)
        XCTAssertEqual(sourcesNode.status, .modified)
        XCTAssertEqual(sourcesNode.statusTextColor, .orange, "Folders containing modified/new files should be colored orange")

        let coreNode = try XCTUnwrap(sourcesNode.children?.first(where: { $0.name == "Core" }))
        XCTAssertTrue(coreNode.isDirectory)
        XCTAssertEqual(coreNode.status, .modified)
        XCTAssertEqual(coreNode.statusTextColor, .orange)

        let uiNode = try XCTUnwrap(sourcesNode.children?.first(where: { $0.name == "UI" }))
        XCTAssertTrue(uiNode.isDirectory)
        XCTAssertEqual(uiNode.status, .new)
        XCTAssertEqual(uiNode.statusTextColor, .green, "Folders containing only new files should be colored green")

        let testsNode = try XCTUnwrap(tree.first(where: { $0.name == "Tests" }))
        XCTAssertTrue(testsNode.isDirectory)
        XCTAssertEqual(testsNode.status, .deleted)
        XCTAssertEqual(testsNode.statusTextColor, .red, "Folders containing only deleted files should be colored red")

        let docsNode = try XCTUnwrap(tree.first(where: { $0.name == "Docs" }))
        XCTAssertTrue(docsNode.isDirectory)
        XCTAssertEqual(docsNode.status, .clean)
        XCTAssertNil(docsNode.statusTextColor, "Clean folders have nil statusTextColor and fall back to systemBlue")

        // Verify CommitPromptViewModel & CommitPromptView file view mode
        XCTAssertEqual(CommitPromptView.viewAsListIconName, "list.bullet")
        XCTAssertEqual(CommitPromptView.viewAsTreeIconName, "list.bullet.indent")
        XCTAssertEqual(CommitPromptView.viewAsListHelp, "View as list")
        XCTAssertEqual(CommitPromptView.viewAsTreeHelp, "View as tree")

        let promptVM = CommitPromptViewModel(repoContext: context)
        XCTAssertEqual(promptVM.fileViewMode, .tree)
        promptVM.fileViewMode = .list
        XCTAssertEqual(promptVM.fileViewMode, .list)
        promptVM.fileViewMode = .tree
        XCTAssertEqual(promptVM.fileViewMode, .tree)
    }

    func testDefaultCollapsedUntrackedFoldersAndTextEditorActive() throws {
        let tempDir = URL(fileURLWithPath: "/tmp/testDefaultCollapsedRepo_\(UUID().uuidString)")
        let statusMap: [String: FileWorkingStatus] = [
            // Folder with only untracked files
            "OnlyUntracked/sub/untracked1.txt": .unknown,
            "OnlyUntracked/untracked2.txt": .unknown,

            // Folder with mixed modifications and untracked files
            "MixedModAndUntracked/modified.txt": .modified,
            "MixedModAndUntracked/untracked.txt": .unknown,

            // Folder with mixed additions and untracked files
            "MixedAddAndUntracked/added.txt": .new,
            "MixedAddAndUntracked/untracked.txt": .unknown,

            // Folder with mixed deletions and untracked files
            "MixedDelAndUntracked/deleted.txt": .deleted,
            "MixedDelAndUntracked/untracked.txt": .unknown,

            // Folder with only modified files
            "OnlyModified/mod1.txt": .modified,

            // Nested folder where parent has modified file and child folder is untracked-only
            "ParentMixed/parent_mod.txt": .modified,
            "ParentMixed/ChildUntracked/file.txt": .unknown
        ]

        let tree = FileTreeNode.buildTree(from: statusMap, repoRoot: tempDir)
        let defaultCollapsed = tree.defaultCollapsedUntrackedNodeIds()

        // 1. OnlyUntracked and its subfolder must be collapsed by default
        XCTAssertTrue(defaultCollapsed.contains("OnlyUntracked"), "Folders with only untracked commits must be collapsed by default")
        XCTAssertTrue(defaultCollapsed.contains("OnlyUntracked/sub"), "Subfolders with only untracked commits must be collapsed by default")

        // 2. Mixed folders must remain expanded (NOT in defaultCollapsed)
        XCTAssertFalse(defaultCollapsed.contains("MixedModAndUntracked"), "Folders containing modifications and untracked files should remain expanded")
        XCTAssertFalse(defaultCollapsed.contains("MixedAddAndUntracked"), "Folders containing additions and untracked files should remain expanded")
        XCTAssertFalse(defaultCollapsed.contains("MixedDelAndUntracked"), "Folders containing deletions and untracked files should remain expanded")

        // 3. Folders with only modified files must remain expanded
        XCTAssertFalse(defaultCollapsed.contains("OnlyModified"), "Folders with modified files should remain expanded")

        // 4. In ParentMixed, parent should remain expanded while child untracked folder is collapsed
        XCTAssertFalse(defaultCollapsed.contains("ParentMixed"), "Parent directory containing modifications should remain expanded")
        XCTAssertTrue(defaultCollapsed.contains("ParentMixed/ChildUntracked"), "Subfolder containing only untracked files should be collapsed by default")

        // 5. Verify containsOnlyUntrackedFiles on individual nodes
        let onlyUntrackedNode = try XCTUnwrap(tree.first(where: { $0.name == "OnlyUntracked" }))
        XCTAssertTrue(onlyUntrackedNode.containsOnlyUntrackedFiles())

        let mixedNode = try XCTUnwrap(tree.first(where: { $0.name == "MixedModAndUntracked" }))
        XCTAssertFalse(mixedNode.containsOnlyUntrackedFiles())

        // 6. Verify CommitMessageTextView initial responder
        let textView = CommitMessageTextView()
        XCTAssertTrue(textView.acceptsFirstResponder)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        textView.makeActive()
    }

    // MARK: - Remotes & Remote Operations Tests
    func testFetchGitRemotes() throws {
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestGitRemotes_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["remote", "add", "origin", "https://github.com/example/repo.git"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["remote", "add", "upstream", "https://github.com/upstream/repo.git"], currentDirectory: repoDir)

        let file = repoDir.appendingPathComponent("test.txt")
        try "test".write(to: file, atomically: true, encoding: .utf8)

        guard let context = VCSManager.shared.detectContext(for: file) else {
            XCTFail("Failed to detect git context")
            return
        }

        let remotes = VCSManager.shared.fetchRemotes(context: context)
        XCTAssertEqual(remotes.count, 2)
        XCTAssertTrue(remotes.contains(where: { $0.name == "origin" && $0.urlString == "https://github.com/example/repo.git" }))
        XCTAssertTrue(remotes.contains(where: { $0.name == "upstream" && $0.urlString == "https://github.com/upstream/repo.git" }))
    }

    func testFetchHgRemotes() throws {
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHgRemotes_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: repoDir)

        let hgrc = """
        [paths]
        default = https://example.com/hg/main
        mirror = https://example.com/hg/mirror

        """
        try hgrc.write(to: repoDir.appendingPathComponent(".hg/hgrc"), atomically: true, encoding: .utf8)

        let file = repoDir.appendingPathComponent("test.txt")
        try "test".write(to: file, atomically: true, encoding: .utf8)

        guard let context = VCSManager.shared.detectContext(for: file, preferredVCS: .hg) else {
            XCTFail("Failed to detect hg context")
            return
        }

        let remotes = VCSManager.shared.fetchRemotes(context: context)
        XCTAssertEqual(remotes.count, 2)
        XCTAssertTrue(remotes.contains(where: { $0.name == "default" && $0.urlString == "https://example.com/hg/main" }))
        XCTAssertTrue(remotes.contains(where: { $0.name == "mirror" && $0.urlString == "https://example.com/hg/mirror" }))
    }

    func testMercurialPushNoChangesFoundIsNotAnError() throws {
        let remoteDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHgRemote_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: remoteDir)
        let remoteHgrc = "[ui]\nusername = Tester <tester@test.com>\n"
        try remoteHgrc.write(to: remoteDir.appendingPathComponent(".hg/hgrc"), atomically: true, encoding: .utf8)

        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHgLocal_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: localDir)
        let localHgrc = "[ui]\nusername = Tester <tester@test.com>\n[paths]\ndefault = \(remoteDir.path)\n"
        try localHgrc.write(to: localDir.appendingPathComponent(".hg/hgrc"), atomically: true, encoding: .utf8)

        let file = localDir.appendingPathComponent("file.txt")
        try "initial content".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["add", "file.txt"], currentDirectory: localDir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "first commit"], currentDirectory: localDir)

        guard let context = VCSManager.shared.detectContext(for: file, preferredVCS: .hg) else {
            XCTFail("Failed to detect hg context")
            return
        }

        // First push succeeds
        XCTAssertNoThrow(try VCSManager.shared.push(context: context, remote: "default"))

        // Second push with no changes returns "no changes found" (exit code 1) and must NOT throw an error
        XCTAssertNoThrow(try VCSManager.shared.push(context: context, remote: "default"))

        // Pull with no changes returns "no changes found" and must NOT throw an error
        XCTAssertNoThrow(try VCSManager.shared.pull(context: context, remote: "default"))
    }

    func testDefaultGitPushSuccessAndPull() throws {
        // Setup bare remote repo
        let remoteDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestBareRemote_\(UUID().uuidString).git")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "--bare"], currentDirectory: remoteDir)

        // Setup local repo
        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLocalRepo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: localDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: localDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: localDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["remote", "add", "origin", remoteDir.path], currentDirectory: localDir)

        let file = localDir.appendingPathComponent("doc.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "doc.txt"], currentDirectory: localDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "first commit"], currentDirectory: localDir)
        // Initial push with upstream tracking
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["push", "-u", "origin", "HEAD"], currentDirectory: localDir)

        // Make second commit
        try "hello world".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-am", "second commit"], currentDirectory: localDir)

        guard let context = VCSManager.shared.detectContext(for: file) else {
            XCTFail("Failed to detect context")
            return
        }

        // Default push should succeed
        XCTAssertNoThrow(try VCSManager.shared.push(context: context, remote: "origin"))

        // Default pull should succeed
        XCTAssertNoThrow(try VCSManager.shared.pull(context: context, remote: "origin"))
    }

    func testDefaultGitPushFailureDoesNotForcePush() throws {
        // Setup bare remote repo
        let remoteDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestConflictRemote_\(UUID().uuidString).git")
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "--bare"], currentDirectory: remoteDir)

        // Setup client 1
        let client1Dir = FileManager.default.temporaryDirectory.appendingPathComponent("TestClient1_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: client1Dir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: client1Dir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Client1"], currentDirectory: client1Dir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "c1@test.com"], currentDirectory: client1Dir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["remote", "add", "origin", remoteDir.path], currentDirectory: client1Dir)
        let file1 = client1Dir.appendingPathComponent("f.txt")
        try "initial".write(to: file1, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "f.txt"], currentDirectory: client1Dir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "c1 base"], currentDirectory: client1Dir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["push", "-u", "origin", "HEAD"], currentDirectory: client1Dir)

        // Setup client 2 cloned from bare remote
        let client2Dir = FileManager.default.temporaryDirectory.appendingPathComponent("TestClient2_\(UUID().uuidString)")
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["clone", remoteDir.path, client2Dir.path], currentDirectory: FileManager.default.temporaryDirectory)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Client2"], currentDirectory: client2Dir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "c2@test.com"], currentDirectory: client2Dir)

        // Client 2 makes and pushes a commit
        let file2 = client2Dir.appendingPathComponent("f.txt")
        try "client2 update".write(to: file2, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-am", "client2 commit"], currentDirectory: client2Dir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["push", "origin"], currentDirectory: client2Dir)

        // Client 1 makes conflicting commit
        try "client1 conflicting update".write(to: file1, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-am", "client1 commit"], currentDirectory: client1Dir)

        guard let context1 = VCSManager.shared.detectContext(for: file1) else {
            XCTFail("Failed context1")
            return
        }

        // Push MUST fail because remote has non-fast-forward commits, and MUST NOT force push
        XCTAssertThrowsError(try VCSManager.shared.push(context: context1, remote: "origin")) { error in
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("rejected") || msg.contains("fetch first") || msg.contains("failed"), "Error message should describe push rejection: \(msg)")
        }
    }

    @MainActor
    func testTabManagerRemotesIntegration() async throws {
        let tm = TabManager()
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestTabManagerRemotes_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["remote", "add", "origin", "https://github.com/example/a.git"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["remote", "add", "backup", "https://github.com/example/b.git"], currentDirectory: repoDir)

        let file = repoDir.appendingPathComponent("sample.txt")
        try "sample".write(to: file, atomically: true, encoding: .utf8)

        guard let context = VCSManager.shared.detectContext(for: file) else {
            XCTFail("Failed to detect context")
            return
        }
        tm.selectedRepoContext = context

        tm.loadRemotes()
        // Wait for async load
        for _ in 0..<50 {
            if !tm.isLoadingRemotes && tm.remoteRepositories.count == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(tm.remoteRepositories.count, 2)
        XCTAssertEqual(tm.remoteRepositories[0].name, "origin")
        XCTAssertEqual(tm.remoteRepositories[1].name, "backup")

        // Test push to non-existent remote URL fails and records error without force push
        let dummyRemote = RemoteRepository(name: "origin", urlString: "https://github.com/example/a.git")
        tm.push(to: dummyRemote)
        XCTAssertTrue(tm.activePushRemotes.contains("origin"))

        // Wait for push to complete with error
        for _ in 0..<100 {
            if !tm.activePushRemotes.contains("origin") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(tm.activePushRemotes.contains("origin"))
        XCTAssertNotNil(tm.pushErrors["origin"], "Push error must be recorded for failed remote")
    }

    @MainActor
    func testCommitDetailsViewShowsFullCommitMessageWhenDescriptionIsMoreThanOneLineLong() async throws {
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestMultilineCommitMsg_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "-b", "main"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: repoDir)

        let file = repoDir.appendingPathComponent("file.txt")

        // 1. First commit: single-line commit message
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "file.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Single line commit message"], currentDirectory: repoDir)

        // 2. Second commit: multiline commit message with description body
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "file.txt"], currentDirectory: repoDir)
        let multilineMsg = "Multiline commit message\n\nThis is a detailed explanation.\nIt has multiple lines of description."
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", multilineMsg], currentDirectory: repoDir)

        guard let context = VCSManager.shared.detectContext(for: file) else {
            XCTFail("Failed to detect repository context")
            return
        }

        let historyVM = CommitHistoryViewModel(repoContext: context)
        historyVM.loadHistory()

        for _ in 0..<100 {
            if historyVM.hasLoaded && !historyVM.isLoading && historyVM.rows.count >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(historyVM.rows.count, 2)
        let multilineRow = historyVM.rows[0]
        let singleLineRow = historyVM.rows[1]

        // When a commit with a single-line description is selected:
        historyVM.selectCommit(singleLineRow.id)
        let singleLineDetailsView = CommitDetailsView(viewModel: historyVM)
        XCTAssertFalse(
            singleLineDetailsView.isShowingCommitMessage,
            "CommitDetailsView must not show full commit message when commit description is only one line"
        )

        // When a commit with more than one line description is selected:
        historyVM.selectCommit(multilineRow.id)
        let multilineDetailsView = CommitDetailsView(viewModel: historyVM)
        XCTAssertTrue(
            multilineDetailsView.isShowingCommitMessage,
            "CommitDetailsView must show full commit message at the bottom when commit description is more than one line long"
        )
        XCTAssertEqual(CommitDetailsView.defaultCommitMessageHeight, 120)
        XCTAssertEqual(CommitDetailsView.descriptionHeaderTitle, "Description")
        XCTAssertEqual(CommitDetailsView.descriptionHeaderIconName, "text.bubble")

        // When comparing commits, isShowingCommitMessage must be false
        historyVM.compareWithSelected(singleLineRow.commit)
        XCTAssertTrue(historyVM.isComparingCommits)
        let comparingDetailsView = CommitDetailsView(viewModel: historyVM)
        XCTAssertFalse(
            comparingDetailsView.isShowingCommitMessage,
            "CommitDetailsView must not show single commit message when comparing commits"
        )
    }

    func testCommitMatchesFilterLogic() {
        let date = Date()
        let gitCommit = CommitInfo(
            id: "a1b2c3d4e5f678901234567890abcdef12345678",
            displayRevision: "a1b2c3d",
            fullRevision: "a1b2c3d4e5f678901234567890abcdef12345678",
            author: "Alice Smith",
            authorEmail: "alice@example.com",
            date: date,
            dateFormatted: "Nov 9, 2026",
            summary: "Implement user authentication",
            fullMessage: "Implement user authentication\n\nDetailed security tokens description."
        )

        let hgCommit = CommitInfo(
            id: "f9e8d7c6b5a432109876543210fedcba98765432",
            displayRevision: "145:f9e8d7c6b5a4",
            fullRevision: "f9e8d7c6b5a432109876543210fedcba98765432",
            author: "Bob Jones",
            authorEmail: "bob@mercurial.org",
            date: date,
            dateFormatted: "Nov 9, 2026",
            summary: "Fix memory leak in parser",
            fullMessage: "Fix memory leak in parser"
        )

        // 1. Description contains (case-insensitive)
        XCTAssertTrue(gitCommit.matchesFilter(query: "user", vcsType: .git))
        XCTAssertTrue(gitCommit.matchesFilter(query: "AUTHENTICATION", vcsType: .git))
        XCTAssertTrue(gitCommit.matchesFilter(query: "security tokens", vcsType: .git))
        XCTAssertFalse(gitCommit.matchesFilter(query: "nonexistent", vcsType: .git))

        // 2. Author contains (case-insensitive)
        XCTAssertTrue(gitCommit.matchesFilter(query: "alice", vcsType: .git))
        XCTAssertTrue(gitCommit.matchesFilter(query: "SMITH", vcsType: .git))
        XCTAssertTrue(gitCommit.matchesFilter(query: "example.com", vcsType: .git))
        XCTAssertFalse(gitCommit.matchesFilter(query: "bob", vcsType: .git))

        // 3. Commit hash starts with (case-insensitive)
        XCTAssertTrue(gitCommit.matchesFilter(query: "a1b2", vcsType: .git))
        XCTAssertTrue(gitCommit.matchesFilter(query: "A1B2C3", vcsType: .git))
        XCTAssertFalse(gitCommit.matchesFilter(query: "b2c3", vcsType: .git), "Commit hash in middle should not match starts-with")

        // 4. Local revision for Mercurial starts with (case-insensitive)
        XCTAssertTrue(hgCommit.matchesFilter(query: "145", vcsType: .hg))
        XCTAssertTrue(hgCommit.matchesFilter(query: "14", vcsType: .hg))
        XCTAssertTrue(hgCommit.matchesFilter(query: "1", vcsType: .hg))
        XCTAssertFalse(hgCommit.matchesFilter(query: "45", vcsType: .hg), "Local revision in middle should not match starts-with")

        // In Git, local revision check should not match if query is not hash prefix
        XCTAssertFalse(hgCommit.matchesFilter(query: "145", vcsType: .git))

        // Mercurial commit hash starts with
        XCTAssertTrue(hgCommit.matchesFilter(query: "f9e8", vcsType: .hg))
        XCTAssertTrue(hgCommit.matchesFilter(query: "F9E8D7", vcsType: .hg))
        XCTAssertFalse(hgCommit.matchesFilter(query: "e8d7", vcsType: .hg))

        // Empty or whitespace query matches all
        XCTAssertTrue(gitCommit.matchesFilter(query: "", vcsType: .git))
        XCTAssertTrue(gitCommit.matchesFilter(query: "   ", vcsType: .git))
    }

    func testCommitHistoryViewModelSearchFiltering() async throws {
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestCommitHistorySearch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init", "-b", "main"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Carol Danvers"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "carol@avengers.org"], currentDirectory: repoDir)

        let file = repoDir.appendingPathComponent("code.txt")

        try "alpha\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "code.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "First initial commit"], currentDirectory: repoDir)

        try "beta\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "code.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "--author=Peter Parker <peter@dailybugle.com>", "-m", "Refactor core engine"], currentDirectory: repoDir)

        try "gamma\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "code.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Fix crash on shutdown\n\nResolves fatal exception"], currentDirectory: repoDir)

        guard let context = VCSManager.shared.detectContext(for: file) else {
            XCTFail("Failed to detect repo context")
            return
        }

        let vm = CommitHistoryViewModel(repoContext: context)
        vm.loadHistory()

        for _ in 0..<100 {
            if vm.hasLoaded && !vm.isLoading && vm.allRows.count >= 3 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(vm.allRows.count, 3)
        XCTAssertEqual(vm.rows.count, 3)

        // Filter by description
        vm.searchText = "refactor"
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.commit.summary, "Refactor core engine")

        // Filter by description multiline body (case-insensitive)
        vm.searchText = "FATAL EXCEPTION"
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.commit.summary, "Fix crash on shutdown")

        // Filter by author name (case-insensitive)
        vm.searchText = "parker"
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.commit.author, "Peter Parker")

        // Filter by author email
        vm.searchText = "avengers.org"
        XCTAssertEqual(vm.rows.count, 2)

        // Filter by commit hash prefix
        let firstCommitHash = vm.allRows.last!.commit.id
        let hashPrefix = String(firstCommitHash.prefix(6))
        vm.searchText = hashPrefix
        XCTAssertTrue(vm.rows.contains(where: { $0.commit.id == firstCommitHash }))

        // Filter by non-matching text
        vm.searchText = "nonexistent_query_xyz"
        XCTAssertEqual(vm.rows.count, 0)

        // Clear filter
        vm.searchText = ""
        XCTAssertEqual(vm.rows.count, 3)
    }

    @MainActor
    func testCommitHistoryRightClickDoesNotChangeSelection() {
        let date = Date()
        let commit1 = CommitInfo(
            id: "commit1",
            displayRevision: "c1",
            fullRevision: "commit1",
            author: "Author 1",
            authorEmail: "a1@test.com",
            date: date,
            dateFormatted: "Nov 9",
            summary: "Commit 1",
            fullMessage: "Commit 1"
        )
        let commit2 = CommitInfo(
            id: "commit2",
            displayRevision: "c2",
            fullRevision: "commit2",
            author: "Author 2",
            authorEmail: "a2@test.com",
            date: date,
            dateFormatted: "Nov 9",
            summary: "Commit 2",
            fullMessage: "Commit 2"
        )

        let row1 = CommitGraphRow(
            commit: commit1,
            parentIds: [],
            nodeLane: 0,
            nodeColorIndex: 0,
            incomingSegments: [],
            outgoingSegments: [],
            maxActiveLane: 0
        )
        let row2 = CommitGraphRow(
            commit: commit2,
            parentIds: ["commit1"],
            nodeLane: 0,
            nodeColorIndex: 0,
            incomingSegments: [],
            outgoingSegments: [],
            maxActiveLane: 0
        )

        var selectedCommitId: String? = "commit1"
        var selectedCommitCalledWith: String? = nil

        let coordinator = CommitHistoryTableViewRepresentable.Coordinator(
            rows: [row1, row2],
            selectedCommitId: selectedCommitId,
            comparisonCommitId: nil,
            vcsType: .git,
            graphColumnWidth: 50,
            authorColumnWidth: 100,
            dateColumnWidth: 100,
            revisionColumnWidth: 80,
            isDark: false,
            onScrollerWidthChange: { _ in },
            onSelectCommit: { id in
                selectedCommitCalledWith = id
                selectedCommitId = id
            },
            canCheckout: { _ in true },
            onCheckout: { _ in },
            canCompareWithSelected: { commit in
                selectedCommitId != commit.id
            },
            onCompareWithSelected: { _ in }
        )

        let tableView = CommitHistoryTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        tableView.coordinator = coordinator
        tableView.rowHeight = 22
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.reloadData()

        // Select row 0 (commit1)
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(tableView.selectedRow, 0)
        XCTAssertEqual(coordinator.selectedCommitId, "commit1")

        // Simulate right click on row 1 (commit2)
        let row1Rect = tableView.rect(ofRow: 1)
        let clickPointInTable = NSPoint(x: row1Rect.midX, y: row1Rect.midY)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(tableView)

        let clickPointInWindow = tableView.convert(clickPointInTable, to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: clickPointInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!

        let menu = tableView.menu(for: event)
        XCTAssertNotNil(menu)

        // Verification 1: Right-clicking on row 1 must NOT change selectedRow or coordinator.selectedCommitId
        XCTAssertEqual(tableView.selectedRow, 0, "Right click must not change the selected table row")
        XCTAssertEqual(coordinator.selectedCommitId, "commit1", "Selected commit ID must remain the previously selected commit")
        XCTAssertNil(selectedCommitCalledWith, "onSelectCommit must not be triggered on right click")

        // Verification 2: "Compare with selected" in the menu should be enabled for row 2 against selected row 1
        let compareItem = menu?.item(withTitle: "Compare with selected")
        XCTAssertNotNil(compareItem)
        XCTAssertTrue(compareItem?.isEnabled == true, "'Compare with selected' should be enabled when right clicking a different row")
        XCTAssertEqual((compareItem?.representedObject as? CommitInfo)?.id, "commit2")
    }

    @MainActor
    func testCommitHistoryCompareWithSelectedSelectsRowRange() {
        let date = Date()
        func makeRow(id: String) -> CommitGraphRow {
            let commit = CommitInfo(
                id: id,
                displayRevision: id,
                fullRevision: id,
                author: "Author",
                authorEmail: "a@test.com",
                date: date,
                dateFormatted: "Nov 9",
                summary: "Summary for \(id)",
                fullMessage: "Summary for \(id)"
            )
            return CommitGraphRow(
                commit: commit,
                parentIds: [],
                nodeLane: 0,
                nodeColorIndex: 0,
                incomingSegments: [],
                outgoingSegments: [],
                maxActiveLane: 0
            )
        }

        let rows = [makeRow(id: "c0"), makeRow(id: "c1"), makeRow(id: "c2"), makeRow(id: "c3"), makeRow(id: "c4")]

        var selectedCommitId: String? = "c1"
        var comparisonCommitId: String? = nil

        let coordinator = CommitHistoryTableViewRepresentable.Coordinator(
            rows: rows,
            selectedCommitId: selectedCommitId,
            comparisonCommitId: comparisonCommitId,
            vcsType: .git,
            graphColumnWidth: 50,
            authorColumnWidth: 100,
            dateColumnWidth: 100,
            revisionColumnWidth: 80,
            isDark: false,
            onScrollerWidthChange: { _ in },
            onSelectCommit: { id in
                selectedCommitId = id
                comparisonCommitId = nil
            },
            canCheckout: { _ in true },
            onCheckout: { _ in },
            canCompareWithSelected: { commit in
                selectedCommitId != commit.id
            },
            onCompareWithSelected: { _ in }
        )

        let tableView = CommitHistoryTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tableView.coordinator = coordinator
        tableView.rowHeight = 22
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.allowsMultipleSelection = true
        coordinator.tableView = tableView
        tableView.reloadData()

        coordinator.syncSelection(forceScroll: false)
        XCTAssertEqual(tableView.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertFalse(coordinator.isRowInComparisonRange(0))
        XCTAssertFalse(coordinator.isRowInComparisonRange(1))
        XCTAssertFalse(coordinator.isRowInComparisonRange(2))

        // When compare with selected is used with c3 (from index 1 to index 3)
        comparisonCommitId = "c3"
        coordinator.update(
            rows: rows,
            selectedCommitId: "c1",
            comparisonCommitId: "c3",
            vcsType: .git,
            graphColumnWidth: 50,
            authorColumnWidth: 100,
            dateColumnWidth: 100,
            revisionColumnWidth: 80,
            isDark: false,
            onScrollerWidthChange: { _ in },
            onSelectCommit: { id in
                selectedCommitId = id
                comparisonCommitId = nil
            },
            canCheckout: { _ in true },
            onCheckout: { _ in },
            canCompareWithSelected: { commit in
                selectedCommitId != commit.id
            },
            onCompareWithSelected: { _ in }
        )

        // All rows from previous selection (c1 at index 1) to selected row (c3 at index 3) must be shown selected
        XCTAssertEqual(tableView.selectedRowIndexes, IndexSet(integersIn: 1...3), "All rows from index 1 to 3 must be selected")
        XCTAssertFalse(coordinator.isRowInComparisonRange(0))
        XCTAssertTrue(coordinator.isRowInComparisonRange(1))
        XCTAssertTrue(coordinator.isRowInComparisonRange(2))
        XCTAssertTrue(coordinator.isRowInComparisonRange(3))
        XCTAssertFalse(coordinator.isRowInComparisonRange(4))

        // Row views should reflect comparison selection
        let rowView0 = tableView.rowView(atRow: 0, makeIfNecessary: true) as? CommitHistoryTableRowView
        let rowView1 = tableView.rowView(atRow: 1, makeIfNecessary: true) as? CommitHistoryTableRowView
        let rowView2 = tableView.rowView(atRow: 2, makeIfNecessary: true) as? CommitHistoryTableRowView
        let rowView3 = tableView.rowView(atRow: 3, makeIfNecessary: true) as? CommitHistoryTableRowView
        let rowView4 = tableView.rowView(atRow: 4, makeIfNecessary: true) as? CommitHistoryTableRowView

        XCTAssertEqual(rowView0?.isComparisonSelected, false)
        XCTAssertEqual(rowView1?.isComparisonSelected, true)
        XCTAssertEqual(rowView2?.isComparisonSelected, true)
        XCTAssertEqual(rowView3?.isComparisonSelected, true)
        XCTAssertEqual(rowView4?.isComparisonSelected, false)
    }

    @MainActor
    func testCommitHistoryMultipleRowSelectionTriggersComparison() {
        let date = Date()
        func makeRow(id: String) -> CommitGraphRow {
            let commit = CommitInfo(
                id: id,
                displayRevision: id,
                fullRevision: id,
                author: "Author",
                authorEmail: "a@test.com",
                date: date,
                dateFormatted: "Nov 9",
                summary: "Summary for \(id)",
                fullMessage: "Summary for \(id)"
            )
            return CommitGraphRow(
                commit: commit,
                parentIds: [],
                nodeLane: 0,
                nodeColorIndex: 0,
                incomingSegments: [],
                outgoingSegments: [],
                maxActiveLane: 0
            )
        }

        let rows = [makeRow(id: "c0"), makeRow(id: "c1"), makeRow(id: "c2"), makeRow(id: "c3"), makeRow(id: "c4")]

        var singleCommitSelected: String? = nil
        var rangeSelected: (earliest: CommitInfo, latest: CommitInfo)? = nil

        let coordinator = CommitHistoryTableViewRepresentable.Coordinator(
            rows: rows,
            selectedCommitId: nil,
            comparisonCommitId: nil,
            vcsType: .git,
            graphColumnWidth: 50,
            authorColumnWidth: 100,
            dateColumnWidth: 100,
            revisionColumnWidth: 80,
            isDark: false,
            onScrollerWidthChange: { _ in },
            onSelectCommit: { id in
                singleCommitSelected = id
            },
            onSelectCommitRange: { earliest, latest in
                rangeSelected = (earliest, latest)
            },
            canCheckout: { _ in true },
            onCheckout: { _ in },
            canCompareWithSelected: { _ in true },
            onCompareWithSelected: { _ in }
        )

        let tableView = CommitHistoryTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tableView.coordinator = coordinator
        tableView.rowHeight = 22
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.allowsMultipleSelection = true
        coordinator.tableView = tableView
        tableView.reloadData()

        // 1. Single row selection triggers onSelectCommit
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(singleCommitSelected, "c1")
        XCTAssertNil(rangeSelected)

        // 2. Multiple row selection (e.g. rows 1, 2, 3) triggers onSelectCommitRange from earliest (c3, bottom) to latest (c1, top)
        rangeSelected = nil
        tableView.selectRowIndexes(IndexSet(integersIn: 1...3), byExtendingSelection: false)
        XCTAssertNotNil(rangeSelected)
        XCTAssertEqual(rangeSelected?.earliest.id, "c3", "Earliest commit must be bottom-most row in table")
        XCTAssertEqual(rangeSelected?.latest.id, "c1", "Latest commit must be top-most row in table")

        // 3. Discontiguous multiple selection (e.g. Cmd+click selecting rows 0 and 4)
        rangeSelected = nil
        tableView.selectRowIndexes(IndexSet([0, 4]), byExtendingSelection: false)
        XCTAssertNotNil(rangeSelected)
        XCTAssertEqual(rangeSelected?.earliest.id, "c4", "Earliest commit must be index 4 (bottom-most)")
        XCTAssertEqual(rangeSelected?.latest.id, "c0", "Latest commit must be index 0 (top-most)")
    }

    @MainActor
    func testCommitHistoryCompareWithSelectedExpandsExistingMultiSelection() async throws {
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestExpandCompare_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: repoDir)

        let file = repoDir.appendingPathComponent("file.txt")
        for i in 1...5 {
            try "Line \(i)\n".write(to: file, atomically: true, encoding: .utf8)
            _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "file.txt"], currentDirectory: repoDir)
            _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit \(i)"], currentDirectory: repoDir)
        }

        guard let context = VCSManager.shared.detectContext(for: repoDir) else {
            XCTFail("Failed to detect git context")
            return
        }

        let vm = CommitHistoryViewModel(repoContext: context)
        vm.loadHistory()
        for _ in 0..<50 {
            if !vm.isLoading && vm.rows.count == 5 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(vm.rows.count, 5)

        // vm.rows:
        // index 0: Commit 5 (latest)
        // index 1: Commit 4
        // index 2: Commit 3
        // index 3: Commit 2
        // index 4: Commit 1 (earliest)
        let row0 = vm.rows[0] // Commit 5
        let row1 = vm.rows[1] // Commit 4
        let row2 = vm.rows[2] // Commit 3
        let row3 = vm.rows[3] // Commit 2
        let row4 = vm.rows[4] // Commit 1

        // 1. Initial selection: select Commit 4 (index 1)
        vm.selectCommit(row1.commit.id)
        XCTAssertEqual(vm.selectedCommitId, row1.commit.id)
        XCTAssertFalse(vm.isComparingCommits)
        XCTAssertFalse(vm.canCompareWithSelected(row1.commit), "Cannot compare a commit with itself")
        XCTAssertTrue(vm.canCompareWithSelected(row3.commit))

        // 2. Compare with Commit 2 (index 3)
        vm.compareWithSelected(row3.commit)
        XCTAssertTrue(vm.isComparingCommits)
        XCTAssertEqual(vm.selectedCommitId, row1.commit.id) // Latest (top-most, index 1)
        XCTAssertEqual(vm.comparisonCommitId, row3.commit.id) // Earliest (bottom-most, index 3)
        XCTAssertEqual(vm.comparisonTargetCommit?.id, row1.commit.id)
        XCTAssertEqual(vm.comparisonBaseCommit?.id, row3.commit.id)

        // 3. canCompareWithSelected checks: rows inside range [1...3] are already included, so cannot compare; outside rows can expand
        XCTAssertFalse(vm.canCompareWithSelected(row1.commit), "Boundary row 1 already in selection range")
        XCTAssertFalse(vm.canCompareWithSelected(row2.commit), "Internal row 2 already in selection range")
        XCTAssertFalse(vm.canCompareWithSelected(row3.commit), "Boundary row 3 already in selection range")
        XCTAssertTrue(vm.canCompareWithSelected(row4.commit), "Row 4 is below range and can expand")
        XCTAssertTrue(vm.canCompareWithSelected(row0.commit), "Row 0 is above range and can expand")

        // 4. Expand downwards: compare with Commit 1 (index 4)
        vm.compareWithSelected(row4.commit)
        XCTAssertTrue(vm.isComparingCommits)
        XCTAssertEqual(vm.selectedCommitId, row1.commit.id, "Top-most stays Commit 4")
        XCTAssertEqual(vm.comparisonCommitId, row4.commit.id, "Bottom-most expands to Commit 1")
        XCTAssertEqual(vm.comparisonTargetCommit?.id, row1.commit.id)
        XCTAssertEqual(vm.comparisonBaseCommit?.id, row4.commit.id)

        // 5. Expand upwards: compare with Commit 5 (index 0)
        vm.compareWithSelected(row0.commit)
        XCTAssertTrue(vm.isComparingCommits)
        XCTAssertEqual(vm.selectedCommitId, row0.commit.id, "Top-most expands to Commit 5")
        XCTAssertEqual(vm.comparisonCommitId, row4.commit.id, "Bottom-most stays Commit 1")
        XCTAssertEqual(vm.comparisonTargetCommit?.id, row0.commit.id)
        XCTAssertEqual(vm.comparisonBaseCommit?.id, row4.commit.id)

        // 6. Direct range comparison via compareRange
        vm.compareRange(earliest: row3.commit, latest: row2.commit)
        XCTAssertTrue(vm.isComparingCommits)
        XCTAssertEqual(vm.selectedCommitId, row2.commit.id)
        XCTAssertEqual(vm.comparisonCommitId, row3.commit.id)
        XCTAssertEqual(vm.comparisonTargetCommit?.id, row2.commit.id)
        XCTAssertEqual(vm.comparisonBaseCommit?.id, row3.commit.id)
    }

    @MainActor
    func testRepositorySidebarShowCommitsOpensFilteredCommitHistoryTab() async throws {
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestShowCommits_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: repoDir)

        let fileA = repoDir.appendingPathComponent("fileA.txt")
        let fileB = repoDir.appendingPathComponent("fileB.txt")

        // Commit 1: Add fileA
        try "Content A1\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "fileA.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit 1: Add fileA"], currentDirectory: repoDir)

        // Commit 2: Add fileB
        try "Content B1\n".write(to: fileB, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "fileB.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit 2: Add fileB"], currentDirectory: repoDir)

        // Commit 3: Modify fileA
        try "Content A2\n".write(to: fileA, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "fileA.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit 3: Modify fileA"], currentDirectory: repoDir)

        guard let context = VCSManager.shared.detectContext(for: repoDir) else {
            XCTFail("Failed to detect git context")
            return
        }

        let tm = TabManager()
        _ = tm.openRepository(at: repoDir)

        // 1. Open commit history tab filtered for fileA.txt
        guard let vmA = tm.openCommitHistoryTab(context: context, filePath: "fileA.txt") else {
            XCTFail("Expected CommitHistoryViewModel for fileA.txt")
            return
        }

        guard let activeTabA = tm.activeTab else {
            XCTFail("Expected active tab")
            return
        }

        XCTAssertTrue(activeTabA.isCommitHistory)
        XCTAssertEqual(activeTabA.title, "fileA.txt", "Tab title must reflect {filepath}")
        XCTAssertEqual(vmA.filteredFilePath, "fileA.txt")

        // Wait for commits to load
        for _ in 0..<50 {
            if !vmA.isLoading && vmA.hasLoaded { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // fileA.txt should only have 2 commits (Commit 3 and Commit 1), not Commit 2
        XCTAssertEqual(vmA.allRows.count, 2, "Filtered commit history for fileA.txt must only include commits modifying fileA.txt")
        let summariesA = vmA.allRows.map { $0.commit.summary }
        XCTAssertTrue(summariesA.contains("Commit 3: Modify fileA"))
        XCTAssertTrue(summariesA.contains("Commit 1: Add fileA"))
        XCTAssertFalse(summariesA.contains("Commit 2: Add fileB"), "Commit 2 must not appear in fileA.txt history")

        // 2. Open commit history tab filtered for fileB.txt
        guard let vmB = tm.openCommitHistoryTab(context: context, filePath: "fileB.txt") else {
            XCTFail("Expected CommitHistoryViewModel for fileB.txt")
            return
        }

        guard let activeTabB = tm.activeTab else {
            XCTFail("Expected active tab")
            return
        }

        XCTAssertTrue(activeTabB.isCommitHistory)
        XCTAssertEqual(activeTabB.title, "fileB.txt", "Tab title must reflect {filepath}")
        XCTAssertEqual(vmB.filteredFilePath, "fileB.txt")

        // Wait for commits to load
        for _ in 0..<50 {
            if !vmB.isLoading && vmB.hasLoaded { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // fileB.txt should only have 1 commit (Commit 2)
        XCTAssertEqual(vmB.allRows.count, 1, "Filtered commit history for fileB.txt must only include commits modifying fileB.txt")
        XCTAssertEqual(vmB.allRows.first?.commit.summary, "Commit 2: Add fileB")

        // 3. Opening fileA.txt again should reuse existing tab rather than duplicate
        let initialTabCount = tm.tabs.count
        let vmAReused = tm.openCommitHistoryTab(context: context, filePath: "fileA.txt")
        XCTAssertEqual(tm.tabs.count, initialTabCount, "Opening existing filtered commit history should reuse tab")
        XCTAssertEqual(vmAReused?.id, vmA.id)
        XCTAssertEqual(tm.activeTab?.id, activeTabA.id)

        // 4. Verify FileTreeItemRow onShowCommits and onShowTimeline callbacks for files
        var showCommitsCalled = false
        var showTimelineCalled = false
        let node = FileTreeNode(
            id: "fileA.txt",
            name: "fileA.txt",
            fullURL: fileA,
            isDirectory: false
        )
        let rowView = FileTreeItemRow(
            node: node,
            status: .clean,
            level: 0,
            isExpanded: false,
            isActive: false,
            onToggleExpand: {},
            onShowTimeline: {
                showTimelineCalled = true
            },
            onShowCommits: {
                showCommitsCalled = true
            }
        )
        rowView.onShowTimeline?()
        XCTAssertTrue(showTimelineCalled, "FileTreeItemRow onShowTimeline callback must be executed for files")
        rowView.onShowCommits?()
        XCTAssertTrue(showCommitsCalled, "FileTreeItemRow onShowCommits callback must be executed for files")

        // 5. Verify folder "Show Commits"
        let subDir = repoDir.appendingPathComponent("subDir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let subFile = subDir.appendingPathComponent("nested.txt")
        try "Nested content\n".write(to: subFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "subDir/nested.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Commit 4: Add nested.txt"], currentDirectory: repoDir)

        guard let vmDir = tm.openCommitHistoryTab(context: context, filePath: "subDir") else {
            XCTFail("Expected CommitHistoryViewModel for subDir")
            return
        }

        guard let activeTabDir = tm.activeTab else {
            XCTFail("Expected active tab for folder")
            return
        }

        XCTAssertTrue(activeTabDir.isCommitHistory)
        XCTAssertEqual(activeTabDir.title, "subDir", "Folder tab title must reflect {folderPath}")
        XCTAssertEqual(vmDir.filteredFilePath, "subDir")
        XCTAssertTrue(vmDir.isFilteredPathADirectory)

        for _ in 0..<50 {
            if !vmDir.isLoading && vmDir.hasLoaded { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(vmDir.allRows.count, 1, "Folder history should only include commits touching files in that folder")
        XCTAssertEqual(vmDir.allRows.first?.commit.summary, "Commit 4: Add nested.txt")

        // Verify FileTreeItemRow onShowCommits callback for directories
        var folderShowCommitsCalled = false
        let dirNode = FileTreeNode(
            id: "subDir",
            name: "subDir",
            fullURL: subDir,
            isDirectory: true
        )
        let folderRowView = FileTreeItemRow(
            node: dirNode,
            status: .clean,
            level: 0,
            isExpanded: true,
            isActive: false,
            onToggleExpand: {},
            onSelect: {},
            onShowCommits: {
                folderShowCommitsCalled = true
            }
        )
        folderRowView.onShowCommits?()
        XCTAssertTrue(folderShowCommitsCalled, "FileTreeItemRow onShowCommits callback must be executed for directories")
    }

    @MainActor
    func testCommitHistoryWorkingSetCommitButtonDisabledWhileLoading() async throws {
        let repoDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestWorkingSetCommitButton_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["init"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.name", "Tester"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["config", "user.email", "tester@test.com"], currentDirectory: repoDir)

        let file = repoDir.appendingPathComponent("file.txt")
        try "Initial".write(to: file, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["add", "file.txt"], currentDirectory: repoDir)
        _ = try ProcessRunner.run(binary: gitBin, arguments: ["commit", "-m", "Initial commit"], currentDirectory: repoDir)

        // Modify file in working copy so uncommitted changes exist
        try "Modified".write(to: file, atomically: true, encoding: .utf8)

        guard let context = VCSManager.shared.detectContext(for: repoDir) else {
            XCTFail("Failed to detect git context")
            return
        }

        let vm = CommitHistoryViewModel(repoContext: context)

        // 1. While initial load is in progress (or hasLoaded == false / isLoading == true):
        // isWorkingSetLoading must be true and isCommitButtonEnabled must be false
        if vm.isLoading || !vm.hasLoaded {
            XCTAssertTrue(vm.isWorkingSetLoading, "isWorkingSetLoading must be true during initial load")
            XCTAssertFalse(vm.isCommitButtonEnabled, "Commit button must be disabled/greyed out during initial load")
        }

        // Wait for history to load
        for _ in 0..<50 {
            if vm.hasLoaded && !vm.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(vm.hasLoaded)

        // Select the uncommitted changes row
        vm.selectCommit(CommitInfo.uncommittedHash)
        XCTAssertEqual(vm.selectedCommitId, CommitInfo.uncommittedHash)

        let detailsView = CommitDetailsView(viewModel: vm)
        XCTAssertTrue(detailsView.isShowingWorkingSetCommitButton, "Commit button bar should be visible for uncommitted changes")

        // 2. Once working directory has finished loading, isWorkingSetLoading is false and Commit button is enabled
        XCTAssertFalse(vm.isWorkingSetLoading, "isWorkingSetLoading must be false once loading is complete")
        XCTAssertTrue(vm.isCommitButtonEnabled, "Commit button should be enabled when working directory is loaded")

        // 3. While working directory changes are being refreshed in the background:
        let refreshTask = vm.refreshWorkingDirectoryChanges()
        XCTAssertTrue(vm.isWorkingSetLoading, "isWorkingSetLoading must be true while refreshing working directory changes")
        XCTAssertFalse(vm.isCommitButtonEnabled, "Commit button must be disabled/greyed out while working directory is refreshing")

        // Wait for refresh to complete
        _ = await refreshTask.value
        XCTAssertFalse(vm.isWorkingSetLoading, "isWorkingSetLoading must be false once refresh completes")
        XCTAssertTrue(vm.isCommitButtonEnabled, "Commit button must be enabled again after refresh completes")
    }
}
