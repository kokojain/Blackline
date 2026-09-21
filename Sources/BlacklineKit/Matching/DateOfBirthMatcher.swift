import Foundation

/// Detects dates of birth (spec §5.3).
///
/// A date is only a date until something nearby says whose birth it is, so this matches a
/// date **beside a label** — `DOB`, `Date of birth`, `Born` — or **under one** as a table
/// column header (``PipeTable``). Every other date on the page is left alone: a form is
/// full of dates and almost none of them identify anyone.
///
/// Dates are accepted numerically in either order (`1974-03-11`, `03/11/1974`, `11.03.1974`)
/// and with a month name either side of the day (`March 11, 1974`, `11 March 1974`). The
/// label is never part of the redacted span.
public struct DateOfBirthMatcher: Matcher {
    public var source: MatchSource { .category(.datesOfBirth) }

    private static let label =
        #"(?:d\.?o\.?b\.?|date\s+of\s+birth|birth\s*date|birthday|born(?:\s+on)?)"#
    private static let month =
        #"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"#
    static let date =
        #"(?:[0-9]{4}[-/.][0-9]{1,2}[-/.][0-9]{1,2}"#
        + #"|[0-9]{1,2}[-/.][0-9]{1,2}[-/.][0-9]{2,4}"#
        + #"|"# + month + #"\s+[0-9]{1,2},?\s+[0-9]{4}"#
        + #"|[0-9]{1,2}\s+"# + month + #",?\s+[0-9]{4})"#

    private let labeled = RegexMatcher(
        pattern: #"\b"# + label + #"\s*[:.\-]?\s*("# + date + #")(?![0-9])"#,
        options: [.caseInsensitive],
        captureGroup: 1
    )
    private let column = ColumnLabeledMatcher(
        header: label,
        value: #"(?i)"# + date
    )

    public init() {}

    public func matches(in text: SourceText) -> [Match] {
        (labeled.matches(in: text, source: source) + column.matches(in: text, source: source))
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
