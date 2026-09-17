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
    static func makePDF(
        lines: [String],
        burnedIn: [String] = [],
        named name: String = "doc"
    ) throws -> URL {
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
        // Drawn as a bitmap, so this text carries no text layer: nothing can match it, and
        // it survives redaction the way a scanned value would.
        if !burnedIn.isEmpty {
            let scale: CGFloat = 3
            let strip = CGRect(x: 0, y: 380, width: 612, height: 120)
            let bitmap = CGContext(
                data: nil, width: Int(strip.width * scale), height: Int(strip.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: strip.width * scale, height: strip.height * scale))
            bitmap.scaleBy(x: scale, y: scale)
            let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
            var y: CGFloat = strip.height - 30
            for line in burnedIn {
                let attributed = NSAttributedString(
                    string: line, attributes: [.font: font, .foregroundColor: NSColor.black]
                )
                bitmap.textPosition = CGPoint(x: 54, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), bitmap)
                y -= 24
            }
            context.draw(bitmap.makeImage()!, in: strip)
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

    // An identifier that exists only inside an image: no matcher can see it in the text
    // layer, so it survives the first pass and only the read-back can find it.
    @Test("An identifier printed inside an image is caught by reading the page back")
    func valueOnlyInAnImageIsCaught() async throws {
        let source = try PDFRedactorTests.makePDF(
            lines: ["Your social security number: 123-45-6789"],
            burnedIn: ["Prior year copy - SSN 987-65-4321"]
        )
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let result = try await PDFRedactor().redact(
            documentAt: source,
            matchers: matchers("social security numbers")
        )

        #expect(result.verificationPasses >= 2, "the image-only SSN should force another pass")
        #expect(result.residueCaughtOnRecheck.contains { $0.contains("987-65-4321") })
    }

    // The bug that prompted this: asked what is still visible, a checker reports the line
    // captions down a tax return, and acting on them blacks out the document's meaning.
    @Test("A report of something the page never set out to remove is ignored")
    func reportsOfUnintendedTextAreIgnored() async throws {
        let source = try PDFRedactorTests.makePDF(lines: [
            "Your social security number: 123-45-6789",
            "1a Gross receipts or sales   1,284,300",
            "3  Gross profit               671,850",
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let result = try await PDFRedactor().redact(
            documentAt: source,
            matchers: matchers("social security numbers"),
            inspectVisibleText: { _ in ["Gross profit", "Gross receipts or sales", "1,284,300"] }
        )

        #expect(result.verificationPasses == 1)
        #expect(result.residueCaughtOnRecheck.isEmpty)
        #expect(result.disposition == .written)

        // The figures are still in the document, because they were never anyone's target.
        let text = PDFRedactorTests.text(of: result.outputURL)
        #expect(result.redactedItemCount == 1)
        #expect(!text.contains("123-45-6789"))
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

@Suite("Writing a document that cannot be proven clean")
struct PDFRedactorUnverifiedTests {

    private func matchers(_ rules: String) -> [any Matcher] {
        MatcherFactory().makeMatchers(for: RulesParser().parse(rules).ruleSet).matchers
    }

    /// One pass allowed, and the page carries a copy of the SSN baked in as an image, so
    /// that pass finds something genuinely still readable and has no budget left to fix it.
    private func unverifiable(_ source: URL) async throws -> PDFRedactor.Result {
        try await PDFRedactor(maximumVerificationPasses: 1, holdsUnverifiedOutputForReview: true)
            .redact(documentAt: source, matchers: matchers("social security numbers"))
    }

    private func fixture() throws -> URL {
        try PDFRedactorTests.makePDF(
            lines: [
                "Your social security number: 123-45-6789",
                "Employer: Knob LLC",
            ],
            burnedIn: ["Prior year copy - SSN 987-65-4321"]
        )
    }

    // The behaviour that matters: the run produces a file. Failing the whole document when
    // the checker runs out of passes left the user with nothing to look at at all.
    @Test("The copy is written, under its redacted name, beside the original")
    func writtenAnyway() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let result = try await unverifiable(source)

        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.outputURL.lastPathComponent.contains("redacted"))
        #expect(result.outputURL.deletingLastPathComponent() == source.deletingLastPathComponent())
        #expect(result.redactedItemCount > 0)
    }

    // Written is not verified, and the result has to keep saying so — a file that looks
    // finished and was never checked is the failure §7 warns about.
    @Test("It reports itself as unverified, with the objections in full")
    func reportsUnverified() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let result = try await unverifiable(source)

        #expect(result.isUnverified)
        #expect(!result.problems.isEmpty)
        #expect(result.problems.contains { $0.contains("still legible") })
        guard case .writtenUnverified = result.disposition else {
            Issue.record("expected the disposition to say it was not verified")
            return
        }
    }

    @Test("What the run did remove is still genuinely gone")
    func redactionStillHappened() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let result = try await unverifiable(source)
        let bytes = try Data(contentsOf: result.outputURL)
        #expect(bytes.range(of: Data("123-45-6789".utf8)) == nil)
    }

    @Test("Writing an unverified copy never overwrites an existing file")
    func neverOverwrites() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let taken = PDFRedactor.outputURL(for: source)
        try Data().write(to: taken)

        let result = try await unverifiable(source)
        #expect(result.outputURL != taken)
        #expect(try Data(contentsOf: taken).isEmpty, "the existing file is untouched")
    }

    @Test("Deleting the copy leaves the original alone")
    func deletingTheCopy() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let result = try await unverifiable(source)
        PDFRedactor.deleteCopy(result)

        #expect(!FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    // Still opt-in: the CLI keeps §5.6's stricter promise.
    @Test("Without the flag the run still fails and writes nothing")
    func defaultStillRefuses() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        await #expect(throws: PDFRedactor.Failure.self) {
            try await PDFRedactor(maximumVerificationPasses: 1).redact(
                documentAt: source,
                matchers: matchers("social security numbers\n\"Knob LLC\""),
                inspectVisibleText: { _ in ["Knob LLC"] }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: PDFRedactor.outputURL(for: source).path))
    }

    @Test("A clean document reports itself as verified")
    func cleanDocumentIsVerified() async throws {
        let source = try PDFRedactorTests.makePDF(lines: [
            "Your social security number: 123-45-6789",
            "Employer: Knob LLC",
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let result = try await PDFRedactor(holdsUnverifiedOutputForReview: true)
            .redact(documentAt: source, matchers: matchers("social security numbers"))

        #expect(result.disposition == .written)
        #expect(!result.isUnverified)
        #expect(result.problems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
    }
}

@Suite("What a checker reports is worth acting on")
struct WorthActingOnTests {

    private let intended = ["12-3456789", "Jane Q Taxpayer", "123 Harbor View Drive"]

    // The bug that prompted this: on a tax return the checker reports every line caption and
    // every figure, and acting on them blacks out the document's meaning.
    @Test("Ignores line captions, form furniture and money", arguments: [
        "Gross profit", "Gross receipts or sales", "Compensation of officers",
        "Salaries and wages", "1,284,300", "671,850",
        "Form 1120-S", "Employer identification number", "Name:",
    ])
    func ignoresWhatWasNeverTargeted(_ reported: String) {
        #expect(PDFRedactor.worthActingOn([reported], intended: intended).isEmpty)
    }

    @Test("Keeps values the page set out to remove", arguments: [
        "12-3456789", "Jane Q Taxpayer", "123 Harbor View Drive",
    ])
    func keepsIntendedValues(_ reported: String) {
        #expect(PDFRedactor.worthActingOn([reported], intended: intended) == [reported])
    }

    // Recognition returns a little more or a little less of a line than the value itself.
    @Test("Matches a partial or surrounding reading of an intended value")
    func toleratesPartialReadings() {
        #expect(PDFRedactor.worthActingOn(["Jane Q"], intended: intended) == ["Jane Q"])
        #expect(PDFRedactor.worthActingOn(["123 Harbor View Drive, Portland"], intended: intended).count == 1)
    }

    @Test("Ignores case and spacing differences")
    func ignoresCaseAndSpacing() {
        #expect(PDFRedactor.worthActingOn(["jane  q   taxpayer"], intended: intended).count == 1)
    }

    @Test("Reports nothing when the page intended nothing")
    func emptyIntent() {
        #expect(PDFRedactor.worthActingOn(["anything"], intended: []).isEmpty)
        #expect(PDFRedactor.worthActingOn([""], intended: intended).isEmpty)
    }
}
