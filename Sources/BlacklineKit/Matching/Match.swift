import Foundation

/// What caused a span of text to be redacted.
///
/// Spec §7 requires the completion notification to state how many items were redacted and
/// by which rules, so provenance travels with every match.
public enum MatchSource: Hashable, Sendable {
    case exact(ExactRule)
    case category(Category)

    /// A short description of the rule, for the completion notification.
    public var ruleDescription: String {
        switch self {
        case .exact(let rule):
            "“\(rule.literal)”"
        case .category(let category):
            category.canonicalName
        }
    }
}

/// One span of text to redact.
public struct Match: Hashable, Sendable {
    /// The span in ``SourceText/original``.
    public let range: Range<String.Index>
    /// The text covered by `range`, including any line break the span crosses.
    public let matchedText: String
    /// The rule that produced this match.
    public let source: MatchSource

    public init(range: Range<String.Index>, matchedText: String, source: MatchSource) {
        self.range = range
        self.matchedText = matchedText
        self.source = source
    }
}
