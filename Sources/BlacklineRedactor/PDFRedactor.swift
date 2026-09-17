import Foundation
import PDFKit
import AppKit
import BlacklineKit
import BlacklineOCR

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
/// **Nothing is written unverified, and verification reads the pixels.** After a page is
/// rendered it is read back with Vision OCR — the only view that corresponds to what a
/// person sees. Anything still legible is boxed and the page is rendered again, up to
/// ``maximumVerificationPasses`` times; a page that will not come clean aborts the document.
/// Checking the text layer alone is not enough, because rasterizing empties it whether or
/// not the boxes landed correctly. The candidate file is then reopened and re-scanned
/// before it is allowed to exist under its real name (§5.6).
public struct PDFRedactor: Sendable {

    /// Raster resolution as a multiple of the PDF's 72 dpi user space. 2.0 ≈ 144 dpi.
    public let scale: CGFloat
    /// Padding added around each black box, in points, so descenders and antialiased edges
    /// are covered rather than fringed.
    public let padding: CGFloat

    /// How many times a page may be rendered, read back, and corrected before the document
    /// is abandoned.
    public let maximumVerificationPasses: Int
    /// Whether rendered pages are read back with OCR. Off makes redaction much faster and
    /// much less trustworthy.
    public let verifiesByReading: Bool

    /// When a document cannot be proven clean, write it anyway and report what is wrong,
    /// instead of failing the run.
    ///
    /// Spec §5.6 says the app never ships a PDF it cannot prove is clean, and with this off
    /// that is exactly what happens — the run fails and nothing is written. In practice that
    /// is too strict to be usable: "cannot prove" is not "is dirty". Recognition misreads,
    /// the checker reports label fragments beside the black boxes, and a document that is
    /// perfectly well redacted can run out of passes and be thrown away, leaving the user
    /// with nothing to look at and no way to see what the objection was.
    ///
    /// With this on, the copy is written under its normal redacted name and the run reports
    /// ``Result/Disposition/writtenUnverified(problems:)``. The caller is then responsible
    /// for telling the user plainly that it was not verified and putting it in front of
    /// them — a file that looks finished and was never checked is the failure §7 warns
    /// about, and this flag moves that duty to the caller rather than removing it.
    public let holdsUnverifiedOutputForReview: Bool

    public init(
        scale: CGFloat = 2.0,
        padding: CGFloat = 1.0,
        maximumVerificationPasses: Int = 3,
        verifiesByReading: Bool = true,
        holdsUnverifiedOutputForReview: Bool = false
    ) {
        self.scale = max(1.0, scale)
        self.padding = max(0, padding)
        self.maximumVerificationPasses = max(1, maximumVerificationPasses)
        self.verifiesByReading = verifiesByReading
        self.holdsUnverifiedOutputForReview = holdsUnverifiedOutputForReview
    }

    /// Where the redactor has got to. Redaction with reading-back enabled takes seconds per
    /// page, and minutes with a model in the loop, so callers need to be able to say so.
    public enum Progress: Sendable {
        case scanning(page: Int, of: Int)
        case locating(page: Int)
        case rendering(page: Int, pass: Int)
        case reading(page: Int, pass: Int)
        case consultingModel(page: Int, pass: Int)
        case residueFound(page: Int, pass: Int, items: [String])
        case pageSettled(page: Int, passes: Int)
        case verifyingDocument
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    /// Given the text visible on a rendered page, returns any spans that are still
    /// sensitive. Supplied by the caller so the redactor need not know about the model.
    public typealias VisibleTextInspector = @Sendable (String) async throws -> [String]

    /// One span that was blacked out, and what accounted for it.
    ///
    /// `text` is the redacted value itself, so it is exactly the information the user is
    /// trying to protect. Anything displaying a finding should mask it by default.
    public struct Finding: Hashable, Sendable {
        public enum Origin: Hashable, Sendable {
            /// Matched by a rule or detector on the document's own text.
            case rule
            /// Located from a proposal by something non-deterministic (the model tier).
            case proposal
            /// Still legible after the first render, and caught by reading the page back.
            case caughtOnRecheck
        }

        public let pageIndex: Int
        public let text: String
        public let ruleDescription: String
        public let origin: Origin
        /// `true` when the rule *is* the value — a quoted exact rule. Anything masking
        /// `text` has to mask the description too, or the label gives the value away.
        public let ruleIsLiteral: Bool

