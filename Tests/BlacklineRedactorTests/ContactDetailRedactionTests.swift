import Foundation
import PDFKit
import Testing
import BlacklineKit
import BlacklineOCR
@testable import BlacklineRedactor

/// The contact categories through the whole pipeline.
///
/// These are the detectors whose matches do not look like the ones the redactor was built
/// on: an email address is a single unbroken token Vision likes to split at the `@`, and a
/// postal address is one match spanning two printed lines. Both place boxes through the
/// same geometry as everything else, and a box that lands wrong is invisible in a count —
/// so the check here is what is *legible on the finished page*, read back with the same
/// recognizer the loop uses. Searching the file's bytes would prove nothing: the page is
/// rasterized, so the text layer is gone either way.
@Suite("Contact details end to end", .serialized)
struct ContactDetailRedactionTests {

    private func page() throws -> URL {
        try PDFRedactorTests.makePDF(lines: [
            "Statement for Sarah Chen",
            "88 Harbor St Apt 4B",
            "Boston MA 02210",
            "Email sarah.chen@example.com",
            "Phone (617) 555-0148",
            "Balance due 1,250.00",
        ])
    }

    /// What can still be read off the finished page.
    private func readable(_ url: URL) throws -> String {
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 4
        let context = try #require(CGContext(
            data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: context)
        return try PageOCR().read(try #require(context.makeImage()), pageBox: box).text
    }

    @Test("The address, the email and the phone number are gone from the page")
    func contactDetailsAreCovered() async throws {
        let source = try page()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let matchers = MatcherFactory().makeMatchers(
            for: RulesParser().parse("""
            email addresses
            phone numbers
            street addresses
            """).ruleSet
        ).matchers

        let result = try await PDFRedactor(verifiesByReading: false)
            .redact(documentAt: source, matchers: matchers)
        #expect(result.redactedItemCount == 3)

        let visible = try readable(result.outputURL)
        #expect(!visible.contains("Harbor"))
        #expect(!visible.contains("02210"))
        #expect(!visible.contains("sarah.chen"))
        #expect(!visible.contains("example.com"))
        #expect(!visible.contains("555-0148"))
    }

    // The matched span is the address, not the page. An address box that over-reaches is
    // the same damage as a detector that does: the document stops being readable by whoever
    // it was sent to.
    @Test("The rest of the page survives")
    func theRestOfThePageSurvives() async throws {
        let source = try page()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let matchers = MatcherFactory().makeMatchers(
            for: RulesParser().parse("street addresses\nemail addresses\nphone numbers").ruleSet
        ).matchers

        let result = try await PDFRedactor(verifiesByReading: false)
            .redact(documentAt: source, matchers: matchers)

        let visible = try readable(result.outputURL)
        #expect(visible.contains("Statement"))
        #expect(visible.contains("Balance due"))
        #expect(visible.contains("1,250.00"))
        // The labels beside the boxes stay: only the values were asked for.
        #expect(visible.contains("Email"))
        #expect(visible.contains("Phone"))
    }
}

/// The whole pipeline over a form laid out in columns, which is where over-redaction shows.
///
/// The failure this guards against was reported as "it redacted too much — the form was
/// useless": every caption and both columns of three rows went black because the value
/// spanned two printed lines and the box came from PDFKit's idea of the row.
///
/// Note what this test does and does not do. It asserts the property — values gone, captions
/// and figures still there — on a document built here. It does *not* reproduce the original
/// failure: that needed a PDF whose text layer interleaves two columns and whose lines
/// PDFKit merges, which is a property of how a particular producer writes the file and is
/// not reliably synthesized. The mechanisms are covered directly by `WrappedValueTests` in
/// BlacklineOCRTests and `BoxExtentTests` above; a real two-column file still has to be
/// looked at.
@Suite("A form stays readable", .serialized)
struct FormLegibilityTests {

    private func form() throws -> URL {
        try PDFRedactorTests.makePDF(lines: [
            "2025 WAGE AND TAX STATEMENT",
            "",
            "Employee:  Sarah J Chen                    Employee SSN:  123-45-6789",
            "           88 Harbor St Apt 4B",
            "           Boston MA 02210                 Date of birth: 03/14/1982",
            "",
            "Box 1  Wages, tips, other compensation ................ 128,450.00",
            "Box 2  Federal income tax withheld .................... 24,107.55",
        ])
    }

    private func readable(_ url: URL) throws -> String {
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 4
        let context = try #require(CGContext(
            data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: context)
        return try PageOCR().read(try #require(context.makeImage()), pageBox: box).text
    }

    @Test("The values go and the captions, columns and figures stay")
    func formSurvivesItsRedaction() async throws {
        let source = try form()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        // A plan's worth of values, including one that was printed across two lines.
        let values = [
            "Sarah J Chen", "123-45-6789", "03/14/1982",
            "88 Harbor St Apt 4B Boston MA 02210",
        ]
        let result = try await PDFRedactor()
            .redact(documentAt: source, matchers: values.map { ExactTextMatcher(literal: $0) })

        let visible = try readable(result.outputURL)
        for gone in ["Sarah", "123-45-6789", "03/14/1982", "Harbor", "02210"] {
            #expect(!visible.contains(gone), "\(gone) is still on the page")
        }
        for kept in ["Employee:", "Employee SSN:", "Date of birth:", "Box 1", "Box 2",
                     "Federal income tax withheld", "128,450.00", "24,107.55"] {
            #expect(visible.contains(kept), "\(kept) was blacked out")
        }
    }
}
