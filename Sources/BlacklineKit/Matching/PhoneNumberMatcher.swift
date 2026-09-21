import Foundation

/// Detects telephone numbers (spec §5.3).
///
/// `NSDataDetector`'s `.phoneNumber` type is the obvious tool and is not used here, because
/// measured on this app's own test text it reports `123-45-6789` and `12-3456789` as phone
/// numbers — an SSN and an EIN — and a bare `021000021` as well. A user who asked for phone
/// numbers and got their routing number blacked out has had the document damaged by a rule
/// they did not write, which is the failure commit "Redact what the rules ask for" exists to
/// prevent. Its boundary is also unknowable, and the point of tier 1 is a boundary you can
/// state.
///
/// So the forms are enumerated:
/// - a parenthesized area code — `(415) 555-0123` — which nothing else is written like;
/// - ten digits grouped 3-3-4 with the **same** separator (space, hyphen or dot), optionally
///   behind a `1` or `+1` trunk prefix. Requiring one separator throughout is what keeps an
///   SSN's 3-2-4 and a card's 4-4-4-4 out;
/// - an international number, which its leading `+` and eight or more digits identify;
/// - anything else — seven digits, a bare ten-digit run — only next to a Phone / Tel /
///   Mobile / Cell / Fax label, on ``AccountNumberMatcher``'s reasoning that shape alone is
///   not evidence. The label is never part of the redacted span.
///
/// An `ext. 42` suffix is included in the match where one follows: it is part of reaching
/// the person, and leaving it behind next to a black box is a poor look on the page.
public struct PhoneNumberMatcher: Matcher {
    public var source: MatchSource { .category(.phoneNumbers) }

    private let engines: [RegexMatcher]

    /// How far a label may sit from the number it qualifies, in characters.
    private static let labelWindow = 25
    /// How many line breaks may fall between a label and its number.
    private static let maximumInterveningLineBreaks = 1

    private static let labelPattern =
        #"(?:phones?|telephones?|tel\.?|mobiles?|cells?|faxe?s?|daytime|evening)"#
    private static let extensionPattern =
        #"(?:\s*(?:ext|ext\.|x|extension)\s*[0-9]{1,6}\b)?"#

    public init() {
        var engines: [RegexMatcher] = []

        // Parenthesized area code. Distinctive enough to stand alone.
        engines.append(
            RegexMatcher(
                pattern: #"(?:\+?1[ .-]?)?\([0-9]{3}\)[ .-]?[0-9]{3}[ .-]?[0-9]{4}"#
                    + Self.extensionPattern,
                options: [.caseInsensitive]
            )
        )

        // Ten digits grouped 3-3-4 by one repeated separator, with an optional trunk prefix.
        engines.append(
            RegexMatcher(
                pattern: #"(?<![0-9.-])(?:\+?1[ .-])?[0-9]{3}([ .-])[0-9]{3}\1[0-9]{4}"#
                    + #"(?![0-9-])"# + Self.extensionPattern,
                options: [.caseInsensitive]
            )
        )

        // International. The leading + is the evidence; the digit count is the guard.
        engines.append(
            RegexMatcher(
                pattern: #"\+[0-9][0-9 .()-]{6,20}[0-9]"#,
                validate: { candidate, _ in
                    (8 ... 15).contains(candidate.count(where: \.isNumber))
                }
            )
        )

        // Everything else needs a label: a seven-digit local number, or a bare run of ten
        // or eleven digits that is indistinguishable from an account or an order number.
        engines.append(
            RegexMatcher(
                pattern: #"\b"# + Self.labelPattern + #"\b[^0-9]{0,\#(Self.labelWindow)}?"#
                    + #"((?:\+?1[ .-]?)?[0-9]{3}[ .-]?[0-9]{4}|[0-9]{10,11})(?![0-9-])"#
                    + Self.extensionPattern,
                options: [.caseInsensitive],
                captureGroup: 1,
                validate: { _, context in
                    context.prefixLineBreaks <= Self.maximumInterveningLineBreaks
                }
            )
        )

        self.engines = engines
    }

    public func matches(in text: SourceText) -> [Match] {
        // The forms overlap by design: a labeled `(415) 555-0123` satisfies two engines, and
        // the labeled engine can report a fragment of a number another engine covers whole.
        // Taking the widest span at each position and dropping what it swallows leaves one
        // finding per number, which is what the §7 count has to mean.
        let found = engines.flatMap { $0.matches(in: text, source: source) }
            .sorted {
                if $0.range.lowerBound != $1.range.lowerBound {
                    return $0.range.lowerBound < $1.range.lowerBound
                }
                return $0.range.upperBound > $1.range.upperBound
            }

        var results: [Match] = []
        for match in found where !(results.last.map { $0.range.overlaps(match.range) } ?? false) {
            results.append(match)
        }
        return results
    }
}
