import Testing
@testable import BlacklineKit

@Suite("SourceText normalization")
struct SourceTextTests {

    @Test("Collapses runs of whitespace to a single space")
    func collapsesWhitespace() {
        #expect(SourceText("Knob   LLC").normalized == "Knob LLC")
        #expect(SourceText("Knob\t\tLLC").normalized == "Knob LLC")
        #expect(SourceText("Knob\n\nLLC").normalized == "Knob LLC")
    }

    @Test("Drops leading and trailing whitespace")
    func trimsEdges() {
        #expect(SourceText("   Knob LLC  \n").normalized == "Knob LLC")
        #expect(SourceText("\n\n").normalized == "")
        #expect(SourceText("").normalized == "")
    }

    @Test("Drops a leading byte-order mark")
    func dropsBOM() {
        #expect(SourceText("\u{FEFF}Knob LLC").normalized == "Knob LLC")
    }

    @Test("Normalizes CRLF and CR line endings")
    func handlesLineEndings() {
        #expect(SourceText("Knob\r\nLLC").normalized == "Knob LLC")
        #expect(SourceText("Knob\rLLC").normalized == "Knob LLC")
    }

    @Test("Rejoins a word hyphenated across a line break")
    func rejoinsHyphenatedWord() {
        #expect(SourceText("Har-\nbor View").normalized == "Harbor View")
        #expect(SourceText("Har-\r\nbor").normalized == "Harbor")
    }

    // The whole point of the letter test: eliding this hyphen would turn an SSN into an
    // unrecognizable digit run, which spec §7 calls the dangerous failure.
    @Test("Keeps a hyphen between digits split across a line break")
    func keepsDigitHyphen() {
        #expect(SourceText("123-45-\n6789").normalized == "123-45-6789")
        #expect(SourceText("4111-\n1111").normalized == "4111-1111")
    }

    @Test("Treats a spaced dash as a dash, not hyphenation")
    func spacedDashIsNotHyphenation() {
        #expect(SourceText("abc -\ndef").normalized == "abc -def")
    }

    @Test("Leaves an ordinary mid-line hyphen alone")
    func keepsInlineHyphen() {
        #expect(SourceText("well-known").normalized == "well-known")
        #expect(SourceText("Har- bor").normalized == "Har- bor")
    }

    @Test("A trailing hyphen at end of text is preserved")
    func trailingHyphen() {
        #expect(SourceText("Har-\n").normalized == "Har-")
    }

    @Test("Maps a normalized range back to the exact original substring")
    func roundTripsSimpleRange() {
        let text = SourceText("Hello Knob LLC world")
        let range = text.normalized.range(of: "Knob LLC")!
        let original = text.originalRange(forNormalized: range)!
        #expect(String(text.original[original]) == "Knob LLC")
        #expect(text.offsets(of: original) == 6 ..< 14)
    }

    @Test("A mapped range covers the line break it spans in the original")
    func roundTripSpansNewline() {
        let text = SourceText("123 Harbor View\nDrive, Apt 2")
        let range = text.normalized.range(of: "Harbor View Drive")!
        let original = text.originalRange(forNormalized: range)!
        #expect(String(text.original[original]) == "Harbor View\nDrive")
    }

    @Test("A mapped range covers an elided hyphenation hyphen")
    func roundTripSpansHyphenation() {
        let text = SourceText("Har-\nbor View")
        let range = text.normalized.range(of: "Harbor")!
        let original = text.originalRange(forNormalized: range)!
        #expect(String(text.original[original]) == "Har-\nbor")
    }

    @Test("Maps ranges at the very start and end of the text")
    func roundTripsEdges() {
        let text = SourceText("Knob LLC")
        let first = text.originalRange(fromOffset: 0, toOffset: 1)!
        #expect(String(text.original[first]) == "K")
        let last = text.originalRange(fromOffset: 7, toOffset: 8)!
        #expect(String(text.original[last]) == "C")
        #expect(last.upperBound == text.original.endIndex)
    }

    @Test("Rejects empty and out-of-bounds ranges")
    func rejectsBadRanges() {
        let text = SourceText("Knob")
        #expect(text.originalRange(fromOffset: 2, toOffset: 2) == nil)
        #expect(text.originalRange(fromOffset: 0, toOffset: 99) == nil)
        #expect(text.originalRange(fromOffset: -1, toOffset: 2) == nil)
    }

    @Test("Every normalized character maps to a non-empty original span")
    func mappingIsTotal() {
        let text = SourceText("  A-\nB  C\r\nD-45-\n6 ")
        for offset in 0 ..< text.normalizedCount {
            let range = text.originalRange(fromOffset: offset, toOffset: offset + 1)
            #expect(range != nil, "offset \(offset) did not map")
            #expect(range.map { $0.lowerBound < $0.upperBound } == true)
        }
    }

    @Test("normalize(_:) matches the instance normalization")
    func staticNormalizeAgrees() {
        let input = " Knob\n LLC "
        #expect(SourceText.normalize(input) == SourceText(input).normalized)
    }

    @Test("Preserves unicode and combining characters")
    func preservesUnicode() {
        #expect(SourceText("Café  Ünïcodé").normalized == "Café Ünïcodé")
        #expect(SourceText("emoji 🔒 here").normalized == "emoji 🔒 here")
    }
}
