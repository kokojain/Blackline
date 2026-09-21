import Foundation

/// The plan for one document: what was found in it, and what a run should remove.
///
/// Written as `<document>.md` beside the source so it can be edited by hand between runs,
/// and read back as the single source of truth for the next Go. Detectors and the model
/// produce the first draft; after that the file decides, so an item the user unticks stays
/// in the document however confidently it was found.
///
/// **It lists the values in the clear.** That is what makes it editable, and it means the
/// file is a plaintext index of exactly what the document is being scrubbed of, sitting in
/// the folder it will be shared from. Anything presenting this file has to say so, and
/// deleting it must be easy.
public struct DocumentPlan: Equatable, Sendable {

    public struct Item: Equatable, Hashable, Sendable {
        /// Ticked items are removed; unticked ones are deliberately left in place.
        public var isSelected: Bool
        /// The text to remove.
        ///
        /// Held as a single line, normalized the way ``SourceText`` normalizes page text.
        /// A postal address matches across the line break the form printed it on, so the
        /// raw matched text arrives here carrying a newline — written straight out it ends
        /// the item's markdown line halfway through, and the plan loses both that value and
        /// the remainder of the line. Normalizing is also what keeps the value *usable*:
        /// ``ExactTextMatcher`` normalizes its needle identically, so the single-line form
        /// still finds the wrapped original on the page.
        public var value: String
        /// What found it, or what it is — free text, for the reader's benefit only.
        public var label: String
        /// 1-based, or `nil` for an item the user added by hand.
        public var page: Int?

        public init(isSelected: Bool = true, value: String, label: String = "", page: Int? = nil) {
            self.isSelected = isSelected
            self.value = SourceText.normalize(value)
            self.label = label.split(whereSeparator: \.isNewline).joined(separator: " ")
            self.page = page
        }
    }

    public var sourceName: String
    public var items: [Item]

    public init(sourceName: String, items: [Item]) {
        self.sourceName = sourceName
        self.items = items
    }

    /// The shortest a ticked value may be and still be used.
    ///
    /// A plan value becomes an ``ExactTextMatcher``, which is a substring search by §4's
    /// design, so a one- or two-character value asks for every occurrence of those
    /// characters in the document rather than for an identifier. Nothing that short is an
    /// identifier, and a plan can pick one up from a model proposal or a slip of the
    /// keyboard.
    public static let minimumValueLength = 3

    /// What a Go should remove.
    public var selectedValues: [String] {
        tickedValues.usable
    }

    /// Ticked values that will not be used, because nothing that short can be an identifier.
    /// A caller that drops them has to say so.
    public var refusedValues: [String] {
        tickedValues.refused
    }

