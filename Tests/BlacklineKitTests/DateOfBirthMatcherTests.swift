import Testing
@testable import BlacklineKit

@Suite("DateOfBirthMatcher")
struct DateOfBirthMatcherTests {
    private let matcher = DateOfBirthMatcher()

    @Test("A date beside a label, in any common form", arguments: [
        ("DOB: 1974-03-11", "1974-03-11"),
        ("D.O.B. 03/11/1974", "03/11/1974"),
        ("Date of birth 11.03.1974", "11.03.1974"),
        ("Birthdate - March 11, 1974", "March 11, 1974"),
        ("born on 11 March 1974", "11 March 1974"),
        ("Birthday: Mar. 11, 1974", "Mar. 11, 1974"),
    ])
    func labeled(_ text: String, _ expected: String) {
        #expect(matcher.matches(in: text).map(\.matchedText) == [expected])
    }

    // A form is full of dates and almost none of them identify anyone.
    @Test("A date without a label is left alone", arguments: [
        "Last revised: 2026-09-18", "Contract End 2027-06-30", "filed 2026-09-04",
        "Dobson & Sons, est. 1974",
    ])
    func unlabeled(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }

    @Test("A column headed DOB labels every date under it")
    func column() {
        let text = """
        | Name | DOB | Hired |
        |---|---|---|
        | Priya R. | 1974-03-11 | 2019-02-01 |
        | James O. | **1979-08-27** | 2020-06-15 |
        """
        #expect(matcher.matches(in: text).map(\.matchedText) == ["1974-03-11", "1979-08-27"])
    }

    @Test("Matches are attributed to the dates of birth category")
    func category() {
        #expect(matcher.matches(in: "DOB 1/2/1990").first?.source == .category(.datesOfBirth))
    }
}