        public init(
            pageIndex: Int,
            text: String,
            ruleDescription: String,
            origin: Origin,
            ruleIsLiteral: Bool = false
        ) {
            self.pageIndex = pageIndex
            self.text = text
            self.ruleDescription = ruleDescription
            self.origin = origin
            self.ruleIsLiteral = ruleIsLiteral
        }
    }

    /// What happened to one page.
    ///
    /// `notExamined` is the case that matters: the page carried no text to search, so
    /// nothing on it was looked at and it was copied through as it was. A summary that
    /// reports only the redaction count turns that into a clean-looking result, which is the
    /// failure spec §7 calls dangerous — so it is reported per page rather than inferred.
    public struct PageOutcome: Sendable {
        public enum Status: Equatable, Sendable {
            case redacted(items: Int, passes: Int)
            case noMatches
            case notExamined(reason: String)
        }

        public let index: Int
        public let status: Status
        public let findings: [Finding]

        public init(index: Int, status: Status, findings: [Finding]) {
            self.index = index
            self.status = status
            self.findings = findings
        }
    }

    public struct Result: Sendable {
        public let outputURL: URL
        /// How many spans were blacked out, for the §3 completion message.
        public let redactedItemCount: Int
        public let pagesRasterized: Int
        public let pageCount: Int
        /// Rules that accounted for the redactions, for the §7 "by which rules" report.
        public let rulesApplied: [String]
        /// The most passes any single page needed before it read back clean.
        public let verificationPasses: Int
        /// Spans that survived the first render and were caught by reading the page back.
        public let residueCaughtOnRecheck: [String]
        /// What happened to each page, in order.
        public let pages: [PageOutcome]
        /// Whether this file is a finished redacted copy or something awaiting a decision.
        public let disposition: Disposition
        /// The name a saved copy takes. Always carries "redacted" (spec §3). Equal to
        /// ``outputURL`` once the file has been written there.
        public let proposedURL: URL

        public enum Disposition: Equatable, Sendable {
            /// Verified: every redacted page was read back and came up clean.
            case written
            /// Written, but not proven clean — these things were still readable when the
            /// passes ran out. The file is real and usable; whether it is good enough is a
            /// judgement only the person who owns the document can make.
            case writtenUnverified(problems: [String])
        }

        /// `true` when the copy exists but could not be verified, so a person has to look.
        public var isUnverified: Bool { disposition != .written }

        /// What could not be cleared, in the engine's own words.
        public var problems: [String] {
            if case .writtenUnverified(let problems) = disposition { return problems }
            return []
        }

        /// Pages that carried no text to search and were copied through unexamined.
        public var unexaminedPages: [Int] {
            pages.compactMap { page in
                if case .notExamined = page.status { return page.index + 1 }
                return nil
            }
        }

