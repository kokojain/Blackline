import Foundation
import Testing
@testable import BlacklineKit

@Suite("DocumentPlan")
struct DocumentPlanTests {

    private func plan(_ items: [DocumentPlan.Item]) -> DocumentPlan {
        DocumentPlan(sourceName: "return.pdf", items: items)
    }

    // MARK: - Round trip

    @Test("Survives being written and read back")
    func roundTrips() {
        let original = plan([
            .init(value: "12-3456789", label: "employer identification numbers", page: 1),
            .init(isSelected: false, value: "1,284,300", label: "amount", page: 1),
            .init(value: "Jane Q Taxpayer", label: "person name", page: 2),
        ])

        let read = DocumentPlan.parse(original.markdown(globalRulesPath: nil), sourceName: "return.pdf")
        #expect(read.items == original.items)
        #expect(read.selectedValues == ["12-3456789", "Jane Q Taxpayer"])
    }

    @Test("Only ticked items are removed")
    func onlyTickedItems() {
        let subject = plan([
            .init(isSelected: true, value: "keep-me-out", page: 1),
            .init(isSelected: false, value: "leave-me-in", page: 1),
        ])
        #expect(subject.selectedValues == ["keep-me-out"])
    }

    @Test("Values keep their exact spelling, spaces and punctuation")
    func preservesAwkwardValues() {
        let awkward = ["123 Harbor View Drive", "Portland, ME 04101", "O'Brien & Sons — Ltd.", "4111 1111 1111 1111"]
        let subject = plan(awkward.map { .init(value: $0, page: 1) })
        let read = DocumentPlan.parse(subject.markdown(globalRulesPath: nil), sourceName: "return.pdf")
        #expect(read.selectedValues == awkward)
    }

    // MARK: - Editing by hand

    @Test("Reads a line typed by hand, with or without a label")
    func handTypedLines() {
        let text = """
        ## Page 1
        - [x] `Acme Holdings` — my own addition
        - [x] `Second Street`
        - [ ] `not this one`
        """
        let read = DocumentPlan.parse(text, sourceName: "return.pdf")
        #expect(read.items.count == 3)
        #expect(read.selectedValues == ["Acme Holdings", "Second Street"])
        #expect(read.items[0].label == "my own addition")
        #expect(read.items[1].label.isEmpty)
    }

    @Test("Accepts the tick forms a person is likely to type", arguments: [
        "- [x] `value`", "- [X] `value`", "* [x] `value`", "   - [x] `value`",
    ])
    func tolerantTicks(_ line: String) {
        let read = DocumentPlan.parse("## Page 1\n\(line)", sourceName: "d.pdf")
        #expect(read.selectedValues == ["value"])
    }

    @Test("Reads a value written without backticks")
    func withoutBackticks() {
        let read = DocumentPlan.parse("## Page 1\n- [x] Acme Holdings — a note", sourceName: "d.pdf")
        #expect(read.selectedValues == ["Acme Holdings"])
        #expect(read.items.first?.label == "a note")
    }

    // Prose, headings and notes must not become redaction targets.
    @Test("Ignores everything that is not an item line")
    func ignoresProse() {
        let text = """
        # Redaction plan — return.pdf

        Tick an item to remove it. Some notes I wrote myself.

        > This file lists the values found in the document.

        ## Page 1
        - [x] `12-3456789` — employer identification numbers

        Another note, with a - dash in it.
        """
        let read = DocumentPlan.parse(text, sourceName: "return.pdf")
        #expect(read.items.count == 1)
        #expect(read.selectedValues == ["12-3456789"])
    }

    @Test("An empty or bodyless plan removes nothing")
    func emptyPlan() {
        #expect(DocumentPlan.parse("", sourceName: "d.pdf").isEmpty)
        #expect(DocumentPlan.parse("# Just a heading", sourceName: "d.pdf").isEmpty)
        #expect(plan([]).isEmpty)
    }

    // MARK: - Merging

    // The plan exists to hold the user's decisions, so a rescan must not undo them.
    @Test("A rescan keeps what the user decided")
    func mergeKeepsDecisions() {
        let edited = plan([
            .init(isSelected: false, value: "1,284,300", label: "amount", page: 1),
            .init(isSelected: true, value: "12-3456789", label: "employer ID", page: 1),
        ])
        let rescan = plan([
            .init(isSelected: true, value: "1,284,300", label: "amount", page: 1),
            .init(isSelected: true, value: "12-3456789", label: "employer ID", page: 1),
            .init(isSelected: true, value: "987-65-4321", label: "social security numbers", page: 2),
        ])

        let merged = edited.merged(with: rescan)
        #expect(merged.items.count == 3)
        #expect(merged.selectedValues == ["12-3456789", "987-65-4321"])
        #expect(merged.items.first { $0.value == "1,284,300" }?.isSelected == false)
    }

    @Test("A rescan keeps lines the user typed themselves")
    func mergeKeepsHandTypedLines() {
        let edited = plan([.init(value: "Acme Holdings", label: "mine", page: nil)])
        let rescan = plan([.init(value: "12-3456789", label: "employer ID", page: 1)])

        let merged = edited.merged(with: rescan)
        #expect(merged.selectedValues.sorted() == ["12-3456789", "Acme Holdings"])
    }

    // MARK: - On disk

    @Test("Writes beside the document, as <name>.md")
    func writesBesideTheDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("2025 Knob LLC 1120S.pdf")
        try Data().write(to: source)

        let written = try plan([.init(value: "12-3456789", page: 1)])
            .write(for: source, globalRulesPath: "~/Documents/globalrules.md")

        #expect(written.lastPathComponent == "2025 Knob LLC 1120S.md")
        #expect(written.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)

