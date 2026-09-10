import Foundation

/// Detects bank and general account numbers (spec §5.3).
///
/// Unlike an SSN or a card number, an account number has no format of its own: US bank
/// accounts run roughly 8–17 digits with no checksum and no fixed prefix, so `000123456789`
/// and an invoice total are indistinguishable as strings. Format is evidence of *shape*,
/// not of sensitivity — what qualifies a number here is its **context**.
///
/// A candidate therefore matches only when an Account / Acct / A/C / Routing / ABA / IBAN /
/// Card label appears shortly before it, within 40 characters and crossing at most one line
/// break. The one-line-break allowance covers the very common statement layout that puts
/// the label on its own line above the value. The label itself is never part of the
/// redacted span.
///
/// IBANs carry enough structure to stand alone and are matched without a label.
///
/// Unlabeled digit runs are available through ``init(includeUnlabeledDigitRuns:minUnlabeledDigits:)``
/// but are **off by default**: without context they flag ordinary long numbers — a bare
/// ten-digit phone number, an order ID — as readily as an account. A caller that knows the
/// document is a statement can opt in.
public struct AccountNumberMatcher: Matcher {
    public var source: MatchSource { .category(.accountNumbers) }

    /// Whether long digit runs with no qualifying label are matched.
    public let includeUnlabeledDigitRuns: Bool
    /// Minimum digits for an unlabeled run to be considered, when enabled.
    public let minUnlabeledDigits: Int

    private let engines: [RegexMatcher]

    /// How far a label may sit from the number it qualifies, in characters.
    private static let labelWindow = 40
    /// How many line breaks may fall between a label and its number.
    private static let maximumInterveningLineBreaks = 1

    private static let labelPattern = #"(?:accounts?|acct\.?|a/c|routing|aba|iban|cards?)"#
    /// Five or more digits, optionally grouped with single spaces or hyphens.
    private static let digitGroupPattern = #"[0-9](?:[- ]?[0-9]){4,}"#

    public init(includeUnlabeledDigitRuns: Bool = false, minUnlabeledDigits: Int = 8) {
        self.includeUnlabeledDigitRuns = includeUnlabeledDigitRuns
        self.minUnlabeledDigits = minUnlabeledDigits

        var engines: [RegexMatcher] = []

        // Labeled: the capture group is the identifier alone, so the label is not redacted.
        engines.append(
            RegexMatcher(
                pattern: #"\b"# + Self.labelPattern + #"\b[^0-9]{0,\#(Self.labelWindow)}?("#
                    + Self.digitGroupPattern + #")(?![0-9-])"#,
                options: [.caseInsensitive],
                captureGroup: 1,
                validate: { _, context in
                    Self.labelIsCloseEnough(context)
                }
            )
        )

        // IBAN: two letters, two check digits, then grouped alphanumerics. Structured
        // enough to stand on its own, and case-sensitive by definition.
        engines.append(
            RegexMatcher(
                pattern: #"\b[A-Z]{2}[0-9]{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#
            )
        )

        if includeUnlabeledDigitRuns {
            let lower = max(1, minUnlabeledDigits)
            engines.append(
                RegexMatcher(
                    pattern: #"(?<![0-9-])[0-9]{\#(lower),17}(?![0-9-])"#
                )
            )
        }

        self.engines = engines
    }

    public func matches(in text: SourceText) -> [Match] {
        var seen: Set<Range<String.Index>> = []
        var results: [Match] = []
        for engine in engines {
            for match in engine.matches(in: text, source: source) where seen.insert(match.range).inserted {
                results.append(match)
            }
        }
        return results.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Rejects a label that reaches its number across more than one line break. The regex
    /// runs on normalized text, where newlines have already become spaces, so this counts
    /// them in the original.
    private static func labelIsCloseEnough(_ context: RegexMatcher.Context) -> Bool {
        guard context.prefixRange.length > 0 else { return true }
        guard let prefixRange = Range(context.prefixRange, in: context.text.normalized),
              let originalRange = context.text.originalRange(forNormalized: prefixRange)
        else { return true }
        let lineBreaks = context.text.original[originalRange].count(where: \.isNewline)
        return lineBreaks <= maximumInterveningLineBreaks
    }
}
