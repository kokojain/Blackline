import Foundation
import Testing
import BlacklineKit
import BlacklineRedactor
import BlacklineOCR
import PDFKit
import AppKit
@testable import BlacklineUI

/// The loop end to end: read a document, edit its plan, press Go.
@MainActor
@Suite("The Go loop", .serialized)
struct GoLoopTests {

    private func fixture() throws -> URL {
        try UIRendering.ReviewSnapshotTests.makeFixture(scannedPage: false)
    }

    private func matchers(_ rules: String) -> [any Matcher] {
        MatcherFactory().makeMatchers(for: RulesParser().parse(rules).ruleSet).matchers
    }

    /// Runs an analysis and waits for it, since the job reports through a callback.
    private func analyse(_ source: URL, rules: String) async throws -> AnalysisJob {
        let job = AnalysisJob(sourceURL: source)
        await withCheckedContinuation { continuation in
            job.run(
                matchers: matchers(rules),
                wanted: [],
                guidance: "",
                usesModel: false,
                globalRulesPath: nil
            ) { _ in continuation.resume() }
        }
        return job
    }

    /// What is actually readable on the finished page.
    ///
    /// Redacted pages are rasterized, so their text layer is gone whether a value was
    /// covered or not — searching the file's bytes cannot tell "removed" from "still there
    /// in the picture". Reading the page back is the only check that can.
    private func readable(_ url: URL, page index: Int = 0) throws -> String {
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: index))
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 4
        let context = try #require(CGContext(
            data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: context)
        let image = try #require(context.makeImage())
        return try PageOCR().read(image, pageBox: box).text
    }

    private func redact(_ source: URL, from plan: DocumentPlan, to output: URL?) async throws -> PDFRedactor.Result {
        try await PDFRedactor(verifiesByReading: false, holdsUnverifiedOutputForReview: true)
            .redact(
                documentAt: source,
                matchers: plan.selectedValues.map { ExactTextMatcher(literal: $0) },
                writingTo: output
            )
    }

    // MARK: - Reading

    @Test("Reading a document writes a plan beside it and redacts nothing")
    func analysisWritesAPlan() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let job = try await analyse(source, rules: "social security numbers\nemployer identification numbers")

        guard case .finished(let planURL) = job.phase else {
            Issue.record("expected the analysis to finish, got \(job.phase)")
            return
        }
        #expect(planURL.lastPathComponent.hasSuffix(".md"))
        #expect(FileManager.default.fileExists(atPath: planURL.path))

        let plan = try #require(DocumentPlan.load(for: source))
        #expect(plan.selectedValues.contains("12-3456789"))
        #expect(plan.selectedValues.contains("123-45-6789"))

        // The whole point of stopping here: no redacted copy exists yet.
        #expect(!FileManager.default.fileExists(atPath: PDFRedactor.outputURL(for: source).path))
    }

    // MARK: - The plan decides

    @Test("Unticking an item leaves it in the document")
    func untickedItemsSurvive() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        _ = try await analyse(source, rules: "social security numbers\n\"Knob LLC\"")
        var plan = try #require(DocumentPlan.load(for: source))

        // The user unticks the company name and keeps the SSN.
        for index in plan.items.indices where plan.items[index].value == "Knob LLC" {
            plan.items[index].isSelected = false
        }
        try plan.write(for: source)

        let edited = try #require(DocumentPlan.load(for: source))
        #expect(edited.selectedValues.contains("123-45-6789"))
        #expect(!edited.selectedValues.contains("Knob LLC"))

        let result = try await redact(source, from: edited, to: nil)
        let visible = try readable(result.outputURL)

        #expect(!visible.contains("123-45-6789"), "the ticked SSN is gone from the page")
        #expect(visible.contains("Knob LLC"), "the unticked company name is still on the page")
    }

    @Test("A value typed into the plan by hand is removed")
    func handTypedValuesAreRemoved() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        _ = try await analyse(source, rules: "social security numbers")
        var plan = try #require(DocumentPlan.load(for: source))
        plan.items.append(.init(value: "Knob LLC", label: "typed by hand"))
        try plan.write(for: source)

        let result = try await redact(source, from: try #require(DocumentPlan.load(for: source)), to: nil)
        let bytes = try Data(contentsOf: result.outputURL)
        #expect(bytes.range(of: Data("Knob LLC".utf8)) == nil)
    }

    // MARK: - Going again

    @Test("A second Go replaces the same file rather than making another")
    func goingAgainReplaces() async throws {
        let source = try fixture()
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await analyse(source, rules: "social security numbers\n\"Knob LLC\"")
        let first = try await redact(source, from: try #require(DocumentPlan.load(for: source)), to: nil)

        // Second time round, only the company name is wanted.
        var plan = try #require(DocumentPlan.load(for: source))
        for index in plan.items.indices {
            plan.items[index].isSelected = plan.items[index].value == "Knob LLC"
        }
        try plan.write(for: source)

        let second = try await redact(source, from: try #require(DocumentPlan.load(for: source)), to: first.outputURL)

        #expect(second.outputURL == first.outputURL)
        let pdfs = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".pdf") }
        #expect(pdfs.count == 2, "the original and one redacted copy, not a trail of them")

        // The file reflects the second plan, not the first.
        let visible = try readable(second.outputURL)
        #expect(!visible.contains("Knob LLC"))
        #expect(visible.contains("123-45-6789"), "unticked this time, so it is back on the page")
    }

    // MARK: - Re-reading

    @Test("Re-reading a document keeps the decisions already made")
    func rereadingKeepsDecisions() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        _ = try await analyse(source, rules: "social security numbers\nemployer identification numbers")
        var plan = try #require(DocumentPlan.load(for: source))
        for index in plan.items.indices where plan.items[index].value == "12-3456789" {
            plan.items[index].isSelected = false
        }
        plan.items.append(.init(value: "Knob LLC", label: "typed by hand"))
        try plan.write(for: source)

        _ = try await analyse(source, rules: "social security numbers\nemployer identification numbers")

        let after = try #require(DocumentPlan.load(for: source))
        #expect(after.items.first { $0.value == "12-3456789" }?.isSelected == false, "the untick survived")
        #expect(after.selectedValues.contains("Knob LLC"), "the hand-typed line survived")
        #expect(after.selectedValues.contains("123-45-6789"))
    }

    @Test("A plan with nothing ticked removes nothing")
    func emptyPlanRemovesNothing() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        _ = try await analyse(source, rules: "social security numbers")
        var plan = try #require(DocumentPlan.load(for: source))
        for index in plan.items.indices { plan.items[index].isSelected = false }
        try plan.write(for: source)

        let empty = try #require(DocumentPlan.load(for: source))
        #expect(empty.isEmpty)

        // Spec §3: a copy identical to the original is a privacy failure, not a success.
        await #expect(throws: PDFRedactor.Failure.self) {
            _ = try await redact(source, from: empty, to: nil)
        }
    }
}
