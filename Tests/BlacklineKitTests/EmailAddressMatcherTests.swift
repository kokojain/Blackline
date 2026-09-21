import Testing
@testable import BlacklineKit

@Suite("EmailAddressMatcher")
struct EmailAddressMatcherTests {
    private let matcher = EmailAddressMatcher()

    @Test("Matches ordinary addresses", arguments: [
        "sarah.chen@example.com",
        "SARAH.CHEN+tax@sub.example.co.uk",
        "n_j@knob-llc.com",
        "accounts%payable@example.org",
        "a@b.io",
    ])
    func matchesAddresses(_ address: String) {
        let found = matcher.matches(in: "Contact \(address) with questions")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == address)
    }

    // The stated boundary: a dotted domain ending in letters. Both of these are the price
    // of keeping `user@2024` and a stray `@` in prose out.
    @Test("Requires a dotted domain with an alphabetic top level", arguments: [
        "chen@localhost", "chen@example", "chen@192.168.0.1", "chen@example.2",
    ])
    func rejectsUndottedDomains(_ candidate: String) {
        #expect(matcher.matches(in: candidate).isEmpty)
    }

    @Test("Does not start mid-address")
    func respectsLeftBoundary() {
        let text = SourceText("sarah.chen@example.com")
        let found = matcher.matches(in: text)
        #expect(found.map { text.offsets(of: $0.range) } == [0 ..< 22])
    }

    @Test("Stops at surrounding punctuation")
    func stopsAtPunctuation() {
        #expect(matcher.matches(in: "(sarah@example.com).").first?.matchedText
            == "sarah@example.com")
    }

    @Test("Matches an address hyphenated across a line break")
    func spansHyphenatedWrap() {
        // SourceText drops a hyphen that wraps between letters, so the domain rejoins.
        let found = matcher.matches(in: "billing@knob-\nllc.com")
        #expect(found.first?.matchedText == "billing@knob-\nllc.com")
    }

    @Test("Finds every address on the page")
    func findsAll() {
        let found = matcher.matches(in: "a@x.com; b@y.org\nc@z.net")
        #expect(found.map(\.matchedText) == ["a@x.com", "b@y.org", "c@z.net"])
    }

    @Test("Matches are attributed to the email addresses category")
    func attribution() {
        #expect(matcher.matches(in: "a@x.com").first?.source == .category(.emailAddresses))
    }
}
