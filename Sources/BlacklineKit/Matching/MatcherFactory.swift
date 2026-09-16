import Foundation

/// Turns a parsed ``RuleSet`` into the matchers that enforce it.
public struct MatcherFactory: Sendable {
    public struct Output: Sendable {
        public let matchers: [any Matcher]
        /// Categories the user asked for that have no detector in this build. Spec §7
        /// treats silent under-redaction as the dangerous failure, so callers must surface
        /// these rather than proceed as if the category were covered.
        public let unsupportedCategories: [Category]

        public init(matchers: [any Matcher], unsupportedCategories: [Category]) {
            self.matchers = matchers
            self.unsupportedCategories = unsupportedCategories
        }
    }

    /// Options forwarded to matchers that have them.
    public var includeUnlabeledDigitRuns: Bool

    public init(includeUnlabeledDigitRuns: Bool = false) {
        self.includeUnlabeledDigitRuns = includeUnlabeledDigitRuns
    }

    public func makeMatchers(for ruleSet: RuleSet) -> Output {
        var matchers: [any Matcher] = ruleSet.exactRules.map(ExactTextMatcher.init(rule:))
        var unsupported: [Category] = []

        for category in ruleSet.categories {
            switch category {
            case .socialSecurityNumbers:
                matchers.append(SSNMatcher())
            case .creditCardNumbers:
                matchers.append(CreditCardMatcher())
            case .employerIdentificationNumbers:
                matchers.append(EINMatcher())
            case .passportNumbers:
                matchers.append(PassportNumberMatcher())
            case .driversLicenseNumbers:
                matchers.append(DriversLicenseMatcher())
            case .accountNumbers:
                matchers.append(
                    AccountNumberMatcher(includeUnlabeledDigitRuns: includeUnlabeledDigitRuns)
                )
            // Detectors for these need NSDataDetector and the NaturalLanguage framework
            // (spec §5.3); they arrive with the PDF pipeline slice.
            case .emailAddresses, .phoneNumbers, .streetAddresses, .personNames, .datesOfBirth:
                unsupported.append(category)
            }
        }

        return Output(matchers: matchers, unsupportedCategories: unsupported)
    }
}
