import Foundation

/// Secret masking for everything that goes into a pack (LOMBOT §5): best effort, pattern by pattern, run on the text
/// before it is cut to size (a cut must never leave half of a secret) and once more over the whole pack. A match is
/// replaced by `marker`; for `password=` and its kind only the value goes, so the line still says what it was.
public enum RemoraSecretMask {
    public static let marker = "[masked]"

    private struct Rule {
        let expression: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        func rule(_ pattern: String, _ template: String = marker, options: NSRegularExpression.Options = []) -> Rule {
            // The patterns are literals of this file; a typo is a programmer error found by the tests.
            // swiftlint:disable:next force_try
            Rule(expression: try! NSRegularExpression(pattern: pattern, options: options), template: template)
        }
        return [
            // PEM blocks first: their body would otherwise be cut up by the later patterns. A block whose END line was
            // cut off by an excerpt's bound is masked to the end of the text.
            rule("-----BEGIN [A-Z0-9 ]+-----[\\s\\S]*?(?:-----END [A-Z0-9 ]+-----|\\z)"),
            // Anthropic and OpenAI style keys: sk-..., sk-ant-..., sk-proj-...
            rule("\\bsk-[A-Za-z0-9_\\-]{16,}"),
            // GitHub tokens: ghp_, gho_, ghu_, ghs_, ghr_ and the fine-grained github_pat_.
            rule("\\bgh[pousr]_[A-Za-z0-9]{16,}"),
            rule("\\bgithub_pat_[A-Za-z0-9_]{16,}"),
            // AWS access key ids (long-lived AKIA, temporary ASIA).
            rule("\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b"),
            // An Authorization header's bearer token.
            rule("\\bBearer\\s+[A-Za-z0-9._~+/=\\-]{8,}", "Bearer \(marker)", options: [.caseInsensitive]),
            // key=value, key: value, "key": "value" for the names that hold secrets; the value goes, the name stays.
            rule("(password|passwd|token|secret|api[_-]?key|access[_-]?key)\\b([\"']?\\s*[:=]\\s*)(\"[^\"\\n]*\"|'[^'\\n]*'|[^\\s\"',;&]+)",
                 "$1$2\(marker)", options: [.caseInsensitive]),
        ]
    }()

    public static func mask(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.expression.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: rule.template)
        }
        return result
    }
}
