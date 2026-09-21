import Testing
@testable import BlacklineKit

@Suite("SecretMatcher")
struct SecretMatcherTests {
    private let matcher = SecretMatcher()

    @Test("Vendor-prefixed tokens stand alone", arguments: [
        "AKIAIOSFODNN7EXAMPLE",
        "sk_live_FAKE51Kx9mQ2vT7b",
        "whsec_9f8e7d6c5b4a39281706f5e4d3c2b1a0",
        "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8",
        "github_pat_11ABCDEFG0123456789abcdefghij",
        "xoxb-FAKE-1234567890-AbCdEfGhIjKl",
        "SG.aBcDeFgHiJkLmNoPqRsTuV.wXyZ0123456789abcdefghij",
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789-AAAAAAAA",
        "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789",
        "AIzaSyA1234567890abcdefghijklmnopqrstuv",
        "glpat-abcdefghijklmnopqrstuvwx",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
    ])
    func prefixedTokens(_ token: String) {
        let found = matcher.matches(in: "Use \(token) to authenticate.")
        #expect(found.map(\.matchedText) == [token])
    }

    @Test("An assignment redacts the value and keeps the name", arguments: [
        ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        ("TWILIO_AUTH_TOKEN=0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef"),
        ("password: hunter2", "hunter2"),
        ("Password = \"correct horse\"", "correct"),
        ("api_key: 'abc123'", "abc123"),
        ("pw `Fw!Edge2024#`", "Fw!Edge2024#"),
        ("Pre-shared key: `9y7Gk1QwZr3Xv5Tn2Lm8Pb4Hd6Fj0Sc1Ae3Ui5Yo7=`", "9y7Gk1QwZr3Xv5Tn2Lm8Pb4Hd6Fj0Sc1Ae3Ui5Yo7="),
        ("client_secret=abc-def-ghi", "abc-def-ghi"),
    ])
    func assignments(_ text: String, _ expected: String) {
        #expect(matcher.matches(in: text).map(\.matchedText) == [expected])
    }

    // The name must carry a credential word, and a label must be followed by a separator
    // or a quote — otherwise ordinary configuration and prose become redactions.
    @Test("Configuration that is not a credential is left alone", arguments: [
        "AWS_DEFAULT_REGION=us-west-2",
        "SORT_KEY=name",
        "root pw in vault `ops/jump-01/root`",
        "the password policy requires twelve characters",
        "upwind: yes",
    ])
    func nonCredentials(_ text: String) {
        #expect(matcher.matches(in: text).isEmpty)
    }

    @Test("Credentials in a URL, leaving the host", arguments: [
        ("postgres://mhs_app:Tr0ub4dor&3@db-prod-01.internal:5432/erp?sslmode=require", "mhs_app:Tr0ub4dor&3"),
        ("redis://:R3d1s-Cache-9x@10.40.2.44:6379/0", ":R3d1s-Cache-9x"),
    ])
    func urlCredentials(_ text: String, _ expected: String) {
        #expect(matcher.matches(in: text).map(\.matchedText) == [expected])
    }

    @Test("A URL without credentials is not a secret")
    func plainURL() {
        #expect(matcher.matches(in: "Admin: https://10.40.0.1:4443/login").isEmpty)
    }

    @Test("A PEM block is one span, armour included")
    func pemBlock() {
        let text = """
        Key follows:
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAyF4kQbP2n7rXv1sT8Zq0dLmH9cWbE3jY5uKaN6oGpR1tVxSz
        0bYwq3sVd7LpN9eRt2XcA8mK4uJhG6fD1iOzE5nB7yCvT0lQaWxSgHkMjUrPfZ3
        -----END RSA PRIVATE KEY-----
        Regards
        """
        let found = matcher.matches(in: text)
        #expect(found.count == 1)
        #expect(found.first?.matchedText.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") == true)
        #expect(found.first?.matchedText.hasSuffix("-----END RSA PRIVATE KEY-----") == true)
    }

    @Test("A bearer token")
    func bearer() {
        #expect(matcher.matches(in: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345")
            .map(\.matchedText) == ["abcdefghijklmnopqrstuvwxyz012345"])
    }

    @Test("Matches are attributed to the secrets category")
    func category() {
        #expect(matcher.matches(in: "token: abc").first?.source == .category(.secrets))
    }
}
