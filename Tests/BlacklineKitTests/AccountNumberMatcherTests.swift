import Testing
@testable import BlacklineKit

@Suite("AccountNumberMatcher")
struct AccountNumberMatcherTests {
    private let matcher = AccountNumberMatcher()

    // MARK: - Context qualifies the number

    @Test("Matches a number introduced by a label", arguments: [
        "Account Number: 000123456789",
        "Account No. 000123456789",
        "account 000123456789",
        "Accounts 000123456789",
        "Acct #: 000123456789",
        "Acct. 000123456789",
        "A/C 000123456789",
        "Routing: 000123456789",
        "ABA 000123456789",
        "Card number 000123456789",
    ])
    func matchesLabeledNumbers(_ text: String) {
        let found = matcher.matches(in: text)
        #expect(found.count == 1)
        #expect(found.first?.matchedText == "000123456789")
    }

    @Test("Matches the label-above-value layout common on statements")
    func matchesLabelOnPreviousLine() {
        let found = matcher.matches(in: "Account Number\n000123456789\nStatement period")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == "000123456789")
    }

    @Test("Keeps the label out of the redacted span")
    func excludesLabelFromRange() {
        let text = SourceText("Account Number: 000123456789")
        let found = matcher.matches(in: text)
        #expect(found.first.map { text.offsets(of: $0.range) } == 16 ..< 28)
    }

    @Test("Matches grouped identifiers", arguments: [
        "Acct #: 12-3456-7", "Account 1234 5678 9012",
    ])
    func matchesGroupedIdentifiers(_ text: String) {
        #expect(matcher.matches(in: text).count == 1)
    }

    @Test("Refuses to reach past more than one line break")
    func labelDoesNotReachTooFar() {
        #expect(matcher.matches(in: "Account Number\n\nSee below.\n000123456789").isEmpty)
    }

    @Test("Refuses to reach past the character window")
    func labelWindowIsBounded() {
        let filler = String(repeating: "x", count: 60)
        #expect(matcher.matches(in: "Account \(filler) 000123456789").isEmpty)
    }

    @Test("A label claims the nearest following number, not a distant one")
    func labelClaimsNearestNumber() {
        let text = SourceText("Account 111111111 and later 222222222")
        let found = matcher.matches(in: text)
        #expect(found.count == 1)
        #expect(found.first?.matchedText == "111111111")
    }

    // MARK: - Format alone is not evidence

    @Test("Ignores an unlabeled digit run by default")
    func ignoresUnlabeledByDefault() {
        #expect(matcher.matches(in: "000123456789").isEmpty)
        #expect(matcher.matches(in: "Total due 000123456789").isEmpty)
    }

    @Test("Ignores ordinary numbers that happen to look numeric", arguments: [
        "Invoice 2024", "Total 1,250.00", "Page 12 of 34", "Order 1234", "Suite 500",
    ])
    func ignoresOrdinaryNumbers(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }

    @Test("A labeled candidate needs at least five digits")
    func requiresEnoughDigits() {
        #expect(matcher.matches(in: "Card ending in 9803").isEmpty)
        #expect(matcher.matches(in: "Account 12345").count == 1)
    }

    // MARK: - Opt-in unlabeled runs

    @Test("Unlabeled digit runs match when explicitly enabled")
    func unlabeledOptIn() {
        let permissive = AccountNumberMatcher(includeUnlabeledDigitRuns: true)
        #expect(permissive.matches(in: "000123456789").count == 1)
        #expect(permissive.matches(in: "Total 1234").isEmpty)
    }

    @Test("The unlabeled digit threshold is configurable")
    func unlabeledThreshold() {
        let strict = AccountNumberMatcher(includeUnlabeledDigitRuns: true, minUnlabeledDigits: 12)
        #expect(strict.matches(in: "12345678").isEmpty)
        #expect(strict.matches(in: "000123456789").count == 1)
    }

    @Test("An enabled unlabeled run is reported once, not twice, when also labeled")
    func doesNotDoubleReport() {
        let permissive = AccountNumberMatcher(includeUnlabeledDigitRuns: true)
        #expect(permissive.matches(in: "Account Number: 000123456789").count == 1)
    }

    // MARK: - IBAN

    @Test("Matches an IBAN without needing a label", arguments: [
        "GB82 WEST 1234 5698 7654 32",   // canonical four-character grouping
        "GB82 WEST 12345698 765432",
        "DE89370400440532013000",
        "FR1420041010050500013M02606",
    ])
    func matchesIBAN(_ iban: String) {
        let found = matcher.matches(in: "Transfer to \(iban) please")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == iban)
    }

    @Test("Does not treat ordinary uppercase words as an IBAN")
    func ignoresUppercaseProse() {
        #expect(matcher.matches(in: "SEE THE ATTACHED NOTICE").isEmpty)
    }

    // MARK: - General

    @Test("Matches are returned in document order")
    func documentOrder() {
        let text = SourceText("Routing 021000021 then Account 000123456789")
        let found = matcher.matches(in: text)
        #expect(found.count == 2)
        #expect(found.map(\.matchedText) == ["021000021", "000123456789"])
    }

    @Test("Matches a labeled number split across a line break")
    func spansLineBreak() {
        let found = matcher.matches(in: "Account 0001-\n2345-6789 closed")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == "0001-\n2345-6789")
    }

    @Test("Matches are attributed to the account numbers category")
    func carriesCategory() {
        #expect(matcher.matches(in: "Account 000123456789").first?.source == .category(.accountNumbers))
    }
}
