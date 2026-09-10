# Blackline — Local PDF Redaction for Mac

**Working title:** Blackline
**Platform:** macOS (menu bar app), built natively for the Apple ecosystem
**One-liner:** Right-click any PDF, choose "Blackline," and get a copy with all personal information permanently redacted — ready to upload anywhere. Everything runs on-device; nothing ever leaves the Mac.

---

## 1. Problem

People routinely need to share PDFs on the web — tax documents for a loan application, medical records for a portal, bank statements for a landlord, contracts for review. These documents are full of personal information (names, addresses, account numbers, SSNs) that the recipient doesn't need and that shouldn't live on someone else's server forever.

Today the options are bad: Acrobat Pro's redaction tool is expensive and manual, online "redaction" services require uploading the very document you're trying to protect, and drawing black rectangles in Preview is cosmetic — the text underneath remains fully extractable with a copy-paste.

Blackline makes true redaction a one-click, fully local operation.

## 2. Product principles

1. **Local only.** No network access, no accounts, no telemetry. The app is sandboxed and can be verified to make zero outbound connections. This is the core trust promise.
2. **True redaction, not cosmetic.** Redacted content is removed from the document, not covered up. Text cannot be recovered by selection, extraction, or metadata inspection.
3. **One action, zero configuration in the moment.** The user sets up their `redact.txt` once. After that, redacting a file is a single right-click or menu pick.
4. **Non-destructive.** The original PDF is never modified. Output is always a new file next to the original.

## 3. Core user flows

### Flow A — Right-click "Blackline"

The user has a PDF (perhaps just viewed in Preview or Acrobat). They locate it in Finder, right-click, and choose **Blackline** from the context menu. A moment later, a redacted copy appears in the same directory.

Implementation note: macOS doesn't allow third-party items inside Acrobat's or Preview's own right-click menus, so this flow is delivered through the mechanisms Apple provides for exactly this purpose:

- A **Finder Quick Action / Services entry** ("Blackline") that appears when right-clicking any PDF in Finder.
- The same service is reachable from within Preview via **Preview menu → Services → Blackline** while the document is open.
- The **Share sheet** ("Share → Blackline") from Finder, Preview, and any app that shares PDFs.

Together these cover the "right-click and blackline it" experience the platform-native way.

### Flow B — Menu bar pull-down

The user clicks the Blackline icon in the menu bar and chooses **Redact a PDF…**. A standard open panel appears; they pick a file; the redacted copy is written to the same directory. The menu also shows the last few redacted files for quick access.

### Flow C — Drag and drop (bonus)

Dragging one or more PDFs onto the menu bar icon redacts them all. This also enables simple batch use.

### Output naming

For an input `statement.pdf`, the output is `statement redacted.pdf` in the same directory. If that name exists, append a counter (`statement redacted 2.pdf`). Never overwrite anything.

### Completion feedback

A macOS notification confirms success: "statement.pdf → 14 items redacted." Clicking it reveals the new file in Finder. If nothing matched the rules, the app says so rather than silently producing an identical copy — a silent no-op is a privacy failure.

## 4. The `redact.txt` rules file

All redaction rules live in a single plain-text file the user can edit in any editor. Default location: `~/Documents/redact.txt` (configurable; the menu bar has an "Edit Redaction Rules" item that opens it).

One rule per line. Two kinds of rules:

**Quoted lines = exact text matches.** The literal string between the quotes is found and redacted wherever it appears.

**Unquoted lines = descriptions.** These name a *category* of information, and the app's detectors find every instance.

```
# Blackline rules — lines starting with # are comments

# Exact matches (quoted)
"Nikhil"
"Knob LLC"
"123 Harbor View Drive"
"4417-XXXX-XXXX-9803"

# Descriptions (unquoted) — detected automatically
email addresses
phone numbers
social security numbers
street addresses
account numbers
dates of birth
person names
```

Details:

- Exact matches are case-insensitive by default; a `!` prefix (`!"ACME"`) forces case-sensitive matching.
- Descriptions map to built-in detectors (Section 5). The app ships with a documented vocabulary of supported categories; unrecognized descriptions produce a gentle warning in the completion notification rather than failing silently.
- Blank lines and `#` comments are ignored.
- The file is re-read on every run, so edits take effect immediately — no app restart.

## 5. Redaction engine

The pipeline for each PDF:

