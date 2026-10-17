import Foundation
import SwiftUI

/// Syntax colours for fenced code (CHAT-SPEC → Content, T3 Code's rules: common languages only, never while a block
/// streams, nothing above 20,000 characters, a cache bounded by entries and by bytes). A small scanner, not a grammar:
/// comments, strings, numbers, keywords, function calls and capitalised names. The palette is the terminal's
/// (VS Code Dark+), from `LoomTheme.Chat`.
enum ChatHighlighter {
    static let maximumCharacters = 20_000

    enum Token: Equatable {
        case plain, keyword, function, string, comment, type, number
        case added, removed
    }

    struct Piece: Equatable {
        var text: String
        var token: Token
    }

    /// The colored text of a finished block, or nil when it is not highlighted (unknown language, too long, streaming).
    @MainActor
    static func highlighted(_ code: String, language: String?, isStreaming: Bool = false) -> AttributedString? {
        guard !isStreaming, code.count <= maximumCharacters, let key = canonical(language) else { return nil }
        let cacheKey = "\(key):\(code.hashValue):\(code.utf8.count)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached.value }
        let pieces = tokens(code, language: key)
        var result = AttributedString()
        for piece in pieces {
            var run = AttributedString(piece.text)
            if let color = color(for: piece.token) { run.foregroundColor = color }
            result.append(run)
        }
        cache.setObject(Box(result), forKey: cacheKey, cost: code.utf8.count * 6)
        return result
    }

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// Bounded by entries and by bytes (the cost is an estimate of the attributed text's size).
    @MainActor private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 300
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func color(for token: Token) -> Color? {
        switch token {
        case .plain: nil
        case .keyword: LoomTheme.Chat.syntaxKeyword
        case .function: LoomTheme.Chat.syntaxFunction
        case .string: LoomTheme.Chat.syntaxString
        case .comment: LoomTheme.Chat.syntaxComment
        case .type: LoomTheme.Chat.syntaxType
        case .number: LoomTheme.Chat.syntaxNumber
        case .added: LoomTheme.Chat.diffAdd
        case .removed: LoomTheme.Chat.diffRemove
        }
    }

    // MARK: Languages

    private struct Spec {
        var keywords: Set<String>
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        var quotes: Set<Character> = ["\"", "'"]
        var tripleQuotes = false
        var caseInsensitive = false
        var typesByCapital = true
    }

