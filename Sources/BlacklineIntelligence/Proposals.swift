import Foundation
import BlacklineKit

/// A span some detector believes is personal information, identified by its *text*.
///
/// Proposals carry no positions. That is deliberate: a component that guesses at offsets
/// can black out the wrong part of a page, so anything proposing redactions states what it
/// found and lets ``ProposalLocator`` decide where — or whether — it occurs.
public struct Proposal: Hashable, Sendable {
    /// The text as the proposer copied it. Only meaningful once located on the page.
    public let text: String
    /// The proposer's own label for what this is.
    public let kind: String
    /// Why it was considered identifying.
    public let reason: String

    public init(text: String, kind: String, reason: String) {
        self.text = text
        self.kind = kind
        self.reason = reason
    }
}

/// A proposal that was found on the page, with the spans it resolved to.
public struct LocatedProposal: Sendable {
    public let proposal: Proposal
    public let matches: [Match]

    public init(proposal: Proposal, matches: [Match]) {
        self.proposal = proposal
        self.matches = matches
    }
}

/// Resolves proposals to spans on a page, discarding any that do not occur there.
///
/// This is the containment boundary for anything non-deterministic. A proposal only becomes
/// a redaction if its text genuinely appears in the document, which means a model that
/// paraphrases, mis-copies, or invents a span cannot cause a black box to land at a guessed
/// position — the worst it can do is propose something that gets dropped.
public struct ProposalLocator: Sendable {
    public init() {}

    /// Returns what was located and what was not. The second list is worth surfacing: it
    /// is a proposer's error rate made visible.
    public func locate(
        _ proposals: [Proposal],
        in page: SourceText
    ) -> (located: [LocatedProposal], unlocated: [Proposal]) {
        var located: [LocatedProposal] = []
        var unlocated: [Proposal] = []

        for proposal in proposals {
            // Reusing the exact matcher means a proposal still resolves against text that
            // wrapped or hyphenated across a line break, which is how PDFs actually render.
            let found = ExactTextMatcher(literal: proposal.text).matches(in: page)
            if found.isEmpty {
                unlocated.append(proposal)
            } else {
                located.append(LocatedProposal(proposal: proposal, matches: found))
            }
        }
        return (located, unlocated)
    }
}

/// Splits page text into pieces small enough for a model to take in one pass.
public enum TextChunker {
    /// Splits on line boundaries, never mid-line: cutting a line in half could sever an
    /// identifier so that neither piece is recognizable in either chunk.
    public static func chunks(of text: String, maxLength: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.count > maxLength else { return [text] }

        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + line.count + 1 > maxLength {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? String(line) : "\n" + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// Rejects the two things a checker reliably gets wrong when inspecting a page that has
/// already been redacted.
///
/// Asked what is still visible, a model reports the field labels sitting beside the black
/// boxes — "Name:", "Account number:" — and the fragments of half-covered words that OCR
/// returns as garbage. Acting on either blacks out more of the page each pass until nothing
/// is left. Neither is information that survived redaction.
///
/// The filter stays deliberately loose. A phrase like "Employer ID n" — a label a black box
/// cut through — still passes, and the result is a label getting covered as well. Tightening
/// the rule to catch it means rejecting anything ending in a one- or two-letter word, which
/// also rejects "Jane Q": a real name the checker is right about. Spec §7 makes that trade
/// one-sided, so the filter errs toward covering too much.
public enum ResidueFilter {
    public static func looksLikeAValue(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        // A label announces a field; the value begins after it.
        guard !trimmed.hasSuffix(":") else { return false }
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return false }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        let hasDigits = trimmed.contains(where: \.isNumber)
        // A single short run of letters is almost always a word clipped by a black box.
        if words.count == 1, !hasDigits, trimmed.count < 6 { return false }
        return true
    }
}
