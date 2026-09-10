import Foundation

/// Detects payment card numbers (spec §5.3).
///
/// Candidates are 13–19 digits with optional single space or hyphen separators, gated on
/// the Luhn checksum. Every real card number satisfies Luhn, so the check removes almost
/// all false positives without risking a false negative on a genuine card.
///
/// Note that a *masked* number such as `4417-XXXX-XXXX-9803` deliberately does not match —
/// it has only eight digits. Spec §4 files that example under quoted exact rules, which is
/// where a masked number belongs.
public struct CreditCardMatcher: Matcher {
    public var source: MatchSource { .category(.creditCardNumbers) }

    /// When `false`, any 13–19 digit run matches. Off-label; the checksum is what makes
    /// this matcher safe to run unattended.
    public let requiresLuhn: Bool

    private let engine: RegexMatcher

    public init(requiresLuhn: Bool = true) {
        self.requiresLuhn = requiresLuhn
        var validator: (@Sendable (String, RegexMatcher.Context) -> Bool)?
        if requiresLuhn {
            validator = { candidate, _ in CreditCardMatcher.passesLuhn(candidate) }
        }
        self.engine = RegexMatcher(
            pattern: #"(?<![0-9-])[0-9](?:[ -]?[0-9]){12,18}(?![0-9-])"#,
            validate: validator
        )
    }

    public func matches(in text: SourceText) -> [Match] {
        engine.matches(in: text, source: source)
    }

    /// The Luhn (mod 10) checksum, ignoring any separators in `candidate`.
    public static func passesLuhn(_ candidate: String) -> Bool {
        var sum = 0
        var double = false
        var digitCount = 0
        for character in candidate.reversed() {
            guard let digit = character.wholeNumberValue, character.isNumber else { continue }
            digitCount += 1
            var value = digit
            if double {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            double.toggle()
        }
        guard digitCount > 0 else { return false }
        return sum % 10 == 0
    }
}
