import Foundation

/// A literal string to redact wherever it appears, written as a quoted line in `redact.txt`.
///
/// Per spec §4, exact matches are case-insensitive unless the line carries a `!` prefix.
public struct ExactRule: Hashable, Sendable {
    /// The literal text between the quotes, exactly as written.
    public let literal: String
    /// `true` when the rule was written with a `!` prefix.
    public let isCaseSensitive: Bool
    /// 1-based line number in the source rules file, for diagnostics and reporting.
    public let lineNumber: Int

    public init(literal: String, isCaseSensitive: Bool = false, lineNumber: Int = 0) {
        self.literal = literal
        self.isCaseSensitive = isCaseSensitive
        self.lineNumber = lineNumber
    }
}

/// A category rule: an unquoted line naming a class of information to detect.
public struct CategoryRule: Hashable, Sendable {
    public let category: Category
    /// 1-based line number in the source rules file.
    public let lineNumber: Int

    public init(category: Category, lineNumber: Int = 0) {
        self.category = category
        self.lineNumber = lineNumber
    }
}

/// The rules parsed from a `redact.txt`, in file order.
public struct RuleSet: Hashable, Sendable {
    public let exactRules: [ExactRule]
    public let categoryRules: [CategoryRule]

    public init(exactRules: [ExactRule] = [], categoryRules: [CategoryRule] = []) {
        self.exactRules = exactRules
        self.categoryRules = categoryRules
    }

    public var categories: [Category] { categoryRules.map(\.category) }

    /// `true` when the file yielded nothing to redact. Running with an empty rule set can
    /// only produce an unchanged copy, which spec §3 calls a privacy failure — callers are
    /// expected to surface this rather than write output.
    public var isEmpty: Bool { exactRules.isEmpty && categoryRules.isEmpty }

    public var ruleCount: Int { exactRules.count + categoryRules.count }
}
