import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if canImport(Archaeologist)
import Archaeologist
#endif

// MARK: - Window Frame View

private struct WindowFrameView: View {
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

// MARK: - Main Timeline Renderer

@MainActor
@main
public struct RenderTimelineMain {
    public static func main() async {
        print("Starting timeline GIF generator...")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        do {
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory
                .appendingPathComponent("Archaeologist_GIF_\(UUID().uuidString)")
                .appendingPathComponent("Git Sample")
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let git = "git"
            _ = try ProcessRunner.run(binary: git, arguments: ["init"], currentDirectory: tempDir)
            _ = try ProcessRunner.run(binary: git, arguments: ["config", "user.name", "Ada Lovelace"], currentDirectory: tempDir)
            _ = try ProcessRunner.run(binary: git, arguments: ["config", "user.email", "ada@example.com"], currentDirectory: tempDir)

            let swiftFile = tempDir.appendingPathComponent("Calculator.swift")

            // Commit 1: Initial Calculator in Swift
            let rev1 = """
            // Calculator.swift
            // Basic arithmetic calculator

            import Foundation

            public struct Calculator {
                public init() {}

                public func add(_ a: Double, _ b: Double) -> Double {
                    return a + b
                }

                public func subtract(_ a: Double, _ b: Double) -> Double {
                    return a - b
                }
            }
            """
            try rev1.write(to: swiftFile, atomically: true, encoding: .utf8)
            _ = try ProcessRunner.run(binary: git, arguments: ["add", "Calculator.swift"], currentDirectory: tempDir)
            _ = try ProcessRunner.run(binary: git, arguments: ["commit", "-m", "Initial commit: Add basic addition and subtraction\n\nSets up Calculator struct with add and subtract operations."], currentDirectory: tempDir)

            // Commit 2: Add multiplication & division
            let rev2 = """
            // Calculator.swift
            // Basic arithmetic calculator

            import Foundation

            public struct Calculator {
                public init() {}

                public func add(_ a: Double, _ b: Double) -> Double {
                    return a + b
                }

                public func subtract(_ a: Double, _ b: Double) -> Double {
                    return a - b
                }

                public func multiply(_ a: Double, _ b: Double) -> Double {
                    return a * b
                }

                public func divide(_ a: Double, _ b: Double) throws -> Double {
                    guard b != 0 else {
                        throw NSError(domain: "MathError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Division by zero"])
                    }
                    return a / b
                }
            }
            """
            try rev2.write(to: swiftFile, atomically: true, encoding: .utf8)
            _ = try ProcessRunner.run(binary: git, arguments: ["commit", "-am", "feat: Add multiplication and safe division\n\nSupports multiply and divide methods, throwing on zero denominator."], currentDirectory: tempDir)

            // Commit 3: Add power and square root
            let rev3 = """
            // Calculator.swift
            // Advanced arithmetic calculator with scientific functions

            import Foundation

            public struct Calculator {
                public init() {}

                public func add(_ a: Double, _ b: Double) -> Double {
                    return a + b
                }

                public func subtract(_ a: Double, _ b: Double) -> Double {
                    return a - b
                }

                public func multiply(_ a: Double, _ b: Double) -> Double {
                    return a * b
                }

                public func divide(_ a: Double, _ b: Double) throws -> Double {
                    guard b != 0 else {
                        throw NSError(domain: "MathError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Division by zero"])
                    }
                    return a / b
                }

                public func power(base: Double, exponent: Double) -> Double {
                    return pow(base, exponent)
                }

                public func squareRoot(_ value: Double) throws -> Double {
                    guard value >= 0 else {
                        throw NSError(domain: "MathError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Negative square root"])
                    }
                    return sqrt(value)
                }
            }
            """
            try rev3.write(to: swiftFile, atomically: true, encoding: .utf8)
            _ = try ProcessRunner.run(binary: git, arguments: ["commit", "-am", "feat: Add power and squareRoot operations\n\nImplements power and square root operations using Foundation math functions."], currentDirectory: tempDir)

            // Commit 4: Add modulo
            let rev4 = """
            // Calculator.swift
            // Advanced arithmetic calculator with scientific functions

            import Foundation

            public struct Calculator {
                public init() {}

                public func add(_ a: Double, _ b: Double) -> Double {
                    return a + b
                }

                public func subtract(_ a: Double, _ b: Double) -> Double {
                    return a - b
                }

                public func multiply(_ a: Double, _ b: Double) -> Double {
                    return a * b
                }

                public func divide(_ a: Double, _ b: Double) throws -> Double {
                    guard b != 0 else {
                        throw NSError(domain: "MathError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Division by zero"])
                    }
                    return a / b
                }

                public func power(base: Double, exponent: Double) -> Double {
                    return pow(base, exponent)
                }

                public func squareRoot(_ value: Double) throws -> Double {
                    guard value >= 0 else {
                        throw NSError(domain: "MathError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Negative square root"])
                    }
                    return sqrt(value)
                }

                public func modulo(_ a: Int, _ b: Int) throws -> Int {
                    guard b != 0 else {
                        throw NSError(domain: "MathError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Modulo by zero"])
                    }
                    return a % b
                }
            }
            """
            try rev4.write(to: swiftFile, atomically: true, encoding: .utf8)
            _ = try ProcessRunner.run(binary: git, arguments: ["commit", "-am", "feat: Add modulo operation\n\nSupports modulo remainder operator for integer calculations."], currentDirectory: tempDir)

            // Commit 5: Add percentage and absolute operations
            let rev5 = """
            // Calculator.swift
            // Advanced arithmetic calculator with scientific functions

            import Foundation

            public struct Calculator {
                public init() {}

                public func add(_ a: Double, _ b: Double) -> Double {
                    return a + b
                }

                public func subtract(_ a: Double, _ b: Double) -> Double {
                    return a - b
                }

                public func multiply(_ a: Double, _ b: Double) -> Double {
                    return a * b
                }

                public func divide(_ a: Double, _ b: Double) throws -> Double {
                    guard b != 0 else {
                        throw NSError(domain: "MathError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Division by zero"])
                    }
                    return a / b
                }

                public func power(base: Double, exponent: Double) -> Double {
                    return pow(base, exponent)
                }

                public func squareRoot(_ value: Double) throws -> Double {
                    guard value >= 0 else {
                        throw NSError(domain: "MathError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Negative square root"])
                    }
                    return sqrt(value)
                }

                public func modulo(_ a: Int, _ b: Int) throws -> Int {
                    guard b != 0 else {
                        throw NSError(domain: "MathError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Modulo by zero"])
                    }
                    return a % b
                }

                public func percentage(_ value: Double, of total: Double) -> Double {
                    guard total != 0 else { return 0 }
                    return (value / total) * 100.0
                }

                public func absolute(_ value: Double) -> Double {
                    return abs(value)
                }
            }
            """
            try rev5.write(to: swiftFile, atomically: true, encoding: .utf8)
            _ = try ProcessRunner.run(binary: git, arguments: ["commit", "-am", "feat: Add percentage and absolute operations\n\nIncludes percentage calculation and absolute value helper."], currentDirectory: tempDir)

            // Setup Mercurial sample for multi-tab layout
            let (_, hgFiles) = try SampleRepoService.shared.setupSampleHgRepo()
            let pyFile = hgFiles[0]

            let tabManager = TabManager()
            tabManager.openInTab(url: swiftFile, preferredVCS: .git)
            tabManager.openInTab(url: pyFile, preferredVCS: .hg)
            if let firstTab = tabManager.tabs.first {
                tabManager.selectTab(id: firstTab.id)
            }

            guard let activeVM = tabManager.activeViewModel else {
                fatalError("No active view model")
            }

            var waitCount = 0
            while activeVM.isLoading && waitCount < 50 {
                try await Task.sleep(nanoseconds: 100_000_000)
                waitCount += 1
            }
            print("Loaded commits: \(activeVM.commits.count)")

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

            let framesDir = fileManager.temporaryDirectory.appendingPathComponent("Archaeologist_TimelineFrames_\(UUID().uuidString)")
            try fileManager.createDirectory(at: framesDir, withIntermediateDirectories: true)

            func drawMousePointer(in ctx: CGContext, at point: CGPoint) {
                ctx.saveGState()
                ctx.translateBy(x: point.x, y: point.y)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: -17))
                path.addLine(to: CGPoint(x: 4.5, y: -13))
                path.addLine(to: CGPoint(x: 7.5, y: -20))
                path.addLine(to: CGPoint(x: 10, y: -19))
                path.addLine(to: CGPoint(x: 7, y: -12))
                path.addLine(to: CGPoint(x: 12, y: -12))
                path.closeSubpath()

                ctx.setShadow(offset: CGSize(width: 1, height: -2), blur: 3, color: CGColor(gray: 0, alpha: 0.5))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.addPath(path)
                ctx.fillPath()

                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                let innerPath = CGMutablePath()
                innerPath.move(to: CGPoint(x: 1, y: -2))
                innerPath.addLine(to: CGPoint(x: 1, y: -14.5))
                innerPath.addLine(to: CGPoint(x: 4.5, y: -11.5))
                innerPath.addLine(to: CGPoint(x: 7.5, y: -18.5))
                innerPath.addLine(to: CGPoint(x: 8.8, y: -18))
                innerPath.addLine(to: CGPoint(x: 5.8, y: -11))
                innerPath.addLine(to: CGPoint(x: 10, y: -11))
                innerPath.closeSubpath()

                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.addPath(innerPath)
                ctx.fillPath()
                ctx.restoreGState()
            }

