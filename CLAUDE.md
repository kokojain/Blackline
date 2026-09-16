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

## Repo layout and commands

```
blackline-spec.md          the product spec; sections are cited throughout the code
Package.swift              BlacklineKit, swift-tools-version 6.0, macOS 14+
Sources/BlacklineKit/      the redaction engine (library only — no UI, no PDFKit)
Sources/BlacklineIntelligence/  on-device model tier (FoundationModels, macOS 26+)
Sources/BlacklineOCR/      Vision text recognition; page geometry read from pixels
Sources/BlacklineRedactor/ PDF rendering, redaction, and verification (PDFKit)
Sources/BlacklinePreview/  blackline-preview, a read-only CLI (this one does use PDFKit)
Sources/BlacklineRedactCLI/ blackline-redact, writes the redacted copy
Sources/BlacklineUI/       the app's views and job model (a library, so it can be rendered)
Sources/BlacklineApp/      Blackline.app entry point: MenuBarExtra + review window
Scripts/make-app.sh        assembles Blackline.app around the SwiftPM executable
Tests/BlacklineKitTests/   swift-testing (`import Testing`)
samples/                   scratch space for test documents; gitignored
```

```sh
swift build                          # build the library
swift test                           # run the full suite
swift test --filter SSNMatcherTests  # one suite

swift run blackline-preview <file.pdf> [--rules <redact.txt>] [--mask] [--llm]
swift run blackline-redact  <file.pdf> [--rules <redact.txt>] [--llm] [--scale N]

./Scripts/make-app.sh && open .build/Blackline.app   # the menu bar app
```

SwiftPM cannot build an app bundle, and a menu bar app needs one — `LSUIElement` keeps it
out of the Dock and UserNotifications will not register for a loose binary. `make-app.sh`
wraps the executable and ad-hoc signs it.

`blackline-preview` reports what *would* be redacted. It writes nothing and cannot produce
a redacted PDF — the redaction stage does not exist. Its most important output is what it
says it did **not** check: categories with no detector, and pages with no extractable text.
A scanned page currently yields zero matches and a loud warning, which is the shape of the
false negative spec §7 warns about.

BlacklineKit imports **Foundation only**, on purpose. Keeping PDFKit, AppKit, and SwiftUI
out is what makes the matching logic testable headlessly, which matters because spec §7
names false negatives as the dangerous failure. PDF and UI work belongs in targets that
depend on this one, never inside it.

### How redaction works

Pages carrying a match are **rasterized**: rendered to an image with black boxes burned
in, then re-embedded. Spec §5.4 describes this as the fallback behind content-stream
surgery; here it is the only path, because its guarantee needs no qualification — there is
no text object left to recover, whatever the original encoding did. The cost is real and is
stated in the output: redacted pages stop being selectable and searchable. Pages with no
matches are copied through untouched and keep their text.

Content-stream surgery is deferred rather than half-built. A surgical path that works on
most encodings is exactly the false negative §7 warns about.

**Box geometry comes from the rendered pixels, not from PDFKit.** This is the hardest-won
rule in the codebase. Neither PDFKit text API can be trusted on its own:

- `characterBounds(at:)` returns degenerate rectangles on real documents — zero-height boxes
  at the wrong baseline, one character reporting the next line's x.
- `selection.bounds(for:)` is no better where PDFKit merges two visual rows into one "line".
  Measured on one file: a selection reporting x=167.8…311.8 for text actually drawn at
  x=254…320 — a box 86pt to the left that stops before the last digit of an EIN.

So each page is rendered clean and read with Vision *before* any box is placed, and the
recognized word boxes are the primary source; PDFKit's are kept only where the two agree.
Recognition runs at `recognitionScale` (4×), independent of output resolution, because
Vision misreads small print at the default raster scale.

Recognition is not reliable either — it returns `12-3456789` as `12-3456/89` at confidence
1.00, so neither an exact search nor a confidence threshold finds it. `PageReading` therefore
falls back to approximate location, with tolerance scaling by length, and widens an
approximate box by one character because its extent is approximate too. That last detail is
load-bearing: without it the final digit of an identifier stays visible.

