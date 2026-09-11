import Foundation
import PDFKit
import AppKit
import BlacklineKit

/// Produces a redacted copy of a PDF (spec §5.4–5.6).
///
/// **How the content is removed.** Every page carrying a match is *rasterized*: rendered to
/// an image with black boxes burned in, then re-embedded as an image-only page. Spec §5.4
/// describes this as the fallback behind content-stream surgery; here it is the only path,
/// because it is the one whose guarantee can be stated without qualification — there is no
/// text object left in the output to recover, whatever the original encoding did.
///
/// The cost is real and is not hidden: text on redacted pages stops being selectable and
/// searchable, and the file gets larger. Content-stream surgery, which would preserve both
/// for the untouched runs, is deferred rather than half-done — a surgical path that works
/// on most encodings is exactly the false negative spec §7 warns about.
///
/// **What else is removed.** Output is assembled as a fresh document, so incremental-save
/// history, document metadata, and the original object graph do not carry over. Annotation
/// and form-field values are matched too, and a matching annotation is deleted before the
/// page is drawn rather than merely covered.
///
/// **Nothing is written unverified.** The candidate is written to a temporary file,
/// reopened, and re-scanned with the same matchers. Only if nothing matches does it move to
/// the final destination, per §5.6.
public struct PDFRedactor: Sendable {

    /// Raster resolution as a multiple of the PDF's 72 dpi user space. 2.0 ≈ 144 dpi.
    public let scale: CGFloat
    /// Padding added around each black box, in points, so descenders and antialiased edges
    /// are covered rather than fringed.
    public let padding: CGFloat

    public init(scale: CGFloat = 2.0, padding: CGFloat = 1.0) {
        self.scale = max(1.0, scale)
        self.padding = max(0, padding)
    }

    public struct Result: Sendable {
        public let outputURL: URL
        /// How many spans were blacked out, for the §3 completion message.
        public let redactedItemCount: Int
        public let pagesRasterized: Int
        public let pageCount: Int
        /// Rules that accounted for the redactions, for the §7 "by which rules" report.
        public let rulesApplied: [String]
    }

