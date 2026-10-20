import Foundation

/// Whether a Bash command line can be proven to change nothing (V22: a side chat answers `can_use_tool` for Bash itself, S6 Q2:
/// the model routes around a refused `Write` through `echo > file`). A pure function. Anything it cannot prove read-only is
/// "may write": refusing a harmless command is fine, allowing a writing one is not.
///
/// The shell's grammar is read just far enough to be sure of what runs:
/// - **May write:** command or process substitution (`$(`, backtick, `<(`, `>(`) and every other `$` outside single quotes; every
///   redirection except `>/dev/null`, `2>/dev/null`, `&>/dev/null` and `2>&1`; `;`, `&&`, `||`, `&`, newlines, heredocs, groups
///   and subshells; a leading variable assignment; and any program not listed below (`sudo`, `env`, `xargs`, `eval`, `exec`,
///   `sh -c`, `tee`, `sed`, `awk`, …).
/// - **Pipes** are allowed when every part is read-only.
/// - **The programs** below, some with flag rules: a flag that writes a file, runs a program or follows forever makes the line
///   may-write.
public enum ReadOnlyCommand {
    public static func isReadOnly(_ command: String) -> Bool {
        guard let segments = parse(command) else { return false }
        return segments.allSatisfy(isReadOnlySegment)
    }

    // MARK: Reading the line

    /// The words of each pipeline stage, quotes removed; nil for anything the rules above refuse.
    static func parse(_ text: String) -> [[String]]? {
        let chars = Array(text)
        let count = chars.count
        var segments: [[String]] = []
        var words: [String] = []
        var current = ""
        var inWord = false
        var index = 0

        func endWord() {
            if inWord { words.append(current) }
            current = ""
            inWord = false
        }
        func isBoundary(_ c: Character) -> Bool { c == " " || c == "\t" || c == "|" || c == "&" }
        /// After `>` or `&>`: blanks, then a word that must be `/dev/null`, ending at a boundary or the end.
        func readNullTarget() -> Bool {
            while index < count, chars[index] == " " || chars[index] == "\t" { index += 1 }
            let target = "/dev/null"
            let end = index + target.count
            guard end <= count, String(chars[index..<end]) == target, end == count || isBoundary(chars[end]) else { return false }
            index = end
            return true
        }

        while index < count {
            let c = chars[index]
            switch c {
            case "'":
                inWord = true
                index += 1
                while index < count, chars[index] != "'" { current.append(chars[index]); index += 1 }
                guard index < count else { return nil }
                index += 1
            case "\"":
                inWord = true
                index += 1
                while index < count, chars[index] != "\"" {
                    let d = chars[index]
                    if d == "$" || d == "`" || d == "\n" || d == "\r" { return nil }
                    if d == "\\" {
                        guard index + 1 < count else { return nil }
                        let e = chars[index + 1]
                        if e == "$" || e == "`" || e == "\n" || e == "\r" { return nil }
                        if e == "\"" || e == "\\" { current.append(e); index += 2; continue }
                    }
                    current.append(d)
                    index += 1
                }
                guard index < count else { return nil }
                index += 1
            case "\\":
                guard index + 1 < count, chars[index + 1] != "\n", chars[index + 1] != "\r" else { return nil }
                inWord = true
                current.append(chars[index + 1])
                index += 2
            case "$", "`", "<", "(", ")", ";", "\n", "\r":
                return nil
            case " ", "\t":
                endWord()
                index += 1
            case "|":
                guard index + 1 >= count || (chars[index + 1] != "|" && chars[index + 1] != "&") else { return nil }
                endWord()
                guard !words.isEmpty else { return nil }
                segments.append(words)
                words = []
                index += 1
            case "&":
                // Only `&>/dev/null`: a background job, `&&` and `|&` are refused.
                guard index + 1 < count, chars[index + 1] == ">" else { return nil }
                endWord()
                index += 2
                guard index >= count || chars[index] != ">", readNullTarget() else { return nil }
            case ">":
                // `>/dev/null` and `2>/dev/null` (and `1>`), or exactly `2>&1`.
                var descriptor = ""
                if inWord, !current.isEmpty, current.allSatisfy(\.isNumber) { descriptor = current; current = ""; inWord = false }
                else { endWord() }
                index += 1
                guard index < count else { return nil }
                if chars[index] == "&" {
                    guard descriptor == "2", index + 1 < count, chars[index + 1] == "1",
                          index + 2 == count || isBoundary(chars[index + 2]) else { return nil }
                    index += 2
                } else {
                    guard ["", "1", "2"].contains(descriptor), chars[index] != ">", chars[index] != "|", readNullTarget() else { return nil }
                }
            default:
                inWord = true
                current.append(c)
                index += 1
            }
        }
        endWord()
        guard !words.isEmpty else { return nil }
        segments.append(words)
        return segments
    }

