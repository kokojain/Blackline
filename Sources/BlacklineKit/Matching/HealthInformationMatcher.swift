import Foundation

/// Detects protected health information (spec §5.3): the identifiers a health plan or a
/// provider assigns, and a diagnosis where the page labels one.
///
/// Three forms, each needing a label on ``AccountNumberMatcher``'s reasoning that shape
/// alone is not evidence:
///
/// - **Plan and record identifiers** — a value with a digit in it after `Member ID`, `MRN`,
///   `Medical record number`, `Patient ID`, `Claim`, `Policy`, `Group #`, `NPI`. `Claim`
///   and `Group` are accepted bare because that is how claim letters print them
///   (`Claim STD-2026-311`, `Group #GRP-77120`), at the cost of requiring five characters
///   so `claim 3 items` is prose. One label may introduce a comma-separated list, each
///   entry optionally annotated in parentheses — `Member IDs: RM-01 (Bakr), RM-02 (Nowak)`
///   — and the whole list is the span, annotations included, because a holder's name
///   beside a member number is not less sensitive than the number.
/// - **A labelled diagnosis** — the text after `Dx:` or `Diagnosis:`. Where a
///   parenthesised ICD code follows within eighty characters the span runs through it,
///   comma and all (`major depressive disorder, recurrent (ICD-10 F33.1)`); otherwise it
///   stops at the first punctuation, or after sixty characters.
/// - **A labelled ICD code** — `ICD-10 Z48.812`. The code alone names the condition.
///
/// Not matched: a condition named in prose without a label, a medication, a procedure.
/// Those are the model tier's to find, since nothing about their shape says what they are.
public struct HealthInformationMatcher: Matcher {
    public var source: MatchSource { .category(.healthInformation) }

    private let engines: [RegexMatcher]

    private static let identifierLabel =
        #"(?:member\s+(?:id|number|no\.?|#)|subscriber\s+(?:id|number|no\.?)"#
        + #"|medical\s+record\s+(?:number|no\.?|#)|mrn|patient\s+(?:id|number|no\.?)"#
        + #"|claim(?:\s+(?:number|no\.?|id|#))?|policy\s+(?:number|no\.?|#)"#
        + #"|group(?:\s+(?:number|no\.?))?\s*#?|npi|health\s+plan\s+(?:id|number))"#
    private static let diagnosisLabel = #"(?:dx|diagnosis|diagnoses|diagnosed\s+with)"#
    private static let identifier = #"[A-Z]{0,4}-?[0-9][A-Z0-9-]{3,}"#
    private static let icdCode =
        #"[A-Z][0-9]{2}(?:\.[0-9A-Z]{1,4})?"#
    private static let icdReference =
        #"\(?ICD-?(?:9|10|11)(?:-CM)?\s*:?\s*"# + icdCode + #"\)?"#

    public init() {
        engines = [
            RegexMatcher(
                pattern: #"\b"# + Self.identifierLabel + #"\b[^0-9]{0,25}?"#
                    + #"("# + Self.identifier
                    + #"(?:\s*(?:\([^()]{0,40}\))?,\s*"# + Self.identifier + #")*)(?![A-Z0-9-])"#,
                options: [.caseInsensitive],
                captureGroup: 1
            ),
            RegexMatcher(
                pattern: #"\b"# + Self.diagnosisLabel + #"\s*[:\-]\s*"#
                    + #"(.{1,80}?"# + Self.icdReference + #"|[^,;.()]{4,60})"#,
                options: [.caseInsensitive],
                captureGroup: 1
            ),
            RegexMatcher(
                pattern: #"\bICD-?(?:9|10|11)(?:-CM)?\s*:?\s*("# + Self.icdCode + #")\b"#,
                captureGroup: 1
            ),
        ]
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
}