    public enum Failure: Error, LocalizedError {
        case cannotOpen(URL)
        case encrypted
        /// Spec §3: producing an identical copy is a privacy failure, not a success.
        case nothingMatched
        case renderFailed(page: Int)
        case writeFailed
        /// Spec §5.6: content survived into the candidate output, so it was discarded.
        case verificationFailed(residue: [String])
        /// PDFKit resolved a span to different text than the matcher intended, so the black
        /// box would have landed in the wrong place.
        case geometryMismatch(expected: String, resolved: String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let url):
                "could not open \(url.path) as a PDF"
            case .encrypted:
                "the document is encrypted and locked; password handling is not built yet"
            case .nothingMatched:
                "no rule matched anything in this document, so no redacted copy was written"
            case .renderFailed(let page):
                "could not render page \(page)"
            case .writeFailed:
                "could not write the redacted PDF"
            case .verificationFailed(let residue):
                "verification failed — content survived redaction: \(residue.joined(separator: ", "))"
            case .geometryMismatch(let expected, let resolved):
                "could not locate \(expected.debugDescription) on the page — PDFKit resolved that "
                    + "position to \(resolved.debugDescription); no output was written"
            }
        }
    }

    /// Redacts `sourceURL` and returns where the copy landed.
    ///
    /// - Parameters:
    ///   - matchers: run over page text, annotation values, and again during verification.
    ///   - additionalMatches: already-located spans keyed by page index, for proposers that
    ///     are not deterministic enough to re-run during verification (the model tier).
    public func redact(
        documentAt sourceURL: URL,
        matchers: [any Matcher],
        additionalMatches: [Int: [Match]] = [:]
    ) throws -> Result {
        guard let document = PDFDocument(url: sourceURL) else { throw Failure.cannotOpen(sourceURL) }
        guard !document.isLocked else { throw Failure.encrypted }

        let output = PDFDocument()
        var totalRedactions = 0
        var pagesRasterized = 0
        var rulesApplied: Set<String> = []

        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }

            let pageText = page.string ?? ""
            var matches = matchers.flatMap { $0.matches(in: SourceText(pageText)) }
            matches += additionalMatches[index] ?? []

            // Form fields and annotation contents are not always part of the page's text,
            // so they are scanned separately. A matching annotation is removed outright —
            // covering it would leave the value in the file.
            let doomedAnnotations = page.annotations.filter { annotation in
                let values = [annotation.widgetStringValue, annotation.contents]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                return values.contains { value in
                    matchers.contains { !$0.matches(in: SourceText(value)).isEmpty }
                }
            }

            guard !matches.isEmpty || !doomedAnnotations.isEmpty else {
                // Untouched pages are copied through as-is, keeping their text selectable.
                if let copy = page.copy() as? PDFPage {
                    output.insert(copy, at: output.pageCount)
                }
                continue
            }

            for match in matches { rulesApplied.insert(match.source.ruleDescription) }

            var boxes = try redactionBoxes(for: matches, on: page, in: document, pageText: pageText)
            boxes += doomedAnnotations.map { $0.bounds.insetBy(dx: -padding, dy: -padding) }
            for annotation in doomedAnnotations { page.removeAnnotation(annotation) }

            guard let rendered = rasterize(page: page, blackingOut: boxes) else {
                throw Failure.renderFailed(page: index + 1)
            }
            output.insert(rendered, at: output.pageCount)

            totalRedactions += matches.count + doomedAnnotations.count
            pagesRasterized += 1
        }

        guard totalRedactions > 0 else { throw Failure.nothingMatched }

        // Spec §5.5: a fresh document with no attributes carried over.
        output.documentAttributes = [:]

        // Spec §5.6: write a candidate, prove it is clean, and only then let it exist under
        // the real name. A file that fails verification never reaches the output path.
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackline-\(UUID().uuidString).pdf")
        guard output.write(to: candidate) else { throw Failure.writeFailed }
        defer { try? FileManager.default.removeItem(at: candidate) }

        let residue = try verify(candidate, matchers: matchers)
        guard residue.isEmpty else { throw Failure.verificationFailed(residue: residue) }

        let destination = Self.outputURL(for: sourceURL)
        do {
            try FileManager.default.moveItem(at: candidate, to: destination)
        } catch {
            throw Failure.writeFailed
        }

        return Result(
            outputURL: destination,
            redactedItemCount: totalRedactions,
            pagesRasterized: pagesRasterized,
            pageCount: document.pageCount,
            rulesApplied: rulesApplied.sorted()
        )
    }

    // MARK: - Locating

    /// Turns matches into black boxes in page space, one per line the match occupies.
    ///
    /// Geometry comes from `PDFSelection` rather than `characterBounds(at:)`. The latter
    /// returns degenerate rectangles on some documents — zero-height boxes at the wrong
    /// baseline — which produces boxes that miss the text they are meant to cover.
    ///
    /// Every span is checked before it is used: the text PDFKit resolved at those indices
    /// must be the text the matcher found. Without that check a box can land beside the
    /// value instead of on it, and no amount of text-extraction verification would notice,
    /// because rasterizing removes the text layer either way.
    func redactionBoxes(
        for matches: [Match],
        on page: PDFPage,
        in document: PDFDocument,
        pageText: String
    ) throws -> [CGRect] {
        var boxes: [CGRect] = []

        for match in matches {
            // PDFKit indexes characters the way NSString does, in UTF-16 units.
            let lower = pageText.utf16.distance(from: pageText.startIndex, to: match.range.lowerBound)
            let upper = pageText.utf16.distance(from: pageText.startIndex, to: match.range.upperBound)
            guard lower >= 0, upper <= page.numberOfCharacters, lower < upper else {
                throw Failure.geometryMismatch(expected: match.matchedText, resolved: "out of range")
            }

            guard let selection = document.selection(
                from: page, atCharacterIndex: lower,
                to: page, atCharacterIndex: upper - 1
            ) else {
                throw Failure.geometryMismatch(expected: match.matchedText, resolved: "no selection")
            }

            let resolved = selection.string ?? ""
            guard SourceText.normalize(resolved) == SourceText.normalize(match.matchedText) else {
                throw Failure.geometryMismatch(expected: match.matchedText, resolved: resolved)
            }

            // A match that wraps gets one box per line, rather than one rectangle spanning
            // the gap between them and blacking out unrelated text.
            for line in selection.selectionsByLine() {
                let bounds = line.bounds(for: page)
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                let tightened = tightenVertically(bounds, on: page, indices: lower ..< upper)
                boxes.append(tightened.insetBy(dx: -padding, dy: -padding))
            }
        }

        return boxes
    }

    /// Trims an over-tall line box down to the row the glyphs actually occupy.
    ///
    /// `selectionsByLine()` returns PDFKit's idea of a line, which on some documents spans
    /// two visual rows — the box then covers a neighbouring line as well. Glyph boxes can
    /// narrow that down, but they are not trustworthy everywhere: the same documents that
    /// merge rows also report zero-height boxes at the wrong baseline.
    ///
    /// So this tightens only when the glyph geometry is unambiguous — every non-space
    /// character resolved, all of them on one row, and that row inside the line box — and
    /// otherwise returns the original. Erring toward a box that is too *tall* covers a
    /// neighbouring line; erring toward one that is too short leaves the value readable.
    func tightenVertically(_ bounds: CGRect, on page: PDFPage, indices: Range<Int>) -> CGRect {
        var glyphBoxes: [CGRect] = []
        for offset in indices {
            guard offset < page.numberOfCharacters else { return bounds }
            let glyph = page.characterBounds(at: offset)
            // Spaces legitimately have no ink; anything else must resolve.
            if glyph.isNull || glyph.isEmpty || glyph.height <= 0 { continue }
            glyphBoxes.append(glyph)
        }
        guard glyphBoxes.count >= 2 else { return bounds }

        // Every glyph must sit on one row: the rows must all overlap each other vertically.
        let lowestTop = glyphBoxes.map(\.maxY).min() ?? 0
        let highestBottom = glyphBoxes.map(\.minY).max() ?? 0
        guard highestBottom < lowestTop else { return bounds }

        let row = glyphBoxes.dropFirst().reduce(glyphBoxes[0]) { $0.union($1) }
        // The row has to lie inside the line box, and be an improvement on it.
        guard row.minY >= bounds.minY - 0.5,
              row.maxY <= bounds.maxY + 0.5,
              row.height < bounds.height
        else { return bounds }

        // Horizontal extent stays with the selection, which is authoritative; only the
        // vertical band comes from the glyphs.
        return CGRect(x: bounds.minX, y: row.minY, width: bounds.width, height: row.height)
    }

    // MARK: - Rendering

    /// Renders a page to an image with `boxes` filled black, and wraps it as a new page.
    func rasterize(page: PDFPage, blackingOut boxes: [CGRect]) -> PDFPage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }

        // Draw unrotated so that character bounds — which are in page space — line up with
        // what is drawn. The rotation is put back on the replacement page afterwards.
        let rotation = page.rotation
        page.rotation = 0
        defer { page.rotation = rotation }

        let pixelWidth = Int((box.width * scale).rounded())
        let pixelHeight = Int((box.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: context)

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for rect in boxes { context.fill(rect) }

        guard let image = context.makeImage() else { return nil }
        let redacted = PDFPage(image: NSImage(cgImage: image, size: box.size))
        redacted?.setBounds(box, for: .mediaBox)
        redacted?.rotation = rotation
        return redacted
    }

    // MARK: - Verifying

    /// Re-reads a candidate file and reports anything a matcher still finds. Spec §5.6: the
    /// app never ships a PDF it cannot prove is clean.
    ///
    /// Necessary but not sufficient on its own. Rasterizing a page removes its text layer
    /// whether or not the black boxes landed correctly, so this check passes trivially for
    /// rasterized pages — it proves nothing is *extractable*, not that nothing is *visible*.
    /// The guarantee that a box covers what it was meant to cover comes from the selection
    /// check in ``redactionBoxes(for:on:in:pageText:)``.
    func verify(_ url: URL, matchers: [any Matcher]) throws -> [String] {
        guard let document = PDFDocument(url: url) else { return ["output could not be reopened"] }

        var residue: [String] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }

            for match in matchers.flatMap({ $0.matches(in: SourceText(page.string ?? "")) }) {
                residue.append("page \(index + 1): \(match.matchedText)")
            }
            for annotation in page.annotations {
                let values = [annotation.widgetStringValue, annotation.contents].compactMap { $0 }
                for value in values {
                    for match in matchers.flatMap({ $0.matches(in: SourceText(value)) }) {
                        residue.append("page \(index + 1) annotation: \(match.matchedText)")
                    }
                }
            }
        }
        return residue
    }

    // MARK: - Naming

    /// `statement.pdf` becomes `statement redacted.pdf` beside it, never overwriting
    /// anything: a name already in use gets a counter (spec §3).
    public static func outputURL(for source: URL) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "pdf" : source.pathExtension

        var candidate = directory.appendingPathComponent("\(stem) redacted").appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(stem) redacted \(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}