    // MARK: The programs

    private static func isReadOnlySegment(_ words: [String]) -> Bool {
        guard let program = words.first else { return false }
        let arguments = Array(words.dropFirst())
        switch program {
        case "ls", "cat", "head", "wc", "pwd", "echo", "printf", "which", "type", "stat", "du", "df", "cut", "tr",
             "diff", "cmp", "comm", "nl", "column", "basename", "dirname", "realpath", "readlink", "uname", "jq",
             "od", "hexdump", "true", "false", "test", "[":
            return true
        case "grep", "egrep", "fgrep":
            return true
        case "tail":
            // `-f` follows the file for ever.
            return !arguments.contains { $0 == "--follow" || $0.hasPrefix("--follow=") || shortFlags($0).contains("f") || shortFlags($0).contains("F") }
        case "rg":
            return !arguments.contains { $0 == "--pre" || $0.hasPrefix("--pre=") || $0 == "--hostname-bin" || $0.hasPrefix("--hostname-bin=") }
        case "find":
            return !arguments.contains { argument in
                argument == "-delete" || argument.hasPrefix("-exec") || argument.hasPrefix("-ok")
                    || argument.hasPrefix("-fprint") || argument == "-fls"
            }
        case "sort":
            return !arguments.contains { argument in
                argument == "--output" || argument.hasPrefix("--output=") || argument.hasPrefix("--compress-program")
                    || shortFlags(argument).contains("o")
            }
        case "tree":
            return !arguments.contains { $0 == "--output" || shortFlags($0).contains("o") }
        case "file":
            return !arguments.contains { $0 == "--compile" || shortFlags($0).contains("C") }
        case "uniq", "xxd":
            // `uniq in out` and `xxd in out` write the second path.
            return arguments.filter { !$0.hasPrefix("-") || $0 == "-" }.count <= 1
        case "date":
            return !arguments.contains { $0 == "--set" || $0.hasPrefix("--set=") || shortFlags($0).contains("s") }
        case "git":
            return isReadOnlyGit(arguments)
        default:
            return false
        }
    }

    /// The letters of a short-flag cluster (`-abc`), none for a long flag or a word.
    private static func shortFlags(_ argument: String) -> [Character] {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1 else { return [] }
        return Array(argument.dropFirst())
    }

    // MARK: git

    private static func isReadOnlyGit(_ arguments: [String]) -> Bool {
        var rest = arguments[...]
        // The only options before the subcommand: where to look, and no pager.
        while let first = rest.first {
            if first == "--no-pager" { rest = rest.dropFirst() }
            else if first == "-C", rest.count >= 2 { rest = rest.dropFirst(2) }
            else { break }
        }
        guard let subcommand = rest.first, !subcommand.hasPrefix("-") else { return false }
        let options = Array(rest.dropFirst())
        if options.contains(where: { $0.hasPrefix("--output") }) { return false }
        switch subcommand {
        case "status", "log", "diff", "show", "blame", "rev-parse", "ls-files", "describe":
            return true
        case "grep":
            return !options.contains { $0 == "--open-files-in-pager" || $0.hasPrefix("--open-files-in-pager=") || $0.hasPrefix("-O")
                || shortFlags($0).contains("O") }
        case "remote":
            return options.isEmpty || options == ["-v"] || options == ["--verbose"]
        case "config":
            let getters: Set = ["--get", "--get-all", "--get-regexp"]
            let scopes: Set = ["--local", "--global", "--system", "--worktree", "--show-origin", "--show-scope"]
            return options.contains(where: getters.contains) && options.allSatisfy { getters.contains($0) || scopes.contains($0) || !$0.hasPrefix("-") }
        case "branch":
            return isGitBranchListing(options)
        default:
            return false
        }
    }

    /// `git branch` lists, or creates one when it gets a name. Only flags that list are allowed, and names only after `--list`.
    private static func isGitBranchListing(_ options: [String]) -> Bool {
        let flags: Set = ["-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "--show-current", "--no-color", "--color",
                          "--column", "--no-column", "-i", "--ignore-case"]
        let listing: Set = ["--list", "-l"]
        let takingValue: Set = ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at"]
        var lists = false
        var positional = false
        var index = 0
        while index < options.count {
            let option = options[index]
            if listing.contains(option) { lists = true }
            else if takingValue.contains(option) { lists = true; index += 1; guard index < options.count else { return false } }
            else if option.hasPrefix("--sort=") || option.hasPrefix("--format=") || option.hasPrefix("--color=") { }
            else if flags.contains(option) { }
            else if option.hasPrefix("-") { return false }
            else { positional = true }
            index += 1
        }
        return !positional || lists
    }
}
