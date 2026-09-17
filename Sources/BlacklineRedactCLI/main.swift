import Foundation
import PDFKit
import BlacklineKit
import BlacklineIntelligence
import BlacklineRedactor

// Writes a redacted copy of a PDF. The original is never modified and an existing file is
// never overwritten (spec §2, §3).

struct Options {
    var pdfPath: String
    var rulesPath: String
    var useModel: Bool
    var scale: CGFloat
}

func parseArguments() -> Options? {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else { return nil }

    var rulesPath = NSString(string: "~/Documents/redact.txt").expandingTildeInPath
    var useModel = false
    var scale: CGFloat = 2.0
    var positional: [String] = []

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--rules", "-r":
            guard !arguments.isEmpty else { return nil }
            rulesPath = NSString(string: arguments.removeFirst()).expandingTildeInPath
        case "--llm":
            useModel = true
        case "--scale":
            guard !arguments.isEmpty, let value = Double(arguments.removeFirst()) else { return nil }
            scale = CGFloat(value)
        case "--help", "-h":
            return nil
        default:
            positional.append(argument)
        }
    }

    guard positional.count == 1 else { return nil }
    return Options(
        pdfPath: NSString(string: positional[0]).expandingTildeInPath,
        rulesPath: rulesPath,
        useModel: useModel,
        scale: scale
    )
}

