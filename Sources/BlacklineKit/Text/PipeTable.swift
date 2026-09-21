import Foundation

/// The cells of pipe-delimited tables in a page's text, each with the header above it.
///
/// A column header is a label for every cell beneath it, and it is the one label the
/// labelled matchers cannot otherwise see: `AccountNumberMatcher` lets a label sit one line
/// above its value, but a table's header is one line above its *first* row only, and on a
/// markdown table the `|---|` separator row puts even that out of reach. Measured on the
/// synthetic corpus: the two bank accounts in a five-column table went unfound while the
/// same numbers in running text were caught.
///
/// This is deliberately narrow. Only tables drawn with `|` are recognised, because only
/// they carry the column structure in the text itself — a table extracted from a PDF page
/// arrives as rows of words with no way to tell which header a value sat under. A matcher
/// that wants column labels asks here and gets nothing on such a page, which is the honest
/// answer.
enum PipeTable {
    struct Cell: Sendable {
        /// The header cell above this one, trimmed of whitespace and markdown emphasis.
        let header: String
        /// The cell's content, trimmed the same way.
        let text: String
        /// Where `text` sits in the original page text.
        let range: Range<String.Index>
    }

    /// Every cell in every table in `original`, in document order.
    ///
    /// A table is two or more consecutive lines beginning with `|` whose second line is a
    /// separator (`|---|:---:|`); the first line is the header and the rest are rows. A
    /// row with more cells than the header keeps the extras unlabelled.
    static func cells(in original: String) -> [Cell] {
        var cells: [Cell] = []
        var lines: [Substring] = []
        original.enumerateSubstrings(in: original.startIndex..., options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            lines.append(original[range])
        }

        var index = 0
        while index < lines.count {
            guard isTableLine(lines[index]) else { index += 1; continue }
            let start = index
            while index < lines.count, isTableLine(lines[index]) { index += 1 }
            let block = lines[start ..< index]
            guard block.count >= 2, isSeparator(block[start + 1]) else { continue }

            let headers = split(block[start]).map(\.text)
            for row in block.dropFirst(2) {
                for (column, cell) in split(row).enumerated() where !cell.text.isEmpty {
                    guard column < headers.count else { break }
                    cells.append(Cell(header: headers[column], text: cell.text, range: cell.range))
                }
            }
        }
        return cells
    }

    private static func isTableLine(_ line: Substring) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).first == "|"
    }

    /// `|---|:---:|` — every cell is dashes and colons only.
    private static func isSeparator(_ line: Substring) -> Bool {
        let cells = split(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            !cell.text.isEmpty && cell.text.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// The cells between the pipes, trimmed. Markdown emphasis (`**bold**`, `` `code` ``)
    /// around a value is furniture, not part of it.
    private static func split(_ line: Substring) -> [(text: String, range: Range<String.Index>)] {
        var cells: [(text: String, range: Range<String.Index>)] = []
        var pieces = line.split(separator: "|", omittingEmptySubsequences: false)
        // A leading and trailing pipe leave an empty piece at each end.
        if pieces.first?.isEmpty == true { pieces.removeFirst() }
        if pieces.last?.allSatisfy(\.isWhitespace) == true { pieces.removeLast() }
        for piece in pieces {
            let trimmed = trim(piece)
            cells.append((String(trimmed), trimmed.startIndex ..< trimmed.endIndex))
        }
        return cells
    }

    private static let furniture: Set<Character> = [" ", "\t", "*", "_", "`"]

    private static func trim(_ piece: Substring) -> Substring {
        var start = piece.startIndex
        var end = piece.endIndex
        while start < end, furniture.contains(piece[start]) { start = piece.index(after: start) }
        while end > start, furniture.contains(piece[piece.index(before: end)]) { end = piece.index(before: end) }
        return piece[start ..< end]
    }
}
