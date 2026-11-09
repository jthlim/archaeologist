import Foundation
import AppKit

public enum SampleRepoType: String, CaseIterable, Identifiable {
    case git = "Git Sample Repository"
    case hg = "Mercurial Sample Repository"

    public var id: String { rawValue }
}

public final class SampleRepoService: @unchecked Sendable {
    public static let shared = SampleRepoService()

    private let fileManager = FileManager.default

    public init() {}

    public func setupSampleGitRepo() throws -> (repoRoot: URL, sampleFiles: [URL]) {
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("Archaeologist_\(UUID().uuidString)")
            .appendingPathComponent("Git Sample")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let git = "git"
        _ = try ProcessRunner.run(binary: git, arguments: ["init"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: git, arguments: ["config", "user.name", "Ada Lovelace"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: git, arguments: ["config", "user.email", "ada@example.com"], currentDirectory: tempDir)

        // Commit 1: Initial Calculator in Swift
        let swiftFile = tempDir.appendingPathComponent("Calculator.swift")
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

        // Commit 4: Create a sample image (Logo.png)
        let logoFile = tempDir.appendingPathComponent("badge.png")
        let image1 = createSampleImage(text: "V1", color: .systemBlue)
        if let pngData = image1.tiffRepresentation {
            let bitmap = NSBitmapImageRep(data: pngData)
            let png = bitmap?.representation(using: .png, properties: [:])
            try png?.write(to: logoFile)
            _ = try ProcessRunner.run(binary: git, arguments: ["add", "badge.png"], currentDirectory: tempDir)
            _ = try ProcessRunner.run(binary: git, arguments: ["commit", "-m", "assets: Add initial project badge image\n\nBlue circular badge version 1.0."], currentDirectory: tempDir)
        }

        // Commit 5: Update the sample image
        let image2 = createSampleImage(text: "V2", color: .systemPurple)
        if let pngData = image2.tiffRepresentation {
            let bitmap = NSBitmapImageRep(data: pngData)
            let png = bitmap?.representation(using: .png, properties: [:])
            try png?.write(to: logoFile)
            _ = try ProcessRunner.run(binary: git, arguments: ["commit", "-am", "assets: Update project badge to purple v2\n\nRefreshed branding colors for release 2."], currentDirectory: tempDir)
        }

        return (tempDir, [swiftFile, logoFile])
    }

    public func setupSampleHgRepo() throws -> (repoRoot: URL, sampleFiles: [URL]) {
        guard let hgBin = ProcessRunner.resolveBinaryPath(named: "hg") else {
            throw NSError(
                domain: "SampleRepoService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Mercurial (hg) is not installed on this system."]
            )
        }

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("Archaeologist_\(UUID().uuidString)")
            .appendingPathComponent("Mercurial Sample")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        _ = try ProcessRunner.run(binary: hgBin, arguments: ["init"], currentDirectory: tempDir)

        // Set username in .hg/hgrc
        let hgrc = tempDir.appendingPathComponent(".hg").appendingPathComponent("hgrc")
        let hgrcContent = """
        [ui]
        username = Grace Hopper <grace@example.com>
        """
        try hgrcContent.write(to: hgrc, atomically: true, encoding: .utf8)

        // Commit 1: Python Data Processor
        let pyFile = tempDir.appendingPathComponent("processor.py")
        let rev1 = """
        # processor.py
        # Simple pipeline data processor

        import json

        def load_records(filepath):
            with open(filepath, 'r') as f:
                return json.load(f)

        def count_records(records):
            return len(records)
        """
        try rev1.write(to: pyFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["add", "processor.py"], currentDirectory: tempDir)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "Initial hg commit: Add basic record loader\n\nSupports json load and record count."], currentDirectory: tempDir)

        // Commit 2: Add filtering and stats
        let rev2 = """
        # processor.py
        # Simple pipeline data processor with filtering

        import json

        def load_records(filepath):
            with open(filepath, 'r') as f:
                return json.load(f)

        def count_records(records):
            return len(records)

        def filter_active(records):
            '''Filter active records from list'''
            return [r for r in records if r.get('active', False)]

        def calculate_average(records, key='score'):
            '''Calculate average score across records'''
            values = [r[key] for r in records if key in r]
            if not values:
                return 0.0
            return sum(values) / len(values)
        """
        try rev2.write(to: pyFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "Add active record filtering and statistics\n\nIncludes calculate_average and filter_active functions."], currentDirectory: tempDir)

        // Commit 3: Add export and CLI runner
        let rev3 = """
        # processor.py
        # Simple pipeline data processor with CLI export

        import json
        import sys

        def load_records(filepath):
            with open(filepath, 'r') as f:
                return json.load(f)

        def count_records(records):
            return len(records)

        def filter_active(records):
            '''Filter active records from list'''
            return [r for r in records if r.get('active', False)]

        def calculate_average(records, key='score'):
            '''Calculate average score across records'''
            values = [r[key] for r in records if key in r]
            if not values:
                return 0.0
            return sum(values) / len(values)

        def export_summary(records, output_path):
            summary = {
                'total': count_records(records),
                'active': len(filter_active(records)),
                'avg_score': calculate_average(records)
            }
            with open(output_path, 'w') as f:
                json.dump(summary, f, indent=2)
            print(f"Summary written to {output_path}")

        if __name__ == '__main__':
            print("Processor module ready.")
        """
        try rev3.write(to: pyFile, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run(binary: hgBin, arguments: ["commit", "-m", "feat: Add export_summary and CLI execution\n\nOutputs summary metrics JSON file."], currentDirectory: tempDir)

        return (tempDir, [pyFile])
    }

    private func createSampleImage(text: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 260, height: 260)
        let image = NSImage(size: size)
        image.lockFocus()

        // Background
        color.setFill()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: 40, yRadius: 40)
        path.fill()

        // Inner circle
        NSColor.white.withAlphaComponent(0.2).setFill()
        let innerRect = rect.insetBy(dx: 30, dy: 30)
        let innerPath = NSBezierPath(ovalIn: innerRect)
        innerPath.fill()

        // Label
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let strSize = str.size()
        let strRect = NSRect(
            x: (size.width - strSize.width) / 2,
            y: (size.height - strSize.height) / 2,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: strRect)

        image.unlockFocus()
        return image
    }
}
