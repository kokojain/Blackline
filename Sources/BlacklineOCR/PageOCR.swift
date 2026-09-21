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

        // A value that wrapped is on no single line, so the search above cannot find it.
        if boxes.isEmpty {
            boxes = boxesAcrossLines(covering: needle)
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

    /// Boxes for a value printed across consecutive lines, one box per line.
    ///
    /// A postal address is set over two or three rows, so the value a matcher reports spans
    /// them — and searching a single line's text can never find it. What the caller does
    /// without this is fall back to PDFKit's geometry, which on a form covers the whole row:
    /// redacting an employee's address took the `Employee:` label, the SSN caption and the
    /// row's remaining columns with it, and three lines of a W-2 became one black slab. That
    /// is the over-redaction that ruins a document.
    ///
    /// The structure that makes exact placement possible: a value that wrapped **ends at the
    /// end of one line and resumes at the start of the next**. So the first piece must be a
    /// suffix of its line's words, any middle line must be consumed whole, and the last piece
    /// must be a prefix of its line's words. Nothing else is accepted, which is what keeps
    /// this from matching a scatter of words down the page.
    func boxesAcrossLines(covering needle: String) -> [CGRect] {
        let wanted = Self.normalize(needle).split(separator: " ").map(String.init)
        guard wanted.count >= 2 else { return [] }

        for start in lines.indices {
            let words = self.words(of: lines[start])
            guard !words.isEmpty else { continue }

            // The first piece has to reach the end of its line: a wrapped value cannot have
            // unrelated text after it on the same row.
            for first in words.indices {
                let head = words.count - first
                guard head < wanted.count,
                      matches(wanted.prefix(head), words[first...])
                else { continue }

                var boxes = [box(of: words[first...])]
                var consumed = head
                var line = start + 1

                while consumed < wanted.count, line < lines.count {
                    let next = self.words(of: lines[line])
                    guard !next.isEmpty else { break }
                    let remaining = wanted.count - consumed

                    if remaining <= next.count {
                        // The tail: it must start this line, and may end inside it.
                        guard matches(wanted.suffix(remaining), next.prefix(remaining)) else { break }
                        boxes.append(box(of: next.prefix(remaining)))
                        return boxes
                    }

                    // A middle line is consumed whole or not at all.
                    guard matches(wanted[consumed ..< consumed + next.count], next[...]) else { break }
                    boxes.append(box(of: next[...]))
                    consumed += next.count
                    line += 1
                }
            }
        }
        return []
    }

    private typealias Word = (text: String, box: CGRect)

    private func words(of line: RecognizedLine) -> [Word] {
        line.tokens.map { (Self.normalize(String(line.text[$0.range])), $0.box) }
            .filter { !$0.0.isEmpty }
    }

    private func box(of words: ArraySlice<Word>) -> CGRect {
        words.dropFirst().reduce(words.first?.box ?? .null) { $0.union($1.box) }
    }

    /// Word-by-word comparison, allowing the misreads recognition makes within a word —
    /// `02210` comes back as `0Z210`. A word must be the same length and nearly the same
    /// characters; a quarter of them may differ, and never more than two.
    private func matches(_ wanted: ArraySlice<String>, _ found: ArraySlice<Word>) -> Bool {
        guard wanted.count == found.count else { return false }
        for (want, have) in zip(wanted, found) {
            if want == have.text { continue }
            guard want.count == have.text.count else { return false }
            let tolerance = min(2, want.count / 4)
            var mismatches = 0
            for (expected, actual) in zip(want, have.text) where expected != actual {
                guard Self.isRecognitionArtefact(expected: expected, found: actual) else {
                    return false
                }
                mismatches += 1
            }
            guard mismatches <= tolerance else { return false }
        }
        return true
    }

    /// Whether a character that differs is recognition misreading the page, or the page
    /// genuinely saying something else.
    ///
    /// Vision substitutes a letter or a symbol for a digit: `0Z210` for `02210`,
    /// `12-3456/89` for `12-3456789`. That is what the approximate paths exist to absorb.
    /// It does **not** turn one digit into another — so where both characters are digits and
    /// they differ, the text on the page is a different number. Measured on a W-2: without
    /// this, the employee's `Boston MA 02210` also blacked out the employer's
    /// `Boston MA 02110`, one line below.
    static func isRecognitionArtefact(expected: Character, found: Character) -> Bool {
        !(expected.isNumber && found.isNumber)
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
                var differentValue = false
                for offset in 0 ..< wanted.count
                where characters[start + offset] != wanted[offset] {
                    // One digit standing where another was wanted is not a misread: it is a
                    // different number, and covering it removes something nobody asked to
                    // remove. See ``isRecognitionArtefact``.
                    guard Self.isRecognitionArtefact(
                        expected: wanted[offset], found: characters[start + offset]
                    ) else {
                        differentValue = true
                        break
                    }
                    mismatches += 1
                    if mismatches >= bestMismatches { break }
                }
                if !differentValue, mismatches < bestMismatches {
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
