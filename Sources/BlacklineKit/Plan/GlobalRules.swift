import Foundation

/// Free-form guidance that applies to every document, edited through "Fine tune…".
///
/// Prose, and therefore only ever read by the model — a detector cannot act on a sentence.
/// It sits alongside `redact.txt` rather than replacing it, because that file's grammar is
/// what drives the regex detectors: they run without the model, give the same answer twice,
/// and are the floor the read-back verification checks against.
public struct GlobalRules: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The guidance with markdown furniture stripped, ready to put in a prompt. Headings and
    /// bullets are for the person editing the file; the model just needs the sentences.
    public var guidance: String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var line = line.trimmingCharacters(in: .whitespaces)
                while line.hasPrefix("#") { line.removeFirst() }
                for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
                    line.removeFirst(bullet.count)
                }
                if line.hasPrefix("> ") { line.removeFirst(2) }
                return line.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public static func load(from url: URL) -> GlobalRules {
        GlobalRules(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// What a new installation starts with: enough to show the shape without deciding
    /// anything on the user's behalf.
    public static let starter = """
        # Global rules

        Guidance here applies to every document you redact. It is read by the on-device
        model, so write it as sentences rather than patterns — exact strings and categories
        belong in `redact.txt`.

        - Remove anything that identifies a person or a company: names, addresses,
          identification numbers.
        - Leave money alone. Amounts, totals, balances and percentages are not personal
          information, and removing them ruins the document.
        - Leave form titles, line captions and box numbers alone.
        """
}
