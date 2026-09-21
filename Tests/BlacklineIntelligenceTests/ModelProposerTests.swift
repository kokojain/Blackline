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

@Suite("ProposalFilter")
struct ProposalFilterTests {

    // A tax return is mostly figures, and almost none of them identify anyone. Redacting
    // them ruins the document for whoever has to read it and protects nobody.
    @Test("Rejects money and bare quantities", arguments: [
        "84,320.00", "1,250.00", "$1,250", "$ 84,320.00", "284,300", "0", "12.5%",
        "(2,000)", "100.000 %", "18,400", "6,250", "2025", "1120",
    ])
    func rejectsMoney(_ candidate: String) {
        #expect(ProposalFilter.isNotIdentifying(candidate))
    }

    // Long digit runs are identifiers even though they are made only of digits, so the
    // filter has to let them through.
    @Test("Keeps identifiers that happen to be all digits", arguments: [
        "000123456789", "123456789", "021000021", "4111111111111111",
    ])
    func keepsLongDigitRuns(_ candidate: String) {
        #expect(!ProposalFilter.isNotIdentifying(candidate))
    }

    @Test("Keeps everything that is plainly identifying", arguments: [
        "12-3456789", "123-45-6789", "Jane Q Taxpayer", "Knob LLC",
        "123 Harbor View Drive", "Portland, ME 04101", "4111 1111 1111 1111",
    ])
    func keepsIdentifiers(_ candidate: String) {
        #expect(!ProposalFilter.isNotIdentifying(candidate))
    }

    @Test("Rejects nothing-at-all")
    func rejectsEmpty() {
        #expect(ProposalFilter.isNotIdentifying(""))
        #expect(ProposalFilter.isNotIdentifying("   "))
    }

    // Observed on a W-2: the model reported "Box 2", "Box 3" and "Box 17" as account
    // numbers. Vision reads a caption and its dotted leader as one token, so blacking out
    // "Box 2" takes the whole row with it — three rows of the form went black.
    // A 1120S carries a page listing dozens of IRS forms. The model reported the lot as
    // account numbers; they are the same on every copy in the country.
    @Test("Rejects the names of published forms", arguments: [
        "Form 1041-ND", "Form 1041 (trust)", "Form 990 (bankruptcy estate only)",
        "SCHEDULE K-1", "FORM 3885-CORP", "Form 8879-S", "Sch. D",
    ])
    func rejectsPublishedForms(_ candidate: String) {
        #expect(ProposalFilter.isNotIdentifying(candidate))
    }

    @Test("Keeps a form reference that carries a name", arguments: [
        "Schedule K-1 for Jane Taxpayer", "Form 1120S Knob Holdings",
    ])
    func keepsNamedFormReferences(_ candidate: String) {
        #expect(!ProposalFilter.isNotIdentifying(candidate))
    }

    @Test("Rejects box and line captions", arguments: [
        "Box 1", "Box 17", "box 2", "Line 12", "Line 7a", "Part 3", "Schedule 1",
        "Form 1040", "Page 2", "Item 4", "Column 3", "Step 2", "Code 12",
    ])
    func rejectsFormFurniture(_ candidate: String) {
        #expect(ProposalFilter.isNotIdentifying(candidate))
    }

    // The caption test must not reach a value that merely starts with one of those words.
    @Test("Keeps values a caption test could swallow", arguments: [
        "PO Box 1234", "Box 1234567890", "Lines Ltd", "Schedule K-1 for Jane Taxpayer",
        "Formby, Merseyside L37 3PX",
    ])
    func keepsValuesNearCaptions(_ candidate: String) {
        #expect(!ProposalFilter.isNotIdentifying(candidate))
    }

    // The instructions forbid reporting money. A proposal labelled "money" is one the model
    // has itself put out of scope while reporting it anyway.
    @Test("Rejects a proposal the model labels as money", arguments: [
        "money", "Money", "dollar amount", "total", "account balance", "annual wages",
        "compensation", "percentage", "form title", "line number",
    ])
    func rejectsExcludedKinds(_ kind: String) {
        #expect(ProposalFilter.isExcludedKind(kind))
    }

    @Test("Keeps the kinds that are the point of the model tier", arguments: [
        "person name", "street address", "date of birth", "account number", "email address",
        "employer identification number", "signature", "", "preparer identifier",
    ])
    func keepsIdentifyingKinds(_ kind: String) {
        #expect(!ProposalFilter.isExcludedKind(kind))
    }
}

/// What the model hands back around a value, and what has to come off before it is redacted.
@Suite("Proposals carry their captions")
struct ProposalCaptionTests {

    // Observed on a W-2: asked for the personal information on the page, the model reports
    // the field label with the value. Redacting that span blacks out the caption, and a form
    // without its captions cannot be read.
    @Test("The caption in front of a value is removed", arguments: [
        ("Employee SSN: 123-45-6789", "123-45-6789"),
        ("Employee: Sarah J Chen", "Sarah J Chen"),
        ("Contact: payroll@example.com", "payroll@example.com"),
        ("Date of birth: 03/14/1982", "03/14/1982"),
    ])
    func stripsCaptions(_ testCase: (String, String)) {
        #expect(ProposalFilter.valueWithoutLabel(testCase.0) == testCase.1)
    }

    @Test("A value that is not a caption plus a value is left alone", arguments: [
        "123-45-6789", "Sarah J Chen", "https://example.com/portal",
        "88 Harbor St Apt 4B", "Suite 900: 400 Atlantic Ave",
    ])
    func keepsPlainValues(_ value: String) {
        #expect(ProposalFilter.valueWithoutLabel(value) == value)
    }

