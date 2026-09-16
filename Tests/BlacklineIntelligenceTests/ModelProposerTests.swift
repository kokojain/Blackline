import Testing
import BlacklineKit
@testable import BlacklineIntelligence

// The model itself is not exercised here — it is non-deterministic and needs Apple
// Intelligence enabled. What is tested is the deterministic plumbing around it, which is
// what keeps an unpredictable component safe to use.
@Suite("Proposal plumbing")
struct ProposalPlumbingTests {

    @Test("Short text is sent as a single chunk")
    func singleChunk() {
        #expect(TextChunker.chunks(of: "one line", maxLength: 100) == ["one line"])
    }

    @Test("Empty text produces no chunks")
    func emptyText() {
        #expect(TextChunker.chunks(of: "", maxLength: 100).isEmpty)
    }

    @Test("Long text is split on line boundaries")
    func splitsOnLines() {
        let text = (1 ... 20).map { "line number \($0)" }.joined(separator: "\n")
        let chunks = TextChunker.chunks(of: text, maxLength: 60)
        #expect(chunks.count > 1)
        // Nothing may be lost or duplicated: the chunks must rejoin into the original.
        #expect(chunks.joined(separator: "\n") == text)
        for chunk in chunks {
            #expect(!chunk.hasPrefix("\n") && !chunk.hasSuffix("\n"))
        }
    }

    // Cutting mid-line could split an identifier in half, so an over-long line is sent
    // whole rather than truncated.
    @Test("A single over-long line is kept intact")
    func overlongLine() {
        let line = String(repeating: "x", count: 500)
        let chunks = TextChunker.chunks(of: line, maxLength: 100)
        #expect(chunks == [line])
    }

    @Test("Chunking never drops content, at any budget", arguments: [10, 37, 60, 200])
    func losslessAtAnyBudget(_ budget: Int) {
        let text = (1 ... 30).map { "field \($0): value \($0)" }.joined(separator: "\n")
        #expect(TextChunker.chunks(of: text, maxLength: budget).joined(separator: "\n") == text)
    }

    // Rule 2 of the proposer contract: a span the model invents cannot be located, so it
    // is discarded rather than redacted at a guessed offset.
    @Test("Proposals that do not appear on the page are discarded, not located")
    func discardsUnlocatable() {
        let page = SourceText("Your name: Jane Q Taxpayer")
        let proposals = [
            Proposal(text: "Jane Q Taxpayer", kind: "person name", reason: "names the filer"),
            Proposal(text: "Robert Invented", kind: "person name", reason: "hallucinated"),
        ]
        let (located, unlocated) = ProposalLocator().locate(proposals, in: page)
        #expect(located.count == 1)
        #expect(located.first?.matches.first?.matchedText == "Jane Q Taxpayer")
        #expect(unlocated.map(\.text) == ["Robert Invented"])
    }

    // Proposals inherit the matcher layer's wrap tolerance: the model reads normalized
    // text and proposes "Harbor View Drive", but the page wrapped it mid-word.
    @Test("A proposal still locates text that wrapped across a line")
    func locatesAcrossLineBreak() {
        let page = SourceText("Address: 123 Har-\nbor View Drive, Apt 2")
        let proposal = Proposal(
            text: "123 Harbor View Drive",
            kind: "street address",
            reason: "locates the filer"
        )
        let (located, unlocated) = ProposalLocator().locate([proposal], in: page)
        #expect(unlocated.isEmpty)
        #expect(located.first?.matches.first?.matchedText == "123 Har-\nbor View Drive")
    }
}

@Suite("ResidueFilter")
struct ResidueFilterTests {

    // Asked what is still visible on a redacted page, a checker reports the labels beside
    // the black boxes. Acting on those blacks out the page a line at a time.
    @Test("Rejects field labels", arguments: [
        "Name:", "Account number:", "SSN:",
    ])
    func rejectsLabels(_ candidate: String) {
        #expect(!ResidueFilter.looksLikeAValue(candidate))
    }

    // OCR of a word clipped by a black box comes back as garbage, at full confidence.
    @Test("Rejects clipped fragments", arguments: ["Emplo", "ifica", "ETN", "x", ""])
    func rejectsFragments(_ candidate: String) {
        #expect(!ResidueFilter.looksLikeAValue(candidate))
    }

    // Deliberately loose: a label the box cut through still passes, so a label gets covered
    // too. Tightening this to reject it would also reject "Jane Q", which is a real name.
    @Test("Lets a truncated label through rather than risk dropping a short name")
    func prefersOverCoverage() {
        #expect(ResidueFilter.looksLikeAValue("Employer ID n"))
        #expect(ResidueFilter.looksLikeAValue("Jane Q"))
    }

    @Test("Keeps values that genuinely identify someone", arguments: [
        "12-3456789", "123-45-6789", "Jane Q Taxpayer", "123 Harbor View Drive",
        "Knob LLC", "Portland, ME 04101", "000123456789",
    ])
    func keepsValues(_ candidate: String) {
        #expect(ResidueFilter.looksLikeAValue(candidate))
    }
}

@Suite("Chunk splitting")
struct ChunkSplittingTests {

    // The context window holds the reply as well as the prompt, so whether a chunk fits
    // cannot be known in advance. When one does not, it is halved and asked again — which
    // only works if halving never lands inside an identifier.
    @Test("Halving prefers a line break, then a space")
    func halvesOnBoundaries() throws {
        let lined = "aaaa bbbb\ncccc dddd"
        let (first, second) = try #require(TextChunker.halve(lined))
        #expect(first + second == lined)
        #expect(second.hasPrefix("\n"))

        let spaced = "aaaaa bbbbb"
        let (left, right) = try #require(TextChunker.halve(spaced))
        #expect(left + right == spaced)
        #expect(right.hasPrefix(" "))
    }

    @Test("Halving never loses or duplicates text", arguments: [
        "12-3456789 and 987-65-4321",
        "one\ntwo\nthree\nfour",
        String(repeating: "x", count: 501),
        "a b",
    ])
    func halvingIsLossless(_ text: String) throws {
        let (first, second) = try #require(TextChunker.halve(text))
        #expect(first + second == text)
        #expect(!first.isEmpty)
        #expect(!second.isEmpty)
    }

    @Test("A single character cannot be halved")
    func singleCharacter() {
        #expect(TextChunker.halve("x") == nil)
        #expect(TextChunker.halve("") == nil)
    }

    // Splitting has to stop somewhere, or a chunk the model simply refuses would recurse
    // until every character is its own request.
    @Test("There is a floor below which splitting stops")
    func hasAFloor() {
        #expect(TextChunker.smallestUsefulChunk > 0)
        #expect(TextChunker.smallestUsefulChunk < 1_200)
    }
}
