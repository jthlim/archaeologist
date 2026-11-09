import Foundation
import AppKit

public struct HexDumpFormatter {
    private static let hexLookup: [String] = (0...255).map { String(format: "%02X", $0) }

    /// Returns the total number of rows needed for the given data length.
    public static func rowCount(dataLength: Int, bytesPerRow: Int = 16) -> Int {
        guard dataLength > 0 else { return 0 }
        let validBytesPerRow = max(16, (bytesPerRow / 16) * 16)
        return (dataLength + validBytesPerRow - 1) / validBytesPerRow
    }

    /// Formats a single row on demand for the given row index.
    /// Each row displays:
    /// - Offset address (8 hex digits zero-padded, e.g. 00000000)
    /// - Two spaces
    /// - Hex byte values (separated by spaces, with extra space every 8 bytes)
    /// - Two spaces + '|'
    /// - Printable characters representing the bytes at the end (or '.' for non-printable bytes)
    /// - '|'
    public static func formatRow(data: Data, rowIndex: Int, bytesPerRow: Int = 16) -> String {
        let validBytesPerRow = max(16, (bytesPerRow / 16) * 16)
        let offset = rowIndex * validBytesPerRow
        guard offset < data.count else { return "" }
        let chunkSize = min(validBytesPerRow, data.count - offset)

        var output = ""
        output.reserveCapacity(12 + validBytesPerRow * 3 + (validBytesPerRow / 8) + validBytesPerRow + 6)

        // 1. Offset column (8 hex digits)
        output.append(String(format: "%08X  ", offset))

        // 2. Hex values
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<validBytesPerRow {
                if i < chunkSize {
                    let b = ptr[offset + i]
                    output.append(hexLookup[Int(b)])
                    output.append(" ")
                } else {
                    output.append("   ")
                }
                if (i + 1) % 8 == 0 && (i + 1) < validBytesPerRow {
                    output.append(" ")
                }
            }

            output.append(" |")

            // 3. Characters representing the hex bytes at the end
            for i in 0..<chunkSize {
                let b = ptr[offset + i]
                if b >= 32 && b <= 126 {
                    output.append(Character(UnicodeScalar(b)))
                } else {
                    output.append(".")
                }
            }
            output.append("|")
        }

        return output
    }

    /// Formats a single row as an NSAttributedString with colored syntax:
    /// - Offset bytes: Blue
    /// - Hex values: Default text color
    /// - Pipes: Grey
    /// - ASCII characters: Green
    public static func formatAttributedRow(
        data: Data,
        rowIndex: Int,
        bytesPerRow: Int = 16,
        isDark: Bool,
        font: NSFont
    ) -> NSAttributedString {
        let validBytesPerRow = max(16, (bytesPerRow / 16) * 16)
        let offset = rowIndex * validBytesPerRow
        guard offset < data.count else { return NSAttributedString() }
        let chunkSize = min(validBytesPerRow, data.count - offset)

        let offsetColor = isDark
            ? NSColor(calibratedRed: 0.40, green: 0.70, blue: 1.0, alpha: 1.0)
            : NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.85, alpha: 1.0)
        let hexColor = isDark
            ? NSColor(calibratedWhite: 0.90, alpha: 1.0)
            : NSColor.textColor
        let pipeColor = isDark
            ? NSColor(calibratedWhite: 0.50, alpha: 1.0)
            : NSColor.systemGray
        let asciiColor = isDark
            ? NSColor(calibratedRed: 0.42, green: 0.85, blue: 0.52, alpha: 1.0)
            : NSColor(calibratedRed: 0.06, green: 0.38, blue: 0.12, alpha: 1.0)

        let result = NSMutableAttributedString()

        // 1. Offset column (Blue)
        let offsetStr = String(format: "%08X  ", offset)
        result.append(NSAttributedString(string: offsetStr, attributes: [
            .font: font,
            .foregroundColor: offsetColor
        ]))

        // 2. Hex values (Default text color)
        var hexStr = ""
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<validBytesPerRow {
                if i < chunkSize {
                    let b = ptr[offset + i]
                    hexStr.append(hexLookup[Int(b)])
                    hexStr.append(" ")
                } else {
                    hexStr.append("   ")
                }
                if (i + 1) % 8 == 0 && (i + 1) < validBytesPerRow {
                    hexStr.append(" ")
                }
            }
        }
        hexStr.append(" ")
        result.append(NSAttributedString(string: hexStr, attributes: [
            .font: font,
            .foregroundColor: hexColor
        ]))

        // 3. Opening pipe (Grey)
        result.append(NSAttributedString(string: "|", attributes: [
            .font: font,
            .foregroundColor: pipeColor
        ]))

        // 4. ASCII section (Green)
        var asciiStr = ""
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<chunkSize {
                let b = ptr[offset + i]
                if b >= 32 && b <= 126 {
                    asciiStr.append(Character(UnicodeScalar(b)))
                } else {
                    asciiStr.append(".")
                }
            }
        }
        result.append(NSAttributedString(string: asciiStr, attributes: [
            .font: font,
            .foregroundColor: asciiColor
        ]))

        // 5. Closing pipe (Grey)
        result.append(NSAttributedString(string: "|", attributes: [
            .font: font,
            .foregroundColor: pipeColor
        ]))

        return result
    }

    /// Formats only the hex byte values for a single row.
    public static func formatHexOnly(data: Data, rowIndex: Int, bytesPerRow: Int = 16) -> String {
        let validBytesPerRow = max(16, (bytesPerRow / 16) * 16)
        let offset = rowIndex * validBytesPerRow
        guard offset < data.count else { return "" }
        let chunkSize = min(validBytesPerRow, data.count - offset)

        var output = ""
        output.reserveCapacity(chunkSize * 3)
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<chunkSize {
                let b = ptr[offset + i]
                output.append(hexLookup[Int(b)])
                if i + 1 < chunkSize {
                    output.append(" ")
                }
            }
        }
        return output
    }

    /// Formats only the printable ASCII representation for a single row.
    public static func formatAsciiOnly(data: Data, rowIndex: Int, bytesPerRow: Int = 16) -> String {
        let validBytesPerRow = max(16, (bytesPerRow / 16) * 16)
        let offset = rowIndex * validBytesPerRow
        guard offset < data.count else { return "" }
        let chunkSize = min(validBytesPerRow, data.count - offset)

        var output = ""
        output.reserveCapacity(chunkSize)
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<chunkSize {
                let b = ptr[offset + i]
                if b >= 32 && b <= 126 {
                    output.append(Character(UnicodeScalar(b)))
                } else {
                    output.append(".")
                }
            }
        }
        return output
    }

    /// Formats binary data into standard hex dump rows.
    /// - Parameters:
    ///   - data: Raw binary data.
    ///   - bytesPerRow: Number of bytes per row, enforced to be a positive multiple of 16 (defaults to 16).
    /// - Returns: The formatted hex dump string.
    public static func format(data: Data, bytesPerRow: Int = 16) -> String {
        guard !data.isEmpty else { return "00000000  \n" }

        let totalRows = rowCount(dataLength: data.count, bytesPerRow: bytesPerRow)
        var output = ""
        output.reserveCapacity(totalRows * 80)
        for row in 0..<totalRows {
            output.append(formatRow(data: data, rowIndex: row, bytesPerRow: bytesPerRow))
            output.append("\n")
        }
        return output
    }
}
