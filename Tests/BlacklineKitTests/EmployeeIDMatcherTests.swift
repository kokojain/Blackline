import Testing
@testable import BlacklineKit

@Suite("EmployeeIDMatcher")
struct EmployeeIDMatcherTests {
    private let matcher = EmployeeIDMatcher()

    @Test("An identifier beside a label", arguments: [
        ("Employee ID E-04471", "E-04471"),
        ("Emp. No.: 004471", "004471"),
        ("Staff # EMP12345", "EMP12345"),
        ("(Employee ID E-04471)", "E-04471"),
    ])
    func labeled(_ text: String, _ expected: String) {
        #expect(matcher.matches(in: text).map(\.matchedText) == [expected])
    }

    @Test("A column headed Emp ID labels every cell under it")
    func column() {
        let text = """
        | Emp ID | Name |
        |---|---|
        | E-01192 | Rafael |
        | E-02331 | Aisha |
        """
        #expect(matcher.matches(in: text).map(\.matchedText) == ["E-01192", "E-02331"])
    }

    @Test("Nothing without a label", arguments: ["E-04471", "employee count 618", "staff of 27"])
    func unlabeled(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }

    @Test("Matches are attributed to the employee ids category")
    func category() {
        #expect(matcher.matches(in: "Employee # 1234").first?.source == .category(.employeeIdentifiers))
    }
}
