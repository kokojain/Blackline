import Foundation

/// The documented vocabulary of category descriptions accepted in `redact.txt` (spec §4).
///
/// Each case carries a set of aliases so users can write the description naturally —
/// `ssn`, `SSNs`, and `social security numbers` all name the same category.
public enum Category: String, CaseIterable, Hashable, Sendable {
    case emailAddresses
    case phoneNumbers
    case socialSecurityNumbers
    case streetAddresses
    case personNames
    case accountNumbers
    case creditCardNumbers
    case datesOfBirth
    case employerIdentificationNumbers
    case passportNumbers
    case driversLicenseNumbers
    case secrets
    case ipAddresses
    case healthInformation
    case employeeIdentifiers

    /// The spelling used when echoing a category back to the user.
    public var canonicalName: String {
        switch self {
        case .emailAddresses: "email addresses"
        case .phoneNumbers: "phone numbers"
        case .socialSecurityNumbers: "social security numbers"
        case .streetAddresses: "street addresses"
        case .personNames: "person names"
        case .accountNumbers: "account numbers"
        case .creditCardNumbers: "credit card numbers"
        case .datesOfBirth: "dates of birth"
        case .employerIdentificationNumbers: "employer identification numbers"
        case .passportNumbers: "passport numbers"
        case .driversLicenseNumbers: "driver's license numbers"
        case .secrets: "secrets"
        case .ipAddresses: "ip addresses"
        case .healthInformation: "health information"
        case .employeeIdentifiers: "employee ids"
        }
    }

    /// Every accepted spelling, including the canonical one. All lowercase, single-spaced.
    public var aliases: [String] {
        switch self {
        case .emailAddresses:
            ["email addresses", "email address", "emails", "email",
             "e-mail addresses", "e-mail address", "e-mails", "e-mail"]
        case .phoneNumbers:
            ["phone numbers", "phone number", "phones", "phone",
             "telephone numbers", "telephone number", "mobile numbers", "mobile number"]
        case .socialSecurityNumbers:
            ["social security numbers", "social security number", "social security",
             "ssn", "ssns", "ssn numbers"]
        case .streetAddresses:
            ["street addresses", "street address", "addresses", "address",
             "mailing addresses", "mailing address", "postal addresses", "postal address",
             "home addresses", "home address"]
        case .personNames:
            ["person names", "person name", "people names", "names", "name",
             "full names", "full name"]
        case .accountNumbers:
            ["account numbers", "account number", "accounts", "account",
             "bank account numbers", "bank account number", "bank accounts",
             "routing numbers", "routing number"]
        case .creditCardNumbers:
            ["credit card numbers", "credit card number", "credit cards", "credit card",
             "card numbers", "card number", "payment card numbers", "payment card number"]
        case .datesOfBirth:
            ["dates of birth", "date of birth", "dob", "dobs",
             "birth dates", "birth date", "birthdates", "birthdate",
             "birthdays", "birthday"]
        case .employerIdentificationNumbers:
            ["employer identification numbers", "employer identification number",
             "employer id numbers", "employer id number", "employer ids",
             "ein", "eins", "federal tax id", "federal tax ids",
             "federal tax identification numbers", "federal tax identification number",
             "tax id numbers", "tax id number", "tax ids", "taxpayer identification numbers",
             "taxpayer identification number", "tins"]
        case .passportNumbers:
            ["passport numbers", "passport number", "passports", "passport"]
        case .driversLicenseNumbers:
            ["driver's license numbers", "driver's license number", "drivers license numbers",
             "drivers license number", "driver licence numbers", "driver licence number",
             "driving licence numbers", "driving licence number",
             "driver's licenses", "drivers licenses", "license numbers", "license number",
             "licence numbers", "licence number", "dl numbers", "dl number"]
        case .secrets:
            ["secrets", "secret", "credentials", "credential", "passwords", "password",
             "api keys", "api key", "access tokens", "access token", "tokens", "token",
             "private keys", "private key", "secret keys", "secret key"]
        case .ipAddresses:
            ["ip addresses", "ip address", "ips", "ip", "ipv4 addresses", "ipv6 addresses",
             "network addresses", "network address"]
        case .healthInformation:
            ["health information", "medical information", "phi",
             "protected health information", "health records", "medical records",
             "medical record numbers", "medical record number", "diagnoses", "diagnosis",
             "member ids", "member id", "claim numbers", "claim number",
             "patient ids", "patient id"]
        case .employeeIdentifiers:
            ["employee ids", "employee id", "employee numbers", "employee number",
             "employee identifiers", "staff ids", "staff id", "staff numbers", "staff number",
             "personnel numbers", "personnel number"]
        }
    }

    private static let lookup: [String: Category] = {
        var table: [String: Category] = [:]
        for category in Category.allCases {
            for alias in category.aliases {
                table[alias] = category
            }
        }
        return table
    }()

    /// Resolves a raw description line to a category, ignoring case and extra whitespace.
    /// Returns `nil` for descriptions outside the documented vocabulary; spec §4 requires
    /// those to warn rather than fail.
    public static func named(_ raw: String) -> Category? {
        lookup[normalizeDescription(raw)]
    }

    static func normalizeDescription(_ raw: String) -> String {
        raw.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
