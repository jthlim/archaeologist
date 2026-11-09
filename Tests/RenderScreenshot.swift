import Foundation
import AppKit
import SwiftUI

struct WindowFrameView: View {
    let tabManager: TabManager

    var body: some View {
        VStack(spacing: 0) {
            // Window Titlebar
            ZStack {
                Color(NSColor.windowBackgroundColor)

                // Title
                HStack {
                    Spacer()
                    Text("Archaeologist")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.secondary.opacity(0.85))
                    Spacer()
                }

                // Traffic lights on left
                HStack {
                    HStack(spacing: 7.5) {
                        Circle().fill(Color(red: 1.0, green: 0.36, blue: 0.34)).frame(width: 12, height: 12)
                        Circle().fill(Color(red: 1.0, green: 0.76, blue: 0.20)).frame(width: 12, height: 12)
                        Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.28)).frame(width: 12, height: 12)
                    }
                    .padding(.leading, 12)

                    Spacer()
                }
            }
            .frame(height: 36)
            .overlay(Divider(), alignment: .bottom)

            ContentView(tabManager: tabManager)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

@MainActor
@main
struct RenderScreenshotMain {
    static func main() async {
        print("Starting screenshot generator...")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        do {
            let (_, gitFiles) = try SampleRepoService.shared.setupSampleGitRepo()
            let swiftFile = gitFiles[0]

            let (_, hgFiles) = try SampleRepoService.shared.setupSampleHgRepo()
            let pyFile = hgFiles[0]

            let tabManager = TabManager()
            tabManager.openInTab(url: swiftFile, preferredVCS: .git)
            tabManager.openInTab(url: pyFile, preferredVCS: .hg)
            // Switch back to the first tab (Calculator.swift)
            if let firstTab = tabManager.tabs.first {
                tabManager.selectTab(id: firstTab.id)
            }

            guard let activeVM = tabManager.activeViewModel else {
                fatalError("No active view model")
            }

            // Wait for commits to load
            var waitCount = 0
            while activeVM.isLoading && waitCount < 50 {
                try await Task.sleep(nanoseconds: 100_000_000)
                waitCount += 1
            }

            print("Loaded commits: \(activeVM.commits.count)")
            if activeVM.commits.count >= 3 {
                // Select commit index 2 (Commit 3: Add power and square root, which has deletions and additions)
                activeVM.selectedCommitIndex = 2
            } else if activeVM.commits.count >= 2 {
                activeVM.selectedCommitIndex = 1
            }

            // Wait for content to finish loading
            waitCount = 0
            while (activeVM.isContentLoading || activeVM.currentContent == nil) && waitCount < 50 {
                try await Task.sleep(nanoseconds: 100_000_000)
                waitCount += 1
            }
            print("Content loaded! Lines: \(activeVM.currentContent?.textLines.count ?? 0)")

            let windowWidth: CGFloat = 1100
            let windowHeight: CGFloat = 740
            let frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Archaeologist"
            window.appearance = NSAppearance(named: .darkAqua)

            let windowView = WindowFrameView(tabManager: tabManager)
                .frame(width: windowWidth, height: windowHeight)
                .preferredColorScheme(.dark)

            let hostingView = NSHostingView(rootView: windowView)
            hostingView.frame = frame
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            hostingView.layoutSubtreeIfNeeded()

            // Wait for layout and views to settle
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            hostingView.layoutSubtreeIfNeeded()

            guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                fatalError("Failed to create bitmapImageRepForCachingDisplay")
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                fatalError("Failed to generate PNG data")
            }

            let outputPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Screenshot.png")
            try pngData.write(to: outputPath)
            print("Successfully saved screenshot to \(outputPath.path)")
            exit(0)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
