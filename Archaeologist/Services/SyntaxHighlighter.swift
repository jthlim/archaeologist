import Foundation
import AppKit

public enum SyntaxLanguage: String, CaseIterable, Identifiable {
    case swift = "Swift"
    case python = "Python"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case c = "C"
    case cpp = "C++"
    case rust = "Rust"
    case go = "Go"
    case java = "Java"
    case kotlin = "Kotlin"
    case ruby = "Ruby"
    case shell = "Shell"
    case html = "HTML"
    case css = "CSS"
    case json = "JSON"
    case yaml = "YAML"
    case sql = "SQL"
    case markdown = "Markdown"
    case binary = "Binary"
    case plain = "Plain Text"

    public var id: String { rawValue }

    public static func detect(filename: String, firstLine: String? = nil, isBinary: Bool = false) -> SyntaxLanguage {
        if isBinary { return .binary }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "py", "pyw": return .python
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "mts", "cts", "tsx": return .typescript
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hxx", "hh": return .cpp
        case "rs": return .rust
        case "go": return .go
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "rb": return .ruby
        case "sh", "bash", "zsh", "fish": return .shell
        case "html", "htm", "xml", "svg": return .html
        case "css", "scss", "sass", "less": return .css
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "sql": return .sql
        case "md", "markdown": return .markdown
        default:
            if let first = firstLine {
                if first.hasPrefix("#!") {
                    if first.contains("python") { return .python }
                    if first.contains("bash") || first.contains("sh") || first.contains("zsh") { return .shell }
                    if first.contains("node") { return .javascript }
                    if first.contains("ruby") { return .ruby }
                }
            }
            return .plain
        }
    }
}

public final class SyntaxHighlighter: @unchecked Sendable {
    public static let shared = SyntaxHighlighter()

    private var cache = NSCache<NSString, NSAttributedString>()
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()

