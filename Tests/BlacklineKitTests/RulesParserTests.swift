import Foundation
import Testing
@testable import BlacklineKit

@Suite("RulesParser")
struct RulesParserTests {
    private let parser = RulesParser()

    // MARK: - Skipped lines

    @Test("An empty file yields an empty rule set")
    func emptyFile() {
        let result = parser.parse("")
        #expect(result.ruleSet.isEmpty)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Comments, blank lines, and whitespace-only lines are ignored", arguments: [
        "# Blackline rules",
        "   # indented comment",
        "",
        "   ",
        "\t",
    ])
    func ignoresNonRuleLines(_ line: String) {
        let result = parser.parse(line)
        #expect(result.ruleSet.isEmpty)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("A comment must start the line, so # inside a literal is kept")
    func hashInsideLiteral() {
        let result = parser.parse("\"Apt #4\"")
        #expect(result.ruleSet.exactRules.map(\.literal) == ["Apt #4"])
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - Exact rules

    @Test("A quoted line becomes a case-insensitive exact rule")
    func quotedRule() {
        let result = parser.parse("\"Nikhil\"")
        let rule = try! #require(result.ruleSet.exactRules.first)
        #expect(rule.literal == "Nikhil")
        #expect(rule.isCaseSensitive == false)
        #expect(rule.lineNumber == 1)
    }

    @Test("A ! prefix makes the exact rule case-sensitive")
    func caseSensitiveRule() {
        let result = parser.parse("!\"ACME\"")
        let rule = try! #require(result.ruleSet.exactRules.first)
        #expect(rule.literal == "ACME")
        #expect(rule.isCaseSensitive)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Whitespace around a ! prefix is tolerated")
    func caseSensitiveWithSpace() {
        let result = parser.parse("! \"ACME\"")
        #expect(result.ruleSet.exactRules.first?.isCaseSensitive == true)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Surrounding whitespace is trimmed, inner whitespace preserved")
    func trimsAroundRule() {
        let result = parser.parse("   \"Knob  LLC\"   ")
        #expect(result.ruleSet.exactRules.map(\.literal) == ["Knob  LLC"])
    }

    @Test("Inner quotes are kept, since the literal runs to the last quote")
    func innerQuotes() {
        let result = parser.parse("\"say \"hi\"\"")
        #expect(result.ruleSet.exactRules.map(\.literal) == ["say \"hi\""])
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - Malformed lines

    @Test("An unterminated quote is reported and the line skipped")
    func unterminatedQuote() {
        let result = parser.parse("\"Nikhil")
        #expect(result.ruleSet.isEmpty)
        #expect(result.diagnostics.map(\.kind) == [.unterminatedQuote])
        #expect(result.diagnostics.first?.lineNumber == 1)
    }

    @Test("A lone quote character is an unterminated quote")
    func loneQuote() {
        #expect(parser.parse("\"").diagnostics.map(\.kind) == [.unterminatedQuote])
    }

    @Test("A stray quote on a description is reported")
    func strayQuote() {
        let result = parser.parse("Nikhil\"")
        #expect(result.ruleSet.isEmpty)
        #expect(result.diagnostics.map(\.kind) == [.strayQuote])
    }

    @Test("Empty and whitespace-only literals are reported", arguments: ["\"\"", "\"   \""])
    func emptyLiteral(_ line: String) {
        let result = parser.parse(line)
        #expect(result.ruleSet.isEmpty)
        #expect(result.diagnostics.map(\.kind) == [.emptyExactMatch])
    }

    @Test("A ! prefix without quotes is reported", arguments: ["!Nikhil", "!", "!  "])
    func bangWithoutQuotes(_ line: String) {
        let result = parser.parse(line)
        #expect(result.ruleSet.isEmpty)
        #expect(result.diagnostics.map(\.kind) == [.caseSensitiveMarkerRequiresQuotes])
    }

    @Test("One bad line does not cost the rules around it")
    func badLineIsIsolated() {
        let result = parser.parse("""
        "Nikhil"
        "unterminated
        email addresses
        """)
        #expect(result.ruleSet.exactRules.map(\.literal) == ["Nikhil"])
        #expect(result.ruleSet.categories == [.emailAddresses])
        #expect(result.diagnostics.map(\.lineNumber) == [2])
    }

    // MARK: - Categories

    @Test("Every documented alias resolves to its category")
    func allAliasesResolve() {
        for category in Category.allCases {
            for alias in category.aliases {
                #expect(Category.named(alias) == category, "alias “\(alias)”")
            }
        }
    }

    @Test("Category descriptions ignore case and extra whitespace", arguments: [
        "email addresses", "Email Addresses", "  EMAIL   ADDRESSES  ", "e-mail",
    ])
    func categoryNormalization(_ description: String) {
        let result = parser.parse(description)
        #expect(result.ruleSet.categories == [.emailAddresses])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("The categories listed in the spec's example file all parse")
    func specExampleCategories() {
        let result = parser.parse("""
        email addresses
        phone numbers
        social security numbers
        street addresses
        account numbers
        dates of birth
        person names
        """)
        #expect(result.diagnostics.isEmpty)
        #expect(result.ruleSet.categories == [
            .emailAddresses, .phoneNumbers, .socialSecurityNumbers,
            .streetAddresses, .accountNumbers, .datesOfBirth, .personNames,
        ])
    }

    @Test("An unrecognized description warns rather than failing")
    func unknownCategory() {
        let result = parser.parse("shoe sizes")
        #expect(result.ruleSet.isEmpty)
        #expect(result.diagnostics.map(\.kind) == [.unknownCategory("shoe sizes")])
        #expect(result.diagnostics.first?.message.contains("shoe sizes") == true)
    }

    // MARK: - Duplicates

    @Test("A repeated rule is kept once and reported")
    func duplicates() {
        let result = parser.parse("""
        "Nikhil"
        email addresses
        "Nikhil"
        email addresses
        """)
        #expect(result.ruleSet.exactRules.count == 1)
        #expect(result.ruleSet.categories == [.emailAddresses])
        #expect(result.diagnostics.map(\.kind) == [.duplicateRule, .duplicateRule])
        #expect(result.diagnostics.map(\.lineNumber) == [3, 4])
    }

    @Test("Case-sensitive and case-insensitive versions of a literal are distinct rules")
    func caseSensitivityDistinguishesRules() {
        let result = parser.parse("\"ACME\"\n!\"ACME\"")
        #expect(result.ruleSet.exactRules.count == 2)
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - File shape

    @Test("Line numbers are 1-based and survive skipped lines")
    func lineNumbers() {
        let result = parser.parse("""
        # comment

        "Nikhil"

        email addresses
        """)
        #expect(result.ruleSet.exactRules.first?.lineNumber == 3)
        #expect(result.ruleSet.categoryRules.first?.lineNumber == 5)
    }

    @Test("CRLF and CR line endings parse identically to LF", arguments: ["\n", "\r\n", "\r"])
    func lineEndings(_ terminator: String) {
        let result = parser.parse(["\"Nikhil\"", "email addresses"].joined(separator: terminator))
        #expect(result.ruleSet.exactRules.count == 1)
        #expect(result.ruleSet.categories == [.emailAddresses])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("A leading byte-order mark does not break the first rule")
    func byteOrderMark() {
        let result = parser.parse("\u{FEFF}\"Nikhil\"")
        #expect(result.ruleSet.exactRules.map(\.literal) == ["Nikhil"])
    }

    @Test("Unicode literals survive parsing")
    func unicodeLiteral() {
        let result = parser.parse("\"Café Münster 🔒\"")
        #expect(result.ruleSet.exactRules.map(\.literal) == ["Café Münster 🔒"])
    }

    @Test("The spec's example rules file parses cleanly")
    func specExampleFile() {
        let result = parser.parse("""
        # Blackline rules — lines starting with # are comments

        # Exact matches (quoted)
        "Nikhil"
        "Knob LLC"
        "123 Harbor View Drive"
        "4417-XXXX-XXXX-9803"

        # Descriptions (unquoted) — detected automatically
        email addresses
        phone numbers
        social security numbers
        street addresses
        account numbers
        dates of birth
        person names
        """)
        #expect(result.diagnostics.isEmpty)
        #expect(result.ruleSet.exactRules.count == 4)
        #expect(result.ruleSet.categoryRules.count == 7)
        #expect(result.ruleSet.ruleCount == 11)
        #expect(!result.ruleSet.isEmpty)
    }

    @Test("Parsing from a file on disk agrees with parsing a string")
    func parsesFromDisk() throws {
        let contents = "\"Nikhil\"\nemail addresses\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromDisk = try parser.parse(contentsOf: url)
        #expect(fromDisk.ruleSet == parser.parse(contents).ruleSet)
    }

    @Test("Reading a missing file throws")
    func missingFileThrows() {
        let url = URL(fileURLWithPath: "/nonexistent/redact.txt")
        #expect(throws: (any Error).self) { try parser.parse(contentsOf: url) }
    }
}

@Suite("RulesParser file handling")
struct RulesParserFileTests {
    private let parser = RulesParser()

    private func writeTemp(_ contents: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("redact-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    // TextEdit saves Rich Text by default, so a hand-made rules file is often RTF. Every
    // rule line then ends in a backslash and none of them parse — the failure has to name
    // the real cause rather than reporting an empty rule set.
    @Test("A Rich Text file is rejected with an explanation, not silently empty")
    func rejectsRichText() throws {
        let rtf = """
        {\\rtf1\\ansi\\ansicpg1252\\cocoartf2822
        \\f0\\fs24 \\cf0 "Knob LLC"\\
        social security numbers}
        """
        let url = try writeTemp(rtf)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: RulesParser.FileError.self) { try parser.parse(contentsOf: url) }
        do {
            _ = try parser.parse(contentsOf: url)
        } catch let error as RulesParser.FileError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("Rich Text"))
            #expect(message.contains("Make Plain Text"))
            #expect(message.contains("textutil"))
        }
    }

    @Test("A plain-text file that merely mentions rtf is not rejected")
    func doesNotOvermatchRTF() throws {
        let url = try writeTemp("\"{\\rtf1 is not the start of this file}\"\nemail addresses")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try parser.parse(contentsOf: url).ruleSet.ruleCount == 2)
    }

    @Test("A non-UTF-8 rules file is read rather than refused")
    func readsLegacyEncoding() throws {
        let url = try writeTemp("\"Café Münster\"\nemail addresses", encoding: .isoLatin1)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try parser.parse(contentsOf: url)
        #expect(result.ruleSet.ruleCount == 2)
        #expect(result.ruleSet.exactRules.first?.literal == "Café Münster")
    }
}
