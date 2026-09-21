import Foundation

/// Detects IP addresses (spec §5.3).
///
/// An IPv4 address is four dotted octets, each 0–255, and nothing else on a page has that
/// shape — except a four-part version number, which is the boundary worth stating: `1.2.3.4`
/// is matched whether it is a host or a release. IPv6 is matched in its full and its
/// `::`-compressed forms; a bare `::` is not an address, and a time like `12:30:45` has too
/// few groups to qualify.
///
/// A port is left in place. `:4443` beside a black box identifies nothing.
public struct IPAddressMatcher: Matcher {
    public var source: MatchSource { .category(.ipAddresses) }

    private let engines: [RegexMatcher]

    private static let octet = #"(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"#
    private static let hextet = #"[0-9A-Fa-f]{1,4}"#

    public init() {
        engines = [
            RegexMatcher(
                pattern: #"(?<![0-9.])(?:"# + Self.octet + #"\.){3}"# + Self.octet + #"(?![0-9.])"#
            ),
            RegexMatcher(
                pattern: #"(?<![0-9A-Fa-f:])(?:"#
                    + #"(?:"# + Self.hextet + #":){7}"# + Self.hextet                  // full
                    + #"|(?:"# + Self.hextet + #":){1,6}:(?:"# + Self.hextet
                    + #"(?::"# + Self.hextet + #"){0,5})?"#                           // a::b
                    + #"|::"# + Self.hextet + #"(?::"# + Self.hextet + #"){0,6}"#     // ::1
                    + #")(?![0-9A-Fa-f:])"#
            ),
        ]
    }

    public func matches(in text: SourceText) -> [Match] {
        engines.flatMap { $0.matches(in: text, source: source) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
