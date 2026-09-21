import Testing
@testable import BlacklineKit

@Suite("HealthInformationMatcher")
struct HealthInformationMatcherTests {
    private let matcher = HealthInformationMatcher()

    @Test("Plan and record identifiers beside their labels", arguments: [
        ("Member ID: RM-0091-338847-02", "RM-0091-338847-02"),
        ("MRN 00448812", "00448812"),
        ("Medical record number: 7781-A", "7781-A"),
        ("Claim STD-2026-311 opened", "STD-2026-311"),
        ("group #GRP-77120", "GRP-77120"),
        ("Policy No. HP1234567", "HP1234567"),
        ("NPI 1234567893", "1234567893"),
    ])
    func identifiers(_ text: String, _ expected: String) {
        #expect(matcher.matches(in: text).map(\.matchedText) == [expected])
    }

    @Test("One label can introduce a list of identifiers")
    func identifierList() {
        let text = "Member ID sample: RM-0091-338847-02 (Bakr), RM-0091-341190-01 (Nowak)."
        #expect(matcher.matches(in: text).map(\.matchedText)
            == ["RM-0091-338847-02 (Bakr), RM-0091-341190-01"])
    }

    @Test("A labelled diagnosis runs through its ICD code, comma and all")
    func diagnosisWithCode() {
        let text = "Dx: major depressive disorder, recurrent (ICD-10 F33.1), intermittent leave approved."
        let found = matcher.matches(in: text).map(\.matchedText)
        #expect(found.contains("major depressive disorder, recurrent (ICD-10 F33.1)"))
        #expect(found.contains("F33.1"))
    }

    @Test("A labelled diagnosis without a code stops at punctuation")
    func diagnosisWithoutCode() {
        #expect(matcher.matches(in: "Diagnosis: fractured left radius, cast applied").map(\.matchedText)
            == ["fractured left radius"])
    }

    @Test("Nothing without a label", arguments: [
        "claim 3 items on the expense form",
        "the group met on Tuesday",
        "recovering from surgery",
        "Z48.812",
    ])
    func unlabeled(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }

    @Test("Matches are attributed to the health information category")
    func category() {
        #expect(matcher.matches(in: "MRN 12345").first?.source == .category(.healthInformation))
    }
}
