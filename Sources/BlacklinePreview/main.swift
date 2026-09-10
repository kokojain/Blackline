import Foundation
import PDFKit
import BlacklineKit

// A read-only preview of what Blackline would redact. It opens a PDF, extracts the text
// PDFKit can see, runs the rules over it, and prints a report. It never writes a file and
// never modifies the input — the redaction pipeline (spec §5.4–5.6) is not built yet, so
// this deliberately cannot produce a redacted document.

struct Options {
    var pdfPath: String
    var rulesPath: String
    var maskMatches: Bool
}

func parseArguments() -> Options? {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else { return nil }

    var rulesPath = NSString(string: "~/Documents/redact.txt").expandingTildeInPath
    var maskMatches = false
    var positional: [String] = []

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--rules", "-r":
            guard !arguments.isEmpty else { return nil }
            rulesPath = NSString(string: arguments.removeFirst()).expandingTildeInPath
        case "--mask":
            maskMatches = true
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
        maskMatches: maskMatches
    )
}

func usage() {
    print("""
    blackline-preview — show what Blackline would redact. Reads only; writes nothing.

    USAGE
      swift run blackline-preview <file.pdf> [--rules <redact.txt>] [--mask]

    OPTIONS
      -r, --rules <path>   Rules file (default: ~/Documents/redact.txt)
          --mask           Print matches as •••• instead of their text
      -h, --help           Show this message
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func display(_ text: String, masked: Bool) -> String {
    let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: "⏎")
    return masked ? String(repeating: "•", count: min(collapsed.count, 12)) : "\"\(collapsed)\""
}

guard let options = parseArguments() else {
    usage()
    exit(CommandLine.arguments.count > 1 ? 0 : 2)
}

// MARK: - Rules

guard FileManager.default.fileExists(atPath: options.rulesPath) else {
    fail("""
    no rules file at \(options.rulesPath)
      Copy samples/redact.example.txt there, or pass --rules <path>.
    """)
}

let parsed: RulesParser.Result
do {
    parsed = try RulesParser().parse(contentsOf: URL(fileURLWithPath: options.rulesPath))
} catch {
    fail("could not read \(options.rulesPath): \(error.localizedDescription)")
}

// Spec §3: a silent no-op is a privacy failure. Refuse rather than report a clean page.
if parsed.ruleSet.isEmpty {
    fail("\(options.rulesPath) contains no usable rules — nothing would be redacted.")
}

// MARK: - Document

guard let document = PDFDocument(url: URL(fileURLWithPath: options.pdfPath)) else {
    fail("could not open \(options.pdfPath) as a PDF")
}
if document.isLocked {
    fail("""
    \(options.pdfPath) is encrypted and locked.
      Password handling (spec §7) is not built yet.
    """)
}

let factory = MatcherFactory()
let built = factory.makeMatchers(for: parsed.ruleSet)

print("Blackline preview")
print("  Document  \(options.pdfPath)  (\(document.pageCount) page\(document.pageCount == 1 ? "" : "s"))")
print("  Rules     \(options.rulesPath)  (\(parsed.ruleSet.ruleCount) rule\(parsed.ruleSet.ruleCount == 1 ? "" : "s"))")
print("")

if !parsed.diagnostics.isEmpty {
    print("Rule warnings")
    for diagnostic in parsed.diagnostics {
        print("  ! \(diagnostic.message)")
    }
    print("")
}

// MARK: - Scan

var totalMatches = 0
var pagesWithoutText: [Int] = []
var matchedRules: Set<String> = []

for pageIndex in 0 ..< document.pageCount {
    let pageNumber = pageIndex + 1
    guard let page = document.page(at: pageIndex) else { continue }

    let extracted = page.string ?? ""
    if extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        pagesWithoutText.append(pageNumber)
        continue
    }

    let text = SourceText(extracted)
    let matches = built.matchers
        .flatMap { $0.matches(in: text) }
        .sorted { $0.range.lowerBound < $1.range.lowerBound }

    guard !matches.isEmpty else {
        print("Page \(pageNumber)  —  nothing matched")
        continue
    }

    totalMatches += matches.count
    print("Page \(pageNumber)  —  \(matches.count) item\(matches.count == 1 ? "" : "s")")
    for match in matches {
        matchedRules.insert(match.source.ruleDescription)
        let label = match.source.ruleDescription.padding(toLength: 26, withPad: " ", startingAt: 0)
        print("    \(label)\(display(match.matchedText, masked: options.maskMatches))")
    }
}

// MARK: - Summary

print("")
print("\(totalMatches) item\(totalMatches == 1 ? "" : "s") matched by \(matchedRules.count) rule\(matchedRules.count == 1 ? "" : "s").")

let unusedRules = Set(parsed.ruleSet.exactRules.map { "“\($0.literal)”" })
    .union(parsed.ruleSet.categories.map(\.canonicalName))
    .subtracting(matchedRules)
if !unusedRules.isEmpty {
    print("Rules that matched nothing: \(unusedRules.sorted().joined(separator: ", "))")
}

// The failures that matter are the ones you cannot see, so they are stated last and plainly.
var gaps: [String] = []

if !built.unsupportedCategories.isEmpty {
    let names = built.unsupportedCategories.map(\.canonicalName).joined(separator: ", ")
    gaps.append("""
    NOT CHECKED — no detector built yet for: \(names).
      These need NSDataDetector and NaturalLanguage (spec §5.3). Until then, list such
      values as quoted exact rules in your rules file.
    """)
}

if !pagesWithoutText.isEmpty {
    let pages = pagesWithoutText.map(String.init).joined(separator: ", ")
    gaps.append("""
    NOT CHECKED — no extractable text on page\(pagesWithoutText.count == 1 ? "" : "s") \(pages) (scanned or image-only).
      OCR (spec §5.2) is not built yet, so these pages were not examined at all.
    """)
}

if !gaps.isEmpty {
    print("")
    for gap in gaps { print(gap) }
}

print("")
print("Preview only — no file was written and \(options.pdfPath) was not modified.")
