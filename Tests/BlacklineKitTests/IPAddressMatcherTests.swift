import Testing
@testable import BlacklineKit

@Suite("IPAddressMatcher")
struct IPAddressMatcherTests {
    private let matcher = IPAddressMatcher()

    @Test("IPv4 addresses, with a port left in place", arguments: [
        ("db-prod-01 at 10.40.2.17", "10.40.2.17"),
        ("https://10.40.0.1:4443", "10.40.0.1"),
        ("203.0.113.10 (public)", "203.0.113.10"),
        ("0.0.0.0", "0.0.0.0"),
    ])
    func ipv4(_ text: String, _ expected: String) {
        #expect(matcher.matches(in: text).map(\.matchedText) == [expected])
    }

    @Test("Not an IPv4 address", arguments: [
        "256.1.1.1", "1.2.3", "1.2.3.4.5", "version 2.4.1", "$14.62", "0.7318f",
    ])
    func notIPv4(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }

    @Test("IPv6 addresses", arguments: [
        "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
        "2001:db8::8a2e:370:7334",
        "fe80::1",
        "::1",
    ])
    func ipv6(_ address: String) {
        #expect(matcher.matches(in: "host \(address) up").map(\.matchedText) == [address])
    }

    @Test("A time or a ratio is not IPv6", arguments: ["12:30:45", "3:2", "::"])
    func notIPv6(_ text: String) {
        #expect(matcher.matches(in: "at \(text) today").isEmpty)
    }

    @Test("Matches are attributed to the ip addresses category")
    func category() {
        #expect(matcher.matches(in: "10.0.0.1").first?.source == .category(.ipAddresses))
    }
}