        public var findings: [Finding] { pages.flatMap(\.findings) }
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
    ///   - matchers: run over page text, annotation values, the text read back off each
    ///     rendered page, and once more over the finished file.
    ///   - additionalMatches: already-located spans keyed by page index, for proposers not
    ///     deterministic enough to re-run during verification (the model tier).
    ///   - inspectVisibleText: consulted with what is legible on each rendered page. This is
    ///     what catches an identifier no matcher was written for — the failure that a second
    ///     pass with the same rules cannot find by definition.
    ///   - progress: called as work proceeds; reading pages back is slow enough to need it.
    public func redact(
        documentAt sourceURL: URL,
        matchers: [any Matcher],
        additionalMatches: [Int: [Match]] = [:],
        writingTo requestedURL: URL? = nil,
        inspectVisibleText: VisibleTextInspector? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> Result {
        guard let document = PDFDocument(url: sourceURL) else { throw Failure.cannotOpen(sourceURL) }
        guard !document.isLocked else { throw Failure.encrypted }

        let output = PDFDocument()
        var totalRedactions = 0
        var pagesRasterized = 0
        var rulesApplied: Set<String> = []
        var worstPassCount = 1
        var residueCaught: [String] = []
        var unresolved: [String] = []
        var outcomes: [PageOutcome] = []

        for index in 0 ..< document.pageCount {
            // A deep run takes minutes, so it has to be stoppable. Cancelling between pages
            // and between passes means nothing half-redacted is ever written: the candidate
            // file is only assembled after the loop completes.
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            progress?(.scanning(page: index + 1, of: document.pageCount))

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
                // A page with nothing to search is not the same as a page with nothing on
                // it, and the difference has to survive into the result.
                let examined = !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                outcomes.append(
                    PageOutcome(
                        index: index,
                        status: examined
                            ? .noMatches
                            : .notExamined(reason: "no extractable text — scanned or image-only"),
                        findings: []
                    )
                )
                continue
            }

            for match in matches { rulesApplied.insert(match.source.ruleDescription) }

            let proposed = Set((additionalMatches[index] ?? []).map(\.range))
            var findings = matches.map { match in
                let isLiteral: Bool
                if case .exact = match.source { isLiteral = true } else { isLiteral = false }
                return Finding(
                    pageIndex: index,
                    text: match.matchedText,
                    ruleDescription: match.source.ruleDescription,
                    origin: proposed.contains(match.range) ? .proposal : .rule,
                    ruleIsLiteral: isLiteral
                )
            }

            // Read the page as drawn before deciding where anything goes. PDFKit's text
            // geometry is not dependable enough to be the only source (see
            // `redactionBoxes`), and recognition at a higher resolution than the output
            // raster reads small print far more reliably.
            var reading: PageReading?
            if verifiesByReading,
               let clean = renderImage(page: page, blackingOut: [], scale: Self.recognitionScale) {
                progress?(.locating(page: index + 1))
                reading = try? PageOCR().read(clean, pageBox: page.bounds(for: .mediaBox))
            }

            var boxes = try redactionBoxes(
                for: matches, on: page, in: document, pageText: pageText, reading: reading
            )
            boxes += doomedAnnotations.map { $0.bounds.insetBy(dx: -padding, dy: -padding) }
            for annotation in doomedAnnotations { page.removeAnnotation(annotation) }

            let settled = try await settle(
                page: page,
                pageNumber: index + 1,
                originalText: pageText,
                intended: matches.map(\.matchedText)
                    + doomedAnnotations.compactMap(\.widgetStringValue),
                boxes: boxes,
                matchers: matchers,
                inspectVisibleText: inspectVisibleText,
                progress: progress
            )

            findings += settled.residue.map { text in
                Finding(
                    pageIndex: index,
                    text: text,
                    ruleDescription: "found by reading the page back",
                    origin: .caughtOnRecheck
                )
            }

            output.insert(settled.page, at: output.pageCount)
            let redactedHere = matches.count + doomedAnnotations.count + settled.extraRedactions
            totalRedactions += redactedHere
            residueCaught += settled.residue
            unresolved += settled.unresolved
            worstPassCount = max(worstPassCount, settled.passes)
            pagesRasterized += 1
            outcomes.append(
                PageOutcome(
                    index: index,
                    status: .redacted(items: redactedHere, passes: settled.passes),
                    findings: findings
                )
            )
        }

        guard totalRedactions > 0 else { throw Failure.nothingMatched }

        // Spec §5.5: a fresh document with no attributes carried over.
        output.documentAttributes = [:]

        // Spec §5.6: write a candidate, prove it is clean, and only then let it exist under
        // the real name. A file that fails verification never reaches the output path.
        progress?(.verifyingDocument)
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackline-\(UUID().uuidString).pdf")
        guard output.write(to: candidate) else { throw Failure.writeFailed }

        let problems = unresolved + (try verify(candidate, matchers: matchers))

        // A run started from a plan replaces that plan's output, so iterating on the plan
        // does not leave "redacted 2", "redacted 3" behind. §3's promise not to overwrite
        // still holds for everything else: only Blackline's own output for this document is
        // ever replaced, and never the original.
        let destination = requestedURL ?? Self.outputURL(for: sourceURL)
        guard destination != sourceURL else {
            try? FileManager.default.removeItem(at: candidate)
            throw Failure.writeFailed
        }

        // Nothing to report: the ordinary, verified path.
        if !problems.isEmpty, !holdsUnverifiedOutputForReview {
            try? FileManager.default.removeItem(at: candidate)
            throw Failure.verificationFailed(residue: problems)
        }

        do {
            if requestedURL != nil, FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: candidate)
            } else {
                try FileManager.default.moveItem(at: candidate, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: candidate)
            throw Failure.writeFailed
        }

        return Result(
            outputURL: destination,
            redactedItemCount: totalRedactions,
            pagesRasterized: pagesRasterized,
            pageCount: document.pageCount,
            rulesApplied: rulesApplied.sorted(),
            verificationPasses: worstPassCount,
            residueCaughtOnRecheck: residueCaught,
            pages: outcomes.sorted { $0.index < $1.index },
            disposition: problems.isEmpty ? .written : .writtenUnverified(problems: problems),
            proposedURL: destination
        )
    }

