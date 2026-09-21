import Foundation

/// Detects credentials: API keys, tokens, passwords, private keys and the credentials
/// embedded in connection URLs.
///
/// A secret is the one identifier whose leak is worse than a person's, and it is also the
/// easiest to state a boundary for, because the vendors chose their prefixes to be
/// recognisable. Four forms are matched:
///
/// - **Vendor-prefixed tokens** — `AKIA…`, `sk_live_…`, `ghp_…`, `xoxb-…`, `SG.….…`,
///   `sk-ant-…`, `AIza…`, `glpat-…`, a three-part JWT. Each stands alone: the prefix is the
///   evidence, and no ordinary word begins that way.
/// - **Assignments** — `AWS_SECRET_ACCESS_KEY=…`, `password: …`, `` pw `…` ``. The name is
///   the evidence and only the value is redacted, since `PASSWORD=` beside a black box tells
///   the reader what was there and nothing more. The name must contain a credential word
///   (secret, token, password, api key, private key…); bare `KEY=` is not enough, because
///   `SORT_KEY=name` is configuration. A label must be followed by `:` or `=` or an opening
///   quote — `pw in vault` is prose, not a password called `in`.
/// - **Credentials in URLs** — the `user:password` between `://` and `@`. The host is left,
///   since where a database lives is not what makes the string dangerous.
/// - **PEM blocks** — everything from `-----BEGIN … PRIVATE KEY-----` to its `END`, armour
///   included. The armour is not sensitive, but a box that stops one line short of the
///   header invites the reader to look for the rest.
///
/// Not matched: high-entropy strings with no prefix and no label. A forty-character base64
/// run is a secret or a checksum, and shape alone cannot say which — the same reasoning
/// that keeps ``AccountNumberMatcher`` from matching bare digit runs.
public struct SecretMatcher: Matcher {
    public var source: MatchSource { .category(.secrets) }

    private let engines: [RegexMatcher]

    /// Credential words that qualify an assignment's name, as a substring of an uppercase
    /// name (`AWS_SECRET_ACCESS_KEY`) or as a label in text (`api key:`, `Pre-shared key:`).
    /// The short forms — `pw`, `pwd`, `psk` — are accepted only as whole words, since
    /// `upwind` is not a password.
    private static let name =
        #"(?:[A-Za-z0-9_-]*(?:secret|token|password|passwd|passphrase|pre-shared[ _-]?key"#
        + #"|api[ _-]?key|apikey|private[ _-]?key|access[ _-]?key|auth[ _-]?key"#
        + #"|client[ _-]?secret)[A-Za-z0-9_-]*|pwd?|psk)"#
    /// A value runs to whitespace or a closing quote; `,` and `;` end a value in prose.
    private static let value = #"([^\s"'`,;]+)"#

    public init() {
        var engines: [RegexMatcher] = []

        // Vendor-prefixed tokens. Case matters: the prefixes are what they are.
        let prefixed: [String] = [
            #"(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"#,            // AWS access key id
            #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\b"#,               // Stripe
            #"\bwhsec_[A-Za-z0-9]{16,}\b"#,                                      // Stripe webhook
            #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"#,                   // GitHub
            #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#,
            #"\bxox[abposre]-[A-Za-z0-9-]{10,}"#,                               // Slack
            #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,                   // SendGrid
            #"\bsk-(?:ant-|proj-|svcacct-)?[A-Za-z0-9_-]{20,}"#,               // OpenAI, Anthropic
            #"\bAIza[0-9A-Za-z_-]{35}\b"#,                                       // Google API key
            #"\bglpat-[A-Za-z0-9_-]{20,}\b"#,                                    // GitLab
            #"\bxkeysib-[A-Za-z0-9-]{20,}\b"#,                                   // Brevo
            #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,  // JWT
        ]
        for pattern in prefixed {
            engines.append(RegexMatcher(pattern: pattern))
        }

        // PEM private key block, armour included. Runs on the normalized text, where the
        // block is one line, so `.` needs no dotall.
        engines.append(
            RegexMatcher(
                pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#
            )
        )

        // Assignments and labels. The name must contain a credential word; the value must
        // follow a separator or an opening quote.
        engines.append(
            RegexMatcher(
                pattern: #"(?<![A-Za-z0-9_-])"# + Self.name
                    + #"\b\s*(?:[:=]\s*["'`]?|["'`])"# + Self.value,
                options: [.caseInsensitive],
                captureGroup: 1
            )
        )

        // `Authorization: Bearer <token>`.
        engines.append(
            RegexMatcher(
                pattern: #"\bbearer\s+([A-Za-z0-9._~+/-]{20,}=*)"#,
                options: [.caseInsensitive],
                captureGroup: 1
            )
        )

        // `scheme://user:password@host` — the user may be empty (`redis://:secret@…`).
        engines.append(
            RegexMatcher(
                pattern: #"\b[a-z][a-z0-9+.-]*://([^/\s:@]*:[^\s@/]+)@"#,
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
