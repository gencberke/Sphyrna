import Foundation
import Testing

/// Remora's reach, pinned (1.6.0 acceptance item 5: "Every model call Sphyrna makes on its own is listed, measured and under
/// its ceiling … Guards fail when either grows"). The suite scans every `.swift` file under the repo's `Sources/`, comments
/// and string literals stripped, and compares what it counts with an exact allow-list. A new site fails it, and so does a
/// removed one, so the lists stay the true ones. A new path to a model call is a reviewed change to these lists, made in the
/// commit that adds it (the Home views' call, for one).
///
/// "Nothing runs by itself" has two halves here: the only automatic entry (`briefIfDue`) is called from one place, and no
/// timer, watcher, observer or delayed hop exists in Remora's own files.
struct RemoraReachTests {
    // MARK: The allow-lists (path relative to the repo, then its count)

    static let host = "Sources/LoomRemora/RemoraHost.swift"
    static let model = "Sources/LoomCatalogUI/CatalogModel+Remora.swift"

    /// `RemoraHost(` constructions: the app makes the one host, in `installRemora`.
    static let hostConstructions: [String: Int] = [model: 1]
    /// `RemoraCall(` constructions: the host's `makeCall` is the one place a call process is made.
    static let callConstructions: [String: Int] = [host: 1]
    /// Files that name the type `RemoraHost` as a whole word: the host and the model API that forwards to it.
    static let hostNamers: Set<String> = [host, model]
    /// Calls of the unasked entry `briefIfDue(`: the model's `briefRemoraIfDue`.
    static let unaskedCalls: [String: Int] = [model: 1]
    /// Calls of the model API's three entries (`askRemora(`, `briefRemora(` and `briefRemoraIfDue(`, summed for each file), where each is
    /// written. Home's calls are all in one file (L3b): the automatic brief when Home shows (1), Catch Me Up, Catch Me Up Anyway and Try Again
    /// of a brief (1) and the field's question (1). The evidence command file counts too (`remora-brief`, `remora-ask`). ⌘K's Ask and the
    /// new-session page's brief (L3c) will add their own.
    static let homeCalls = "Sources/LoomCatalogUI/HomeRemoraCalls.swift"
    static let evidenceCalls = "Sources/loom-app/Evidence/EvidenceRemoraCommands.swift"
    static let modelAPICalls: [String: Int] = [homeCalls: 3, evidenceCalls: 2]

    /// Names that would make something run by itself, in Remora's files.
    static let selfStarting = ["Timer", "DispatchSource", "NWPathMonitor", "FSEventStream", "NotificationCenter", "asyncAfter", "Task.sleep"]

    // MARK: The scan

