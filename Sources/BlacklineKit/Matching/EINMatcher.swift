import Foundation

/// Detects US Employer Identification Numbers (spec §5.3).
///
/// An EIN is nine digits written `NN-NNNNNNN`. That split is distinctive enough to match on
/// its own — phone numbers group 3-3-4, SSNs 3-2-4 — so the hyphenated form needs no
/// context. Written without the hyphen it is indistinguishable from any other nine-digit
/// number, so that form is matched only next to a label.
///
/// This is the identifier that dominates business returns: an 1120-S carries the
/// corporation's EIN on page one and often again on every K-1.
public struct EINMatcher: Matcher {
    public var source: MatchSource { .category(.employerIdentificationNumbers) }

    private let engines: [RegexMatcher]

    private static let labelPattern =
        #"(?:ein|e\.i\.n\.|employer\s+id(?:entification)?|federal\s+tax\s+id(?:entification)?"#
        + #"|taxpayer\s+id(?:entification)?|tax\s+id(?:entification)?)"#

    public init() {
        var engines: [RegexMatcher] = []

        // The hyphenated form stands alone.
        engines.append(RegexMatcher(pattern: #"(?<![0-9-])[0-9]{2}-[0-9]{7}(?![0-9-])"#))

        // Unhyphenated, and therefore only trustworthy beside a label.
        engines.append(
            RegexMatcher(
                pattern: #"\b"# + Self.labelPattern
                    + #"\b[^0-9]{0,25}?([0-9]{9})(?![0-9-])"#,
                options: [.caseInsensitive],
                captureGroup: 1
            )
        )

        self.engines = engines
    }

    public func matches(in text: SourceText) -> [Match] {
        var seen: Set<Range<String.Index>> = []
        var results: [Match] = []
        for engine in engines {
            for match in engine.matches(in: text, source: source) where seen.insert(match.range).inserted {
                results.append(match)
            }
        }
        return results.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

/// Detects passport numbers (spec §5.3).
///
/// Passport numbers have no globally consistent format — six to nine alphanumerics covers
/// most issuers but also covers a great many ordinary strings. Matching therefore requires a
/// label, on the same reasoning as ``AccountNumberMatcher``: shape is not evidence.
public struct PassportNumberMatcher: Matcher {
    public var source: MatchSource { .category(.passportNumbers) }

    private let engine = RegexMatcher(
        pattern: #"\bpassports?\s*(?:number|no\.?|#)?\s*[:.\-]?\s*([A-Z0-9]{6,9})\b"#,
        options: [.caseInsensitive],
        captureGroup: 1
    )

    public init() {}

    public func matches(in text: SourceText) -> [Match] {
        engine.matches(in: text, source: source)
    }
}

/// Detects driver's licence numbers (spec §5.3).
///
/// Formats are state-specific and collectively match almost anything, so like passports this
/// requires a label rather than guessing from shape.
public struct DriversLicenseMatcher: Matcher {
    public var source: MatchSource { .category(.driversLicenseNumbers) }

    private let engine = RegexMatcher(
        pattern: #"\b(?:driver'?s?\s+licen[sc]e|driving\s+licen[sc]e|licen[sc]e|dl)\s*"#
            + #"(?:number|no\.?|#)?\s*[:.\-]?\s*([A-Z0-9]{5,20})\b"#,
        options: [.caseInsensitive],
        captureGroup: 1
    )

    public init() {}

    public func matches(in text: SourceText) -> [Match] {
        engine.matches(in: text, source: source)
    }
}
