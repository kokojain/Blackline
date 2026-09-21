import Foundation

/// Detects employee identifiers (spec §5.3).
///
/// An employee number has whatever shape the employer gave it, so like a passport number
/// it is matched only beside a label — `Employee ID`, `Emp. No.`, `Staff #` — or under one
/// as a table column header (``PipeTable``). The value is up to three letters, an optional
/// hyphen and three to ten digits, which covers `E-04471`, `EMP12345` and a bare `004471`.
public struct EmployeeIDMatcher: Matcher {
    public var source: MatchSource { .category(.employeeIdentifiers) }

    private static let label =
        #"(?:employee|emp\.?|staff|personnel|worker|payroll)\s*(?:ids?|no\.?|numbers?|#)"#
    private static let value = #"[A-Z]{0,3}-?[0-9]{3,10}"#

    private let labeled = RegexMatcher(
        pattern: #"\b"# + label + #"(?![A-Za-z0-9])[^A-Za-z0-9]{0,10}("# + value + #")(?![A-Za-z0-9-])"#,
        options: [.caseInsensitive],
        captureGroup: 1
    )
    private let column = ColumnLabeledMatcher(header: label, value: value)

    public init() {}

    public func matches(in text: SourceText) -> [Match] {
        (labeled.matches(in: text, source: source) + column.matches(in: text, source: source))
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