    struct SourceFile {
        let path: String
        let code: String
    }

    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every `.swift` file under `Sources/`, comments and string literals blanked out.
    static let files: [SourceFile] = {
        let sources = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return [] }
        var found: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = String(url.path.dropFirst(repoRoot.path.count + 1))
            found.append(SourceFile(path: path, code: Matcher.code(of: text)))
        }
        return found.sorted { $0.path < $1.path }
    }()

    /// A path with its count, for the files whose count is not zero.
    static func counts(of name: String, calls: Bool = true, in files: [SourceFile] = files) -> [String: Int] {
        var result: [String: Int] = [:]
        for file in files {
            let count = calls ? Matcher.calls(of: name, in: file.code) : Matcher.words(name, in: file.code)
            if count > 0 { result[file.path] = count }
        }
        return result
    }

    /// One message per file whose count differs from the allow-list.
    static func differences(_ rule: String, found: [String: Int], allowed: [String: Int]) -> [String] {
        var messages: [String] = []
        for path in Set(found.keys).union(allowed.keys).sorted() where found[path, default: 0] != allowed[path, default: 0] {
            messages.append("\(rule): \(path) has \(found[path, default: 0]), the list allows \(allowed[path, default: 0]). "
                + "A new path to a model call is a reviewed change to the allow-list in RemoraReachTests.swift; a removed one must leave it too.")
        }
        return messages
    }

    // MARK: The rules

    @Test func theHostIsMadeInOnePlace() {
        let messages = Self.differences("RemoraHost(", found: Self.counts(of: "RemoraHost"), allowed: Self.hostConstructions)
        #expect(messages.isEmpty, "\(messages)")
    }

    @Test func theCallProcessIsMadeInOnePlace() {
        let messages = Self.differences("RemoraCall(", found: Self.counts(of: "RemoraCall"), allowed: Self.callConstructions)
        #expect(messages.isEmpty, "\(messages)")
    }

    @Test func onlyTheHostAndTheModelAPINameTheHost() {
        let found = Set(Self.counts(of: "RemoraHost", calls: false).keys)
        #expect(found == Self.hostNamers,
                "files naming RemoraHost: \(found.sorted()); the list allows \(Self.hostNamers.sorted()). A new path to a model call is a reviewed change to the allow-list in RemoraReachTests.swift.")
    }

    @Test func theUnaskedEntryIsCalledFromOnePlace() {
        let messages = Self.differences("briefIfDue(", found: Self.counts(of: "briefIfDue"), allowed: Self.unaskedCalls)
        #expect(messages.isEmpty, "\(messages)")
    }

    @Test func theModelAPIIsCalledOnlyFromTheListedFiles() {
        var found: [String: Int] = [:]
        for name in ["askRemora", "briefRemora", "briefRemoraIfDue"] {
            for (path, count) in Self.counts(of: name) { found[path, default: 0] += count }
        }
        let messages = Self.differences("askRemora( / briefRemora( / briefRemoraIfDue(", found: found, allowed: Self.modelAPICalls)
        #expect(messages.isEmpty, "\(messages)")
    }

    @Test func nothingInRemorasFilesStartsByItself() {
        let own = Self.files.filter { $0.path.hasPrefix("Sources/LoomRemora/") || $0.path == Self.model }
        var found: [String: Int] = [:]
        for name in Self.selfStarting {
            for (path, count) in Self.counts(of: name, calls: false, in: own) { found["\(path) (\(name))", default: 0] += count }
        }
        let messages = Self.differences("self-starting names", found: found, allowed: [:])
        #expect(messages.isEmpty, "\(messages) Remora runs only when the app calls it: no timer, watcher or delayed hop.")
    }

    // MARK: Controls

    @Test func theScanSawTheFilesItMust() {
        let paths = Set(Self.files.map(\.path))
        #expect(Self.files.count >= 300, "the scan saw only \(Self.files.count) files under \(Self.repoRoot.path)/Sources")
        for must in [Self.host, Self.model, "Sources/LoomRemora/RemoraCall.swift", "Sources/LoomRemora/RemoraMemory.swift"] {
            #expect(paths.contains(must), "the scan missed \(must)")
        }
        // The files the lists name carry what the lists say (so a scan that blanked everything fails here, not silently).
        #expect(Self.files.first { $0.path == Self.host }.map { Matcher.words("RemoraHost", in: $0.code) > 0 } == true)
        #expect(Self.files.first { $0.path == Self.host }.map { Matcher.calls(of: "RemoraCall", in: $0.code) } == 1)
    }

    @Test func theMatcherFlagsACallInCodeAndIgnoresTheNameInACommentAStringOrADeclaration() {
        let planted = """
        // briefIfDue( in a line comment
        /// RemoraHost( in a doc comment
        /* RemoraCall( in a block comment /* and a nested one */ still a comment briefIfDue( */
        let plain = "briefIfDue( in a string"
        let escaped = "a \\" quote, then briefIfDue("
        let raw = #"RemoraHost( "quoted" in a raw string"#
        let many = \"\"\"
            briefIfDue(
            RemoraCall(
            \"\"\"
        func briefIfDue(homeShown: Bool) {}
        func   briefIfDue(again: Bool) {}
        let ok = host.briefIfDue(homeShown: true)
        let other = host.briefIfDueLater(1) + XbriefIfDue(2)
        let inside = "\\(host.briefIfDue(inInterpolation: true))"
        let created = RemoraHost(dataRoot: root)
        let mentioned = RemoraHostAnswer(x: 1) as RemoraHost
        let delay = Task.sleep(for: .seconds(1)) // and Timer in a comment
        """
        let code = Matcher.code(of: planted)
        #expect(Matcher.calls(of: "briefIfDue", in: code) == 2, "the call in code and the one in an interpolation, nothing else")
        #expect(Matcher.calls(of: "RemoraHost", in: code) == 1)
        #expect(Matcher.calls(of: "RemoraCall", in: code) == 0)
        #expect(Matcher.words("RemoraHost", in: code) == 2, "a whole word: RemoraHostAnswer is another name")
        #expect(Matcher.words("Task.sleep", in: code) == 1 && Matcher.words("Timer", in: code) == 0)
        // The same text, untouched, is what a naive scan would have counted.
        #expect(Matcher.calls(of: "briefIfDue", in: planted) > 2)
        // Line numbers survive blanking, so a failure can point at a line.
        #expect(code.split(separator: "\n", omittingEmptySubsequences: false).count == planted.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    @Test func aPlantedSecondCallFailsTheListComparison() {
        let planted = SourceFile(path: "Sources/LoomRemora/RemoraHost.swift", code: Matcher.code(of: """
            func extra() async { _ = await briefIfDue(homeShown: true, windowRemainingShare: nil) }
            """))
        let found = Self.counts(of: "briefIfDue", in: Self.files.filter { $0.path != Self.host } + [planted])
        let messages = Self.differences("briefIfDue(", found: found, allowed: Self.unaskedCalls)
        #expect(messages.count == 1 && messages[0].contains(Self.host) && messages[0].contains("has 1, the list allows 0"), "\(messages)")
    }
}

/// Comment and string stripping, then counting; pure functions over text.
enum Matcher {
    /// `text` with comments and string literals blanked to spaces (newlines kept). Interpolations inside a string stay as code:
    /// they run.
    static func code(of text: String) -> String {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        scan(bytes, &index, &output, closing: false)
        return String(decoding: output, as: UTF8.self)
    }

