import Foundation

/// Text extracted from a page, together with a normalized form used for matching and a
/// map back to positions in the original.
///
/// Spec §5.3 requires literal matches to span "line breaks and hyphenation". Rather than
/// teach every matcher about line wrapping, the text is normalized once here and every
/// matcher searches the normalized form; the ranges they report are translated back to the
/// original text, which is what the redaction stage needs to black out.
///
/// Normalization:
/// - A leading byte-order mark is dropped.
/// - Runs of whitespace (including newlines) collapse to a single space; leading and
///   trailing whitespace is dropped entirely.
/// - A hyphen at the end of a line is dropped *only when flanked by letters*, so
///   `"Har-\nbor"` becomes `"Harbor"` while `"123-45-\n6789"` becomes `"123-45-6789"`.
///   Eliding the hyphen unconditionally would silently break identifier detection across
///   a line break — exactly the false negative spec §7 calls the dangerous failure.
public struct SourceText: Sendable {
    /// The text as extracted, unmodified. All reported match ranges index into this.
    public let original: String
    /// The form matchers search.
    public let normalized: String

    /// For each character of `normalized`, where its source span begins in `original`.
    private let starts: [String.Index]
    /// For each character of `normalized`, where its source span ends in `original`.
    private let ends: [String.Index]

    public init(_ original: String) {
        self.original = original

        let characters = Array(original)
        let indices = Array(original.indices)
        let count = characters.count

        var normalizedCharacters: [Character] = []
        var starts: [String.Index] = []
        var ends: [String.Index] = []
        normalizedCharacters.reserveCapacity(count)
        starts.reserveCapacity(count)
        ends.reserveCapacity(count)

        /// Where a run of whitespace begins and ends, waiting to be emitted as one space.
        var pendingWhitespace: (start: Int, end: Int)?

        func index(_ offset: Int) -> String.Index {
            offset < count ? indices[offset] : original.endIndex
        }

        /// Emits the pending whitespace run as a single space. Skipped when nothing has
        /// been emitted yet, which drops leading whitespace.
        func flushWhitespace() {
            if let pending = pendingWhitespace, !normalizedCharacters.isEmpty {
                normalizedCharacters.append(" ")
                starts.append(index(pending.start))
                ends.append(index(pending.end))
            }
            pendingWhitespace = nil
        }

        func emit(_ character: Character, at offset: Int) {
            flushWhitespace()
            normalizedCharacters.append(character)
            starts.append(index(offset))
            ends.append(index(offset + 1))
        }

        var offset = 0
        if offset < count, characters[offset] == "\u{FEFF}" { offset += 1 }

        while offset < count {
            let character = characters[offset]

            if character.isWhitespace {
                let start = offset
                while offset < count, characters[offset].isWhitespace { offset += 1 }
                // Merge with any run already pending (possible after an elided hyphen).
                pendingWhitespace = (pendingWhitespace?.start ?? start, offset)
                continue
            }

            if character == "-" {
                // Look past any whitespace that follows to see whether this hyphen sits at
                // the end of a wrapped line.
                var next = offset + 1
                var crossesLine = false
                while next < count, characters[next].isWhitespace {
                    if characters[next].isNewline { crossesLine = true }
                    next += 1
                }
                if crossesLine, next < count {
                    // Hyphenation requires the hyphen to sit directly against the word;
                    // "abc -\ndef" is a dash, not a wrapped word.
                    let previousIsLetter = pendingWhitespace == nil
                        && (normalizedCharacters.last?.isLetter ?? false)
                    let nextIsLetter = characters[next].isLetter
                    if previousIsLetter, nextIsLetter {
                        // Word hyphenation: drop the hyphen and the line break.
                    } else {
                        // Not hyphenation — keep the hyphen, but still close the line break
                        // so identifiers split across lines stay contiguous.
                        emit("-", at: offset)
                    }
                    offset = next
                    pendingWhitespace = nil
                    continue
                }
            }

            emit(character, at: offset)
            offset += 1
        }

        self.normalized = String(normalizedCharacters)
        self.starts = starts
        self.ends = ends
    }

    /// The number of characters in `normalized`.
    var normalizedCount: Int { starts.count }

    /// Translates a range in `normalized` back to the span it came from in `original`.
    ///
    /// The result is contiguous, so characters dropped during normalization that fall
    /// *inside* the span — a wrapped line's newline, a hyphenation hyphen — are included,
    /// which is what a redaction needs to cover.
    public func originalRange(forNormalized range: Range<String.Index>) -> Range<String.Index>? {
        let lower = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
        let upper = normalized.distance(from: normalized.startIndex, to: range.upperBound)
        return originalRange(fromOffset: lower, toOffset: upper)
    }

    /// Translates a character-offset range in `normalized` back to `original`.
    public func originalRange(fromOffset lower: Int, toOffset upper: Int) -> Range<String.Index>? {
        guard lower >= 0, upper <= starts.count, lower < upper else { return nil }
        return starts[lower] ..< ends[upper - 1]
    }

    /// The character-offset range of a range within `original`, for tests and reporting.
    public func offsets(of range: Range<String.Index>) -> Range<Int> {
        original.distance(from: original.startIndex, to: range.lowerBound)
            ..< original.distance(from: original.startIndex, to: range.upperBound)
    }

    /// Applies the same normalization to a search needle so that a rule written with
    /// single spaces matches text that wrapped or double-spaced.
    public static func normalize(_ text: String) -> String {
        SourceText(text).normalized
    }
}