    public static func cachedRegex(for pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }
        let key = "\(options.rawValue)_\(pattern)"
        if let existing = regexCache[key] {
            return existing
        }
        if let reg = try? NSRegularExpression(pattern: pattern, options: options) {
            regexCache[key] = reg
            return reg
        }
        return nil
    }

    public init() {
        cache.countLimit = 50000
    }

    public struct Theme {
        public let keywordColor: NSColor
        public let stringColor: NSColor
        public let commentColor: NSColor
        public let numberColor: NSColor
        public let typeColor: NSColor
        public let functionColor: NSColor
        public let attributeColor: NSColor
        public let textColor: NSColor

        public static var light: Theme {
            Theme(
                keywordColor: NSColor(red: 0.84, green: 0.23, blue: 0.29, alpha: 1.0),   // Crimson / Red
                stringColor: NSColor(red: 0.01, green: 0.18, blue: 0.38, alpha: 1.0),    // Dark Blue
                commentColor: NSColor(red: 0.42, green: 0.45, blue: 0.49, alpha: 1.0),   // Slate gray
                numberColor: NSColor(red: 0.00, green: 0.36, blue: 0.77, alpha: 1.0),    // Blue
                typeColor: NSColor(red: 0.44, green: 0.26, blue: 0.76, alpha: 1.0),      // Purple
                functionColor: NSColor(red: 0.13, green: 0.53, blue: 0.23, alpha: 1.0),  // Forest Green
                attributeColor: NSColor(red: 0.89, green: 0.38, blue: 0.04, alpha: 1.0), // Orange
                textColor: NSColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0)
            )
        }

        public static var dark: Theme {
            Theme(
                keywordColor: NSColor(red: 1.00, green: 0.48, blue: 0.45, alpha: 1.0),   // Salmon / Coral
                stringColor: NSColor(red: 0.65, green: 0.84, blue: 1.00, alpha: 1.0),    // Sky Blue
                commentColor: NSColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1.0),   // Medium Gray
                numberColor: NSColor(red: 0.47, green: 0.75, blue: 1.00, alpha: 1.0),    // Bright Cyan/Blue
                typeColor: NSColor(red: 0.82, green: 0.66, blue: 1.00, alpha: 1.0),      // Lavender
                functionColor: NSColor(red: 0.49, green: 0.91, blue: 0.53, alpha: 1.0),  // Light Green
                attributeColor: NSColor(red: 1.00, green: 0.65, blue: 0.34, alpha: 1.0), // Amber / Gold
                textColor: NSColor(red: 0.90, green: 0.92, blue: 0.94, alpha: 1.0)
            )
        }

        public static func current(isDark: Bool) -> Theme {
            isDark ? dark : light
        }
    }

    public func highlight(
        text: String,
        language: SyntaxLanguage,
        isDark: Bool,
        font: NSFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    ) -> NSAttributedString {
        let cacheKey = "\(language.rawValue)_\(isDark ? "dark" : "light")_\(font.pointSize)_\(text.hashValue)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let theme = Theme.current(isDark: isDark)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.textColor,
            .font: font
        ]

        let attributed = NSMutableAttributedString(string: text, attributes: baseAttrs)
        if language == .plain || text.isEmpty {
            cache.setObject(attributed, forKey: cacheKey)
            return attributed
        }

        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // 1. Numbers
        applyRegex(
            pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#,
            in: text,
            fullRange: fullRange,
            attributed: attributed,
            attributes: [.foregroundColor: theme.numberColor]
        )

        // 2. Types / Classes (PascalCase words)
        applyRegex(
            pattern: #"\b[A-Z][a-zA-Z0-9_]*\b"#,
            in: text,
            fullRange: fullRange,
            attributed: attributed,
            attributes: [.foregroundColor: theme.typeColor]
        )

        // 3. Functions (word followed by `(`)
        applyRegex(
            pattern: #"\b([a-zA-Z_][a-zA-Z0-9_]*)(?=\s*\()"#,
            in: text,
            fullRange: fullRange,
            attributed: attributed,
            attributes: [.foregroundColor: theme.functionColor]
        )

        // 4. Attributes / Annotations / Preprocessor
        let attrPattern: String
        switch language {
        case .swift, .java, .kotlin, .python, .rust:
            attrPattern = #"(?:@|#)[a-zA-Z_][a-zA-Z0-9_]*"#
        case .c, .cpp:
            attrPattern = #"#[a-zA-Z_][a-zA-Z0-9_]*"#
        default:
            attrPattern = #"@[a-zA-Z_][a-zA-Z0-9_]*"#
        }
        applyRegex(
            pattern: attrPattern,
            in: text,
            fullRange: fullRange,
            attributed: attributed,
            attributes: [.foregroundColor: theme.attributeColor]
        )

        // 5. Keywords
        let keywords = keywords(for: language)
        if !keywords.isEmpty {
            let kwPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
            applyRegex(
                pattern: kwPattern,
                in: text,
                fullRange: fullRange,
                attributed: attributed,
                attributes: [
                    .foregroundColor: theme.keywordColor,
                    .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
                ]
            )
        }

        // 6. Strings (override previous tokens)
        let stringPatterns = [
            #"\"\"\"[\s\S]*?\"\"\""#, // Triple quotes
            #"\"(?:[^\"\\]|\\.)*\""#, // Double quotes
            #"'(?:[^'\\]|\\.)*'"#,    // Single quotes
            #"`(?:[^`\\]|\\.)*`"#     // Backticks
        ]
        for pattern in stringPatterns {
            applyRegex(
                pattern: pattern,
                in: text,
                fullRange: fullRange,
                attributed: attributed,
                attributes: [.foregroundColor: theme.stringColor]
            )
        }

        // 7. Comments (override strings & everything else)
        let commentPatterns = commentPatterns(for: language)
        for pattern in commentPatterns {
            applyRegex(
                pattern: pattern,
                in: text,
                fullRange: fullRange,
                attributed: attributed,
                attributes: [
                    .foregroundColor: theme.commentColor,
                    .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                ]
            )
        }

        cache.setObject(attributed, forKey: cacheKey)
        return attributed
    }

    private func applyRegex(
        pattern: String,
        in text: String,
        fullRange: NSRange,
        attributed: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex = Self.cachedRegex(for: pattern) else { return }
        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            if let matchRange = match?.range {
                attributed.addAttributes(attributes, range: matchRange)
            }
        }
    }

    private func commentPatterns(for language: SyntaxLanguage) -> [String] {
        switch language {
        case .swift, .c, .cpp, .rust, .go, .java, .kotlin, .javascript, .typescript:
            return [
                #"//.*$"#,
                #"/\*[\s\S]*?\*/"#
            ]
        case .python, .ruby, .shell, .yaml:
            return [#"#.*$"#]
        case .sql:
            return [
                #"--.*$"#,
                #"/\*[\s\S]*?\*/"#
            ]
        case .html:
            return [#"<!--[\s\S]*?-->"#]
        case .css:
            return [#"/\*[\s\S]*?\*/"#]
        default:
            return [#"//.*$"#, #"#.*$"#]
        }
    }

    private func keywords(for language: SyntaxLanguage) -> [String] {
        switch language {
        case .swift:
            return [
                "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
                "continue", "convenience", "default", "defer", "deinit", "do", "dynamic", "else", "enum",
                "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard",
                "if", "import", "in", "indirect", "infix", "init", "inout", "internal", "is", "lazy", "let",
                "mutating", "nil", "nonmutating", "open", "operator", "optional", "override", "postfix",
                "prefix", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self",
                "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
                "true", "try", "typealias", "unowned", "var", "weak", "where", "while"
            ]
        case .python:
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
                "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while",
                "with", "yield"
            ]
        case .javascript, .typescript:
            return [
                "abstract", "any", "as", "async", "await", "break", "case", "catch", "class", "const",
                "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
                "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in",
                "instanceof", "interface", "let", "new", "null", "of", "package", "private", "protected",
                "public", "return", "set", "static", "super", "switch", "this", "throw", "true", "try",
                "type", "typeof", "undefined", "var", "void", "while", "with", "yield"
            ]
        case .c, .cpp:
            return [
                "auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr", "continue",
                "default", "delete", "do", "double", "else", "enum", "explicit", "export", "extern", "false",
                "float", "for", "friend", "goto", "if", "inline", "int", "long", "mutable", "namespace",
                "new", "noexcept", "nullptr", "operator", "private", "protected", "public", "register",
                "reinterpret_cast", "return", "short", "signed", "sizeof", "static", "static_cast", "struct",
                "switch", "template", "this", "throw", "true", "try", "typedef", "typeid", "typename",
                "union", "unsigned", "using", "virtual", "void", "volatile", "while"
            ]
        case .rust:
            return [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
                "trait", "true", "type", "unsafe", "use", "where", "while"
            ]
        case .go:
            return [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
                "return", "select", "struct", "switch", "type", "var"
            ]
        case .java, .kotlin:
            return [
                "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
                "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
                "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long",
                "native", "new", "null", "package", "private", "protected", "public", "return", "short",
                "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient",
                "true", "try", "void", "volatile", "while", "val", "var", "fun", "when"
            ]
        case .ruby:
            return [
                "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
                "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
                "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
                "unless", "until", "when", "while", "yield"
            ]
        case .shell:
            return [
                "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if",
                "in", "local", "return", "select", "then", "time", "until", "while"
            ]
        case .sql:
            return [
                "SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE", "JOIN", "INNER", "LEFT",
                "RIGHT", "FULL", "OUTER", "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET",
                "AS", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "CREATE", "TABLE", "DROP", "ALTER",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "INDEX", "VIEW", "UNION", "ALL", "DISTINCT"
            ]
        default:
            return []
        }
    }
}
