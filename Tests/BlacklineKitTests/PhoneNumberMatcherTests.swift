import Testing
@testable import BlacklineKit

@Suite("PhoneNumberMatcher")
struct PhoneNumberMatcherTests {
    private let matcher = PhoneNumberMatcher()

    @Test("Matches the forms that stand alone", arguments: [
        "(415) 555-0123", "(415)555-0123", "+1 (415) 555-0123",
        "415-555-0123", "415.555.0123", "415 555 0123",
        "1-800-555-0199", "+44 20 7946 0958", "+81 3 1234 5678",
    ])
    func matchesUnlabeledForms(_ number: String) {
        let found = matcher.matches(in: "Reach us at \(number) any time")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == number)
    }

    // The reason this matcher does not use NSDataDetector: its .phoneNumber type reports
    // all three of these. Redacting an SSN under a "phone numbers" rule damages the
    // document with a rule the user did not write.
    @Test("Leaves other identifiers alone", arguments: [
        "SSN 123-45-6789", "EIN 12-3456789", "Routing 021000021",
        "Card 4111 1111 1111 1111", "Invoice 2024-11-0001", "Filed 03/14/1982",
    ])
    func ignoresOtherIdentifiers(_ candidate: String) {
        #expect(matcher.matches(in: candidate).isEmpty)
    }

    @Test("Requires one separator throughout")
    func rejectsMixedSeparators() {
        #expect(matcher.matches(in: "415-555 0123").isEmpty)
    }

    @Test("Matches a bare ten-digit run only next to a label")
    func bareRunNeedsLabel() {
        #expect(matcher.matches(in: "Order 4155550123 shipped").isEmpty)
        let found = matcher.matches(in: "Phone: 4155550123")
        #expect(found.map(\.matchedText) == ["4155550123"])
    }

    @Test("Matches a seven-digit local number only next to a label")
    func localNumberNeedsLabel() {
        #expect(matcher.matches(in: "Part 555-0123 in stock").isEmpty)
        #expect(matcher.matches(in: "Tel. 555-0123").map(\.matchedText) == ["555-0123"])
    }

    @Test("A label two lines above does not qualify a number")
    func labelDoesNotReachAcrossTwoLines() {
        #expect(matcher.matches(in: "Phone\n\n\n4155550123").isEmpty)
        #expect(matcher.matches(in: "Phone\n4155550123").count == 1)
    }

    @Test("The label is not part of the redacted span")
    func labelIsNotRedacted() {
        #expect(matcher.matches(in: "Mobile 4155550123").first?.matchedText == "4155550123")
    }

    @Test("Includes an extension where one follows")
    func includesExtension() {
        #expect(matcher.matches(in: "Call (415) 555-0123 ext 42 today").first?.matchedText
            == "(415) 555-0123 ext 42")
    }

    @Test("Reports one finding per number, not one per form it satisfies")
    func doesNotDoubleReport() {
        let found = matcher.matches(in: "Phone: (415) 555-0123")
        #expect(found.map(\.matchedText) == ["(415) 555-0123"])
    }

    @Test("Does not match inside a longer digit run", arguments: [
        "1415-555-01234", "94155550123456",
    ])
    func respectsBoundaries(_ candidate: String) {
        #expect(matcher.matches(in: candidate).isEmpty)
    }

    @Test("Matches a number split across a line break")
    func spansLineBreak() {
        let found = matcher.matches(in: "Daytime 415-555-\n0123")
        #expect(found.first?.matchedText == "415-555-\n0123")
    }

    @Test("Matches are attributed to the phone numbers category")
    func attribution() {
        #expect(matcher.matches(in: "415-555-0123").first?.source == .category(.phoneNumbers))
    }
}