    private var tickedValues: (usable: [String], refused: [String]) {
        var seen: Set<String> = []
        var usable: [String] = []
        var refused: [String] = []
        for value in items.filter(\.isSelected).map(\.value) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(value).inserted else { continue }
            if trimmed.count >= Self.minimumValueLength,
               trimmed.contains(where: { $0.isLetter || $0.isNumber }) {
                usable.append(value)
            } else {
                refused.append(value)
            }
        }
        return (usable, refused)
    }

    public var isEmpty: Bool { selectedValues.isEmpty }

    /// `statement.pdf` → `statement.md`, beside it.
    public static func url(for source: URL) -> URL {
        source.deletingPathExtension().appendingPathExtension("md")
    }

    // MARK: - Writing

    public func markdown(globalRulesPath: String?) -> String {
        let ticked = items.count(where: \.isSelected)
        var out = """
        # Redaction plan — \(sourceName)

        **\(ticked) of \(items.count) line\(items.count == 1 ? "" : "s") \
        \(ticked == 1 ? "is" : "are") ticked.** Blackline removes the ticked values and \
        nothing else on the page.

        - `- [x]` remove this value  ·  `- [ ]` leave it in the document
        - Add a line of your own in the same shape to remove something not listed.
        - Save the file, then press **Go**.

        > **This file lists the values in full, so it is as sensitive as the document
        > itself.** Delete it when you are done — the review window has a button for it.

        """

        if let globalRulesPath {
            out += "\nGlobal rules in force: `\(globalRulesPath)`\n"
        }

        let grouped = Dictionary(grouping: items) { $0.page }
        for page in grouped.keys.sorted(by: { ($0 ?? .max) < ($1 ?? .max) }) {
            let heading = page.map { "## Page \($0)" } ?? "## Added by hand"
            out += "\n\(heading)\n\n"
            for item in grouped[page] ?? [] {
                let tick = item.isSelected ? "x" : " "
                let label = item.label.isEmpty ? "" : " — \(item.label)"
                out += "- [\(tick)] `\(item.value)`\(label)\n"
            }
        }

        if items.isEmpty {
            out += "\nNothing was found in this document. Add lines above to remove text anyway.\n"
        }
        return out
    }

    @discardableResult
    public func write(for source: URL, globalRulesPath: String? = nil) throws -> URL {
        let url = Self.url(for: source)
        try markdown(globalRulesPath: globalRulesPath).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Reading

    /// Reads a plan a person may have edited.
    ///
    /// Deliberately forgiving: anything that is not an item line is ignored, so notes,
    /// headings and prose the user adds survive being read even though they are dropped the
    /// next time the file is regenerated.
    public static func parse(_ text: String, sourceName: String) -> DocumentPlan {
        var items: [Item] = []
        var page: Int?

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("## ") {
                let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                page = heading.hasPrefix("Page ") ? Int(heading.dropFirst(5)) : nil
                continue
            }

            guard let item = parseItem(line, page: page) else { continue }
            items.append(item)
        }

        return DocumentPlan(sourceName: sourceName, items: items)
    }

    static func parseItem(_ line: String, page: Int?) -> Item? {
        // `- [x] `value` — label`, with the tick either way and the label optional.
        let markers = ["- [x] ", "- [X] ", "- [ ] ", "* [x] ", "* [X] ", "* [ ] "]
        guard let marker = markers.first(where: { line.hasPrefix($0) }) else { return nil }
        let selected = marker.lowercased().contains("[x]")

        let rest = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }

        // Backticks delimit the value, so it may contain spaces, dashes and quotes. Taking
        // the first and last lets a value contain a backtick without an escape syntax.
        guard let open = rest.firstIndex(of: "`"), open == rest.startIndex,
              let close = rest.lastIndex(of: "`"), close > open
        else {
            // No backticks: treat the whole line as the value, minus a trailing "— label".
            let (value, label) = splitLabel(rest)
            return value.isEmpty ? nil : Item(isSelected: selected, value: value, label: label, page: page)
        }

        let value = String(rest[rest.index(after: open) ..< close])
        let trailing = String(rest[rest.index(after: close)...])
        guard !value.isEmpty else { return nil }
        return Item(isSelected: selected, value: value, label: labelPart(trailing), page: page)
    }

    private static func splitLabel(_ text: String) -> (String, String) {
        for separator in [" — ", " - ", " – "] {
            if let range = text.range(of: separator) {
                return (
                    String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                    String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                )
            }
        }
        return (text, "")
    }

    private static func labelPart(_ trailing: String) -> String {
        let trimmed = trailing.trimmingCharacters(in: .whitespaces)
        for separator in ["—", "-", "–"] where trimmed.hasPrefix(separator) {
            return String(trimmed.dropFirst(separator.count)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    public static func load(for source: URL) -> DocumentPlan? {
        let url = Self.url(for: source)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, sourceName: source.lastPathComponent)
    }

    public static func delete(for source: URL) {
        try? FileManager.default.removeItem(at: Self.url(for: source))
    }

    // MARK: - Merging

    /// Folds a fresh scan into a plan someone has already edited.
    ///
    /// Their decisions are what a plan is *for*, so an item they unticked stays unticked
    /// however confidently it was found again. Anything genuinely new arrives ticked, so a
    /// document that has changed since the last look is still described accurately.
    public func merged(with fresh: DocumentPlan) -> DocumentPlan {
        var decisions: [String: Bool] = [:]
        for item in items { decisions[item.value] = item.isSelected }

        var merged = fresh.items.map { item -> Item in
            var item = item
            if let decided = decisions[item.value] { item.isSelected = decided }
            return item
        }

        // Lines the user typed themselves are not findings, and a rescan must not drop them.
        let found = Set(fresh.items.map(\.value))
        merged += items.filter { !found.contains($0.value) }

        return DocumentPlan(sourceName: fresh.sourceName, items: merged)
    }
}
