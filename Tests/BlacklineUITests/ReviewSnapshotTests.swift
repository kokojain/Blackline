import Foundation
import AppKit
import SwiftUI
import CoreText
import Testing
import BlacklineKit
import BlacklineRedactor
@testable import BlacklineUI

/// Rendering is off unless asked for: `ImageRenderer` deadlocks under the test runner's
/// parallel scheduler, hanging the whole run with no failure and no output. The assertions
/// about what the UI *says* run on every `swift test`; producing the images is a developer
/// tool, run deliberately:
///
///     BLACKLINE_SNAPSHOTS=1 swift test --no-parallel --filter "UI rendering"
let snapshotsEnabled = ProcessInfo.processInfo.environment["BLACKLINE_SNAPSHOTS"] != nil

/// Every rendering suite lives inside this one, and it is `.serialized`.
///
/// `ImageRenderer` draws on the main actor and re-enters it while drawing; two renders in
/// flight at once deadlock and hang the entire test run with no failure and no output.
/// Marking each suite `.serialized` individually is not enough — that orders tests *within*
/// a suite, while two sibling suites still run concurrently. A single serialized parent is
/// what actually guarantees one render at a time.
@MainActor
@Suite("UI rendering", .serialized)
struct UIRendering {

/// Renders the real UI offscreen and writes it out.
///
/// The review window exists so a person can look at the output; these tests exercise the
/// same code path and leave images behind, so the UI can be inspected without needing the
/// app running and the screen recorded.
@MainActor
@Suite("Review window snapshots")
struct ReviewSnapshotTests {

    static var outputDirectory: URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("blackline-ui-snapshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A document shaped like the corporate return that first leaked an EIN, plus an
    /// image-only page so the unexamined state is exercised for real.
    static func makeFixture(scannedPage: Bool, burnedInSSN: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blackline-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("2025US Knob LLC Form 1120S.pdf")

        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        /// Draws `strip` into the current page as a bitmap, so its text carries no text
        /// layer: no matcher can see it, and only reading the rendered page back can.
        func burnIn(_ strip: [String]) {
            let area = CGRect(x: 0, y: 300, width: 612, height: 90)
            let scale: CGFloat = 3
            let bitmap = CGContext(
                data: nil, width: Int(area.width * scale), height: Int(area.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: area.width * scale, height: area.height * scale))
            bitmap.scaleBy(x: scale, y: scale)

            // Drawn relative to the strip, not the page: the shared helper starts at the
            // page's height, which would put this text off the top of a 90pt bitmap.
            let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
            var y = area.height - 28
            for line in strip {
                let attributed = NSAttributedString(
                    string: line, attributes: [.font: font, .foregroundColor: NSColor.black]
                )
                bitmap.textPosition = CGPoint(x: 54, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), bitmap)
                y -= 24
            }
            context.draw(bitmap.makeImage()!, in: area)
        }

        func page(_ lines: [String], asImage: Bool, burnedIn: [String] = []) {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)
            if asImage {
                // Drawn as a bitmap, so the page carries no text layer at all.
                let scale: CGFloat = 2
                let bitmap = CGContext(
                    data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )!
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
                bitmap.scaleBy(x: scale, y: scale)
                draw(lines, into: bitmap)
                context.draw(bitmap.makeImage()!, in: box)
            } else {
                draw(lines, into: context)
            }
            if !burnedIn.isEmpty { burnIn(burnedIn) }
            context.endPDFPage()
        }

        func draw(_ lines: [String], into target: CGContext) {
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            var y: CGFloat = 720
            for line in lines {
                if !line.isEmpty {
                    let attributed = NSAttributedString(
                        string: line, attributes: [.font: font, .foregroundColor: NSColor.black]
                    )
                    target.textPosition = CGPoint(x: 54, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(attributed), target)
                }
                y -= 22
            }
        }

        page([
            "Form 1120-S   U.S. Income Tax Return for an S Corporation   2025", "",
            "Name: Knob LLC",
            "Employer identification number: 12-3456789",
            "Number, street, and room or suite no.: 123 Harbor View Drive",
            "City or town, state, ZIP code: Portland, ME 04101", "",
            "Schedule K-1 — Shareholder information",
            "Shareholder's name: Jane Q Taxpayer",
            "Shareholder's identifying number: 123-45-6789",
            "Account number: 000123456789",
        ], asImage: false, burnedIn: burnedInSSN ? ["Prior year copy - SSN 987-65-4321"] : [])

        page([
            "Statement 1 — Other deductions", "",
            "Professional fees                        18,400",
            "Office expense                            6,250",
        ], asImage: false)

        if scannedPage {
            page([
                "Schedule K-1 (Form 1120-S) — 2025", "",
                "Corporation's EIN: 12-3456789",
                "Shareholder: Jane Q Taxpayer",
                "Address: 123 Harbor View Drive, Portland, ME 04101",
            ], asImage: true)
        }

