import Foundation

/// Shared plumbing for the pattern-driven matchers (spec §5.3, "curated regex patterns
/// for structured identifiers").
///
/// `NSRegularExpression` is `NS_SWIFT_SENDABLE`, so this is `Sendable` without escape
/// hatches. Patterns run against ``SourceText/normalized``; the reported span is one
/// capture group, letting a matcher use surrounding context as evidence without redacting
/// the context itself.
struct RegexMatcher: Sendable {
    /// Extra evidence a validator may consult beyond the captured text.
    struct Context {
        let result: NSTextCheckingResult
        let text: SourceText
        /// The span between the start of the whole match and the start of the capture —
        /// i.e. the label or prefix that qualified the candidate.
        let prefixRange: NSRange
    }

    let regex: NSRegularExpression
    /// Which capture group is the span to redact. 0 is the whole match.
    let captureGroup: Int
    /// Rejects a candidate the pattern alone cannot disqualify (a checksum, a proximity
    /// rule). Returning `false` drops the match.
    let validate: (@Sendable (String, Context) -> Bool)?

    init(
        pattern: String,
        options: NSRegularExpression.Options = [],
        captureGroup: Int = 0,
        validate: (@Sendable (String, Context) -> Bool)? = nil
    ) {
        // These patterns are compile-time constants in this module; a failure here is a
        // programming error, not a runtime condition.
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
        self.captureGroup = captureGroup
        self.validate = validate
    }

    func matches(in text: SourceText, source: MatchSource) -> [Match] {
        let haystack = text.normalized
        let fullRange = NSRange(haystack.startIndex ..< haystack.endIndex, in: haystack)

        var results: [Match] = []
        regex.enumerateMatches(in: haystack, options: [], range: fullRange) { result, _, _ in
            guard let result else { return }
            let captured = result.range(at: min(captureGroup, result.numberOfRanges - 1))
            guard captured.location != NSNotFound,
                  let capturedRange = Range(captured, in: haystack)
            else { return }

            let capturedText = String(haystack[capturedRange])
            if let validate {
                let whole = result.range
                let prefix = NSRange(
                    location: whole.location,
                    length: max(0, captured.location - whole.location)
                )
                let context = Context(result: result, text: text, prefixRange: prefix)
                guard validate(capturedText, context) else { return }
            }

            guard let originalRange = text.originalRange(forNormalized: capturedRange) else { return }
            results.append(
                Match(
                    range: originalRange,
                    matchedText: String(text.original[originalRange]),
                    source: source
                )
            )
        }
        return results
    }
}
