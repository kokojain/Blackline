import Foundation

/// Shared plumbing for the matchers backed by `NSDataDetector` (spec §5.3, "`NSDataDetector`
/// for addresses").
///
/// The same contract as ``RegexMatcher``: the detector runs against ``SourceText/normalized``
/// — which is what lets it see an address that wrapped across three lines as one string —
/// and the spans it reports are translated back into the original text the redactor has to
/// black out.
///
/// `NSDataDetector` subclasses `NSRegularExpression`, which is `NS_SWIFT_SENDABLE`.
struct DataDetectorMatcher: Sendable {
    let detector: NSDataDetector
    /// Narrows or rejects a result the detector's own type is too generous about. It
    /// receives the span the detector reported and returns the span to redact — the same
    /// one, a narrower one, or `nil` to drop the match. Narrowing matters because a
    /// detector that over-reaches blacks out the field *beside* the value.
    let refine: (@Sendable (NSTextCheckingResult, Substring) -> Substring?)?

    init(
        types: NSTextCheckingResult.CheckingType,
        refine: (@Sendable (NSTextCheckingResult, Substring) -> Substring?)? = nil
    ) {
        // A fixed set of checking types; a failure here is a programming error.
        self.detector = try! NSDataDetector(types: types.rawValue)
        self.refine = refine
    }

    func matches(in text: SourceText, source: MatchSource) -> [Match] {
        let haystack = text.normalized
        let fullRange = NSRange(haystack.startIndex ..< haystack.endIndex, in: haystack)

        var results: [Match] = []
        detector.enumerateMatches(in: haystack, options: [], range: fullRange) { result, _, _ in
            guard let result, let range = Range(result.range, in: haystack) else { return }
            let span = refine.map { $0(result, haystack[range]) } ?? haystack[range]
            guard let span, !span.isEmpty,
                  let originalRange = text.originalRange(
                      forNormalized: span.startIndex ..< span.endIndex
                  )
            else { return }
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
