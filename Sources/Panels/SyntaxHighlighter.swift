import AppKit
import Foundation

enum SyntaxHighlighter {
    enum TokenType {
        case keyword, string, number, comment, key, heading, bold, codeSpan

        var color: NSColor {
            switch self {
            case .keyword:  return .systemPurple
            case .string:   return .systemGreen
            case .number:   return .systemBlue
            case .comment:  return .systemGray
            case .key:      return .systemTeal
            case .heading:  return .systemOrange
            case .bold:     return .systemPink
            case .codeSpan: return .systemIndigo
            }
        }
    }

    private struct TokenPattern {
        let type: TokenType
        let regex: NSRegularExpression
    }

    // MARK: - Language Patterns

    private static let jsonPatterns: [TokenPattern] = [
        TokenPattern(type: .key,     regex: try! NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*"\s*(?=:)"#)),
        TokenPattern(type: .string,  regex: try! NSRegularExpression(pattern: #":\s*"[^"\\]*(?:\\.[^"\\]*)*""#)),
        TokenPattern(type: .number,  regex: try! NSRegularExpression(pattern: #"(?<=:\s)-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)),
        TokenPattern(type: .keyword, regex: try! NSRegularExpression(pattern: #"\b(?:true|false|null)\b"#)),
    ]

    private static let swiftPatterns: [TokenPattern] = [
        TokenPattern(type: .comment, regex: try! NSRegularExpression(pattern: #"//.*$"#, options: .anchorsMatchLines)),
        TokenPattern(type: .string,  regex: try! NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*""#)),
        TokenPattern(type: .keyword, regex: try! NSRegularExpression(pattern: #"\b(?:import|class|struct|enum|protocol|func|var|let|if|else|guard|return|switch|case|for|while|do|try|catch|throw|throws|async|await|public|private|internal|fileprivate|open|static|final|override|init|deinit|self|super|true|false|nil|weak|unowned|lazy|mutating|nonmutating|inout|some|any|where|extension|typealias|associatedtype|subscript|didSet|willSet|get|set)\b"#)),
        TokenPattern(type: .number,  regex: try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)),
    ]

    private static let markdownPatterns: [TokenPattern] = [
        TokenPattern(type: .heading,  regex: try! NSRegularExpression(pattern: #"^#{1,6}\s+.*$"#, options: .anchorsMatchLines)),
        TokenPattern(type: .bold,     regex: try! NSRegularExpression(pattern: #"\*\*[^*]+\*\*"#)),
        TokenPattern(type: .codeSpan, regex: try! NSRegularExpression(pattern: #"`[^`]+`"#)),
        TokenPattern(type: .string,   regex: try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^\)]+\)"#)),
    ]

    private static let yamlPatterns: [TokenPattern] = [
        TokenPattern(type: .comment, regex: try! NSRegularExpression(pattern: #"#.*$"#, options: .anchorsMatchLines)),
        TokenPattern(type: .key,     regex: try! NSRegularExpression(pattern: #"^[\w.\-]+(?=\s*:)"#, options: .anchorsMatchLines)),
        TokenPattern(type: .string,  regex: try! NSRegularExpression(pattern: #"(?<=:\s)["'][^"']*["']"#)),
        TokenPattern(type: .keyword, regex: try! NSRegularExpression(pattern: #"\b(?:true|false|null|yes|no)\b"#, options: .caseInsensitive)),
        TokenPattern(type: .number,  regex: try! NSRegularExpression(pattern: #"(?<=:\s)-?\d+(?:\.\d+)?"#)),
    ]

    private static let tomlPatterns: [TokenPattern] = [
        TokenPattern(type: .comment, regex: try! NSRegularExpression(pattern: #"#.*$"#, options: .anchorsMatchLines)),
        TokenPattern(type: .heading, regex: try! NSRegularExpression(pattern: #"^\[+[^\]]+\]+"#, options: .anchorsMatchLines)),
        TokenPattern(type: .key,     regex: try! NSRegularExpression(pattern: #"^[\w.\-]+(?=\s*=)"#, options: .anchorsMatchLines)),
        TokenPattern(type: .string,  regex: try! NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*""#)),
        TokenPattern(type: .keyword, regex: try! NSRegularExpression(pattern: #"\b(?:true|false)\b"#)),
        TokenPattern(type: .number,  regex: try! NSRegularExpression(pattern: #"(?<==\s*)-?\d+(?:\.\d+)?"#)),
    ]

    private static let genericPatterns: [TokenPattern] = [
        TokenPattern(type: .comment, regex: try! NSRegularExpression(pattern: #"(?://|#).*$"#, options: .anchorsMatchLines)),
        TokenPattern(type: .string,  regex: try! NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*""#)),
        TokenPattern(type: .number,  regex: try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)),
    ]

    // MARK: - Pattern Selection

    private static func patterns(for language: EditorLanguage) -> [TokenPattern] {
        switch language {
        case .json:     return jsonPatterns
        case .swift:    return swiftPatterns
        case .markdown: return markdownPatterns
        case .yaml:     return yamlPatterns
        case .toml:     return tomlPatterns
        case .generic:  return genericPatterns
        }
    }

    // MARK: - Highlighting

    static func highlight(_ textStorage: NSTextStorage, language: EditorLanguage, font: NSFont) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let text = textStorage.string

        textStorage.beginEditing()
        // Reset to defaults
        textStorage.setAttributes([.foregroundColor: NSColor.labelColor, .font: font], range: fullRange)
        // Apply patterns
        let patternList = Self.patterns(for: language)
        for pattern in patternList {
            pattern.regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let matchRange = match?.range else { return }
                textStorage.addAttribute(.foregroundColor, value: pattern.type.color, range: matchRange)
            }
        }
        textStorage.endEditing()
    }

    /// Highlight only the given line range (with context padding).
    static func highlightRange(
        _ textStorage: NSTextStorage,
        editedRange: NSRange,
        language: EditorLanguage,
        font: NSFont
    ) {
        let text = textStorage.string
        let nsText = text as NSString
        guard textStorage.length > 0 else { return }

        // Expand to full lines + 2 lines context each side
        let clampedLocation = min(editedRange.location, max(nsText.length - 1, 0))
        let lineStart = nsText.lineRange(for: NSRange(location: clampedLocation, length: 0)).location
        let editEnd = min(NSMaxRange(editedRange), nsText.length)
        let lineEnd = NSMaxRange(nsText.lineRange(for: NSRange(location: max(editEnd - 1, 0), length: 0)))

        // Expand by 2 lines in each direction for multi-line constructs
        var start = lineStart
        for _ in 0..<2 {
            if start == 0 { break }
            start = nsText.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }
        var end = lineEnd
        for _ in 0..<2 {
            if end >= nsText.length { break }
            end = NSMaxRange(nsText.lineRange(for: NSRange(location: end, length: 0)))
        }
        let range = NSRange(location: start, length: end - start)

        textStorage.beginEditing()
        textStorage.setAttributes(
            [.foregroundColor: NSColor.labelColor, .font: font], range: range)
        let patternList = Self.patterns(for: language)
        for pattern in patternList {
            pattern.regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let matchRange = match?.range else { return }
                textStorage.addAttribute(
                    .foregroundColor, value: pattern.type.color, range: matchRange)
            }
        }
        textStorage.endEditing()
    }
}
