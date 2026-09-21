import Testing
@testable import BlacklineKit

@Suite("MatcherFactory")
struct MatcherFactoryTests {
    private let parser = RulesParser()
    private let factory = MatcherFactory()

    @Test("Builds one exact matcher per quoted rule")
    func buildsExactMatchers() {
        let ruleSet = parser.parse("\"Nikhil\"\n\"Knob LLC\"").ruleSet
        let output = factory.makeMatchers(for: ruleSet)
        #expect(output.matchers.count == 2)
        #expect(output.unsupportedCategories.isEmpty)
    }

    @Test("Builds detectors for the categories this slice implements")
    func buildsImplementedCategories() {
        let ruleSet = parser.parse("""
        social security numbers
        credit card numbers
        account numbers
        email addresses
        phone numbers
        street addresses
        """).ruleSet
        let output = factory.makeMatchers(for: ruleSet)
        #expect(output.matchers.count == 6)
        #expect(output.unsupportedCategories.isEmpty)
    }

    // Spec §7 treats silent under-redaction as the dangerous failure, so a category with
    // no detector yet must be reported, never quietly dropped.
    @Test("Reports categories that have no detector yet")
    func reportsUnsupportedCategories() {
        let ruleSet = parser.parse("""
        person names
        dates of birth
        """).ruleSet
        let output = factory.makeMatchers(for: ruleSet)
        #expect(output.matchers.count == 1)
        #expect(output.unsupportedCategories == [.personNames])
    }

    @Test("Builds detectors for the categories added for the synthetic corpus")
    func buildsCorpusCategories() {
        let ruleSet = parser.parse("""
        dates of birth
        secrets
        ip addresses
        health information
        employee ids
        """).ruleSet
        let output = factory.makeMatchers(for: ruleSet)
        #expect(output.matchers.count == 5)
        #expect(output.unsupportedCategories.isEmpty)
    }

    @Test("Forwards the unlabeled-digit-run option to the account matcher")
    func forwardsOptions() {
        let ruleSet = parser.parse("account numbers").ruleSet
        let permissive = MatcherFactory(includeUnlabeledDigitRuns: true)
        let matcher = permissive.makeMatchers(for: ruleSet).matchers.first
        #expect((matcher as? AccountNumberMatcher)?.includeUnlabeledDigitRuns == true)

        let strict = factory.makeMatchers(for: ruleSet).matchers.first
        #expect((strict as? AccountNumberMatcher)?.includeUnlabeledDigitRuns == false)
    }

    @Test("The spec's example rules file drives an end-to-end pass over a page")
    func endToEndOverAPage() {
        let ruleSet = parser.parse("""
        # Blackline rules
        "Nikhil"
        "Knob LLC"
        "4417-XXXX-XXXX-9803"
        social security numbers
        credit card numbers
        account numbers
        email addresses
        phone numbers
        street addresses
        """).ruleSet

        let page = SourceText("""
        Prepared for Nikhil of Knob
        LLC. SSN 123-45-6789.
        88 Harbor St Apt 4B
        Boston MA 02210
        nikhil@knob-llc.example
        Phone (617) 555-0148
        Account Number
        000123456789
        Card on file 4417-XXXX-XXXX-9803
        Backup card 4111 1111 1111 1111
        """)

        let output = factory.makeMatchers(for: ruleSet)
        let matches = output.matchers.flatMap { $0.matches(in: page) }

        #expect(matches.contains { $0.matchedText == "Nikhil" })
        #expect(matches.contains { $0.matchedText == "Knob\nLLC" })       // spans the wrap
        #expect(matches.contains { $0.matchedText == "123-45-6789" })
        #expect(matches.contains { $0.matchedText == "000123456789" })     // label above value
        #expect(matches.contains { $0.matchedText == "4417-XXXX-XXXX-9803" })
        #expect(matches.contains { $0.matchedText == "4111 1111 1111 1111" })
        #expect(matches.contains { $0.matchedText == "88 Harbor St Apt 4B\nBoston MA 02210" })
        #expect(matches.contains { $0.matchedText == "nikhil@knob-llc.example" })
        #expect(matches.contains { $0.matchedText == "(617) 555-0148" })

        // Eleven, not nine: "Backup card 4111…" is flagged by both the credit card matcher
        // (Luhn) and the account matcher ("card" is an account label). Matchers are
        // independent by contract, and keeping "card" in the account vocabulary is what
        // catches non-Luhn store and loyalty numbers. Merging overlapping spans — and
        // reconciling the §3 "items redacted" count — belongs to the redaction stage.
        // and the "Nikhil" rule matches twice — once in the prose, once inside the email
        // address, which is the case-insensitive literal doing exactly what it should.
        #expect(matches.count == 11)
        let visaSources = Set(
            matches.filter { $0.matchedText == "4111 1111 1111 1111" }.map(\.source)
        )
        #expect(visaSources == [.category(.creditCardNumbers), .category(.accountNumbers)])
    }

    @Test("A labeled card number that fails Luhn is still caught as an account number")
    func nonLuhnCardStillCaught() {
        let ruleSet = parser.parse("credit card numbers\naccount numbers").ruleSet
        let matches = factory.makeMatchers(for: ruleSet)
            .matchers.flatMap { $0.matches(in: SourceText("Card number 12345678")) }
        #expect(matches.map(\.matchedText) == ["12345678"])
        #expect(matches.first?.source == .category(.accountNumbers))
    }
}
