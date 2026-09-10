import Foundation

/// Detects US Social Security numbers (spec §5.3).
///
/// Matches the separated forms `123-45-6789` and `123 45 6789`, requiring the *same*
/// separator in both positions so an unrelated pair of numbers does not read as an SSN.
///
/// Two deliberate choices:
/// - No issuance-validity filtering (excluded area numbers `000`/`666`/`9xx`, group `00`,
///   serial `0000`). Spec §7 makes false negatives the dangerous failure, and a mistyped
///   SSN on a form is still an SSN that should not be published.
/// - A bare nine-digit run is *not* matched here — it is indistinguishable from any other
///   nine-digit identifier. ``AccountNumberMatcher`` covers long digit runs when the
///   surrounding context qualifies them.
public struct SSNMatcher: Matcher {
    public var source: MatchSource { .category(.socialSecurityNumbers) }

    private let engine = RegexMatcher(
        pattern: #"(?<![0-9-])[0-9]{3}([- ])[0-9]{2}\1[0-9]{4}(?![0-9-])"#
    )

    public init() {}

    public func matches(in text: SourceText) -> [Match] {
        engine.matches(in: text, source: source)
    }
}
