import Foundation
import os
import PDFKit
import CoreText
import AppKit
import Testing
import BlacklineKit
@testable import BlacklineRedactor

@Suite("PDFRedactor")
struct PDFRedactorTests {

    /// Reading pages back costs about a second each; most of these tests are about what the
    /// redactor produces, not about verification, so they skip it. The loop has its own
    /// tests below.
    static let quick = PDFRedactor(verifiesByReading: false)

    // MARK: - Helpers

    /// Builds a small, well-formed PDF in a temporary directory.
    static func makePDF(lines: [String], named name: String = "doc") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackline-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).pdf")

        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        var y: CGFloat = 730
        for line in lines {
            if !line.isEmpty {
                let attributed = NSAttributedString(
                    string: line,
                    attributes: [.font: font, .foregroundColor: NSColor.black]
                )
                context.textPosition = CGPoint(x: 54, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            y -= 20
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// Writes a PDFDocument to a fresh path. PDFKit cannot reliably write a document back
    /// over the file it was opened from, so tests that mutate one write somewhere new.
    static func write(_ document: PDFDocument, besides source: URL, named name: String) throws -> URL {
        let url = source.deletingLastPathComponent().appendingPathComponent("\(name).pdf")
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    static func text(of url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        return (0 ..< document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    // MARK: - Output naming

    @Test("Names the output after the original, per spec §3")
    func outputNaming() throws {
        let source = try Self.makePDF(lines: ["nothing"], named: "statement")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        #expect(PDFRedactor.outputURL(for: source).lastPathComponent == "statement redacted.pdf")
    }

    @Test("Never overwrites: an existing output name gets a counter")
    func outputNamingCollision() throws {
        let source = try Self.makePDF(lines: ["nothing"], named: "statement")
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data().write(to: directory.appendingPathComponent("statement redacted.pdf"))
        #expect(PDFRedactor.outputURL(for: source).lastPathComponent == "statement redacted 2.pdf")

        try Data().write(to: directory.appendingPathComponent("statement redacted 2.pdf"))
        #expect(PDFRedactor.outputURL(for: source).lastPathComponent == "statement redacted 3.pdf")
    }

    // MARK: - End to end

    @Test("Removes matched text from the output entirely")
    func removesMatchedText() async throws {
        let source = try Self.makePDF(lines: [
            "Your social security number: 123-45-6789",
            "Account number: 000123456789",
            "Employer: Knob LLC",
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let matchers = MatcherFactory().makeMatchers(
            for: RulesParser().parse("social security numbers\naccount numbers").ruleSet
        ).matchers

        let result = try await Self.quick.redact(documentAt: source, matchers: matchers)
        #expect(result.redactedItemCount == 2)
        #expect(result.pagesRasterized == 1)
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))

        // Not merely covered: the text is gone from the document, and from the file's bytes.
        let extracted = Self.text(of: result.outputURL)
        #expect(!extracted.contains("123-45-6789"))
        #expect(!extracted.contains("000123456789"))

        let bytes = try Data(contentsOf: result.outputURL)
        #expect(bytes.range(of: Data("123-45-6789".utf8)) == nil)
        #expect(bytes.range(of: Data("000123456789".utf8)) == nil)
    }

    @Test("Leaves the original untouched, per spec §2")
    func originalIsUntouched() async throws {
        let source = try Self.makePDF(lines: ["Your social security number: 123-45-6789"])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let before = try Data(contentsOf: source)

        let matchers = MatcherFactory().makeMatchers(
            for: RulesParser().parse("social security numbers").ruleSet
        ).matchers
        _ = try await Self.quick.redact(documentAt: source, matchers: matchers)

        #expect(try Data(contentsOf: source) == before)
        #expect(Self.text(of: source).contains("123-45-6789"))
    }

    // Spec §3: a copy identical to the original is a privacy failure, not a success.
    @Test("Writes nothing when no rule matches")
    func refusesEmptyRedaction() async throws {
        let source = try Self.makePDF(lines: ["Nothing sensitive on this page."])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let matchers = MatcherFactory().makeMatchers(
            for: RulesParser().parse("social security numbers").ruleSet
        ).matchers

        await #expect(throws: PDFRedactor.Failure.self) {
            try await Self.quick.redact(documentAt: source, matchers: matchers)
        }
        #expect(!FileManager.default.fileExists(atPath: PDFRedactor.outputURL(for: source).path))
    }

    @Test("Pages with no matches keep their selectable text")
    func untouchedPagesAreNotRasterized() async throws {
        let source = try Self.makePDF(lines: ["Your social security number: 123-45-6789"])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        // Add a clean second page to the same document.
        let document = PDFDocument(url: source)!
        let clean = try Self.makePDF(lines: ["Page two has nothing to hide."], named: "clean")
        defer { try? FileManager.default.removeItem(at: clean.deletingLastPathComponent()) }
        document.insert(PDFDocument(url: clean)!.page(at: 0)!, at: 1)
        let twoPage = try Self.write(document, besides: source, named: "two-page")

        let matchers = MatcherFactory().makeMatchers(
            for: RulesParser().parse("social security numbers").ruleSet
        ).matchers
        let result = try await Self.quick.redact(documentAt: twoPage, matchers: matchers)

        #expect(result.pageCount == 2)
        #expect(result.pagesRasterized == 1)
        // The untouched page was copied through, so its text survives.
        #expect(Self.text(of: result.outputURL).contains("Page two has nothing to hide."))
    }

    @Test("Document metadata does not carry over, per spec §5.5")
    func metadataIsScrubbed() async throws {
        let source = try Self.makePDF(lines: ["Your social security number: 123-45-6789"])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let document = PDFDocument(url: source)!
        document.documentAttributes = [
            PDFDocumentAttribute.authorAttribute: "Jane Q Taxpayer",
            PDFDocumentAttribute.titleAttribute: "2025 return for Jane Q Taxpayer",
        ]
        let tagged = try Self.write(document, besides: source, named: "tagged")

        let matchers = MatcherFactory().makeMatchers(
            for: RulesParser().parse("social security numbers").ruleSet
        ).matchers
        let result = try await Self.quick.redact(documentAt: tagged, matchers: matchers)

        let attributes = PDFDocument(url: result.outputURL)?.documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(attributes[PDFDocumentAttribute.titleAttribute] == nil)

        let bytes = try Data(contentsOf: result.outputURL)
        #expect(bytes.range(of: Data("Jane Q Taxpayer".utf8)) == nil)
    }

    @Test("Reports which rules accounted for the redactions, per spec §7")
    func reportsRules() async throws {
        let source = try Self.makePDF(lines: [
            "SSN 123-45-6789 for Knob LLC",
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let matchers = MatcherFactory().makeMatchers(
            for: RulesParser().parse("social security numbers\n\"Knob LLC\"").ruleSet
        ).matchers
        let result = try await Self.quick.redact(documentAt: source, matchers: matchers)

        #expect(result.redactedItemCount == 2)
        #expect(result.rulesApplied.contains("social security numbers"))
        #expect(result.rulesApplied.contains { $0.contains("Knob LLC") })
    }
}

@Suite("PDFRedactor read-back loop")
struct PDFRedactorVerificationTests {

    private func matchers(_ rules: String) -> [any Matcher] {
        MatcherFactory().makeMatchers(for: RulesParser().parse(rules).ruleSet).matchers
    }

    // The behaviour asked for: check the rendered page, and if something sensitive is still
    // showing, black it out and render again.
    @Test("Residue found on the rendered page triggers another pass")
    func residueTriggersAnotherPass() async throws {
        let source = try PDFRedactorTests.makePDF(lines: [
            "Your social security number: 123-45-6789",
            "Employer: Knob LLC",
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        // Stands in for the model: reports something real the first time it is asked, then
        // agrees the page is clean.
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let inspector: PDFRedactor.VisibleTextInspector = { _ in
            asked.withLock { count in
                count += 1
                return count == 1 ? ["Knob LLC"] : []
            }
        }

        let result = try await PDFRedactor().redact(
            documentAt: source,
            matchers: matchers("social security numbers"),
            inspectVisibleText: inspector
        )

        #expect(result.verificationPasses == 2)
        #expect(result.residueCaughtOnRecheck.contains("Knob LLC"))
        #expect(asked.withLock { $0 } >= 2)
    }

    // Without this the checker chases OCR fragments of half-covered words and never settles.
    @Test("Residue that is not in the document is ignored")
    func ungroundedResidueIsIgnored() async throws {
        let source = try PDFRedactorTests.makePDF(lines: [
            "Your social security number: 123-45-6789",
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let inspector: PDFRedactor.VisibleTextInspector = { _ in ["ificatil", "ETN 9"] }

        let result = try await PDFRedactor().redact(
            documentAt: source,
            matchers: matchers("social security numbers"),
            inspectVisibleText: inspector
        )

        #expect(result.verificationPasses == 1)
        #expect(result.residueCaughtOnRecheck.isEmpty)
    }

    // Spec §5.6: a page still showing something after the last allowed pass produces no file
    // at all, rather than one the user has to check by hand.
    @Test("A page still dirty when the passes run out aborts the document")
    func unsettleablePageAborts() async throws {
        let source = try PDFRedactorTests.makePDF(lines: [
            "Your social security number: 123-45-6789",
            "Employer: Knob LLC",
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let inspector: PDFRedactor.VisibleTextInspector = { _ in ["Knob LLC"] }

        // One pass allowed, and that pass finds something: there is no budget to fix it.
        await #expect(throws: PDFRedactor.Failure.self) {
            try await PDFRedactor(maximumVerificationPasses: 1).redact(
                documentAt: source,
                matchers: matchers("social security numbers"),
                inspectVisibleText: inspector
            )
        }
        #expect(!FileManager.default.fileExists(atPath: PDFRedactor.outputURL(for: source).path))
    }

    // Covered text cannot be read again, which is what makes the loop terminate rather than
    // chase the same finding forever.
    @Test("A finding that gets covered does not reappear on the next pass")
    func loopConverges() async throws {
        let source = try PDFRedactorTests.makePDF(lines: [
            "Your social security number: 123-45-6789",
            "Employer: Knob LLC",
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        // Asks for the same span on every pass; it should be satisfied once it is covered.
        let inspector: PDFRedactor.VisibleTextInspector = { _ in ["Knob LLC"] }

        let result = try await PDFRedactor(maximumVerificationPasses: 4).redact(
            documentAt: source,
            matchers: matchers("social security numbers"),
            inspectVisibleText: inspector
        )
        #expect(result.verificationPasses == 2)
    }

    @Test("Progress is reported for each stage")
    func reportsProgress() async throws {
        let source = try PDFRedactorTests.makePDF(lines: ["SSN 123-45-6789"])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let seen = OSAllocatedUnfairLock(initialState: [String]())
        _ = try await PDFRedactor().redact(
            documentAt: source,
            matchers: matchers("social security numbers"),
            progress: { step in
                seen.withLock { log in
                    switch step {
                    case .scanning: log.append("scanning")
                    case .locating: log.append("locating")
                    case .rendering: log.append("rendering")
                    case .reading: log.append("reading")
                    case .consultingModel: log.append("model")
                    case .residueFound: log.append("residue")
                    case .pageSettled: log.append("settled")
                    case .verifyingDocument: log.append("verifying")
                    }
                }
            }
        )

        let log = seen.withLock { $0 }
        #expect(log.contains("scanning"))
        #expect(log.contains("rendering"))
        #expect(log.contains("reading"))
        #expect(log.contains("settled"))
        #expect(log.contains("verifying"))
    }
}
