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
    /// Below this, a chunk is not worth splitting further.
    public static let smallestUsefulChunk = 240

    /// Splits at the line break nearest the middle, or failing that a space, so a chunk
    /// boundary does not land inside an identifier.
    ///
    /// Used when a chunk overflows the model's context window: whether one fits cannot be
    /// known in advance, because the window holds the reply as well as the prompt, so the
    /// only workable answer is to react by halving and asking again.
    public static func halve(_ text: String) -> (String, String)? {
        let characters = Array(text)
        guard characters.count > 1 else { return nil }
        let middle = characters.count / 2

        func nearest(matching predicate: (Character) -> Bool) -> Int? {
            for offset in 0 ..< middle {
                if middle - offset > 0, predicate(characters[middle - offset]) { return middle - offset }
                if middle + offset < characters.count, predicate(characters[middle + offset]) { return middle + offset }
            }
            return nil
        }

        let cut = nearest(matching: \.isNewline) ?? nearest(matching: \.isWhitespace) ?? middle
        guard cut > 0, cut < characters.count else { return nil }
        return (String(characters[..<cut]), String(characters[cut...]))
    }

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

/// Rejects spans that are not identifying, whatever a model calls them.
///
/// A tax return is mostly figures, and almost none of them identify anyone. Asked the
/// general question a model will happily report wages, totals and balances as sensitive;
/// blacking those out destroys the document for whoever has to read it and protects nobody.
/// The prompt says so too, but a prompt is a request and this is a guarantee.
public enum ProposalFilter {
    public static func isNotIdentifying(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Money and bare quantities: digits with grouping separators, an optional currency
        // mark and an optional decimal part — "84,320.00", "$1,250", "(2,000)", "12.5%".
        let money = /^[\(\)\$£€\-+ ]*[0-9][0-9,. ]*[\)%]?$/
        if trimmed.wholeMatch(of: money) != nil {
            // An identifier made only of digits and separators is still an identifier, and
            // those run long: a total is rarely nine digits, an account number usually is.
            let digits = trimmed.filter(\.isNumber).count
            let hasDecimals = trimmed.contains(".") || trimmed.contains("%")
            return hasDecimals || digits < 8
        }
        // A published form or schedule identifier. "Form 1041-ND", "SCHEDULE K-1" and
        // "Form 990 (trust)" are the names of IRS forms — printed in the instructions, the
        // same on every copy in the country, and identifying nobody. A 1120S carries a page
        // listing dozens of them, and the model reported the lot as account numbers.
        if trimmed.prefixMatch(of: /(?:forms?|schedules?|sch)\b[ .:#]/.ignoresCase()) != nil {
            // Unless a name came along with it. What makes "Form 1041-ND" furniture is that
            // everything after the word "Form" is a code: `ND`, `K-1`, `(trust)`. A word in
            // title case — "Schedule K-1 for Jane Taxpayer" — is somebody's name, and the
            // span has to stay.
            let named = trimmed.split(whereSeparator: \.isWhitespace).dropFirst().contains {
                let bare = $0.trimmingCharacters(in: .punctuationCharacters)
                guard let first = bare.first, first.isUppercase, bare.count >= 2 else {
                    return false
                }
                return bare.dropFirst().contains(where: \.isLowercase)
            }
            if !named { return true }
        }

        // Form furniture: a box, line or schedule caption. These carry a number, so the
        // money test above does not reach them, and blacking them out takes the caption
        // beside the value with it — on a W-2 that is most of the page.
        // Box and line numbers stop at two digits so a PO box — "Box 1234" — is never read
        // as furniture; form and schedule numbers are allowed four, because they run to
        // 1040 and 8879.
        let caption = /^(?:(?:box|line|part|step|item|column|code|page)[ .:#]*[0-9]{1,2}[a-z]?|(?:form|schedule)[ .:#]*(?:[0-9]{1,4}[a-z]?|[a-k]))$/
            .ignoresCase()
        if trimmed.wholeMatch(of: caption) != nil { return true }

        return false
    }

    /// A proposal's text with the caption that introduces it removed.
    ///
    /// Asked for the personal information on a W-2, the model reports
    /// `Employee SSN: 123-45-6789`, `Contact: payroll@…` and `Employer: Harbor Analytics
    /// LLC` — the value *and* the field label in front of it. Redacting that span blacks out
    /// the caption, and a form whose captions are gone cannot be read, which is the
    /// complaint this exists to answer. The value alone is still a literal substring of the
    /// page, so it locates exactly as before.
    ///
    /// Only a caption is removed: up to four words of letters, no digits, followed by a
    /// colon and a space. A prefix carrying digits is part of the value, not a label.
    public static func valueWithoutLabel(_ text: String) -> String {
        let caption = /^[A-Za-z][A-Za-z&'\-]*(?:[ ][A-Za-z&'\-]+){0,3}:[ \t]+/
        guard let match = text.prefixMatch(of: caption) else { return text }
        let remainder = String(text[match.range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        // A caption with nothing after it was never a caption.
        return remainder.count >= 3 ? remainder : text
    }

    /// Whether a proposal is too slight to be an identifier, whatever the model called it.
    ///
    /// This is the guard that matters most, because of how a proposal is used: it becomes an
    /// ``BlacklineKit/ExactTextMatcher``, which is a **substring** search by §4's design —
    /// `"art"` matches inside `"Smart"`. So a one-character proposal is not a redaction, it
    /// is a request to black out every occurrence of that letter in the document.
    ///
    /// Measured on a 21-page 1120S: the model proposed `a` and `b` as "letters", `12a`
    /// through `13g` as "dates of birth", `16a` through `16f` as "phone numbers", and
    /// `cost`, `year`, `period`, `Date` and `Yes` as "person names". Those 180 plan items
    /// produced **2,632 redactions** and a document with almost nothing left on it.
    ///
    /// Three requirements, each aimed at one of those shapes:
    /// - at least four characters, which removes `a`, `b`, `Yes` and `( )`;
    /// - not a form line label — `12a`, `16f` — which carry a digit and would pass the test
    ///   below;
    /// - a digit, or two real words, or eight characters. An identifier has structure:
    ///   numbers carry digits, names and addresses carry several words. `cost`, `year`,
    ///   `Date` and `S/L -` have none of that.
    ///
    /// The cost is a lone surname — `Chen` with no forename — which this drops. That is a
    /// real loss and the right way to lose: a name you want gone from every document belongs
    /// in `redact.txt` as a quoted rule, where it is deterministic, and the detectors this
    /// filter cannot touch are what the coverage guarantee rests on.
    public static func isTooSlight(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 4 { return true }
        if trimmed.wholeMatch(of: /[0-9]{1,2}[a-z]/.ignoresCase()) != nil { return true }

        let hasDigit = trimmed.contains(where: \.isNumber)
        // "Two words" has to mean two words: `S/L -`, the depreciation method printed on a
        // 4562, carries a space and is no more a name than `cost` is.
        let words = trimmed.split(whereSeparator: \.isWhitespace)
            .filter { $0.count(where: { $0.isLetter || $0.isNumber }) >= 2 }
        return !hasDigit && words.count < 2 && trimmed.count < 8
    }

    /// Whether a proposal is a value the rules already found with nothing but a caption
    /// attached to it.
    ///
    /// The model reports `Routing 021000021` and `Direct deposit account number
    /// 000123456789` where a detector has already reported the number alone. Both spans are
    /// the same finding; the rule's is the tighter one, and redacting the model's blacks out
    /// the caption beside it.
    ///
    /// What it must *not* do is discard a proposal that genuinely covers more of the value.
    /// On a two-column form the text layer interleaves the columns, so the address detector
    /// sees `Boston MA 02210` while the model sees the whole of `88 Harbor St Apt 4B Boston
    /// MA 02210` — there the model is right and the rule is short. So the test is what the
    /// extra text *is*: a caption is words, and anything carrying a digit is part of the
    /// value.
    public static func isRuleHitWithCaption(_ proposal: String, ruleValue: String) -> Bool {
        guard let found = proposal.range(of: ruleValue, options: .caseInsensitive) else {
            return false
        }
        let extra = (proposal[..<found.lowerBound] + proposal[found.upperBound...])
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        if extra.isEmpty { return true }
        if extra.contains(where: \.isNumber) { return false }
        let words = extra.split(whereSeparator: \.isWhitespace)
        return words.count <= 5
    }

    /// Whether a proposal the model called a name cannot be one.
    ///
    /// On a Schedule K-1 the model reported `Interest income`, `Ordinary dividends`,
    /// `Net short-term capital gain (loss) (attach Schedule D)` and a 115-character sentence
    /// as person names. Those are the line-item captions running down the form, and blacking
    /// them out leaves a K-1 nobody can read.
    ///
    /// The signal is capitalization. A name is written `David Auer` or `KNOB LLC`; a caption
    /// is written in sentence case, so some word in it starts lowercase. Particles are
    /// allowed — `van`, `de`, `of` — and so are words starting with a digit, since a name
    /// can be followed by a suffix. A name is also not a sentence, so there is a length
    /// bound.
    ///
    /// Applied only where the model claims a *name*. Nothing here touches a detector, and a
    /// name that really is written in sentence case is better handled by a quoted rule.
    public static func isImplausibleName(_ text: String, kind: String) -> Bool {
        guard kind.lowercased().contains("name") else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 60 { return true }

        let particles: Set<String> = [
            "van", "von", "de", "del", "della", "der", "di", "da", "dos", "du", "la", "le",
            "bin", "binte", "ibn", "al", "el", "mac", "mc", "of", "and", "the", "for",
        ]
        for word in trimmed.split(whereSeparator: \.isWhitespace) {
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            guard let first = bare.first else { continue }
            if first.isUppercase || first.isNumber { continue }
            if particles.contains(bare.lowercased()) { continue }
            return true
        }
        return false
    }

    /// Whether a proposal the model called a number cannot be one.
    ///
    /// An identifier is short. Asked about a table on a return, the model came back with a
    /// whole row — figures, percentages and the company name — and called it an account
    /// number; the box for that span covers the row. Anything this long is a line of the
    /// document, not a value in it.
    public static func isImplausibleIdentifier(_ text: String, kind: String) -> Bool {
        let normalized = kind.lowercased()
        let claimsNumber = ["number", "identifier", " id", "ein", "ssn", "itin", "account"]
        guard claimsNumber.contains(where: { normalized.contains($0) }) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).count > 30
    }

    /// Whether a proposal's own label names something this app removes.
    ///
    /// This is an **allow-list**, and that is the point. A deny-list of labels was tried
    /// first and it loses: over three runs of one 1120S the model returned `letter`,
    /// `string`, `form code`, `Account Type`, `property` (for the depreciation classes on a
    /// 4562 — `5-year property`, `27.5 yrs.`, `Class life`) and `question` (for the vehicle
    /// questionnaire, five sentences of it). Every one had to be added by hand after it had
    /// already ruined a page. The supply of labels a model can invent has no end, so the
    /// unknown label has to fail closed.
    ///
    /// What it costs: a real finding under a label nobody thought of is dropped. Three
    /// things make that the right way round. The deterministic detectors do not pass through
    /// here, so provable coverage is unchanged; the read-back loop still reads the finished
    /// page; and the plan is in front of the user, who can add a line by hand. Whereas a
    /// label admitted by mistake blacks out a table before anyone sees it.
    ///
    /// An empty label falls through to the shape tests rather than being dropped — a model
    /// that left the field blank has told us nothing about the span either way.
    public static func isAllowedKind(_ kind: String) -> Bool {
        let normalized = kind.lowercased()
        guard !normalized.trimmingCharacters(in: .whitespaces).isEmpty else { return true }

        // What Blackline removes, in the words a model tends to use for it.
        let allowed = [
            "name", "address", "social security", "ssn", "itin", "tax id", "taxpayer id",
            "ein", "employer identification", "employer id",
            "account", "routing", "iban", "swift", "sort code", "bank", "institution",
            "brokerage", "card", "policy", "member", "patient", "case number", "claim",
            "date of birth", "dob", "birth", "phone", "fax", "email", "e-mail",
            "passport", "licen", "registration", "vehicle identification", "plate",
            "pin", "password", "passcode", "api key", "access code", "token", "secret",
            "credential", "signature", "wallet", "employee id", "student id",
        ]
        return allowed.contains { normalized.contains($0) }
    }

    /// Whether a proposal's own label puts it outside what was asked for.
    ///
    /// The instructions tell the model never to report money. A proposal that comes back
    /// labelled `money` or `wages` is one the model has itself placed out of scope while
    /// reporting it anyway — the label is evidence about the span that its text alone does
    /// not carry, and acting on it costs nothing a rule would have caught: a value that is
    /// genuinely an identifier is found by a detector or proposed again under an
    /// identifying label.
    ///
    /// Kept narrow on purpose. This filter *removes* redactions, so anything it is unsure
    /// about must stay.
    public static func isExcludedKind(_ kind: String) -> Bool {
        let normalized = kind.lowercased()
        guard !normalized.isEmpty else { return false }
        // Exact spellings: these words appear inside kinds that are the point of the tier —
        // "account number" contains "number" — so they cannot be substring tests.
        let exactly: Set<String> = [
            "number", "string", "letter", "code", "date", "title", "label", "caption",
            "text", "word", "value", "field", "line", "box", "form", "checkbox",
        ]
        if exactly.contains(normalized) { return true }

        let excluded = [
            "money", "amount", "total", "subtotal", "balance", "wage", "salary",
            "compensation", "percentage", "figure", "currency",
            "form title", "form number", "form code", "document title", "line number",
            "box number", "line item", "account type",
        ]
        return excluded.contains { normalized.contains($0) }
    }
}
