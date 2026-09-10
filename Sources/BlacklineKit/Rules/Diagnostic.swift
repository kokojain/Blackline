import Foundation

/// A non-fatal problem found while parsing `redact.txt`.
///
/// Spec §4 requires unusable lines to produce "a gentle warning… rather than failing
/// silently", so parsing never throws: the offending line is skipped and reported here
/// while every other rule in the file still takes effect.
public struct Diagnostic: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A line opened with `"` but did not close with one.
        case unterminatedQuote
        /// An unquoted description contained a `"`, which is almost always a typo.
        case strayQuote
        /// A quoted rule with nothing (or only whitespace) between the quotes.
        case emptyExactMatch
        /// A `!` prefix on something other than a quoted literal.
        case caseSensitiveMarkerRequiresQuotes
        /// A description outside the documented category vocabulary.
        case unknownCategory(String)
        /// The same rule appeared earlier in the file; only the first is kept.
        case duplicateRule
    }

    public let kind: Kind
    /// 1-based line number in the source file.
    public let lineNumber: Int
    /// The offending line, trimmed, for echoing back to the user.
    public let lineText: String

    public init(kind: Kind, lineNumber: Int, lineText: String) {
        self.kind = kind
        self.lineNumber = lineNumber
        self.lineText = lineText
    }

    /// A short, user-facing explanation suitable for the completion notification.
    public var message: String {
        switch kind {
        case .unterminatedQuote:
            "Line \(lineNumber): missing a closing quote — this rule was skipped."
        case .strayQuote:
            "Line \(lineNumber): unexpected quote in a description — quote the whole line for an exact match."
        case .emptyExactMatch:
            "Line \(lineNumber): empty quoted rule — this rule was skipped."
        case .caseSensitiveMarkerRequiresQuotes:
            "Line \(lineNumber): the ! prefix only applies to quoted exact matches."
        case .unknownCategory(let description):
            "Line \(lineNumber): “\(description)” isn’t a category Blackline recognizes — this rule was skipped."
        case .duplicateRule:
            "Line \(lineNumber): duplicate of an earlier rule — ignored."
        }
    }
}