    static func canonical(_ language: String?) -> String? {
        guard let raw = language?.lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "swift": return "swift"
        case "python", "py", "python3": return "python"
        case "javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts", "tsx": return "js"
        case "json", "jsonc", "json5": return "json"
        case "bash", "sh", "zsh", "shell", "console", "fish": return "bash"
        case "go", "golang": return "go"
        case "rust", "rs": return "rust"
        case "c", "h", "cpp", "c++", "cc", "hpp", "cxx", "objc", "objective-c", "objectivec": return "c"
        case "java", "kotlin", "kt", "csharp", "cs", "c#", "scala", "dart": return "java"
        case "ruby", "rb": return "ruby"
        case "sql", "postgresql", "mysql", "sqlite": return "sql"
        case "yaml", "yml", "toml", "ini", "dockerfile", "makefile": return "yaml"
        case "diff", "patch": return "diff"
        default: return nil
        }
    }

    private static let cLikeKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "struct", "union", "enum",
        "typedef", "static", "const", "void", "int", "char", "float", "double", "long", "short", "unsigned", "signed", "sizeof",
        "class", "public", "private", "protected", "namespace", "using", "template", "typename", "new", "delete", "nullptr", "true",
        "false", "auto", "inline", "virtual", "extern", "import", "package", "interface", "extends", "implements", "final", "try",
        "catch", "finally", "throw", "throws", "this", "super", "null", "boolean", "byte", "abstract", "override", "fun", "val",
        "var", "when", "object", "data", "sealed", "internal", "lateinit", "async", "await", "in", "is", "as", "operator", "string",
        "bool", "readonly", "get", "set", "yield", "defer",
    ]

    private static func spec(for language: String) -> Spec? {
        switch language {
        case "swift":
            Spec(keywords: ["let", "var", "func", "class", "struct", "enum", "protocol", "extension", "if", "else", "guard", "return",
                            "switch", "case", "default", "for", "while", "in", "import", "public", "private", "internal", "fileprivate",
                            "open", "static", "init", "deinit", "self", "super", "try", "catch", "throw", "throws", "rethrows", "async",
                            "await", "actor", "nil", "true", "false", "where", "as", "is", "some", "any", "final", "override", "mutating",
                            "nonisolated", "typealias", "associatedtype", "defer", "do", "break", "continue", "fallthrough", "lazy",
                            "weak", "unowned", "inout", "subscript", "operator", "macro", "repeat", "Self"])
        case "python":
            Spec(keywords: ["def", "class", "if", "elif", "else", "return", "import", "from", "as", "for", "while", "in", "not", "and",
                            "or", "is", "None", "True", "False", "try", "except", "finally", "raise", "with", "lambda", "yield", "pass",
                            "break", "continue", "async", "await", "global", "nonlocal", "del", "assert", "self"],
                 lineComments: ["#"], blockComment: nil, tripleQuotes: true)
        case "js":
            Spec(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default",
                            "break", "continue", "class", "extends", "new", "this", "super", "import", "from", "export", "async",
                            "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true",
                            "false", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static",
                            "void", "yield", "as", "declare", "namespace", "abstract", "delete", "get", "set"],
                 quotes: ["\"", "'", "`"])
        case "json":
            Spec(keywords: ["true", "false", "null"], lineComments: [], blockComment: nil, quotes: ["\""], typesByCapital: false)
        case "bash":
            Spec(keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function",
                            "return", "export", "local", "in", "set", "unset", "source", "cd", "echo", "exit", "readonly", "trap"],
                 lineComments: ["#"], blockComment: nil, typesByCapital: false)
        case "go":
            Spec(keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer",
                            "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "select", "nil",
                            "true", "false", "fallthrough", "goto"],
                 quotes: ["\"", "'", "`"])
        case "rust":
            Spec(keywords: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "crate", "self", "Self", "super",
                            "if", "else", "match", "for", "while", "loop", "return", "break", "continue", "as", "in", "where", "async",
                            "await", "move", "ref", "const", "static", "unsafe", "dyn", "true", "false", "None", "Some", "Ok", "Err", "type"],
                 quotes: ["\""])
        case "c":
            Spec(keywords: cLikeKeywords)
        case "java":
            Spec(keywords: cLikeKeywords)
        case "ruby":
            Spec(keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do",
                            "return", "yield", "begin", "rescue", "ensure", "nil", "true", "false", "self", "require", "attr_accessor",
                            "case", "when", "then", "and", "or", "not", "puts"],
                 lineComments: ["#"], blockComment: nil)
        case "sql":
            Spec(keywords: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter",
                            "drop", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "limit", "having", "as", "and",
                            "or", "not", "null", "primary", "key", "index", "distinct", "union", "all", "in", "is", "like", "between",
                            "exists", "case", "when", "then", "else", "end", "asc", "desc", "default", "references", "foreign", "with"],
                 lineComments: ["--"], quotes: ["'", "\""], caseInsensitive: true, typesByCapital: false)
        case "yaml":
            Spec(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], blockComment: nil, typesByCapital: false)
        default:
            nil
        }
    }

    // MARK: Scanner

    static func tokens(_ code: String, language: String) -> [Piece] {
        if language == "diff" { return diffTokens(code) }
        guard let spec = spec(for: language) else { return [Piece(text: code, token: .plain)] }
        let scalars = Array(code.unicodeScalars)
        let count = scalars.count
        var pieces: [Piece] = []
        var plainStart = 0
        var i = 0

        func flushPlain(to end: Int) {
            guard end > plainStart else { return }
            pieces.append(Piece(text: string(scalars[plainStart..<end]), token: .plain))
        }
        func emit(_ start: Int, _ end: Int, _ token: Token) {
            flushPlain(to: start)
            pieces.append(Piece(text: string(scalars[start..<end]), token: token))
            plainStart = end
        }
        func starts(with text: String, at index: Int) -> Bool {
            var position = index
            for scalar in text.unicodeScalars {
                guard position < count, scalars[position] == scalar else { return false }
                position += 1
            }
            return true
        }
        func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || scalar == "$" || scalar == "@" || (scalar.isASCII && CharacterSet.letters.contains(scalar))
        }
        func isIdentifierPart(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || scalar == "$" || (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar))
        }

        while i < count {
            let scalar = scalars[i]
            if spec.lineComments.contains(where: { starts(with: $0, at: i) }) {
                var end = i
                while end < count, scalars[end] != "\n" { end += 1 }
                emit(i, end, .comment)
                i = end
                continue
            }
            if let block = spec.blockComment, starts(with: block.open, at: i) {
                var end = i + block.open.unicodeScalars.count
                while end < count, !starts(with: block.close, at: end) { end += 1 }
                end = min(count, end + block.close.unicodeScalars.count)
                emit(i, end, .comment)
                i = end
                continue
            }
            let quote = Character(scalar)
            if spec.quotes.contains(quote) {
                let triple = spec.tripleQuotes && starts(with: String(repeating: String(quote), count: 3), at: i)
                var end = i + (triple ? 3 : 1)
                while end < count {
                    if scalars[end] == "\\" { end += 2; continue }
                    if triple {
                        if starts(with: String(repeating: String(quote), count: 3), at: end) { end += 3; break }
                    } else if scalars[end] == scalar {
                        end += 1
                        break
                    } else if scalars[end] == "\n", quote != "`" {
                        break
                    }
                    end += 1
                }
                end = min(count, end)
                // JSON keys read as names, values as strings.
                var token = Token.string
                if language == "json" {
                    var look = end
                    while look < count, scalars[look] == " " { look += 1 }
                    if look < count, scalars[look] == ":" { token = .type }
                }
                emit(i, end, token)
                i = end
                continue
            }
            if scalar.isASCII, CharacterSet.decimalDigits.contains(scalar), i == 0 || !isIdentifierPart(scalars[i - 1]) {
                var end = i + 1
                while end < count, isIdentifierPart(scalars[end]) || scalars[end] == "." { end += 1 }
                emit(i, end, .number)
                i = end
                continue
            }
            if isIdentifierStart(scalar) {
                var end = i + 1
                while end < count, isIdentifierPart(scalars[end]) { end += 1 }
                let word = string(scalars[i..<end])
                let probe = spec.caseInsensitive ? word.lowercased() : word
                if spec.keywords.contains(probe) {
                    emit(i, end, .keyword)
                } else {
                    var look = end
                    while look < count, scalars[look] == " " { look += 1 }
                    if look < count, scalars[look] == "(", language != "json" {
                        emit(i, end, .function)
                    } else if spec.typesByCapital, word.count > 1, let first = word.unicodeScalars.first, first.properties.isUppercase {
                        emit(i, end, .type)
                    }
                }
                i = end
                continue
            }
            i += 1
        }
        flushPlain(to: count)
        return pieces
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func diffTokens(_ code: String) -> [Piece] {
        var pieces: [Piece] = []
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let suffix = index < lines.count - 1 ? "\n" : ""
            let token: Token
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { token = .comment }
            else if line.hasPrefix("@@") { token = .type }
            else if line.hasPrefix("+") { token = .added }
            else if line.hasPrefix("-") { token = .removed }
            else { token = .plain }
            pieces.append(Piece(text: String(line) + suffix, token: token))
        }
        return pieces
    }
}
