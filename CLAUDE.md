# Blackline

Local PDF redaction for macOS. A menu bar app: right-click any PDF in Finder, choose
"Blackline," and get a copy alongside it with all personal information permanently
redacted. Everything runs on-device.

Full spec: `blackline-spec.md` (in this repo).

## Product

**Problem:** Sharing tax documents, medical records, or bank statements online means
handing over names, addresses, and account numbers the recipient doesn't need. Acrobat
Pro is expensive and manual, online redaction services require uploading the very
document you're protecting, and black rectangles in Preview are cosmetic — the text
underneath is still copy-pasteable.

**Principles:**

1. **Local only.** No network access, no accounts, no telemetry — verifiably zero
   outbound connections. This is the core trust promise.
2. **True redaction, not cosmetic.** Content is removed, not covered. Unrecoverable by
   selection, extraction, or metadata inspection.
3. **One action, zero configuration in the moment.** Rules are set up once in
   `redact.txt`; redacting is then a single right-click.
4. **Non-destructive.** The original is never modified. Output is `statement redacted.pdf`
   next to `statement.pdf`, never overwriting (append a counter on collision).

**Entry points:** Finder Quick Action / Services entry, Preview → Services, Share sheet,
menu bar "Redact a PDF…" open panel, and drag-and-drop onto the menu bar icon (batch).

**Rules file:** `~/Documents/redact.txt` (configurable), re-read on every run. Quoted
lines are exact matches (case-insensitive; `!` prefix forces case-sensitive); unquoted
lines name a detector category. `#` comments and blanks ignored.

**Engine pipeline:** parse with PDFKit → OCR fallback via Vision for scanned pages →
match quoted rules literally and category rules through the detector stack → redact by
content-stream surgery where safe, rasterizing the page where it isn't → scrub metadata,
annotations, form fields, attachments, and incremental-save history → **verify** by
re-extracting text from the candidate output and re-running the matchers, force-
rasterizing and re-verifying on any hit. Output is only written once verification passes.
A silent no-op is treated as a privacy failure: the completion notification always states
the count and which rules matched.

## Architecture (spec §6)

| Layer | Technology |
|---|---|
| Language / UI | Swift, SwiftUI (settings & onboarding), AppKit `NSStatusItem` for the menu bar |
| PDF handling | PDFKit + Core Graphics (CGPDF) for content-stream work |
| OCR | Vision framework (on-device) |
| Entity detection | NaturalLanguage framework, `NSDataDetector` |
| System integration | NSServices (Finder right-click + Services menu), Share extension, Shortcuts actions |
| Automation | App Intents: a "Redact PDF" action for Shortcuts, Automator, and Siri |
| Security | App Sandbox with user-selected file access and security-scoped bookmarks; hardened runtime; notarized; **no network entitlement at all** |
| Distribution | Mac App Store plus notarized direct-download DMG; universal binary (Apple silicon + Intel) |
| Requirements | macOS 14 (Sonoma) or later |

The missing network entitlement is a feature to advertise: the OS itself enforces that
Blackline cannot phone home. Because the engine is exposed as an App Intent, folder-
watching automations fall out for free.

Later, out of scope for now: iOS/iPadOS Share-sheet companion, opt-in iCloud Drive sync
of `redact.txt` (the only feature that would touch iCloud).

## MVP scope (spec §8)

**In v1.0:**

- Menu bar app
- Finder right-click service
- Open-panel and drag-and-drop flows
- `redact.txt` with quoted exact matches, plus these categories: email addresses, phone
  numbers, SSNs, street addresses, person names, account/credit-card numbers, dates of birth
- True redaction with rasterization fallback
- Metadata scrubbing
- Verification pass
- Notifications

**Deferred:** review-before-save mode, batch folder watching, iOS companion, iCloud rule
sync, per-document rule overrides, redaction report export (a sidecar listing what was
removed and where).

**Known v1 limitations:** vector logos and signatures aren't detectable as text.
Encrypted PDFs prompt for the password locally and write unencrypted output unless the
user opts to re-encrypt.

**Open questions (spec §9):** whether "person names" should redact every detected name or
only those listed in `redact.txt` (a `names: listed-only` toggle); whether to offer
`blacklined` as an alternative output suffix; whether a side-by-side visual diff should
land before v2's full review mode.
