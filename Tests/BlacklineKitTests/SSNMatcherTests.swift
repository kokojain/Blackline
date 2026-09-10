import Testing
@testable import BlacklineKit

@Suite("SSNMatcher")
struct SSNMatcherTests {
    private let matcher = SSNMatcher()

    @Test("Matches hyphen- and space-separated SSNs", arguments: [
        "123-45-6789", "123 45 6789", "000-00-0000", "999-99-9999",
    ])
    func matchesSeparatedForms(_ ssn: String) {
        let found = matcher.matches(in: "SSN: \(ssn) on file")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == ssn)
    }

    // No issuance-validity filtering: spec §7 makes false negatives the dangerous failure,
    // and a mistyped SSN on a form is still an SSN.
    @Test("Does not filter out numbers the SSA would never issue")
    func keepsUnissuableNumbers() {
        #expect(matcher.matches(in: "666-00-0000").count == 1)
    }

    @Test("Requires the same separator in both positions", arguments: [
        "123-45 6789", "123 45-6789",
    ])
    func rejectsMixedSeparators(_ candidate: String) {
        #expect(matcher.matches(in: candidate).isEmpty)
    }

    // Deliberate: a bare nine-digit run is indistinguishable from any other identifier.
    // AccountNumberMatcher covers long digit runs when context qualifies them.
    @Test("Does not match a bare nine-digit run")
    func ignoresBareDigits() {
        #expect(matcher.matches(in: "123456789").isEmpty)
    }

    @Test("Does not match inside a longer digit run", arguments: [
        "1123-45-6789", "123-45-67890", "123-45-6789-0", "12-345-6789",
    ])
    func respectsBoundaries(_ candidate: String) {
        #expect(matcher.matches(in: candidate).isEmpty)
    }

    @Test("Matches an SSN split across a line break")
    func spansLineBreak() {
        let found = matcher.matches(in: "Taxpayer ID 123-45-\n6789 for 2025")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == "123-45-\n6789")
    }

    @Test("Finds every SSN in the page, with correct positions")
    func findsAllWithPositions() {
        let text = SourceText("123-45-6789 and 987-65-4321")
        let found = matcher.matches(in: text)
        #expect(found.count == 2)
        #expect(found.map { text.offsets(of: $0.range) } == [0 ..< 11, 16 ..< 27])
    }

    @Test("Matches are attributed to the social security numbers category")
    func carriesCategory() {
        #expect(matcher.matches(in: "123-45-6789").first?.source == .category(.socialSecurityNumbers))
    }

    @Test("Ignores ordinary text and dates", arguments: [
        "no numbers here", "12/31/2025", "call 555-1234", "1-2-3",
    ])
    func ignoresNonSSNs(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }
}