func usage() {
    print("""
    blackline-redact — write a redacted copy of a PDF. The original is never modified.

    USAGE
      swift run blackline-redact <file.pdf> [--rules <redact.txt>] [--llm] [--scale N]

    OPTIONS
      -r, --rules <path>   Rules file (default: ~/Documents/redact.txt)
          --llm            Also use the on-device model (macOS 26, Apple Intelligence)
          --scale N        Raster resolution, multiples of 72 dpi (default 2.0 ≈ 144 dpi)
      -h, --help           Show this message

    Redacted pages are rasterized, so their text stops being selectable. That is what
    makes the removal provable rather than cosmetic.
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

guard let options = parseArguments() else {
    usage()
    exit(CommandLine.arguments.count > 1 ? 0 : 2)
}

// MARK: - Rules

guard FileManager.default.fileExists(atPath: options.rulesPath) else {
    fail("no rules file at \(options.rulesPath) — copy samples/redact.example.txt there, or pass --rules")
}

let parsed: RulesParser.Result
do {
    parsed = try RulesParser().parse(contentsOf: URL(fileURLWithPath: options.rulesPath))
} catch let error as RulesParser.FileError {
    // Already names the file and how to fix it; don't wrap it in another path.
    fail(error.errorDescription ?? "could not read \(options.rulesPath)")
} catch {
    fail("could not read \(options.rulesPath): \(error.localizedDescription)")
}
if parsed.ruleSet.isEmpty {
    fail("\(options.rulesPath) contains no usable rules — nothing would be redacted.")
}
for diagnostic in parsed.diagnostics {
    print("! \(diagnostic.message)")
}

let built = MatcherFactory().makeMatchers(for: parsed.ruleSet)
let sourceURL = URL(fileURLWithPath: options.pdfPath)

guard let document = PDFDocument(url: sourceURL) else { fail("could not open \(options.pdfPath) as a PDF") }
if document.isLocked { fail("\(options.pdfPath) is encrypted and locked; password handling is not built yet") }

// MARK: - Model tier

var additionalMatches: [Int: [Match]] = [:]
var unlocatedCount = 0

if options.useModel {
    guard #available(macOS 26.0, *) else { fail("--llm requires macOS 26 or later") }
    if case .failure(let reason) = ModelProposer.checkAvailability() {
        fail("--llm unavailable: \(reason.errorDescription ?? "unknown")")
    }
    let proposer = ModelProposer()
    let locator = ProposalLocator()
    // Told to find what the rules ask for, rather than deciding for itself.
    let wanted = parsed.ruleSet.categories.map(\.canonicalName)
    for index in 0 ..< document.pageCount {
        guard let page = document.page(at: index), let pageText = page.string, !pageText.isEmpty else { continue }
        print("Reading page \(index + 1) of \(document.pageCount) with the on-device model…")
        do {
            let proposals = try await proposer.proposals(forPage: pageText, wanted: wanted)
            let (located, unlocated) = locator.locate(proposals, in: SourceText(pageText))
            unlocatedCount += unlocated.count
            var spans: Set<Range<String.Index>> = []
            additionalMatches[index] = located
                .flatMap(\.matches)
                .filter { spans.insert($0.range).inserted }
        } catch {
            print("! page \(index + 1): the model failed (\(error.localizedDescription)); rules still applied")
        }
    }
}

// MARK: - Pages the tool cannot examine

// Stated before the result, because a page with no extractable text is not redacted at all
// and a clean-looking summary must not be the only thing the user reads.
let unreadablePages = (0 ..< document.pageCount).compactMap { index -> Int? in
    guard let page = document.page(at: index) else { return nil }
    let text = page.string ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? index + 1 : nil
}

// MARK: - Progress reporting

// Reading each page back takes a second or two, and consulting the model takes several, so
// the work has to be visible. On a terminal the transient steps overwrite one another; when
// output is piped they become ordinary lines so nothing is lost in a log.
let isTerminal = isatty(FileHandle.standardOutput.fileDescriptor) == 1

@Sendable func status(_ line: String) {
    if isTerminal {
        print("\u{1B}[2K\r   \(line)", terminator: "")
        fflush(stdout)
    } else {
        print("   \(line)")
    }
}

@Sendable func settled(_ line: String) {
    if isTerminal {
        print("\u{1B}[2K\r   \(line)")
    } else {
        print("   \(line)")
    }
}

let progress: PDFRedactor.ProgressHandler = { step in
    switch step {
    case .scanning(let page, let total):
        print("Page \(page) of \(total)")
    case .locating:
        status("locating the matched text on the rendered page")
    case .rendering(_, let pass):
        status("pass \(pass) · rendering")
    case .reading(_, let pass):
        status("pass \(pass) · reading the rendered page back")
    case .consultingModel(_, let pass):
        status("pass \(pass) · asking the on-device model what is still visible…")
    case .residueFound(_, let pass, let items):
        settled("pass \(pass) · STILL VISIBLE: \(items.map { "“\($0)”" }.joined(separator: ", "))")
        status("pass \(pass) · blacking those out and rendering again")
    case .pageSettled(_, let passes):
        settled("clean after \(passes) pass\(passes == 1 ? "" : "es")")
    case .verifyingDocument:
        print("Verifying the finished document…")
    }
}

// What the model is asked on each re-read. Distinct from first-pass detection: this one
// looks at a page that has already been redacted and reports what survived.
var inspector: PDFRedactor.VisibleTextInspector?
if options.useModel, #available(macOS 26.0, *) {
    let proposer = ModelProposer()
    let wanted = parsed.ruleSet.categories.map(\.canonicalName)
    inspector = { visibleText in
        try await proposer.residue(inVisibleText: visibleText, wanted: wanted).map(\.text)
    }
}

// MARK: - Redact

do {
    let redactor = PDFRedactor(scale: options.scale)
    let result = try await redactor.redact(
        documentAt: sourceURL,
        matchers: built.matchers,
        additionalMatches: additionalMatches,
        inspectVisibleText: inspector,
        progress: progress
    )

    print("")
    print("\(sourceURL.lastPathComponent) → \(result.redactedItemCount) item\(result.redactedItemCount == 1 ? "" : "s") redacted")
    print("  Written   \(result.outputURL.path)")
    print("  Rules     \(result.rulesApplied.joined(separator: ", "))")
    print("  Pages     \(result.pagesRasterized) of \(result.pageCount) rasterized (their text is no longer selectable)")
    print("  Passes    up to \(result.verificationPasses) render-and-read-back pass\(result.verificationPasses == 1 ? "" : "es") per page")
    if result.residueCaughtOnRecheck.isEmpty {
        print("  Verified  every page read back clean on the first render")
    } else {
        let caught = Set(result.residueCaughtOnRecheck).sorted()
        print("  Caught    \(caught.count) item\(caught.count == 1 ? "" : "s") the first pass missed, found by reading the page back:")
        for item in caught { print("              “\(item)”") }
    }

    var warnings: [String] = []
    if !built.unsupportedCategories.isEmpty {
        warnings.append("""
        NOT REDACTED — no detector built yet for: \(built.unsupportedCategories.map(\.canonicalName).joined(separator: ", ")).
        """)
    }
    if !unreadablePages.isEmpty {
        warnings.append("""
        NOT REDACTED — page\(unreadablePages.count == 1 ? "" : "s") \(unreadablePages.map(String.init).joined(separator: ", ")) had no extractable text (scanned or image-only).
          OCR is not built yet, so \(unreadablePages.count == 1 ? "it was" : "they were") copied through untouched.
        """)
    }
    if unlocatedCount > 0 {
        warnings.append("DISCARDED — \(unlocatedCount) model proposal\(unlocatedCount == 1 ? "" : "s") could not be located on the page and \(unlocatedCount == 1 ? "was" : "were") dropped.")
    }
    if !warnings.isEmpty {
        print("")
        for warning in warnings { print(warning) }
    }
} catch let failure as PDFRedactor.Failure {
    // Spec §5.6 and §3: a failed verification or an empty match set means no file, not a
    // quietly imperfect one.
    fail(failure.errorDescription ?? "redaction failed")
} catch {
    fail(error.localizedDescription)
}
