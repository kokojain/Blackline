import Foundation
import CoreGraphics
import Vision

/// A word recognized on a page, and where it sits.
public struct RecognizedToken: Sendable {
    /// Where this word falls in its line's text.
    public let range: Range<String.Index>
    /// The word's box, in PDF page coordinates.
    public let box: CGRect
}

/// A line of text recognized on a page.
public struct RecognizedLine: Sendable {
    public let text: String
    /// The whole line's box, in PDF page coordinates.
    public let box: CGRect
    public let tokens: [RecognizedToken]
    /// Vision's confidence, 0...1. Text clipped by a black box tends to come back garbled
    /// and low-confidence, and passing those fragments on produces nonsense findings.
    public let confidence: Float
}

/// What Vision could actually read off a rendered page.
///
/// This is the only view of a redacted page that corresponds to what a person sees. Once a
/// page is rasterized its text layer is gone, so extraction-based checks pass on a page with
/// a plainly legible identifier still on it. Reading the pixels back is how that is caught.
public struct PageReading: Sendable {
    public let lines: [RecognizedLine]

    public init(lines: [RecognizedLine]) {
        self.lines = lines
    }

    /// Everything readable on the page, one line per line.
    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    public var isEmpty: Bool {
        lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Boxes covering every occurrence of `needle`, in page coordinates.
    ///
    /// Falls back to the whole line when the words cannot be pinned down individually —
    /// covering too much is the safe direction.
    public func boxes(covering needle: String) -> [CGRect] {
        let wanted = Self.normalize(needle)
        guard !wanted.isEmpty else { return [] }

        var boxes: [CGRect] = []
        for line in lines {
            var searchStart = line.text.startIndex
            while searchStart < line.text.endIndex,
                  let found = line.text.range(
                      of: needle,
                      options: [.caseInsensitive],
                      range: searchStart ..< line.text.endIndex
                  ) {
                let covering = line.tokens.filter { $0.range.overlaps(found) }
                if covering.isEmpty {
                    boxes.append(line.box)
                } else {
                    boxes.append(covering.dropFirst().reduce(covering[0].box) { $0.union($1.box) })
                }
                searchStart = found.upperBound
            }

            // OCR often renders spacing differently from the matcher's view of the text, so
            // a needle that fails a literal search may still be on this line.
            if boxes.isEmpty, Self.normalize(line.text).contains(wanted) {
                boxes.append(line.box)
            }
        }

        // Recognition misreads digits in some fonts — "12-3456789" comes back as
        // "12-3456/89" — at full confidence, so neither an exact search nor a confidence
        // threshold finds it. The line's own geometry stays correct even when its
        // characters do not, so fall back to locating the value approximately.
        if boxes.isEmpty {
            boxes = approximateBoxes(covering: needle)
        }
        return boxes
    }

    /// Finds `needle` allowing for misrecognized characters, and returns the box around the
    /// best-matching stretch of text.
    ///
    /// Only used when an exact search has already failed. The tolerance scales with length,
    /// so a long identifier may differ in several characters while a short one must nearly
    /// match — a loose threshold on a short string would match almost anywhere.
    func approximateBoxes(covering needle: String) -> [CGRect] {
        let wanted = Array(needle)
        guard wanted.count >= 6 else { return [] }
        let tolerance = max(1, wanted.count / 3)

        var boxes: [CGRect] = []
        for line in lines {
            let characters = Array(line.text)
            guard characters.count >= wanted.count else { continue }

            var bestStart: Int?
            var bestMismatches = tolerance + 1
            for start in 0 ... (characters.count - wanted.count) {
                var mismatches = 0
                for offset in 0 ..< wanted.count where characters[start + offset] != wanted[offset] {
                    mismatches += 1
                    if mismatches >= bestMismatches { break }
                }
                if mismatches < bestMismatches {
                    bestMismatches = mismatches
                    bestStart = start
                }
            }

            guard let start = bestStart, bestMismatches <= tolerance else { continue }
            let lower = line.text.index(line.text.startIndex, offsetBy: start)
            let upper = line.text.index(lower, offsetBy: wanted.count)
            let covering = line.tokens.filter { $0.range.overlaps(lower ..< upper) }
            if covering.isEmpty {
                boxes.append(line.box)
            } else {
                let box = covering.dropFirst().reduce(covering[0].box) { $0.union($1.box) }
                // The match was approximate, so its extent is approximate too: a character
                // misread at either end may have been tokenized away, leaving the last digit
                // of an identifier outside the box. Allow one character of slop.
                let characterWidth = box.width / CGFloat(max(wanted.count, 1))
                boxes.append(box.insetBy(dx: -characterWidth, dy: 0))
            }
        }
        return boxes
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Reads a rendered page with Vision's on-device text recognition (spec §5.2).
public struct PageOCR: Sendable {
    public let languages: [String]
    /// `false` uses the fast recognition path; accuracy is the default because a missed
    /// character here means a missed identifier.
    public let usesAccurateRecognition: Bool

    /// Lines Vision is less sure of than this are discarded. Half-covered words beside a
    /// black box read as garbage — "Emplo", "ificatil" — and feeding those to a checker
    /// produces findings that are not really on the page.
    public let minimumConfidence: Float

    public init(
        languages: [String] = ["en-US"],
        usesAccurateRecognition: Bool = true,
        minimumConfidence: Float = 0.4
    ) {
        self.languages = languages
        self.usesAccurateRecognition = usesAccurateRecognition
        self.minimumConfidence = minimumConfidence
    }

    /// Recognizes text in `image`, mapping every box into `pageBox`'s coordinate space.
    ///
    /// `image` must be a render of exactly `pageBox`, at any scale — Vision reports
    /// normalized coordinates with a bottom-left origin, which is also PDF's convention, so
    /// the mapping is a straight scale with no flip.
    public func read(_ image: CGImage, pageBox: CGRect) throws -> PageReading {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = usesAccurateRecognition ? .accurate : .fast
        request.usesLanguageCorrection = false  // never "correct" an identifier into another
        request.recognitionLanguages = languages

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        func toPageSpace(_ normalized: CGRect) -> CGRect {
            CGRect(
                x: pageBox.minX + normalized.minX * pageBox.width,
                y: pageBox.minY + normalized.minY * pageBox.height,
                width: normalized.width * pageBox.width,
                height: normalized.height * pageBox.height
            )
        }

        var lines: [RecognizedLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            guard !text.isEmpty, candidate.confidence >= minimumConfidence else { continue }

            var tokens: [RecognizedToken] = []
            for word in text.split(whereSeparator: \.isWhitespace) {
                guard let range = text.range(of: word) else { continue }
                guard let rectangle = try? candidate.boundingBox(for: range) else { continue }
                tokens.append(RecognizedToken(range: range, box: toPageSpace(rectangle.boundingBox)))
            }

            lines.append(
                RecognizedLine(
                    text: text,
                    box: toPageSpace(observation.boundingBox),
                    tokens: tokens,
                    confidence: candidate.confidence
                )
            )
        }

        return PageReading(lines: lines)
    }
}