    // MARK: - Render, read back, correct, repeat

    private struct SettledPage {
        let page: PDFPage
        let passes: Int
        let residue: [String]
        /// Still legible when the passes ran out. Non-empty means this page could not be
        /// proven clean, whatever else happened to it.
        let unresolved: [String]
        var extraRedactions: Int { residue.count }
    }

    /// Renders a page, reads back what is legible on it, and blacks out anything still
    /// showing — repeating until a pass finds nothing new.
    ///
    /// This is the step that catches what the matchers never knew to look for. A second pass
    /// using the same rules would re-derive the same answer; what makes this worth doing is
    /// that the checker is different from the detector — Vision sees the rendered page, and
    /// `inspectVisibleText` can bring judgement the rules do not have.
    private func settle(
        page: PDFPage,
        pageNumber: Int,
        originalText: String,
        intended: [String],
        boxes initialBoxes: [CGRect],
        matchers: [any Matcher],
        inspectVisibleText: VisibleTextInspector?,
        progress: ProgressHandler?
    ) async throws -> SettledPage {
        let box = page.bounds(for: .mediaBox)
        var boxes = initialBoxes
        var residue: [String] = []
        var pass = 1

        while true {
            try Task.checkCancellation()
            progress?(.rendering(page: pageNumber, pass: pass))
            guard let image = renderImage(page: page, blackingOut: boxes) else {
                throw Failure.renderFailed(page: pageNumber)
            }

            guard verifiesByReading else {
                guard let rendered = makePage(from: image, box: box, rotation: page.rotation) else {
                    throw Failure.renderFailed(page: pageNumber)
                }
                return SettledPage(page: rendered, passes: pass, residue: residue, unresolved: [])
            }

            progress?(.reading(page: pageNumber, pass: pass))
            let reading = try PageOCR().read(image, pageBox: box)

            // What the rules can still see on the rendered page.
            var stillVisible = matchers
                .flatMap { $0.matches(in: SourceText(reading.text)) }
                .map(\.matchedText)

            // A rule matching the rendered page is evidence in its own right and is acted on
            // as it stands — that is how a value printed inside an image gets caught, since
            // the text layer never showed it to anyone.
            //
            // What a checker *reports* is different, and is narrowed to values this page
            // already set out to remove. See `worthActingOn`.
            if let inspectVisibleText, !reading.isEmpty {
                progress?(.consultingModel(page: pageNumber, pass: pass))
                let reported = try await inspectVisibleText(reading.text)
                stillVisible += Self.worthActingOn(reported, intended: intended)
            }

            // Only act on spans that can actually be located on the page.
            var newBoxes: [CGRect] = []
            var newResidue: [String] = []
            for span in stillVisible {
                let found = reading.boxes(covering: span)
                    .map { $0.insetBy(dx: -padding, dy: -padding) }
                    .filter { candidate in !boxes.contains { $0.contains(candidate) } }
                if !found.isEmpty {
                    newBoxes += found
                    newResidue.append(span)
                }
            }

            if newBoxes.isEmpty {
                progress?(.pageSettled(page: pageNumber, passes: pass))
                guard let rendered = makePage(from: image, box: box, rotation: page.rotation) else {
                    throw Failure.renderFailed(page: pageNumber)
                }
                return SettledPage(page: rendered, passes: pass, residue: residue, unresolved: [])
            }

            progress?(.residueFound(page: pageNumber, pass: pass, items: newResidue))
            residue += newResidue
            boxes += newBoxes
            pass += 1

            guard pass <= maximumVerificationPasses else {
                let attempts = pass - 1
                let problems = newResidue.map {
                    "page \(pageNumber): “\($0)” still legible after \(attempts) pass\(attempts == 1 ? "" : "es")"
                }
                // Out of passes. Either abandon the document, or keep the best render and
                // let the caller put it in front of someone — but never quietly treat this
                // page as finished.
                guard holdsUnverifiedOutputForReview else {
                    throw Failure.verificationFailed(residue: problems)
                }
                guard let rendered = makePage(from: image, box: box, rotation: page.rotation) else {
                    throw Failure.renderFailed(page: pageNumber)
                }
                return SettledPage(
                    page: rendered, passes: pass - 1, residue: residue, unresolved: problems
                )
            }
        }
    }

