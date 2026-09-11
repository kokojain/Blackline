import Foundation

/// Reads a `redact.txt` into a ``RuleSet`` (spec §4).
///
/// Grammar, one rule per line:
/// - A line whose first non-space character is `#` is a comment; blank lines are ignored.
/// - A quoted line is an exact literal match. The literal is everything between the first
///   and last `"`, so `"Apt #4"` needs no escaping.
/// - An optional `!` before the opening quote forces case-sensitive matching.
/// - Any other non-empty line is a category description, resolved through ``Category``.
///
/// Parsing never throws on bad content: unusable lines become ``Diagnostic``s and every
/// other rule still applies.
public struct RulesParser: Sendable {
    public struct Result: Sendable {
        public let ruleSet: RuleSet
        public let diagnostics: [Diagnostic]

        public init(ruleSet: RuleSet, diagnostics: [Diagnostic]) {
            self.ruleSet = ruleSet
            self.diagnostics = diagnostics
        }
    }

    public init() {}

    /// Why a rules file could not be read at all, as distinct from rules inside it being
    /// malformed — those are reported as ``Diagnostic``s and never throw.
    public enum FileError: Error, LocalizedError {
        /// The file is Rich Text, not plain text. TextEdit saves RTF by default, so this is
        /// the most likely reason a hand-made rules file appears empty: every rule ends up
        /// wrapped in markup and none of them parse.
        case richText(URL)
        /// The bytes are not text in any encoding Foundation could identify.
        case unreadableEncoding(URL)

        public var errorDescription: String? {
            switch self {
            case .richText(let url):
                """
                \(url.path) is a Rich Text file, not plain text, so none of its rules could be \
                read. TextEdit saves Rich Text by default — use Format ▸ Make Plain Text and \
                save again, or convert it with:
                  textutil -format rtf -convert txt "\(url.path)" -output "\(url.path)"
                """
            case .unreadableEncoding(let url):
                "\(url.path) could not be read as text in any known encoding."
            }
        }
    }

    /// Reads and parses a rules file. Throws only if the file cannot be read *as text*;
    /// malformed rules inside a readable file are reported through `Result.diagnostics`.
    public func parse(contentsOf url: URL) throws -> Result {
        let contents: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            contents = utf8
        } else {
            // A rules file edited on another platform may not be UTF-8; let Foundation
            // identify the encoding rather than failing on a file that is perfectly good.
            var encoding = String.Encoding.utf8
            guard let detected = try? String(contentsOf: url, usedEncoding: &encoding) else {
                throw FileError.unreadableEncoding(url)
            }
            contents = detected
        }

        guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\\rtf") else {
            throw FileError.richText(url)
        }
        return parse(contents)
    }

    public func parse(_ contents: String) -> Result {
        var exactRules: [ExactRule] = []
        var categoryRules: [CategoryRule] = []
        var diagnostics: [Diagnostic] = []
        var seenExact: Set<ExactKey> = []
        var seenCategories: Set<Category> = []

        for (offset, rawLine) in Self.splitLines(contents).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            func report(_ kind: Diagnostic.Kind) {
                diagnostics.append(Diagnostic(kind: kind, lineNumber: lineNumber, lineText: line))
            }

            var body = line
            var isCaseSensitive = false
            if body.hasPrefix("!") {
                isCaseSensitive = true
                body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            if body.hasPrefix("\"") {
                guard body.count >= 2, body.hasSuffix("\"") else {
                    report(.unterminatedQuote)
                    continue
                }
                let literal = String(body.dropFirst().dropLast())
                guard !literal.trimmingCharacters(in: .whitespaces).isEmpty else {
                    report(.emptyExactMatch)
                    continue
                }
                let key = ExactKey(literal: literal, isCaseSensitive: isCaseSensitive)
                guard seenExact.insert(key).inserted else {
                    report(.duplicateRule)
                    continue
                }
                exactRules.append(
                    ExactRule(literal: literal, isCaseSensitive: isCaseSensitive, lineNumber: lineNumber)
                )
            } else {
                // A `!` only means anything in front of a quoted literal.
                guard !isCaseSensitive else {
                    report(.caseSensitiveMarkerRequiresQuotes)
                    continue
                }
                guard !body.contains("\"") else {
                    report(.strayQuote)
                    continue
                }
                guard let category = Category.named(body) else {
                    report(.unknownCategory(body))
                    continue
                }
                guard seenCategories.insert(category).inserted else {
                    report(.duplicateRule)
                    continue
                }
                categoryRules.append(CategoryRule(category: category, lineNumber: lineNumber))
            }
        }

        return Result(
            ruleSet: RuleSet(exactRules: exactRules, categoryRules: categoryRules),
            diagnostics: diagnostics
        )
    }

    private struct ExactKey: Hashable {
        let literal: String
        let isCaseSensitive: Bool
    }

    /// Splits on LF, CRLF, or CR, and drops a leading byte-order mark, so a rules file
    /// edited on any platform parses the same way.
    static func splitLines(_ contents: String) -> [Substring] {
        var text = Substring(contents)
        if text.hasPrefix("\u{FEFF}") { text = text.dropFirst() }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }
}