            func captureFrame(frameIndex: Int, cursorPoint: CGPoint?) throws {
                hostingView.layoutSubtreeIfNeeded()
                guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                    fatalError("Failed to create bitmapImageRepForCachingDisplay")
                }
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

                guard let baseCGImage = bitmapRep.cgImage else {
                    fatalError("Failed to extract base CGImage")
                }

                let width = baseCGImage.width
                let height = baseCGImage.height
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                guard let ctx = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    fatalError("Failed to create CGContext")
                }

                ctx.draw(baseCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                if let cursor = cursorPoint {
                    let scale = CGFloat(width) / windowWidth
                    drawMousePointer(in: ctx, at: CGPoint(x: cursor.x * scale, y: (windowHeight - cursor.y) * scale))
                }

                guard let finalImage = ctx.makeImage() else {
                    fatalError("Failed to make final image")
                }
                let finalRep = NSBitmapImageRep(cgImage: finalImage)
                guard let pngData = finalRep.representation(using: .png, properties: [:]) else {
                    fatalError("Failed to serialize PNG")
                }
                let frameURL = framesDir.appendingPathComponent(String(format: "frame_%04d.png", frameIndex))
                try pngData.write(to: frameURL)
            }

            // Scrubber geometry:
            // Sidebar width: 240
            // Timeline padding: 16 on left & right
            // Track start: 240 + 16 = 256
            // Track width: 1100 - 240 - 32 = 828
            // Scrubber node centerY: y = 135 pt from window top
            let trackStartX: CGFloat = 256.0
            let trackWidth: CGFloat = 828.0
            let trackY: CGFloat = 135.0
            let numCommits = activeVM.commits.count
            func commitX(for index: Int) -> CGFloat {
                guard numCommits > 1 else { return trackStartX + trackWidth / 2 }
                return trackStartX + (CGFloat(index) / CGFloat(numCommits - 1)) * trackWidth
            }