1. **Parse** the document with PDFKit and extract text with position information for every page.
2. **OCR fallback.** If a page has no extractable text (a scanned document), run it through the Vision framework's on-device text recognition so scanned PDFs are supported too.
3. **Match** against the rules:
   - Quoted rules → literal string search across page text (spanning line breaks and hyphenation where possible).
   - Category rules → a layered detector stack, all on-device:
     - `NSDataDetector` for emails, phone numbers, URLs, dates, street addresses.
     - The **NaturalLanguage** framework's named-entity recognition for person names, organizations, and places.
     - Curated regex patterns for structured identifiers: SSNs, EINs, credit card and bank account numbers, passport numbers, driver's license formats.
4. **Redact for real.** Matched regions are removed, not covered:
   - Where the PDF structure allows, the matched text runs are removed from the content stream and replaced with a black box glyph area.
   - Where clean content-stream surgery isn't safe (complex encodings, overlapping operators), the affected page is **rasterized**: rendered to an image with black boxes burned in, then re-embedded. This guarantees the text is gone, at the cost of selectability on that page. The app prefers the surgical path and falls back to rasterization automatically.
5. **Scrub the rest of the file.** True redaction is more than page content:
   - Document metadata (Title, Author, Subject, Keywords, XMP).
   - Annotations, form field values, and embedded file attachments (matched content redacted; attachments containing matches are stripped with a note).
   - Any incremental-save history is discarded by writing a fresh, flattened document.
6. **Verify.** Before writing the output, the engine re-extracts all text from the candidate output and re-runs the matchers. If any rule still matches, the pages involved are force-rasterized and re-verified. The file is only written once verification passes — the app never ships a PDF it can't prove is clean.

## 6. Apple ecosystem architecture

| Layer | Technology |
|---|---|
| Language / UI | Swift, SwiftUI (settings & onboarding), AppKit `NSStatusItem` for the menu bar |
| PDF handling | PDFKit + Core Graphics (CGPDF) for content-stream work |
| OCR | Vision framework (on-device) |
| Entity detection | NaturalLanguage framework, `NSDataDetector` |
| System integration | NSServices (Finder right-click + Services menu), Share extension, Shortcuts actions |
| Automation | App Intents: a "Redact PDF" action usable in Shortcuts, Automator, and via Siri |
| Security | App Sandbox with user-selected file access and security-scoped bookmarks; hardened runtime; notarized; **no network entitlement at all** |
| Distribution | Mac App Store, plus a notarized direct-download DMG; universal binary (Apple silicon + Intel) |
| Requirements | macOS 14 (Sonoma) or later |

The absence of the network entitlement is a feature to advertise: the OS itself enforces that Blackline cannot phone home.

### Ecosystem roadmap

- **Shortcuts everywhere:** because the engine is exposed as an App Intent, users can build folder-watching automations ("anything dropped in ~/ToRedact gets blacklined").
- **iOS/iPadOS companion (later):** the same engine packaged as a Share-sheet extension on iPhone and iPad — redact a PDF straight from Mail or Files.
- **iCloud-synced rules (later, opt-in):** `redact.txt` synced via iCloud Drive so rules follow the user across devices. Sync is the only feature that would touch iCloud, and it remains strictly optional.

## 7. Edge cases and safety notes

- **Text inside images** on otherwise text-based pages: Vision OCR runs on embedded images too, and matches trigger rasterization of the region.
- **Vector logos / signatures:** not detectable as text; v1 documents this limitation. A later "review mode" could show pages before writing output.
- **Encrypted PDFs:** prompt for the password locally; output is written unencrypted unless the user opts to re-encrypt.
- **Huge documents:** processing is streamed page by page with a progress indicator in the menu bar icon.
- **False negatives are the dangerous failure.** The verify pass (5.6) exists for this reason, and the completion notification always states exactly how many items were redacted and by which rules, so a suspiciously low count is visible immediately.

## 8. MVP scope

**In v1.0:** menu bar app; Finder right-click service; open-panel and drag-and-drop flows; `redact.txt` with quoted exact matches plus these categories — email addresses, phone numbers, SSNs, street addresses, person names, account/credit-card numbers, dates of birth; true redaction with rasterization fallback; metadata scrubbing; verification pass; notifications.

**Deferred:** review-before-save mode, batch folder watching, iOS companion, iCloud rule sync, per-document rule overrides, redaction report export (a sidecar listing what was removed and where).

## 9. Open questions

1. Should "person names" redact *all* detected names, or only names listed in `redact.txt`? (Redacting every name in a contract may be too aggressive; a `names: listed-only` toggle in the rules file could resolve this.)
2. Default output suffix: `redacted` (per the spec) — worth also offering `blacklined` as a preference?
3. Should the app offer a quick visual diff (original vs. redacted, side by side) as a confidence builder before v2's full review mode?