    @Test("A proposal that is a rule's finding plus its caption is recognised", arguments: [
        ("Routing 021000021", "021000021"),
        ("Direct deposit account number 000123456789", "000123456789"),
        ("Employer EIN: 12-3456789", "12-3456789"),
        ("123-45-6789", "123-45-6789"),
    ])
    func spotsCaptionedRuleHits(_ testCase: (String, String)) {
        #expect(ProposalFilter.isRuleHitWithCaption(testCase.0, ruleValue: testCase.1))
    }

    // On a two-column form the text layer interleaves the columns, so the address detector
    // sees only part of the address and the model sees all of it. Dropping the model's span
    // there would leave the street on the page.
    @Test("A proposal that genuinely covers more is kept")
    func keepsWiderProposals() {
        #expect(!ProposalFilter.isRuleHitWithCaption(
            "88 Harbor St Apt 4B Boston MA 02210", ruleValue: "Boston MA 02210"
        ))
        #expect(!ProposalFilter.isRuleHitWithCaption(
            "Sarah J Chen, 88 Harbor St", ruleValue: "Sarah J Chen"
        ))
    }
}

/// What the model hands back on a dense return, and why the shape of a value is evidence.
///
/// Every case here was taken from one run over a 21-page 1120S whose plan, unfiltered,
/// held 180 items and produced 2,632 redactions.
@Suite("Proposals have to look like what they claim to be")
struct ProposalShapeTests {

    @Test("Rejects values too slight to be an identifier", arguments: [
        "a", "b", "Yes", "( )", "12a", "13g", "16f", "cost", "year", "Date", "period",
        "S/L -", "1",
    ])
    func rejectsSlightValues(_ candidate: String) {
        #expect(ProposalFilter.isTooSlight(candidate))
    }

    @Test("Keeps values that carry the structure of an identifier", arguments: [
        "123-45-6789", "87-4091539", "David Auer", "KNOB LLC", "000123456789",
        "sarah.chen@example.com", "(617) 555-0148", "88 Harbor St",
    ])
    func keepsStructuredValues(_ candidate: String) {
        #expect(!ProposalFilter.isTooSlight(candidate))
    }

    // Line-item captions running down a Schedule K-1, all reported as person names.
    @Test("Rejects a caption the model called a name", arguments: [
        "Interest income", "Ordinary dividends", "Qualified dividends",
        "Net short-term capital gain (loss) (attach Schedule D)",
        "Other net rental income (loss). Subtract line 3c",
        "Unrecaptured section 1250 gain (attach statement)",
    ])
    func rejectsCaptionsCalledNames(_ candidate: String) {
        #expect(ProposalFilter.isImplausibleName(candidate, kind: "person name"))
    }

    @Test("Keeps names as names are written", arguments: [
        "David Auer", "KNOB LLC", "Sarah J Chen", "Knob Holdings LLC",
        "Ludwig van Beethoven", "Daniel Ortiz", "O'Brien & Sons",
    ])
    func keepsRealNames(_ candidate: String) {
        #expect(!ProposalFilter.isImplausibleName(candidate, kind: "person name"))
    }

    // The shape test only applies where the model claims a name.
    @Test("Says nothing about a value it was not asked about")
    func onlyJudgesNames() {
        #expect(!ProposalFilter.isImplausibleName("Interest income", kind: "account number"))
    }

    @Test("Rejects a table row the model called an account number")
    func rejectsOverlongIdentifiers() {
        let row = "24506035 130000 100.000 1000.00000 KNOB LLC 87"
        #expect(ProposalFilter.isImplausibleIdentifier(row, kind: "account number"))
        #expect(!ProposalFilter.isImplausibleIdentifier("000123456789", kind: "account number"))
        #expect(!ProposalFilter.isImplausibleIdentifier("87-4091539", kind: "EIN"))
    }
}

/// Tier 3 may only contribute a finding it can name as something this app removes.
@Suite("Proposal labels are an allow-list")
struct ProposalKindAllowListTests {

    @Test("Allows the labels for what Blackline removes", arguments: [
        "person name", "organization name", "company name", "street address",
        "social security number", "SSN", "ITIN", "employer identification number", "EIN",
        "account number", "routing number", "bank name", "financial institution",
        "credit card number", "date of birth", "DOB", "phone number", "email address",
        "passport number", "driver's license number", "PIN", "password", "API key",
        "access code", "signature", "insurance policy number", "wallet address",
    ])
    func allowsIdentifyingKinds(_ kind: String) {
        #expect(ProposalFilter.isAllowedKind(kind))
    }

    // Every one of these came back from a real run and ruined part of a page.
    @Test("Drops a label that names something else", arguments: [
        "property", "question", "letter", "string", "form code",
        "document title", "line item", "description", "class life", "method",
        "depreciation class", "checkbox", "instruction", "amount", "figure",
    ])
    func dropsUnknownKinds(_ kind: String) {
        #expect(!ProposalFilter.isAllowedKind(kind))
    }

    // "Account Type" names the kind of an account rather than an account, and it carries
    // the word "account" — so the allow-list passes it and the deny-list has to catch it.
    @Test("A label naming a value's type is caught by the deny-list")
    func typeLabelsAreDenied() {
        #expect(ProposalFilter.isAllowedKind("Account Type"))
        #expect(ProposalFilter.isExcludedKind("Account Type"))
    }

    // A blank label says nothing either way, so the shape tests decide.
    @Test("An empty label is not itself a reason to drop")
    func allowsEmptyKind() {
        #expect(ProposalFilter.isAllowedKind(""))
        #expect(ProposalFilter.isAllowedKind("   "))
    }
}
