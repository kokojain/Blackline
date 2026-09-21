import Foundation
import CoreGraphics
import CoreText
import AppKit
import Testing
@testable import BlacklineOCR

@Suite("PageReading")
struct PageReadingTests {

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> RecognizedLine {
        // One token per word, laid out evenly across the line's width.
        var tokens: [RecognizedToken] = []
        let words = text.split(whereSeparator: \.isWhitespace)
        let perCharacter = width / CGFloat(max(text.count, 1))
        for word in words {
            guard let range = text.range(of: word) else { continue }
            let start = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound))
            tokens.append(
                RecognizedToken(
                    range: range,
                    box: CGRect(x: x + start * perCharacter, y: y,
                                width: CGFloat(word.count) * perCharacter, height: 12)
                )
            )
        }
        return RecognizedLine(
            text: text,
            box: CGRect(x: x, y: y, width: width, height: 12),
            tokens: tokens,
            confidence: 1
        )
    }

    @Test("Boxes an exact match around just those words")
    func exactMatch() {
        let reading = PageReading(lines: [line("Account number: 000123456789", x: 50, y: 700, width: 280)])
        let boxes = reading.boxes(covering: "000123456789")
        #expect(boxes.count == 1)
        // The label is left alone.
        #expect(boxes[0].minX > 50 + 100)
    }

    @Test("Finds every occurrence on a line")
    func repeatedMatch() {
        let reading = PageReading(lines: [line("Knob LLC and Knob LLC", x: 0, y: 0, width: 210)])
        #expect(reading.boxes(covering: "Knob LLC").count == 2)
    }

    @Test("Reports nothing when the text is absent")
    func noMatch() {
        let reading = PageReading(lines: [line("nothing to see", x: 0, y: 0, width: 100)])
        #expect(reading.boxes(covering: "123-45-6789").isEmpty)
    }

    // Recognition misreads digits in some fonts at full confidence — "12-3456789" comes
    // back as "12-3456/89" — so an exact search finds nothing and the identifier would be
    // left showing.
    @Test("Locates an identifier that recognition misread", arguments: [
        "12-3456/89", "12-3456(89", "45-b/8901", "l2-3456789",
    ])
    func fuzzyMatch(_ misread: String) {
        let reading = PageReading(lines: [line("Employer ID \(misread) end", x: 0, y: 0, width: 300)])
        #expect(!reading.boxes(covering: "12-3456789").isEmpty || !reading.boxes(covering: "45-6789012").isEmpty)
    }

    @Test("An approximate box is widened, since its extent is approximate too")
    func fuzzyBoxCarriesSlop() {
        let exact = PageReading(lines: [line("EIN 12-3456789 x", x: 0, y: 0, width: 160)])
        let misread = PageReading(lines: [line("EIN 12-3456/89 x", x: 0, y: 0, width: 160)])
        let exactBox = exact.boxes(covering: "12-3456789").first
        let fuzzyBox = misread.boxes(covering: "12-3456789").first
        #expect(exactBox != nil)
        #expect(fuzzyBox != nil)
        // Wider than the exact hit, so a character tokenized away at either end is covered.
        #expect((fuzzyBox?.width ?? 0) > (exactBox?.width ?? 0))
    }

    @Test("Short strings are not matched approximately")
    func fuzzyRequiresLength() {
        // Two characters of tolerance on a short string would match almost anywhere.
        let reading = PageReading(lines: [line("abc def", x: 0, y: 0, width: 70)])
        #expect(reading.boxes(covering: "xyz").isEmpty)
    }
}

@Suite("PageOCR end to end")
struct PageOCRTests {

