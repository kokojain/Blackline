import Foundation

/// Detects postal addresses (spec §5.3).
///
/// This is the one category where `NSDataDetector` is straightforwardly the right tool: an
/// address has no shape a regex can state, and the system detector already knows the street
/// suffixes, the unit designators, the state abbreviations and the postcode formats.
///
/// Three adjustments:
/// - A result must carry a **street or a postcode**. Left alone the detector will report a
///   bare `New York NY` as an address, and blacking out a city name on a form redacts
///   nothing about a person while making the page harder to read.
/// - The whole detected span is redacted, city, state and postcode included, rather than the
///   street component alone. `redact.txt` says "street addresses" because that is how people
///   write it; what they mean is where they live, and a redaction that leaves the postcode
///   visible has narrowed the search to a few thousand households rather than protected one.
/// - The span **ends at the postcode**, unless a country follows it. See
///   ``endingAtPostcode(_:components:)``.
/// - A US state needs a **five-digit ZIP**. The detector read `Palo Alto PA-3260` — a
///   firewall model — as a city, a state and the postcode `3260`, and a product name is
///   the kind of thing that sits in a table where blacking it out takes the row's meaning.
///
/// The detector runs on ``SourceText/normalized``, so an address set over three lines — the
/// usual layout on a form — is seen as a single string.
public struct StreetAddressMatcher: Matcher {
    public var source: MatchSource { .category(.streetAddresses) }

    private let engine = DataDetectorMatcher(types: .address) { result, span in
        let components = result.addressComponents ?? [:]
        guard components[.street] != nil || components[.zip] != nil else { return nil }
        guard StreetAddressMatcher.hasPlausiblePostcode(components) else { return nil }
        return StreetAddressMatcher.endingAtPostcode(span, components: components)
    }

    public init() {}

    public func matches(in text: SourceText) -> [Match] {
        engine.matches(in: text, source: source)
    }

    private static let usStates: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN",
        "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV",
        "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN",
        "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "DC", "PR", "VI", "GU", "AS", "MP",
    ]

    /// A postcode under a US state is five digits, optionally with a four-digit suffix.
    /// Anything else the detector called a ZIP there is a model number or a figure. An
    /// address with no state, or a non-US one, is taken as the detector reports it.
    static func hasPlausiblePostcode(_ components: [NSTextCheckingKey: String]) -> Bool {
        guard let state = components[.state], usStates.contains(state.uppercased()),
              let postcode = components[.zip]
        else { return true }
        let digits = postcode.split(separator: "-")
        return (digits.count == 1 || digits.count == 2)
            && digits[0].count == 5 && digits[0].allSatisfy(\.isNumber)
            && (digits.count == 1 || (digits[1].count == 4 && digits[1].allSatisfy(\.isNumber)))
    }

    /// Cuts the span at the end of the postcode, keeping a country that follows it.
    ///
    /// An address printed on a form has no commas — the line breaks were the punctuation,
    /// and ``SourceText`` has turned them into spaces. Without them the detector reads one
    /// word too far and hands back `88 Harbor St Apt 4B Boston MA 02210 Wages`, calling
    /// "Wages" the city. Blacking out the label of the next field is the damage commit
    /// "Redact what the rules ask for" is about, and a postcode is the end of an address
    /// everywhere it is written last.
    ///
    /// The cost is the formats that print the postcode *before* the town — a German address
    /// with no country line keeps `Berlin` visible. That is the right way round to be wrong
    /// here: the street and postcode are gone, and a city on its own identifies a few
    /// hundred thousand people.
    static func endingAtPostcode(
        _ span: Substring,
        components: [NSTextCheckingKey: String]
    ) -> Substring {
        guard let postcode = components[.zip],
              let postcodeRange = span.range(of: postcode, options: .backwards)
        else { return span }

        var end = postcodeRange.upperBound
        if let country = components[.country],
           let countryRange = span.range(of: country, options: .backwards),
           countryRange.lowerBound >= postcodeRange.upperBound {
            end = countryRange.upperBound
        }
        return span[span.startIndex ..< end]
    }
}