    private static let quote = UInt8(ascii: "\""), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), backslash = UInt8(ascii: "\\")
    private static let newline = UInt8(ascii: "\n"), hash = UInt8(ascii: "#"), open = UInt8(ascii: "("), close = UInt8(ascii: ")")

    private static func blank(_ byte: UInt8) -> UInt8 { byte == newline ? newline : UInt8(ascii: " ") }

    /// Copies code, blanks comments and strings. With `closing`, stops at the `)` that ends an interpolation.
    private static func scan(_ b: [UInt8], _ i: inout Int, _ out: inout [UInt8], closing: Bool) {
        var depth = 0
        while i < b.count {
            let c = b[i]
            let next: UInt8? = i + 1 < b.count ? b[i + 1] : nil
            if c == slash, next == slash {
                while i < b.count, b[i] != newline { out.append(UInt8(ascii: " ")); i += 1 }
            } else if c == slash, next == star {
                var nesting = 0
                repeat {
                    if i + 1 < b.count, b[i] == slash, b[i + 1] == star { nesting += 1; out += [32, 32]; i += 2 }
                    else if i + 1 < b.count, b[i] == star, b[i + 1] == slash { nesting -= 1; out += [32, 32]; i += 2 }
                    else { out.append(blank(b[i])); i += 1 }
                } while nesting > 0 && i < b.count
            } else if c == quote || (c == hash && rawStringStarts(b, i)) {
                string(b, &i, &out)
            } else if closing, c == open {
                depth += 1; out.append(c); i += 1
            } else if closing, c == close {
                if depth == 0 { return }
                depth -= 1; out.append(c); i += 1
            } else {
                out.append(c); i += 1
            }
        }
    }

    private static func rawStringStarts(_ b: [UInt8], _ i: Int) -> Bool {
        var j = i
        while j < b.count, b[j] == hash { j += 1 }
        return j < b.count && b[j] == quote
    }

    /// At the opening of a string literal (`"`, `"""`, `#"`, `##"""` …): blanks it, scanning interpolations as code.
    private static func string(_ b: [UInt8], _ i: inout Int, _ out: inout [UInt8]) {
        var hashes = 0
        while i < b.count, b[i] == hash { hashes += 1; out.append(32); i += 1 }
        let multiline = i + 2 < b.count && b[i + 1] == quote && b[i + 2] == quote
        let delimiter = multiline ? 3 : 1
        out += Array(repeating: 32, count: delimiter)
        i += delimiter
        while i < b.count {
            let c = b[i]
            if c == backslash, hasHashes(b, i + 1, hashes), i + 1 + hashes < b.count {
                let after = b[i + 1 + hashes]
                if after == open {
                    out += Array(repeating: 32, count: 1 + hashes)
                    out.append(open)
                    i += 2 + hashes
                    scan(b, &i, &out, closing: true)
                    if i < b.count { out.append(close); i += 1 }
                } else {
                    out += Array(repeating: UInt8(ascii: " "), count: 1 + hashes)
                    out.append(blank(after))
                    i += 2 + hashes
                }
            } else if c == quote, closes(b, i, delimiter: delimiter, hashes: hashes) {
                out += Array(repeating: 32, count: delimiter + hashes)
                i += delimiter + hashes
                return
            } else if c == newline, !multiline {
                return
            } else {
                out.append(blank(c)); i += 1
            }
        }
    }

    private static func hasHashes(_ b: [UInt8], _ from: Int, _ count: Int) -> Bool {
        guard from + count <= b.count else { return false }
        return (0..<count).allSatisfy { b[from + $0] == hash }
    }

    private static func closes(_ b: [UInt8], _ i: Int, delimiter: Int, hashes: Int) -> Bool {
        guard i + delimiter + hashes <= b.count else { return false }
        return (0..<delimiter).allSatisfy { b[i + $0] == quote } && hasHashes(b, i + delimiter, hashes)
    }

    private static let identifier = "A-Za-z0-9_"

    /// Call expressions of `name`: the identifier, whole, followed by `(`, and not a `func` declaration.
    static func calls(of name: String, in code: String) -> Int {
        let pattern = "(?<![\(identifier)])\(NSRegularExpression.escapedPattern(for: name))\\s*\\("
        return matches(pattern, in: code).filter { !isDeclaration(at: $0, in: code) }.count
    }

    /// `name` as a whole word (not a prefix or suffix of a longer identifier), calls or not.
    static func words(_ name: String, in code: String) -> Int {
        let pattern = "(?<![\(identifier)])\(NSRegularExpression.escapedPattern(for: name))(?![\(identifier)])"
        return matches(pattern, in: code).count
    }

    private static func matches(_ pattern: String, in code: String) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(code.startIndex..., in: code)
        return expression.matches(in: code, range: whole).compactMap { Range($0.range, in: code) }
    }

    /// Whether the text just before the match is the keyword `func`.
    private static func isDeclaration(at range: Range<String.Index>, in code: String) -> Bool {
        var before = code[..<range.lowerBound]
        while let last = before.last, last == " " || last == "\t" { before = before.dropLast() }
        guard before.hasSuffix("func") else { return false }
        let head = before.dropLast(4)
        guard let previous = head.last else { return true }
        return !(previous.isLetter || previous.isNumber || previous == "_")
    }
}
