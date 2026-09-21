import Foundation

/// Matches whole table cells whose column header is a label a matcher would accept in
/// running text (see ``PipeTable``).
///
/// Both patterns must match their whole string: the header is a label or it is not, and a
/// cell under a labelled header is a value or it is not — a cell reading `see note 4` under
/// `Account Number` is left alone.
struct ColumnLabeledMatcher: Sendable {
    let header: NSRegularExpression
    let value: NSRegularExpression

    init(header: String, value: String) {
        // Compile-time constants in this module; a failure here is a programming error.
        self.header = try! NSRegularExpression(pattern: "^(?:" + header + ")$", options: [.caseInsensitive])
        self.value = try! NSRegularExpression(pattern: "^(?:" + value + ")$")
    }

    func matches(in text: SourceText, source: MatchSource) -> [Match] {
        PipeTable.cells(in: text.original).compactMap { cell in
            guard matches(header, cell.header), matches(value, cell.text) else { return nil }
            return Match(range: cell.range, matchedText: cell.text, source: source)
        }
    }

    private func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}