            var currentFrameIndex = 0

            // 1. Initial pause at commit 0 (6 frames)
            activeVM.selectedCommitIndex = 0
            try await Task.sleep(nanoseconds: 200_000_000)
            hostingView.layoutSubtreeIfNeeded()
            for _ in 0..<6 {
                try captureFrame(frameIndex: currentFrameIndex, cursorPoint: CGPoint(x: commitX(for: 0), y: trackY))
                currentFrameIndex += 1
            }

            // 2. Drag forward from commit 0 to 4 (24 frames)
            let totalDragForwardSteps = 24
            for step in 1...totalDragForwardSteps {
                let t = CGFloat(step) / CGFloat(totalDragForwardSteps)
                let floatCommit = t * CGFloat(numCommits - 1)
                let targetIdx = Int(round(floatCommit))
                if activeVM.selectedCommitIndex != targetIdx {
                    activeVM.selectedCommitIndex = targetIdx
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let curX = trackStartX + t * trackWidth
                try captureFrame(frameIndex: currentFrameIndex, cursorPoint: CGPoint(x: curX, y: trackY))
                currentFrameIndex += 1
            }

            // 3. Pause at commit 4 (latest) (8 frames)
            for _ in 0..<8 {
                try captureFrame(frameIndex: currentFrameIndex, cursorPoint: CGPoint(x: commitX(for: numCommits - 1), y: trackY))
                currentFrameIndex += 1
            }

            // 4. Drag backward from commit 4 to commit 2 (16 frames)
            let targetBackIdx = 2
            let startX = commitX(for: numCommits - 1)
            let endX = commitX(for: targetBackIdx)
            let totalDragBackSteps = 16
            for step in 1...totalDragBackSteps {
                let t = CGFloat(step) / CGFloat(totalDragBackSteps)
                let curX = startX + t * (endX - startX)
                let ratio = (curX - trackStartX) / trackWidth
                let floatCommit = ratio * CGFloat(numCommits - 1)
                let targetIdx = max(0, min(numCommits - 1, Int(round(floatCommit))))
                if activeVM.selectedCommitIndex != targetIdx {
                    activeVM.selectedCommitIndex = targetIdx
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try captureFrame(frameIndex: currentFrameIndex, cursorPoint: CGPoint(x: curX, y: trackY))
                currentFrameIndex += 1
            }

            // 5. Settle on Commit 3 showing both added & removed diff highlights (12 frames)
            for _ in 0..<12 {
                try captureFrame(frameIndex: currentFrameIndex, cursorPoint: CGPoint(x: endX, y: trackY))
                currentFrameIndex += 1
            }

            print("Captured \(currentFrameIndex) frames.")

            // Assemble into timeline.gif using ffmpeg
            let paletteURL = fileManager.temporaryDirectory.appendingPathComponent("palette_\(UUID().uuidString).png")
            let outputGif = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("timeline.gif")

            let ffmpeg = ProcessRunner.resolveBinaryPath(named: "ffmpeg") ?? "/opt/homebrew/bin/ffmpeg"
            _ = try ProcessRunner.run(
                binary: ffmpeg,
                arguments: [
                    "-y",
                    "-i", "\(framesDir.path)/frame_%04d.png",
                    "-vf", "fps=10,palettegen=stats_mode=diff",
                    paletteURL.path
                ],
                currentDirectory: framesDir
            )

            _ = try ProcessRunner.run(
                binary: ffmpeg,
                arguments: [
                    "-y",
                    "-framerate", "10",
                    "-i", "\(framesDir.path)/frame_%04d.png",
                    "-i", paletteURL.path,
                    "-lavfi", "fps=10,paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                    outputGif.path
                ],
                currentDirectory: framesDir
            )

            print("Successfully rendered timeline GIF to \(outputGif.path)")

            // Clean up temporary files
            try? fileManager.removeItem(at: framesDir)
            try? fileManager.removeItem(at: paletteURL)
            try? fileManager.removeItem(at: tempDir)
            exit(0)
        } catch {
            print("Error rendering timeline GIF: \(error)")
            exit(1)
        }
    }
}
