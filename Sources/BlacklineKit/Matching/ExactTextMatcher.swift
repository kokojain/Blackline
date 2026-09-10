import Foundation

/// Finds every occurrence of a literal string (spec §4, quoted rules).
///
/// Per §4 the literal is redacted "wherever it appears", so this is a substring search —
/// `"art"` matches inside `"Smart"`. Matching is case-insensitive unless the rule carries
/// a `!` prefix. Diacritics are significant: `"Café"` does not match `"Cafe"`.
public struct ExactTextMatcher: Matcher {
    public let rule: ExactRule
    /// The literal, normalized the same way page text is, so a rule written with single
    /// spaces still matches text that wrapped across a line.
    private let needle: String

    public var source: MatchSource { .exact(rule) }

    public init(rule: ExactRule) {
        self.rule = rule
        self.needle = SourceText.normalize(rule.literal)
    }

    public init(literal: String, isCaseSensitive: Bool = false) {
        self.init(rule: ExactRule(literal: literal, isCaseSensitive: isCaseSensitive))
    }

    public func matches(in text: SourceText) -> [Match] {
        // A rule that normalizes to nothing would match endlessly; the parser rejects such
        // rules, but guard anyway rather than hang on a hand-built matcher.
        guard !needle.isEmpty else { return [] }

        let haystack = text.normalized
        let options: String.CompareOptions = rule.isCaseSensitive ? [] : [.caseInsensitive]

        var results: [Match] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let found = haystack.range(
                  of: needle,
                  options: options,
                  range: searchStart ..< haystack.endIndex
              ) {
            if let originalRange = text.originalRange(forNormalized: found) {
                results.append(
                    Match(
                        range: originalRange,
                        matchedText: String(text.original[originalRange]),
                        source: source
                    )
                )
            }
            // Occurrences do not overlap: resume after this one.
            searchStart = found.upperBound > found.lowerBound
                ? found.upperBound
                : haystack.index(after: found.lowerBound)
        }
        return results
    }
}