**Text-extraction verification is necessary but not sufficient.** This is the trap worth
remembering: rasterizing deletes the text layer whether or not the boxes landed correctly,
so §5.6's re-scan passes trivially on a page with a visible, unredacted SSN. It was caught
happening — twice. The guards that actually work are the span check in `redactionBoxes`
(the text PDFKit resolves at a span's indices must equal the text the matcher found) and the
read-back loop below. Note the span check validates the *index mapping*, not the *bounds* —
it passed on the misplaced boxes described above.

### The read-back loop

`PDFRedactor.settle(page:…)` renders a page, reads it back with Vision, and blacks out
anything still legible, repeating until a pass finds nothing new. A page that is still dirty
after `maximumVerificationPasses` aborts the whole document rather than producing a file
someone has to check by hand.

What makes this worth doing is that **the checker differs from the detector**. Re-running the
same matchers finds the same answer by definition; the point is that Vision sees the page as
drawn, and `inspectVisibleText` can bring judgement no rule encodes. That closure is how the
model participates without `BlacklineRedactor` knowing FoundationModels exists.

Two properties keep the loop honest:

- **It terminates on its own.** Covered text cannot be read again, so a finding that gets
  blacked out does not come back.
- **Findings are grounded in the source.** A reported span only counts if it genuinely
  appears in the original page text. Recognition of a half-covered word returns fragments
  ("ificatil", "ETN 9") and a checker faithfully reports them; grounding discards those
  without having to guess which findings are real.

Asked the general "find personal information" question, a model looking at an already
redacted page reports the field labels beside the black boxes and then the form's own title,
and the page goes black. `ModelProposer.residue(inVisibleText:)` asks a different question
with explicit negative examples, and `ResidueFilter` drops the obvious garbage. Both matter;
neither alone was enough.

Output is `<name> redacted.pdf` beside the original, with a counter on collision — the
original is never modified and nothing is ever overwritten (§2, §3). The candidate is
written to a temporary file, reopened, and re-scanned; only then does it move to the real
name. A document where no rule matches produces **no file at all**, because a copy identical
to the original is a privacy failure rather than a success (§3).

### When a document cannot be proven clean

Refusing to write anything — §5.6's literal reading — turned out to be unusable. On real
documents the checker runs out of passes routinely: recognition misreads, and the model
reports fragments of labels sitting beside the black boxes. The run then failed, nothing was
written, and the user had no file and no way to see what the objection even was.

So `holdsUnverifiedOutputForReview` (on in the app, off in the CLI) writes the copy under
its normal `… redacted.pdf` name and reports
`Result.Disposition.writtenUnverified(problems:)`. The duty §5.6 was protecting does not go
away, it moves: the caller must say plainly that the file was not verified and put it in
front of someone. The review window does that with a banner, the objections quoted in full,
and a status bar driven from the same state — a green "came up clean" under a warning banner
would be the worst message this app could show.

Note the engine's objections are evidence, not verdicts. Several passes of "still legible"
usually means the checker could not convince itself, not that the document is unsafe. That
is exactly why the judgement belongs to the person who owns the document.

### The app layer

`BlacklineUI` is a library, not part of the executable, so its views can be rendered
offscreen and looked at. `BlacklineApp` is only the `@main` entry point.

The review window exists because **under-redaction is invisible in a summary and obvious on
the page**. Every design decision in it follows from that:

- **Hold space flips to the original in place.** Flicker-comparing the same position is how a
  misplaced box becomes obvious; side-by-side at half width is how one gets missed.
- **`not checked` outranks the redaction count.** It colours the status bar, the page
  thumbnail and the findings pane, and the window opens on an unexamined page when there is
  one. A clean-looking total over a page nobody examined is the worst screen the app could
  show.
- **Status is always a glyph plus words**, never colour alone.
- **Findings are masked by default — including the rule label.** A quoted rule *is* the
  value, so `Finding.ruleIsLiteral` exists to let the row show "exact rule" instead of
  handing back what the mask hid. This was caught by rendering the list and reading it.

Because deep runs 10–15s per page, redaction is a background job: progress names the current
step (the model pass says so rather than spinning), the queue is sequential, and
`Task.checkCancellation()` at page and pass boundaries makes Cancel real. Deep degrades to
thorough where Apple Intelligence is unavailable and **says so in the result** — silently
degrading would misrepresent what was checked.

Snapshot tests render the real views and write PNGs to `$TMPDIR/blackline-ui-snapshots`,
but **rendering is off unless asked for**:

```sh
BLACKLINE_SNAPSHOTS=1 swift test --no-parallel --filter UIRendering
```

`ImageRenderer` deadlocks under the test runner's parallel scheduler — the run hangs with no
failure and no output, which costs far more than the images are worth. `.serialized` on the
suites is not enough, because sibling suites still run concurrently. The assertions about
what the UI *says* run on every `swift test`; producing the images is a deliberate act.
`ImageRenderer` also does not lay out `ScrollView` or `LazyVStack` content, so rows are
rendered on their own.

### Detection tiers

Detection is layered, and the layering is a safety property, not just organization:

1. **Deterministic floor** — regex and (later) `NSDataDetector` in BlacklineKit. Structured
   identifiers with a knowable coverage boundary: you can state exactly which SSN formats
   are caught. Fast, reproducible, immune to anything written in the document.
2. **NER** — `NLTagScheme.nameType` for person/place/organization. Not built yet; works
   back to macOS 10.14 and returns spans directly.
3. **On-device model** — `BlacklineIntelligence`, behind `--llm`. Catches what a pattern
   cannot: values that are sensitive because of the surrounding context rather than their
   shape.

Three rules govern tier 3, and they are what make a non-deterministic component safe to put
inside a privacy tool:

- **It only adds.** A model proposal can introduce a redaction; nothing it returns can
  retract one found by tier 1. The coverage you can *prove* never shrinks.
- **It proposes text, never positions.** `ProposalLocator` resolves every proposal through
  `ExactTextMatcher`, so a span that does not literally occur on the page is discarded
  rather than blacked out at a guessed offset. `blackline-preview` prints discarded
  proposals — that count is the model's error rate, made visible.
- **The document cannot give instructions.** Page text is untrusted input; a PDF can carry
  a sentence aimed at the model, including invisible white-on-white text. The structural
  defense is the rule above: injected text can only cause spans that genuinely appear on
  the page to be redacted, never fewer. Do not weaken this to prompt wording alone.

**The context window holds the reply, not just the prompt.** A page dense enough to produce
dozens of findings overflows it even when its text fits, and the failure arrives as
`GenerationError.exceededContextWindowSize` — there is no way to predict it, so the only
workable answer is to react: `ModelProposer` halves the chunk with `TextChunker.halve` (on a
line break, else a space, so a boundary never lands inside an identifier) and asks again,
down to a floor. The generated schema carries no "reason" field for the same reason — it was
never shown to anyone and its tokens were enough to lose a whole page's findings.

A page the model fails on is **counted and reported**, never swallowed: the rules still ran
there, but nothing looked for identifiers no rule describes, and the review window says so.

Sampling is `.greedy` so two runs over one document agree — a privacy tool that reports
different findings each time cannot be reasoned about.

`ProposalLocator` and `TextChunker` deliberately live outside the `@available(macOS 26)`
gate and have no FoundationModels dependency, so the containment logic is testable
everywhere and reusable by any future proposer.

### Implementation status

Built: rules parsing (§4) and the matching layer (§5.3) — `RulesParser`, `SourceText`
normalization, and `ExactTextMatcher`, `SSNMatcher`, `CreditCardMatcher`,
`AccountNumberMatcher` behind the `Matcher` protocol.

Also built: `blackline-preview`, a read-only CLI that extracts text with PDFKit and reports
matches per page; and the tier-3 model proposer behind `--llm`.

Also built: redaction with rasterization (§5.4), metadata scrubbing (§5.5), and the
verification pass (§5.6), driven by `blackline-redact`.

Not built yet: OCR (§5.2), so scanned pages are copied through unexamined; content-stream
surgery, so redacted pages lose selectable text; encrypted-PDF password handling; and the
whole app layer — no menu bar app, Finder service, Share extension, or App Intent.

Category detectors for email addresses, phone numbers, street addresses, person names, and
dates of birth are also still missing — they need `NSDataDetector` and NaturalLanguage.
`MatcherFactory` reports these through `unsupportedCategories` rather than passing them
over silently.

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
