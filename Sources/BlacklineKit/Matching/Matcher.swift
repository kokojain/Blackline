import Foundation

/// Finds spans of text that a rule requires be redacted.
///
/// Matchers operate on ``SourceText`` rather than a bare `String` so they inherit
/// wrap- and hyphenation-tolerance, and so the ranges they return point into the original
/// page text.
public protocol Matcher: Sendable {
    /// The rule this matcher enforces, attached to every match it produces.
    var source: MatchSource { get }

    /// Every span in `text` that this matcher requires be redacted, in document order.
    func matches(in text: SourceText) -> [Match]
}

extension Matcher {
    /// Convenience for callers that have a plain string in hand.
    public func matches(in text: String) -> [Match] {
        matches(in: SourceText(text))
    }
}
