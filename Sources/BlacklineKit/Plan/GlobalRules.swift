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

    /// How much of this file can go into a prompt, in characters.
    ///
    /// The on-device model's context window holds the instructions, the guidance, the page
    /// text *and* the reply — 4,096 tokens for all four. Measured: a 24 KB policy document
    /// pasted in here produces a 5,508-token prompt, and every page of every document fails
    /// with `exceededContextWindowSize`. `ModelProposer` halves the *page* on that error,
    /// which cannot help when the guidance is what overflowed, so the run degrades to the
    /// detectors alone — silently, which is the failure spec §7 is about.
    ///
    /// 3,000 characters is roughly 800 tokens, leaving the instructions (~400), a page chunk
    /// (~350) and the 1,200-token reply comfortable room. A standing instruction longer than
    /// this is a policy document; keep it beside `globalrules.md` and put the operative part
    /// — what to find, what to leave alone — in the file itself.
    public static let promptBudget = 3_000

    /// The guidance with markdown furniture stripped, ready to put in a prompt. Headings and
    /// bullets are for the person editing the file; the model just needs the sentences.
    ///
    /// Trimmed to ``promptBudget`` at a line boundary. A caller that trims must say so —
    /// see ``omittedCharacterCount``.
    public var guidance: String {
        let whole = strippedGuidance
        guard whole.count > Self.promptBudget else { return whole }

        var kept: [Substring] = []
        var used = 0
        for line in whole.split(separator: "\n", omittingEmptySubsequences: false) {
            guard used + line.count + 1 <= Self.promptBudget else { break }
            kept.append(line)
            used += line.count + 1
        }
        return kept.joined(separator: "\n")
    }

    /// How much of the file did not fit in the prompt. Zero when all of it did.
    ///
    /// Whoever puts guidance in a prompt has to report this: guidance that was not sent did
    /// not apply, and a run that implies it followed rules it never saw is exactly the
    /// silent under-redaction spec §7 warns about.
    public var omittedCharacterCount: Int {
        max(0, strippedGuidance.count - guidance.count)
    }

    /// All of it, furniture stripped and nothing dropped.
    public var strippedGuidance: String {
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
