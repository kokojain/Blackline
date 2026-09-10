import Testing
@testable import BlacklineKit

@Suite("ExactTextMatcher")
struct ExactTextMatcherTests {

    private func matches(_ literal: String, in text: String, caseSensitive: Bool = false) -> [Match] {
        ExactTextMatcher(literal: literal, isCaseSensitive: caseSensitive)
            .matches(in: SourceText(text))
    }

    @Test("Finds a single occurrence")
    func singleOccurrence() {
        let found = matches("Knob LLC", in: "Invoice from Knob LLC, thanks.")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == "Knob LLC")
    }

    @Test("Finds every occurrence, in document order")
    func everyOccurrence() {
        let text = SourceText("Nikhil paid Nikhil, then Nikhil left.")
        let found = ExactTextMatcher(literal: "Nikhil").matches(in: text)
        #expect(found.count == 3)
        #expect(found.map { text.offsets(of: $0.range).lowerBound } == [0, 12, 25])
    }

    @Test("Reports no matches when the literal is absent")
    func noMatches() {
        #expect(matches("Knob LLC", in: "Nothing to see here.").isEmpty)
    }

    @Test("Matches at the very start and the very end of the text")
    func matchesAtEdges() {
        let text = SourceText("Knob LLC and Knob LLC")
        let found = ExactTextMatcher(literal: "Knob LLC").matches(in: text)
        #expect(found.count == 2)
        #expect(text.offsets(of: found[0].range) == 0 ..< 8)
        #expect(found[1].range.upperBound == text.original.endIndex)
    }

    @Test("Is case-insensitive by default", arguments: ["Nikhil", "nikhil", "NIKHIL", "nIkHiL"])
    func caseInsensitiveByDefault(_ variant: String) {
        #expect(matches("Nikhil", in: "Signed by \(variant) today").count == 1)
    }

    @Test("A ! prefixed rule matches only the exact casing")
    func caseSensitive() {
        #expect(matches("ACME", in: "ACME Corp", caseSensitive: true).count == 1)
        #expect(matches("ACME", in: "Acme Corp", caseSensitive: true).isEmpty)
        #expect(matches("ACME", in: "acme corp", caseSensitive: true).isEmpty)
    }

    // Spec §4: the literal is redacted "wherever it appears" — so this is a substring
    // search, not a word search.
    @Test("Matches inside a larger word")
    func matchesInsideWord() {
        let found = matches("art", in: "Smart carts")
        #expect(found.count == 2)
    }

    @Test("Overlapping occurrences are reported once each, not doubled")
    func nonOverlapping() {
        let found = matches("aa", in: "aaaa")
        #expect(found.count == 2)
    }

    @Test("Spans a line break in the page text")
    func spansLineBreak() {
        let text = SourceText("Mail to 123 Harbor View\nDrive before Friday.")
        let found = ExactTextMatcher(literal: "123 Harbor View Drive").matches(in: text)
        #expect(found.count == 1)
        // The reported span covers the newline, so the redaction covers both lines.
        #expect(found.first?.matchedText == "123 Harbor View\nDrive")
    }

    @Test("Spans a hyphenated word broken across lines")
    func spansHyphenation() {
        let text = SourceText("Property of Knob\nLLC in Har-\nbor City")
        #expect(ExactTextMatcher(literal: "Harbor City").matches(in: text).first?.matchedText == "Har-\nbor City")
        #expect(ExactTextMatcher(literal: "Knob LLC").matches(in: text).first?.matchedText == "Knob\nLLC")
    }

    @Test("Tolerates extra whitespace between words", arguments: [
        "Knob LLC", "Knob  LLC", "Knob\tLLC", "Knob \n LLC",
    ])
    func toleratesWhitespaceRuns(_ rendering: String) {
        #expect(matches("Knob LLC", in: "Owned by \(rendering).").count == 1)
    }

    @Test("A rule written with stray whitespace still matches")
    func normalizesTheNeedle() {
        #expect(matches("  Knob   LLC ", in: "Owned by Knob LLC.").count == 1)
    }

    @Test("Diacritics are significant")
    func diacriticsMatter() {
        #expect(matches("Café", in: "the Café closed").count == 1)
        #expect(matches("Café", in: "the Cafe closed").isEmpty)
    }

    @Test("Matches unicode literals")
    func unicodeLiteral() {
        #expect(matches("Münster 🔒", in: "at Münster 🔒 today").count == 1)
    }

    @Test("A literal that normalizes to nothing matches nothing", arguments: ["", "   ", "\n"])
    func emptyNeedle(_ literal: String) {
        #expect(matches(literal, in: "any text at all").isEmpty)
    }

    @Test("Matches carry the originating rule for the redaction report")
    func carriesProvenance() {
        let rule = ExactRule(literal: "Nikhil", isCaseSensitive: false, lineNumber: 4)
        let found = ExactTextMatcher(rule: rule).matches(in: SourceText("Nikhil"))
        #expect(found.first?.source == .exact(rule))
        #expect(found.first?.source.ruleDescription.contains("Nikhil") == true)
    }

    @Test("The String convenience overload agrees with the SourceText one")
    func stringConvenience() {
        let matcher = ExactTextMatcher(literal: "Knob LLC")
        #expect(matcher.matches(in: "Knob LLC").count == matcher.matches(in: SourceText("Knob LLC")).count)
    }
}