    /// Renders text to a bitmap the way a page would be rendered.
    private func image(_ lines: [String], width: CGFloat = 612, height: CGFloat = 200) -> CGImage {
        let scale: CGFloat = 4
        let context = CGContext(
            data: nil, width: Int(width * scale), height: Int(height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
        context.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        var y = height - 30
        for line in lines {
            let attributed = NSAttributedString(
                string: line, attributes: [.font: font, .foregroundColor: NSColor.black]
            )
            context.textPosition = CGPoint(x: 20, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            y -= 24
        }
        return context.makeImage()!
    }

    @Test("Reads a rendered page and places boxes in page coordinates")
    func readsRenderedPage() throws {
        let pageBox = CGRect(x: 0, y: 0, width: 612, height: 200)
        let reading = try PageOCR().read(
            image(["Employer identification number: 12-3456789"]), pageBox: pageBox
        )

        #expect(!reading.isEmpty)
        #expect(reading.text.contains("Employer"))

        let boxes = reading.boxes(covering: "12-3456789")
        #expect(!boxes.isEmpty)
        // Vision reports bottom-left-origin normalized coordinates, the same convention as
        // PDF, so a box must land inside the page and near the text's baseline.
        for box in boxes {
            #expect(pageBox.contains(box.insetBy(dx: 1, dy: 1)))
            #expect(box.midY > 150)
        }
    }

    @Test("A blank page reads as empty")
    func blankPage() throws {
        let reading = try PageOCR().read(image([]), pageBox: CGRect(x: 0, y: 0, width: 612, height: 200))
        #expect(reading.isEmpty)
    }
}

/// A value printed across two or three rows — the ordinary shape of a postal address on a
/// form — and the misreads recognition makes while reading one back.
@Suite("Wrapped values")
struct WrappedValueTests {

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> RecognizedLine {
        var tokens: [RecognizedToken] = []
        let words = text.split(whereSeparator: \.isWhitespace)
        let perCharacter = width / CGFloat(max(text.count, 1))
        var searchFrom = text.startIndex
        for word in words {
            guard let range = text.range(of: word, range: searchFrom ..< text.endIndex) else { continue }
            searchFrom = range.upperBound
            let start = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound))
            tokens.append(
                RecognizedToken(
                    range: range,
                    box: CGRect(x: x + start * perCharacter, y: y,
                                width: CGFloat(word.count) * perCharacter, height: 12)
                )
            )
        }
        return RecognizedLine(text: text, box: CGRect(x: x, y: y, width: width, height: 12),
                              tokens: tokens, confidence: 1)
    }

    /// A form row in two columns: the value on the left, an unrelated field on the right.
    private var form: PageReading {
        PageReading(lines: [
            line("Employee: Sarah J Chen", x: 50, y: 700, width: 200),
            line("88 Harbor St Apt 4B", x: 95, y: 686, width: 140),
            line("Boston MA 02210", x: 95, y: 672, width: 110),
            line("Employer EIN: 12-3456789", x: 310, y: 672, width: 180),
            line("Boston MA 02110", x: 95, y: 658, width: 110),
        ])
    }

    // Without this the value is on no single line, the caller falls back to PDFKit's
    // geometry, and PDFKit hands back the whole row — captions, second column and all.
    @Test("A value spanning two rows gets one box per row")
    func wrappedValueIsBoxedPerLine() {
        let boxes = form.boxes(covering: "88 Harbor St Apt 4B Boston MA 02210")
        #expect(boxes.count == 2)
        #expect(boxes.allSatisfy { $0.maxX <= 240 })     // never reaches the second column
        #expect(boxes.map(\.minY).sorted() == [672, 686])
    }

    @Test("It is placed even where recognition misread a character")
    func toleratesAMisread() {
        let misread = PageReading(lines: [
            line("88 Harbor St Apt 4B", x: 95, y: 686, width: 140),
            line("Boston MA 0Z210", x: 95, y: 672, width: 110),      // "Z" for "2"
        ])
        #expect(misread.boxes(covering: "88 Harbor St Apt 4B Boston MA 02210").count == 2)
    }

    // One digit standing where another was wanted is a different number, not a misread.
    // Measured on a W-2: the employee's postcode blacked out the employer's, one row down.
    @Test("A different number on another row is left alone")
    func doesNotCoverADifferentNumber() {
        let boxes = form.boxes(covering: "Boston MA 02210")
        #expect(boxes.count == 1)
        #expect(boxes[0].minY == 672)
    }

    @Test("A value that stops short of the line's end does not wrap")
    func requiresTheValueToReachTheLineEnd() {
        // "Sarah" is followed by more text on its line, so nothing here wrapped.
        #expect(form.boxes(covering: "Sarah 88 Harbor").isEmpty)
    }

    @Test("Words scattered down the page are not joined up")
    func doesNotJoinUnrelatedLines() {
        #expect(form.boxes(covering: "Chen Boston MA 02110").isEmpty)
    }
}
