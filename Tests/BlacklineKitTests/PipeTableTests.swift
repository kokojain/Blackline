import Testing
@testable import BlacklineKit

@Suite("PipeTable")
struct PipeTableTests {
    @Test("Cells carry the header above them, trimmed of emphasis")
    func cells() {
        let text = """
        Intro line.
        | Account | Routing | **Account Number** |
        |---|:---:|---|
        | Operating | 125000024 | `4471928830155` |
        | Treasury | 125000024 | **4471928830163** |
        After.
        """
        let cells = PipeTable.cells(in: text)
        #expect(cells.map(\.header) == ["Account", "Routing", "Account Number", "Account", "Routing", "Account Number"])
        #expect(cells.map(\.text) == ["Operating", "125000024", "4471928830155", "Treasury", "125000024", "4471928830163"])
        #expect(cells.allSatisfy { String(text[$0.range]) == $0.text })
    }

    @Test("Lines with pipes but no separator row are not a table")
    func noSeparator() {
        #expect(PipeTable.cells(in: "| a | b |\n| c | d |").isEmpty)
    }

    @Test("A row longer than its header keeps the extra cells unlabelled")
    func longRow() {
        let cells = PipeTable.cells(in: "| H |\n|---|\n| v1 | v2 |")
        #expect(cells.map(\.text) == ["v1"])
    }
}