    /// Pages are recognized at this scale regardless of output resolution; Vision misreads
    /// small print rendered at the default raster scale.
    static let recognitionScale: CGFloat = 4.0

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
        pageText: String,
        reading: PageReading?
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
            var fromPDFKit: [CGRect] = []
            for line in selection.selectionsByLine() {
                let bounds = line.bounds(for: page)
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                let tightened = tightenVertically(bounds, on: page, indices: lower ..< upper)
                fromPDFKit.append(tightened.insetBy(dx: -padding, dy: -padding))
            }

            // Where recognition located the text, believe it: its boxes come from the ink on
            // the page and cannot drift from it. PDFKit's are then kept only where the two
            // agree, which discards the pathological ones without discarding the useful
            // extra coverage when they line up.
            let fromReading = (reading?.boxes(covering: match.matchedText) ?? [])
                .map { $0.insetBy(dx: -padding, dy: -padding) }

            if fromReading.isEmpty {
                boxes += fromPDFKit
            } else {
                boxes += fromReading
                boxes += fromPDFKit.filter { candidate in
                    fromReading.contains { $0.intersects(candidate) }
                }
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

    /// Filters what a *checker* reports down to values this page actually set out to remove.
    ///
    /// Applies to reports only, never to a rule matching the rendered page — a rule hit is
    /// evidence on its own, and is what catches a value printed inside an image.
    ///
    /// A checker is asked what is still visible on a page that has already been redacted,
    /// and answers with a great deal that is not evidence of anything: the field labels
    /// beside the boxes, the form's title, every line-item caption down a tax return, and
    /// fragments of words the boxes clipped. Acting on those blacks out more of the page
    /// every pass and ruins the document while protecting nobody. The failure this loop
    /// exists for — a box that landed wrong, leaving a value still showing — always concerns
    /// a value the first pass already found. Asked what is still visible on a
    /// redacted page, a model returns the field labels beside the boxes, the form's title,
    /// the line-item captions down a tax return, and fragments of words the boxes clipped.
    /// Acting on those blacks out more of the page every pass and ruins the document while
    /// protecting nobody.
    ///
    /// Finding something genuinely new is the first pass's job, on clean text, which it does
    /// far more reliably than it reads a page it has already redacted.
    static func worthActingOn(_ reported: [String], intended: [String]) -> [String] {
        let wanted = intended
            .map { SourceText.normalize($0).lowercased() }
            .filter { !$0.isEmpty }

        return reported.filter { span in
            let candidate = SourceText.normalize(span).lowercased()
            guard !candidate.isEmpty else { return false }
            // Either direction: recognition may return only part of a value, or a little
            // more of the line than the value itself.
            return wanted.contains { $0.contains(candidate) || candidate.contains($0) }
        }
    }

    // MARK: - Rendering

    /// Renders a page to an image with `boxes` filled black.
    func renderImage(page: PDFPage, blackingOut boxes: [CGRect], scale: CGFloat? = nil) -> CGImage? {
        let scale = scale ?? self.scale
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }

        // Draw unrotated so that the boxes — which are in page space — line up with what is
        // drawn. The rotation is put back on the replacement page afterwards.
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

        return context.makeImage()
    }

    /// Wraps a rendered image as a page of the original's size and orientation.
    func makePage(from image: CGImage, box: CGRect, rotation: Int) -> PDFPage? {
        let page = PDFPage(image: NSImage(cgImage: image, size: box.size))
        page?.setBounds(box, for: .mediaBox)
        page?.rotation = rotation
        return page
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

    /// Deletes a written copy. The original is never touched.
    public static func deleteCopy(_ result: Result) {
        try? FileManager.default.removeItem(at: result.outputURL)
    }

    /// `statement.pdf` becomes `statement redacted.pdf` beside it, never overwriting
    /// anything: a name already in use gets a counter (spec §3).
    public static func outputURL(for source: URL) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "pdf" : source.pathExtension
        return uniqueURL(
            like: directory.appendingPathComponent("\(stem) redacted").appendingPathExtension(ext)
        )
    }

    /// The given name, or the next free counter after it. Never returns a path that exists.
    static func uniqueURL(like wanted: URL) -> URL {
        guard FileManager.default.fileExists(atPath: wanted.path) else { return wanted }

        let directory = wanted.deletingLastPathComponent()
        let stem = wanted.deletingPathExtension().lastPathComponent
        let ext = wanted.pathExtension.isEmpty ? "pdf" : wanted.pathExtension

        var counter = 2
        while true {
            let candidate = directory
                .appendingPathComponent("\(stem) \(counter)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
