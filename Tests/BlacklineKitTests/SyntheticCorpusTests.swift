import Foundation
import Testing
@testable import BlacklineKit

/// Runs the first pass — the deterministic matchers, driven by a `redact.txt` — over
/// `Fixtures/synthetic-proprietary-packet.md`, a fictional company's internal packet seeded
/// with one of everything: SSNs, cards, bank details, addresses, phones, emails, tax IDs,
/// dates of birth, PHI, credentials, network topology, employee numbers, and the names of
/// people, products and code-named deals. The values are all inert (900-series SSNs, 555
/// exchanges, industry test PANs) and the file's own Appendix A is the answer key these
/// expectations are drawn from.
///
/// The rules come from `Fixtures/synthetic-proprietary-packet.redact.txt`, the file a user
/// at this company would write: every category, plus quoted rules for what no detector can
/// find — the people, and the names the company gave its secrets. That is the product's
/// answer for those (spec §4), and this suite holds the first pass to it: **with that file,
/// nothing proprietary survives the first pass.**
///
/// The unit suites each prove one matcher on the text it was written for. This suite is the
/// other direction: one document that looks like the ones users actually redact, and two
/// questions about it. Did every detector find what §7 says it must (a miss is the
/// dangerous failure)? And did nothing black out a word, a dollar figure or a form code
/// that identifies nobody (the "it redacted too much" failure, which ruins the page)?
///
/// `withKnownIssue` marks where the answer is currently "no". A known issue that stops
/// reproducing fails the test, so fixing one means deleting its annotation here.
@Suite("Synthetic corpus")
struct SyntheticCorpusTests {
    private static func fixture(_ name: String, _ ext: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
    }

    private static let corpus = SourceText(
        try! String(contentsOf: fixture("synthetic-proprietary-packet", "md"), encoding: .utf8)
    )

    private static let rules = try! RulesParser()
        .parse(contentsOf: fixture("synthetic-proprietary-packet.redact", "txt"))

    private static let output = MatcherFactory().makeMatchers(for: rules.ruleSet)

    private static let matches: [Match] = output.matchers.flatMap { $0.matches(in: corpus) }

    /// The distinct values one category found, single-spaced.
    private func found(_ category: BlacklineKit.Category) -> Set<String> {
        Set(
            Self.matches
                .filter { $0.source == .category(category) }
                .map { SourceText.normalize($0.matchedText) }
        )
    }

    /// The distinct values the quoted rules found.
    private var foundByExactRules: Set<String> {
        Set(
            Self.matches.compactMap { match in
                if case .exact = match.source { return SourceText.normalize(match.matchedText) }
                return nil
            }
        )
    }

    /// Every value anything found, whatever the rule.
    private var everythingFound: Set<String> {
        Set(Self.matches.map { SourceText.normalize($0.matchedText) })
    }

    // MARK: - The rules file

    @Test("The rules file parses without a diagnostic")
    func rulesParse() {
        #expect(Self.rules.diagnostics.isEmpty)
    }

    @Test("Only person names lack a detector, and that is reported, not silently skipped")
    func unsupportedCategoriesAreReported() {
        #expect(Self.output.unsupportedCategories == [.personNames])
    }

    // MARK: - What must be found (Appendix A)

