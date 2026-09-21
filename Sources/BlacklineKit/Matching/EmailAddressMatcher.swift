import Foundation

/// Detects email addresses (spec §5.3).
///
/// The coverage boundary is worth stating plainly, because a deterministic detector is only
/// useful if you can say what it catches: a local part of the characters RFC 5322 permits
/// unquoted, an `@`, and a **dotted** domain ending in two or more letters. That last
/// requirement is what keeps `chen@localhost` and a stray `user@2024` out, at the cost of
/// missing intranet addresses that have no public TLD — a trade made knowing which way it
/// errs, since those do not appear in the documents this app exists for.
///
/// The address must be contiguous. ``SourceText`` folds a wrapped line into a single space,
/// so an address broken across lines *after* the `@` is not matched. Tolerating a space
/// there would let ordinary prose — "write me @ example.com" — read as an address, and the
/// wrap is rare in the forms and statements this sees.
public struct EmailAddressMatcher: Matcher {
    public var source: MatchSource { .category(.emailAddresses) }

    private let engine = RegexMatcher(
        pattern: #"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@"#
            + #"(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}\b"#
    )

    public init() {}

    public func matches(in text: SourceText) -> [Match] {
        engine.matches(in: text, source: source)
    }
}
