import Testing
@testable import BlacklineKit

@Suite("EINMatcher")
struct EINMatcherTests {
    private let matcher = EINMatcher()

    // The identifier that dominates business returns, and the one that went unredacted on
    // a real 1120-S because no detector existed for it.
    @Test("Matches the hyphenated form without needing a label", arguments: [
        "12-3456789", "98-7654321", "45-6789012",
    ])
    func matchesHyphenated(_ ein: String) {
        let found = matcher.matches(in: "Employer identification number: \(ein)")
        #expect(found.count == 1)
        #expect(found.first?.matchedText == ein)
    }

    @Test("Matches every EIN on a page")
    func matchesAll() {
        let text = """
        Employer identification number: 12-3456789 EIN 98-7654321
        B Employer ID number 45-6789012
        """
        #expect(matcher.matches(in: text).count == 3)
    }

    @Test("Matches an unhyphenated EIN next to a label", arguments: [
        "EIN 123456789", "Employer identification number 123456789",
        "Federal tax ID: 123456789", "Taxpayer identification number 123456789",
    ])
    func matchesLabeledUnhyphenated(_ text: String) {
        #expect(matcher.matches(in: text).map(\.matchedText) == ["123456789"])
    }

    // Nine bare digits are indistinguishable from any other identifier; that is the account
    // matcher's territory, and only with context.
    @Test("Ignores nine bare digits with no label")
    func ignoresUnlabeledDigits() {
        #expect(matcher.matches(in: "Reference 123456789 follows").isEmpty)
    }

    @Test("Does not confuse other groupings for an EIN", arguments: [
        "123-45-6789",      // SSN: 3-2-4
        "555-123-4567",     // phone: 3-3-4
        "12-34567",         // too few digits
        "12-34567890",      // too many
    ])
    func ignoresOtherFormats(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }

    @Test("Matches an EIN split across a line break")
    func spansLineBreak() {
        #expect(matcher.matches(in: "EIN 12-\n3456789").first?.matchedText == "12-\n3456789")
    }

    // The category's aliases include "tax ids", and a business has more of those than the
    // federal one.
    @Test("Matches other tax registrations beside their label", arguments: [
        ("WA UBI **603-118-227**", "603-118-227"),
        ("VAT (DE) **DE311894520**", "DE311894520"),
        ("GST number: 12 345 678 901", "12 345 678 901"),
        ("ABN 51 824 753 556", "51 824 753 556"),
    ])
    func matchesOtherTaxIDs(_ text: String, _ expected: String) {
        #expect(matcher.matches(in: text).map(\.matchedText) == [expected])
    }

    @Test("A tax label beside a short figure is not a registration", arguments: [
        "VAT 20%", "sales tax 1,234.56", "tax id pending",
    ])
    func ignoresTaxFigures(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }

    @Test("Attributes matches to the employer identification numbers category")
    func carriesCategory() {
        #expect(matcher.matches(in: "12-3456789").first?.source == .category(.employerIdentificationNumbers))
    }
}

@Suite("Labelled government IDs")
struct GovernmentIDMatcherTests {

    // Neither format is distinctive — passport and licence numbers collectively match almost
    // any short alphanumeric — so both require a label, like account numbers.
    @Test("Passport numbers match only next to a label")
    func passportNeedsLabel() {
        #expect(PassportNumberMatcher().matches(in: "Passport number: X1234567").map(\.matchedText) == ["X1234567"])
        #expect(PassportNumberMatcher().matches(in: "Passport X1234567").map(\.matchedText) == ["X1234567"])
        #expect(PassportNumberMatcher().matches(in: "Reference X1234567").isEmpty)
    }

    @Test("Driver's licence numbers match only next to a label")
    func licenceNeedsLabel() {
        #expect(DriversLicenseMatcher().matches(in: "Driver's license: S12345678").map(\.matchedText) == ["S12345678"])
        #expect(DriversLicenseMatcher().matches(in: "License number S12345678").map(\.matchedText) == ["S12345678"])
        #expect(DriversLicenseMatcher().matches(in: "Serial S12345678").isEmpty)
    }

    // Every issuer puts a digit in the number; without the rule, the word after "license"
    // or "passport" in prose is redacted.
    @Test("A word after the label is not a number", arguments: [
        "BIS license application", "passport renewal", "license agreement",
    ])
    func labelBeforeProse(_ text: String) {
        #expect(DriversLicenseMatcher().matches(in: text).isEmpty)
        #expect(PassportNumberMatcher().matches(in: text).isEmpty)
    }

    @Test("The new categories resolve from their aliases", arguments: [
        ("ein", Category.employerIdentificationNumbers),
        ("EINs", Category.employerIdentificationNumbers),
        ("federal tax id", Category.employerIdentificationNumbers),
        ("passport numbers", Category.passportNumbers),
        ("driver's license numbers", Category.driversLicenseNumbers),
        ("dl number", Category.driversLicenseNumbers),
    ])
    func aliasesResolve(_ alias: String, _ expected: Category) {
        #expect(Category.named(alias) == expected)
    }

    @Test("MatcherFactory builds the new detectors")
    func factoryBuildsThem() {
        let ruleSet = RulesParser().parse("""
        employer identification numbers
        passport numbers
        driver's license numbers
        """).ruleSet
        let output = MatcherFactory().makeMatchers(for: ruleSet)
        #expect(output.matchers.count == 3)
        #expect(output.unsupportedCategories.isEmpty)
    }


}