        let reloaded = try #require(DocumentPlan.load(for: source))
        #expect(reloaded.selectedValues == ["12-3456789"])

        DocumentPlan.delete(for: source)
        #expect(DocumentPlan.load(for: source) == nil)
    }

    // It is a plaintext index of exactly what is being removed, in the folder the document
    // will be shared from. The file has to say so itself.
    @Test("The file warns what it contains")
    func warnsAboutItsContents() {
        let text = plan([.init(value: "12-3456789", page: 1)]).markdown(globalRulesPath: nil)
        // The warning is wrapped across lines in the file, so check its parts.
        #expect(text.contains("lists the values in full"))
        #expect(text.contains("as sensitive"))
        #expect(text.contains("Delete it when you are done"))
    }
}

@Suite("GlobalRules")
struct GlobalRulesTests {

    @Test("Strips markdown furniture, keeping the sentences")
    func stripsFurniture() {
        let rules = GlobalRules(text: """
        # Global rules

        - Remove names and addresses.
        * Leave money alone.
        > Never touch line captions.
        """)
        let guidance = rules.guidance
        #expect(guidance == "Global rules\nRemove names and addresses.\nLeave money alone.\nNever touch line captions.")
    }

    @Test("An absent or blank file is simply empty")
    func emptyRules() {
        #expect(GlobalRules(text: "").isEmpty)
        #expect(GlobalRules(text: "   \n\n  ").isEmpty)
        #expect(GlobalRules.load(from: URL(fileURLWithPath: "/nonexistent/globalrules.md")).isEmpty)
    }

    // The starter file has to model the behaviour the user asked for: identifiers out,
    // money left alone.
    @Test("The starter file says to leave money alone")
    func starterLeavesMoneyAlone() {
        #expect(GlobalRules.starter.contains("Leave money alone"))
        #expect(GlobalRules(text: GlobalRules.starter).isEmpty == false)
    }
}

/// Guidance goes into a prompt whose whole context — instructions, rules, page text and the
/// reply — is about 4,000 tokens. A policy document pasted into `globalrules.md` overflows
/// it on every page, and the failure is silent: the run falls back to the detectors alone.
@Suite("Global rules fit in the prompt")
struct GlobalRulesBudgetTests {

    private func longRules(characters: Int) -> GlobalRules {
        let line = "Remove every identifier that names a person or an organisation."
        let lines = (characters / line.count) + 2
        return GlobalRules(text: (0 ..< lines).map { _ in "- \(line)" }.joined(separator: "\n"))
    }

    @Test("Ordinary guidance is passed through whole")
    func shortGuidanceIsUntouched() {
        let rules = GlobalRules(text: GlobalRules.starter)
        #expect(rules.guidance == rules.strippedGuidance)
        #expect(rules.omittedCharacterCount == 0)
    }

    @Test("Guidance past the budget is trimmed to it")
    func longGuidanceIsTrimmed() {
        let rules = longRules(characters: GlobalRules.promptBudget * 3)
        #expect(rules.guidance.count <= GlobalRules.promptBudget)
        #expect(rules.omittedCharacterCount > 0)
    }

    @Test("It is trimmed at a line boundary, so no rule is cut in half")
    func trimsAtALineBoundary() {
        let rules = longRules(characters: GlobalRules.promptBudget * 2)
        let lines = rules.guidance.split(separator: "\n")
        #expect(lines.allSatisfy { $0.hasSuffix("organisation.") })
    }

    // Trimming silently would mean a run implying it followed rules it never saw.
    @Test("What was dropped is countable, so a caller can report it")
    func omissionIsCountable() {
        let rules = longRules(characters: GlobalRules.promptBudget * 2)
        #expect(rules.omittedCharacterCount
            == rules.strippedGuidance.count - rules.guidance.count)
    }
}

/// A postal address is matched across the line break the form printed it on, so the value
/// reaching a plan carries a newline.
@Suite("Plan items are one line")
struct DocumentPlanLineTests {

    @Test("A value that wrapped is stored on one line")
    func wrappedValueIsFolded() {
        let item = DocumentPlan.Item(value: "400 Atlantic Ave Suite 900\nBoston MA 02110")
        #expect(item.value == "400 Atlantic Ave Suite 900 Boston MA 02110")
    }

    // Written raw, the newline ends the markdown line halfway through: the value is lost and
    // so is the rest of the line after it.
    @Test("Such a plan survives a round trip through the file")
    func roundTripsThroughTheFile() {
        let plan = DocumentPlan(sourceName: "w2.pdf", items: [
            DocumentPlan.Item(value: "400 Atlantic Ave Suite 900\nBoston MA 02110",
                              label: "street addresses", page: 1),
            DocumentPlan.Item(value: "123-45-6789", label: "social security numbers", page: 1),
        ])
        let reread = DocumentPlan.parse(plan.markdown(globalRulesPath: nil), sourceName: "w2.pdf")
        #expect(reread.items.count == 2)
        #expect(reread.selectedValues == [
            "400 Atlantic Ave Suite 900 Boston MA 02110", "123-45-6789",
        ])
    }

    // The folded value has to still find the wrapped text, or the fix would trade a broken
    // plan for a missed redaction.
    @Test("The folded value still matches the text it came from")
    func foldedValueStillMatches() {
        let page = SourceText("Employer\n400 Atlantic Ave Suite 900\nBoston MA 02110\nBox 1")
        let item = DocumentPlan.Item(value: "400 Atlantic Ave Suite 900\nBoston MA 02110")
        let found = ExactTextMatcher(literal: item.value).matches(in: page)
        #expect(found.count == 1)
        #expect(found.first?.matchedText == "400 Atlantic Ave Suite 900\nBoston MA 02110")
    }
}
