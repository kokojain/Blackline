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
