import Testing
@testable import BlacklineKit

@Suite("StreetAddressMatcher")
struct StreetAddressMatcherTests {
    private let matcher = StreetAddressMatcher()

    @Test("Matches a full postal address, postcode included")
    func matchesFullAddress() {
        let found = matcher.matches(in: "Home: 1600 Amphitheatre Parkway, Mountain View, CA 94043.")
        #expect(found.map(\.matchedText) == ["1600 Amphitheatre Parkway, Mountain View, CA 94043"])
    }

    @Test("Matches a unit number and a PO box", arguments: [
        "88 Harbor St Apt 4B, Boston MA 02210",
        "PO Box 1234, Austin TX 78701",
    ])
    func matchesUnitsAndBoxes(_ address: String) {
        #expect(matcher.matches(in: "Mail to \(address) before Friday")
            .map(\.matchedText) == [address])
    }

    // NSDataDetector will call a bare city and state an address. Blacking that out redacts
    // nothing about a person and makes the page harder to read.
    @Test("Leaves a place name with no street or postcode alone", arguments: [
        "Filed in California this year.", "Springfield, IL", "New York, New York",
    ])
    func ignoresBarePlaceNames(_ candidate: String) {
        #expect(matcher.matches(in: candidate).isEmpty)
    }

    @Test("Matches an address set over three lines, as forms print it")
    func spansLines() {
        let text = SourceText("""
        Employee
        88 Harbor St Apt 4B
        Boston MA 02210
        Wages 52,300.00
        """)
        let found = matcher.matches(in: text)
        #expect(found.count == 1)
        #expect(found.first?.matchedText == "88 Harbor St Apt 4B\nBoston MA 02210")
    }

    @Test("The name above an address is not swept into the span")
    func excludesTheName() {
        let found = matcher.matches(in: "Sarah Chen, 88 Harbor St Apt 4B, Boston MA 02210")
        #expect(found.first?.matchedText.hasPrefix("88") == true)
    }

    // Without commas the detector reads one word past the postcode and calls the next
    // field's label the city.
    @Test("Stops at the postcode rather than taking the next field with it")
    func stopsAtThePostcode() {
        let found = matcher.matches(in: "88 Harbor St Apt 4B Boston MA 02210-1234 Wages 52,300.00")
        #expect(found.map(\.matchedText) == ["88 Harbor St Apt 4B Boston MA 02210-1234"])
    }

    @Test("Keeps a country that follows the postcode")
    func keepsTrailingCountry() {
        let found = matcher.matches(in: "Musterstrasse 12, 10115 Berlin, Germany")
        #expect(found.map(\.matchedText) == ["Musterstrasse 12, 10115 Berlin, Germany"])
    }

    // NSDataDetector read a firewall model as a city, a state and a postcode.
    @Test("A US state needs a five-digit ZIP", arguments: [
        "fw-edge-01 | Palo Alto PA-3260 | admin", "Model: Boston MA 220",
    ])
    func rejectsImplausibleUSPostcode(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }

    @Test("A ZIP+4 is still a ZIP")
    func acceptsZIPPlus4() {
        #expect(matcher.matches(in: "88 Harbor St, Boston MA 02210-1234").count == 1)
    }

    @Test("Matches are attributed to the street addresses category")
    func attribution() {
        #expect(matcher.matches(in: "PO Box 1234, Austin TX 78701").first?.source
            == .category(.streetAddresses))
    }
}