    @Test("Every SSN in the executive compensation table, and nothing else")
    func socialSecurityNumbers() {
        #expect(found(.socialSecurityNumbers) == [
            "900-12-4471", "900-45-8823", "900-78-1105", "900-33-6690", "900-91-2378",
        ])
    }

    @Test("Every date of birth under the DOB column, and no other date on the page")
    func datesOfBirth() {
        #expect(found(.datesOfBirth) == [
            "1974-03-11", "1979-08-27", "1981-11-02", "1985-06-19", "1977-01-30",
        ])
    }

    @Test("Every test PAN on the corporate card program with its expiry and CVV, and nothing else")
    func creditCardNumbers() {
        #expect(found(.creditCardNumbers) == [
            "3714 4963 5398 431", "4111 1111 1111 1111", "5555 5555 5555 4444",
            "04/28", "7291", "11/27", "883", "02/29", "412",
        ])
    }

    @Test("The federal EIN, the state UBI and the German VAT number")
    func taxIdentifiers() {
        #expect(found(.employerIdentificationNumbers) == ["91-1834726", "603-118-227", "DE311894520"])
    }

    @Test("Every bank account: the treasury table, the payroll export, the IBAN and the SWIFT code")
    func accountNumbers() {
        #expect(found(.accountNumbers).isSuperset(of: [
            "125000024", "4471928830155", "4471928830163",                        // §2.3 table
            "DE89 3704 0044 0532 0130 00", "NRDLDEHHXXX",                          // escrow
            "325070760", "8812093347", "8812093902", "325081403", "7710455819",    // §5.3
            "8812094410", "7710456022",
        ]))
    }

    @Test("Every employee and customer email address, and the service account")
    func emailAddresses() {
        #expect(found(.emailAddresses).isSuperset(of: [
            "rafael.mendes@meridianhalcyon.example",
            "aisha.bakr@meridianhalcyon.example",
            "tomasz.nowak@meridianhalcyon.example",
            "dana.whitfield@meridianhalcyon.example",
            "yuki.tanaka@meridianhalcyon.example",
            "ingrid.halvorsen@nordvik.example",
            "c.reyes@pacificrail.example",
            "mhs-telemetry@mhs-prod-418822.iam.gserviceaccount.com",
        ]))
    }

    @Test("Every US and international phone number, and nothing that is not one")
    func phoneNumbers() {
        #expect(found(.phoneNumbers) == [
            "(253) 555-0147", "(206) 555-0193", "(425) 555-0121", "(253) 555-0166",
            "(360) 555-0178", "(415) 555-0102",
            "+47 555 01 234", "+47 555 09 876",
        ])
    }

    @Test("Every home address in the payroll export, ending at the postcode, and nothing else")
    func streetAddresses() {
        #expect(found(.streetAddresses) == [
            "1420 Pacific Ave Apt 7B, Tacoma, WA 98402",
            "88 Harbor View Dr, Gig Harbor, WA 98335",
            "5601 NE 24th St, Bellevue, WA 98004",
            "2210 S Union Ave, Tacoma, WA 98405",
            "917 Cherry St, Olympia, WA 98501",
        ])
    }

    @Test("Every employee number, labelled inline or by its column")
    func employeeIdentifiers() {
        #expect(found(.employeeIdentifiers) == ["E-01192", "E-02331", "E-03874", "E-04471", "E-05108"])
    }

    @Test("Every credential in the security section: keys, tokens, passwords, URL credentials, the PEM block")
    func secrets() {
        let expected: Set<String> = [
            "AKIAIOSFODNN7EXAMPLE",
            "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "f3a9c1d2e8b74a6f9d0c1e2b3a4f5d6e7c8b9a01",
            "sk_test_FAKE51Kx9mQ2vT7b",
            "whsec_9f8e7d6c5b4a39281706f5e4d3c2b1a0f9e8d7c6",
            "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8",
            "xoxb-FAKE-1234567890-AbCdEfGhIjKl",
            "SG.aBcDeFgHiJkLmNoPqRsTuV.wXyZ0123456789abcdefghijklmnopqrstuvwxyzAB",
            "sk-proj-FAKE0000000000000000000000000000000000000000000",
            "sk-ant-api03-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE-AAAAAAAA",
            "0123456789abcdef0123456789abcdef",
            "mhs_app:Tr0ub4dor&3", "telemetry_rw:Sp4rr0w!2026", "root:Passw0rd_ChangeMe", ":R3d1s-Cache-9x",
            "Fw!Edge2024#",
            "9y7Gk1QwZr3Xv5Tn2Lm8Pb4Hd6Fj0Sc1Ae3Ui5Yo7=",
        ]
        let secrets = found(.secrets)
        #expect(secrets.isSuperset(of: expected))
        #expect(secrets.contains { $0.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") && $0.hasSuffix("-----END RSA PRIVATE KEY-----") })
        // Nothing else in §6.1 is a secret: a region, a service-account address.
        #expect(!secrets.contains("us-west-2"))
        #expect(!secrets.contains("mhs-telemetry@mhs-prod-418822.iam.gserviceaccount.com"))
    }

    @Test("Every host on the network topology, and nothing that merely has dots in it")
    func ipAddresses() {
        #expect(found(.ipAddresses) == [
            "203.0.113.10", "10.40.0.1", "10.40.2.17", "10.40.1.5", "10.40.1.9", "10.50.3.30", "10.40.2.44",
        ])
    }

    @Test("Every claim, member and group number, both diagnoses and both ICD codes")
    func healthInformation() {
        #expect(found(.healthInformation) == [
            "GRP-77120", "STD-2026-311", "STD-2026-327",
            "post-surgical recovery (ICD-10 Z48.812)", "Z48.812",
            "major depressive disorder, recurrent (ICD-10 F33.1)", "F33.1",
            "RM-0091-338847-02 (Bakr), RM-0091-341190-01",
        ])
    }

    @Test("The quoted rules find every person, code name and trade-secret designation they name")
    func exactRules() {
        let byRule = foundByExactRules.map { $0.lowercased() }
        for rule in Self.rules.ruleSet.exactRules {
            #expect(byRule.contains(rule.literal.lowercased()), "rule “\(rule.literal)” found nothing")
        }
    }

    // MARK: - What must be left on the page

    // None of these identify a person or unlock anything. Each is the kind of thing a
    // detector reaches for by shape — a long number, a hyphenated code, a capitalised word
    // next to a label — and each, blacked out, would take a table cell or a sentence with it.
    @Test("Figures, dates, codes and prose are never redacted", arguments: [
        "$585,000", "240,000", "$48.7M", "61.3%", "$14.62/share", "€61.5M",     // money and ratios
        "2026-09-18", "2027-06-30", "2026-11-04", "2026-10-22",                   // dates that are not births
        "HR-2026-0088", "INC-2026-0412", "SEC-2291", "MHS-PS-0417", "Z1187442",    // ticket and spec numbers
        "EP3 921 447", "US 11,204,553", "2:26-cv-01187", "BWB/K-2211/2024",       // patents, dockets, contracts
        "0x3A7F", "0.7318f", "MHS_MULTIPATH_REJECT",                               // source code
        "us-west-2", "AWS_DEFAULT_REGION", "5432", "4443",                          // configuration, ports
        "application", "Palo Alto PA-3260", "in", "vault",                          // prose beside a label
        "Operating", "Treasury", "Payroll / AP", "Cascadia First Bank",              // table cells beside numbers
        "145 °C", "38 minutes", "62.5 g", "3A001",                                  // the formulation, the ECCN
    ])
    func leavesNonIdentifyingValues(_ value: String) {
        #expect(!everythingFound.contains(value))
    }
}