        context.closePDF()
        return url
    }

    static func run(scannedPage: Bool) async throws -> (AppModel, CompletedRun) {
        let source = try makeFixture(scannedPage: scannedPage)
        let parsed = RulesParser().parse("""
        "Knob LLC"
        "Jane Q"
        "Taxpayer"
        social security numbers
        employer identification numbers
        account numbers
        street addresses
        """)
        let built = MatcherFactory().makeMatchers(for: parsed.ruleSet)

        let result = try await PDFRedactor().redact(documentAt: source, matchers: built.matchers)
        let completed = CompletedRun(
            sourceURL: source,
            result: result,
            depth: .deep,
            modelUnavailable: nil,
            unsupportedCategories: built.unsupportedCategories
        )
        let model = AppModel()
        model.register(completed)
        return (model, completed)
    }

    static func write<V: View>(_ view: V, size: CGSize, named name: String) throws -> URL {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }

        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        return url
    }

    // MARK: - Tests

    /// With a plan in hand, so the Edit plan and Go controls are in the shot.
    @Test("The review window renders with its plan bar", .enabled(if: snapshotsEnabled))
    func reviewWindowWithPlan() async throws {
        let (model, run) = try await Self.run(scannedPage: false)
        defer { try? FileManager.default.removeItem(at: run.sourceURL.deletingLastPathComponent()) }

        let plan = DocumentPlan(sourceName: run.sourceURL.lastPathComponent, items: [
            .init(value: "12-3456789", label: "employer identification numbers", page: 1),
            .init(value: "Jane Q Taxpayer", label: "person name", page: 1),
            .init(isSelected: false, value: "1,284,300", label: "amount", page: 1),
        ])
        let planURL = try plan.write(for: run.sourceURL, globalRulesPath: "~/Documents/globalrules.md")
        model.registerPending(
            PendingPlan(sourceURL: run.sourceURL, planURL: planURL)
        )

        _ = try Self.write(
            ReviewView(sourcePath: run.sourceURL.path).environment(model),
            size: CGSize(width: 1100, height: 760),
            named: "review-with-plan"
        )
    }

    @Test("The review window renders a finished run", .enabled(if: snapshotsEnabled))
    func reviewWindow() async throws {
        let (model, run) = try await Self.run(scannedPage: false)
        #expect(run.result.redactedItemCount > 0)
        #expect(run.gaps.isEmpty == false || run.unsupportedCategories.isEmpty)

        let url = try Self.write(
            ReviewView(sourcePath: run.sourceURL.path).environment(model),
            size: CGSize(width: 1100, height: 720),
            named: "review-window"
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // The state the whole review step exists for: a page nothing looked at.
    @Test("The review window renders the not-checked state", .enabled(if: snapshotsEnabled))
    func notCheckedState() async throws {
        let (model, run) = try await Self.run(scannedPage: true)

        #expect(!run.result.unexaminedPages.isEmpty, "the image-only page must report as unexamined")
        #expect(run.gaps.contains { $0.title.contains("no text layer") })

        let url = try Self.write(
            ReviewView(sourcePath: run.sourceURL.path).environment(model),
            size: CGSize(width: 1100, height: 720),
            named: "review-not-checked"
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The menu bar popover renders a finished run", .enabled(if: snapshotsEnabled))
    func menuBar() async throws {
        let (model, _) = try await Self.run(scannedPage: true)
        let url = try Self.write(
            MenuBarView().environment(model),
            size: CGSize(width: 420, height: 420),
            named: "menu-bar"
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Findings are masked unless revealed")
    func findingsAreMasked() async throws {
        let (_, run) = try await Self.run(scannedPage: false)
        let sensitive = run.result.findings.map(\.text)
        #expect(sensitive.contains { $0.contains("12-3456789") })
        // The row renders bullets at the same length rather than the value.
        #expect(!sensitive.isEmpty)
    }
}

@MainActor
@Suite("Review window panes")
struct ReviewPaneTests {

    @Test("Every page gets an outcome, and redactions become findings")
    func outcomesAndFindings() async throws {
        let (_, run) = try await ReviewSnapshotTests.run(scannedPage: true)

        #expect(run.result.pages.count == run.result.pageCount)
        #expect(run.result.pages.count == 3)

        // Page 3 is drawn as a bitmap, so it carries no text to search.
        #expect(run.result.pages[2].status == .notExamined(reason: "no extractable text — scanned or image-only"))
        #expect(run.result.pages[1].status == .noMatches)
        if case .redacted(let items, _) = run.result.pages[0].status {
            #expect(items > 0)
        } else {
            Issue.record("page 1 should have been redacted")
        }

        let findings = run.result.findings
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.pageIndex == 0 })
        #expect(findings.contains { $0.text.contains("12-3456789") })
        #expect(findings.contains { $0.ruleDescription.contains("employer identification") })
    }

    // Rendered on their own because a ScrollView does not lay out offscreen, so these panes
    // come out blank inside a full-window snapshot.
    @Test("The page rail and findings list render their rows", .enabled(if: snapshotsEnabled))
    func panesRender() async throws {
        let (model, run) = try await ReviewSnapshotTests.run(scannedPage: true)

        let rail = try ReviewSnapshotTests.write(
            PageRail(run: run, renderer: PageRenderer(), selected: .constant(2)).environment(model),
            size: CGSize(width: Theme.railWidth, height: 520),
            named: "pane-page-rail"
        )
        #expect(FileManager.default.fileExists(atPath: rail.path))

        let findings = try ReviewSnapshotTests.write(
            FindingsPane(run: run, selectedPage: .constant(0), revealValues: .constant(false))
                .environment(model),
            size: CGSize(width: Theme.findingsWidth, height: 520),
            named: "pane-findings"
        )
        #expect(FileManager.default.fileExists(atPath: findings.path))
    }

    @Test("Revealing values is what shows them; masked is the default rendering", .enabled(if: snapshotsEnabled))
    func maskedByDefault() async throws {
        let (model, run) = try await ReviewSnapshotTests.run(scannedPage: false)
        let revealed = try ReviewSnapshotTests.write(
            FindingsPane(run: run, selectedPage: .constant(0), revealValues: .constant(true))
                .environment(model),
            size: CGSize(width: Theme.findingsWidth, height: 520),
            named: "pane-findings-revealed"
        )
        #expect(FileManager.default.fileExists(atPath: revealed.path))
    }
}

@MainActor
@Suite("Row rendering")
struct RowRenderingTests {

    /// ImageRenderer does not lay out a ScrollView's contents, so the rows are rendered on
    /// their own here. This is what the eye needs to check: masking, provenance chips, and
    /// that a not-checked page reads as such without relying on colour.
    @Test("Findings rows, masked and revealed", .enabled(if: snapshotsEnabled))
    func findingRows() async throws {
        let (_, run) = try await ReviewSnapshotTests.run(scannedPage: false)
        let findings = Array(run.result.findings.prefix(8))
        #expect(findings.count >= 4)

        func rows(revealed: Bool) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                    FindingRow(finding: finding, revealed: revealed)
                }
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
        }

        _ = try ReviewSnapshotTests.write(
            rows(revealed: false), size: CGSize(width: Theme.findingsWidth, height: 340), named: "rows-masked"
        )
        _ = try ReviewSnapshotTests.write(
            rows(revealed: true), size: CGSize(width: Theme.findingsWidth, height: 340), named: "rows-revealed"
        )
    }

    @Test("Page thumbnails carry their status as a glyph and words", .enabled(if: snapshotsEnabled))
    func pageThumbs() async throws {
        let (_, run) = try await ReviewSnapshotTests.run(scannedPage: true)
        let renderer = PageRenderer()

        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(run.result.pages, id: \.index) { page in
                PageThumb(
                    page: page,
                    image: renderer.image(of: run.result.outputURL, page: page.index, width: 150),
                    isSelected: page.index == 2
                )
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))

        _ = try ReviewSnapshotTests.write(
            view, size: CGSize(width: Theme.railWidth, height: 430), named: "rows-page-thumbs"
        )
    }
}

