import Testing
@testable import BlacklineKit

@Suite("CreditCardMatcher")
struct CreditCardMatcherTests {
    private let matcher = CreditCardMatcher()

    @Test("Matches Luhn-valid test numbers across brands and lengths", arguments: [
        "4111111111111111",   // Visa, 16
        "4222222222222",      // Visa, 13
        "5555555555554444",   // Mastercard, 16
        "378282246310005",    // Amex, 15
        "6011111111111117",   // Discover, 16
        "3530111333300000",   // JCB, 16
        "30569309025904",     // Diners Club, 14
    ])
    func matchesValidCards(_ pan: String) {
        let found = matcher.matches(in: "Charged to \(pan) today")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == pan)
    }

    @Test("Matches grouped numbers with spaces or hyphens", arguments: [
        "4111 1111 1111 1111", "4111-1111-1111-1111", "3782 822463 10005",
    ])
    func matchesGroupedForms(_ pan: String) {
        #expect(matcher.matches(in: "Card \(pan).").first?.matchedText == pan)
    }

    @Test("Rejects numbers that fail the Luhn checksum", arguments: [
        "4111111111111112", "5555555555554443", "1234567890123456",
    ])
    func rejectsLuhnFailures(_ candidate: String) {
        #expect(matcher.matches(in: "Ref \(candidate).").isEmpty)
    }

    @Test("Rejects runs that are too short or too long", arguments: [
        "411111111111",          // 12 digits
        "41111111111111111111",  // 20 digits
    ])
    func rejectsWrongLengths(_ candidate: String) {
        #expect(matcher.matches(in: "Ref \(candidate).").isEmpty)
    }

    // The spec's own example (§4) is a masked number, filed under quoted exact rules.
    // It must not match here — there are only eight digits present.
    @Test("Does not match a masked card number")
    func ignoresMaskedNumber() {
        #expect(matcher.matches(in: "Card 4417-XXXX-XXXX-9803 on file").isEmpty)
    }

    @Test("Does not match inside a longer digit run")
    func respectsBoundaries() {
        #expect(matcher.matches(in: "94111111111111119").isEmpty)
    }

    @Test("Matches a card number split across a line break")
    func spansLineBreak() {
        let found = matcher.matches(in: "Card 4111-1111-\n1111-1111 exp 09/28")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == "4111-1111-\n1111-1111")
    }

    @Test("Finds every card on the page")
    func findsAll() {
        #expect(matcher.matches(in: "4111111111111111 / 378282246310005").count == 2)
    }

    @Test("Matches are attributed to the credit card numbers category")
    func carriesCategory() {
        #expect(matcher.matches(in: "4111111111111111").first?.source == .category(.creditCardNumbers))
    }

    @Test("Luhn checking can be disabled")
    func luhnOptional() {
        #expect(CreditCardMatcher(requiresLuhn: false).matches(in: "1234567890123456").count == 1)
    }

    @Test("passesLuhn ignores separators and rejects non-digits")
    func luhnHelper() {
        #expect(CreditCardMatcher.passesLuhn("4111 1111 1111 1111"))
        #expect(CreditCardMatcher.passesLuhn("4111-1111-1111-1111"))
        #expect(!CreditCardMatcher.passesLuhn("4111111111111112"))
        #expect(!CreditCardMatcher.passesLuhn(""))
        #expect(!CreditCardMatcher.passesLuhn("abcd"))
    }
}