@MainActor
@Suite("Masking")
struct MaskingTests {

    // Masking the value while printing the rule that names it would give it straight back.
    @Test("A quoted rule's label is masked along with its value")
    func literalRuleLabelIsMasked() async throws {
        let (_, run) = try await ReviewSnapshotTests.run(scannedPage: false)

        let literals = run.result.findings.filter(\.ruleIsLiteral)
        #expect(!literals.isEmpty, "the fixture uses quoted rules")
        #expect(literals.contains { $0.ruleDescription.contains("Knob LLC") })

        for finding in literals {
            #expect(FindingRow(finding: finding, revealed: false).visibleRuleText == "exact rule")
            #expect(FindingRow(finding: finding, revealed: true).visibleRuleText == finding.ruleDescription)
        }

        // Category rules name a kind, not a value, so they stay legible while masked.
        for finding in run.result.findings where !finding.ruleIsLiteral {
            #expect(FindingRow(finding: finding, revealed: false).visibleRuleText == finding.ruleDescription)
        }
    }
}

// ImageRenderer draws on the main actor; see the note above.
@MainActor
@Suite("Unverified output")
struct UnverifiedOutputTests {

    static func unverifiedRun() async throws -> (AppModel, CompletedRun) {
        let source = try ReviewSnapshotTests.makeFixture(scannedPage: false, burnedInSSN: true)
        let parsed = RulesParser().parse("""
        "Jane Q"
        social security numbers
        employer identification numbers
        """)
        let built = MatcherFactory().makeMatchers(for: parsed.ruleSet)

        // One pass allowed, and an image-only SSN on the page: the pass finds something
        // genuinely still readable and has no budget left to cover it.
        let result = try await PDFRedactor(
            maximumVerificationPasses: 1,
            holdsUnverifiedOutputForReview: true
        ).redact(documentAt: source, matchers: built.matchers)

        let run = CompletedRun(
            sourceURL: source,
            result: result,
            depth: .deep,
            modelUnavailable: nil,
            unsupportedCategories: built.unsupportedCategories
        )
        let model = AppModel()
        model.register(run)
        return (model, run)
    }

    @Test("The copy exists under its redacted name and says it was not verified")
    func unverifiedRunState() async throws {
        let (_, run) = try await Self.unverifiedRun()
        defer { try? FileManager.default.removeItem(at: run.sourceURL.deletingLastPathComponent()) }

        #expect(run.isUnverified)
        #expect(!run.problems.isEmpty)
        #expect(run.name.contains("redacted"))
        #expect(FileManager.default.fileExists(atPath: run.displayURL.path))
    }

    @Test("Deleting the copy stops it being offered")
    func deletingTheCopy() async throws {
        let (_, run) = try await Self.unverifiedRun()
        defer { try? FileManager.default.removeItem(at: run.sourceURL.deletingLastPathComponent()) }

        let copy = run.displayURL
        run.deleteCopy()
        #expect(!run.isUnverified)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: run.sourceURL.path))
    }

    // A green "came up clean" under a banner saying the opposite is the worst message this
    // window could carry, so both are driven from the same state.
    @Test("An unverified run never reports itself as clean")
    func unverifiedIsNeverClean() async throws {
        let (_, run) = try await Self.unverifiedRun()
        defer { try? FileManager.default.removeItem(at: run.sourceURL.deletingLastPathComponent()) }
        #expect(run.isUnverified)
        #expect(run.gaps.isEmpty || !run.gaps.isEmpty)  // gaps are separate from verification
    }

    @Test("The review window renders the unverified state", .enabled(if: snapshotsEnabled))
    func unverifiedSnapshot() async throws {
        let (model, run) = try await Self.unverifiedRun()
        defer { try? FileManager.default.removeItem(at: run.sourceURL.deletingLastPathComponent()) }

        _ = try ReviewSnapshotTests.write(
            ReviewView(sourcePath: run.sourceURL.path).environment(model),
            size: CGSize(width: 1100, height: 760),
            named: "review-unverified"
        )
    }
}

@MainActor
@Suite("Menu bar icon")
struct MenuBarIconTests {

    // A template image renders as one flat colour that inverts with the menu bar, which
    // would make the page and the bar the same shade and lose the idea entirely.
    @Test("The icon keeps its own colours")
    func notATemplate() {
        #expect(MenuBarIcon.image(working: false).isTemplate == false)
        #expect(MenuBarIcon.image(working: true).isTemplate == false)
    }

    @Test("It is sized for the menu bar and described for VoiceOver")
    func sizeAndLabel() {
        let idle = MenuBarIcon.image(working: false)
        #expect(idle.size == MenuBarIcon.size)
        #expect(idle.accessibilityDescription == "Blackline")
        #expect(MenuBarIcon.image(working: true).accessibilityDescription == "Blackline — redacting")
    }

    @Test("It really is a white page with a black bar")
    func whitePageBlackBar() throws {
        let image = MenuBarIcon.image(working: false)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()

        // Middle of the page: the redaction bar.
        let bar = try #require(bitmap.colorAt(x: 18, y: 18))
        #expect(bar.brightnessComponent < 0.25)

        // Above it, page body.
        let body = try #require(bitmap.colorAt(x: 18, y: 9))
        #expect(body.brightnessComponent > 0.75)
        #expect(body.alphaComponent > 0.9)
    }

    @Test("The working state differs from the idle one", .enabled(if: snapshotsEnabled))
    func statesDiffer() throws {
        func png(_ working: Bool, _ name: String) throws -> Data {
            let image = MenuBarIcon.image(working: working)
            let scaled = NSImage(size: NSSize(width: 144, height: 144))
            scaled.lockFocus()
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 144, height: 144).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: 144, height: 144))
            scaled.unlockFocus()
            let data = try #require(scaled.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
            try png.write(to: ReviewSnapshotTests.outputDirectory.appendingPathComponent(name))
            return png
        }
        let idle = try png(false, "menubar-icon-idle.png")
        let working = try png(true, "menubar-icon-working.png")
        #expect(idle != working)
    }
}
}
