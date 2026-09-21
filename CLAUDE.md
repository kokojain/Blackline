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
Tests/BlacklineKitTests/Fixtures/  synthetic-proprietary-packet.md — a fictional company packet seeded
                           with one of every identifier; SyntheticCorpusTests runs every
                           detector over it (misses and over-reach are both failures)
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

`blackline-preview` reports what *would* be redacted. It writes nothing — producing the copy
is `blackline-redact`'s job. Its most important output is what it says it did **not** check:
categories with no detector, and pages with no extractable text. A scanned page currently
yields zero matches and a loud warning, which is the shape of the false negative spec §7
warns about.

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

**A misread is a letter or a symbol where a digit was wanted, never a different digit.**
Vision returns `0Z210` for `02210` and `/` for `7`; it does not turn a 2 into a 1. So
`PageOCR.isRecognitionArtefact` rejects any candidate whose difference is digit-for-digit,
and both approximate paths honour it. Measured on a W-2: without that rule the employee's
`Boston MA 02210` also blacked out the employer's `Boston MA 02110` one row below, because
a tolerance of five mismatches over fifteen characters covers a different postcode easily.

**A value printed across two rows is placed row by row.** A postal address is the ordinary
case, and searching one line's text can never find it: the caller then falls back to PDFKit's
geometry, which on a two-column form covers the whole row. That is the "it redacted too much"
failure in its most damaging form — redacting an employee's address took the `Employee:`
caption, the SSN label and the second column with it, and three rows of a W-2 became one
black slab. `PageReading.boxesAcrossLines` uses the one piece of structure a wrapped value
has: it **ends at the end of a line and resumes at the start of the next**. The first piece
must be a suffix of its line's words, middle lines are consumed whole, the last piece must be
a prefix. Nothing else is accepted, so it cannot join a scatter of words down the page.

**"The two agree" cannot mean "the boxes overlap".** PDFKit's box is kept alongside the
recognized one where they agree, for the extra coverage when they line up — but a box
spanning the whole row overlaps the right answer by definition, so overlap alone re-admits
exactly the pathological boxes the recognizer was brought in to replace. `PDFRedactor.agrees`
requires PDFKit's box to be no more than half as big again as the recognized one **in both
directions**. Width alone is not enough: measured on the same form, a box for a value on one
row came back 29 points tall and clipped the employer's name on the row above.

**Text-extraction verification is necessary but not sufficient.** This is the trap worth
remembering: rasterizing deletes the text layer whether or not the boxes landed correctly,
so §5.6's re-scan passes trivially on a page with a visible, unredacted SSN. It was caught
happening — twice. The guards that actually work are the span check in `redactionBoxes`
(the text PDFKit resolves at a span's indices must equal the text the matcher found) and the
read-back loop below. Note the span check validates the *index mapping*, not the *bounds* —
it passed on the misplaced boxes described above.

### The model finds what the rules ask for

The model is told the categories from the user's `redact.txt` and to report nothing else.
Left to its own judgement it decides for itself what is sensitive, and on a tax return that
means every dollar figure on the page: wages, totals, balances. Blacking those out ruins the
document for whoever has to read it and protects nobody — a return is mostly figures and
almost none of them identify anyone. `ProposalFilter.isNotIdentifying` is the hard guard
behind the prompt, since a prompt is a request and this needs to be a guarantee.

**A proposal's label is an allow-list, not a deny-list.** `ProposalFilter.isAllowedKind`
keeps a proposal only where its own label names something this app removes — a name, an
address, an account, a tax number, a date of birth, a PIN, a key. A deny-list was tried
first and it loses: over three runs of one 1120S the model returned `letter`, `string`,
`form code`, `Account Type`, `property` (the depreciation classes on a 4562 — `5-year
property`, `27.5 yrs.`, `Class life`) and `question` (the vehicle questionnaire, five
sentences of it, which duly went black on page 18). Each had to be added by hand *after* it
had ruined a page, and the supply of labels a model can invent has no end. The unknown label
has to fail closed. What it costs is a real finding under a label nobody thought of; the
detectors do not pass through here, the read-back loop still runs, and the plan is in front
of the user — whereas a label admitted by mistake blacks out a table before anyone sees it.

**Nothing too slight to be an identifier.** `isTooSlight` requires four characters, rejects
form line labels (`12a`, `16f`), and then wants a digit, two real words, or eight
characters. This is the guard that matters most, because a proposal becomes an
`ExactTextMatcher` and §4 makes that a *substring* search: `a` is not a redaction, it is a
request to black out every letter *a* in the document. Measured on a 21-page 1120S, a plan
holding `a`, `b`, `cost`, `year` and `12a`…`13g` turned 180 lines into **2,632 redactions**
and left nothing on the page. The cost is a lone surname, which belongs in `redact.txt`
anyway, where it is deterministic.

It rejects three more things, all found by reading a plan the model had written for a W-2.
**Form furniture:** it reported `Box 2`, `Box 3` and `Box 17` as account numbers, and since
Vision reads a caption and its dotted leader as one token, blacking out `Box 2` took the
whole row with it — three rows of the form went black. Box and line numbers stop at two
digits so a PO box is never mistaken for furniture. **A kind the instructions already
excluded:** a proposal labelled `money` or `wages` is one the model has itself placed out of
scope while reporting it anyway, and the label is evidence its text alone does not carry.
**The caption in front of the value:** asked for the personal information on the page, it
reports `Employee SSN: 123-45-6789` and `Contact: payroll@…` — the value *and* its field
label. Redacting that span blacks out the caption, and a form without captions cannot be
read. `valueWithoutLabel` takes off up to four words of letters followed by a colon and a
space; a prefix carrying a digit is part of the value, not a label. The prompt asks for the
same thing, but a prompt is a request.

`AnalysisJob` then drops a proposal that is a rule's own finding with a caption attached —
`Routing 021000021` beside the account matcher's `021000021` — since the rule's span is the
tighter one and is already in the plan. What it must not do is discard a proposal that
genuinely covers more: on a two-column form the text layer interleaves the columns, so the
address detector sees `Boston MA 02210` while the model sees the whole of `88 Harbor St Apt
4B Boston MA 02210`. `ProposalFilter.isRuleHitWithCaption` decides by what the extra text
*is* — a caption is words, and anything carrying a digit is part of the value.

All of these stay narrow, because this filter *removes* redactions and only tier 3 is subject
to it — the deterministic floor is untouched.

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
- **A rule hit is acted on; a checker's report is not.** A matcher finding an identifier on
  the rendered page is evidence in its own right — that is how a value printed inside an
  image gets caught, since the text layer never showed it to anyone. What a checker
  *reports* goes through `worthActingOn` first, which keeps only values this page already
  set out to remove. Asked what is still visible on a redacted page, a checker answers with
  the field labels beside the boxes, the form's title, every line-item caption down a tax
  return, and fragments of clipped words. Acting on those blacks out more of the page every
  pass. The failure this loop exists for — a box that landed wrong — always concerns a value
  the first pass already found; finding something genuinely new is the first pass's job, on
  clean text, which it does far more reliably.

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

1. **Deterministic floor** — regex, plus `NSDataDetector` for postal addresses, in
   BlacklineKit. Structured identifiers with a knowable coverage boundary: you can state
   exactly which SSN formats are caught. Fast, reproducible, immune to anything written in
   the document.

   `NSDataDetector` is used for addresses and *not* for phone numbers, and the asymmetry is
   the tier's whole point. An address has no shape a regex can state, so the system detector
   is strictly better than anything written here. Its `.phoneNumber` type, though, reports
   `123-45-6789`, `12-3456789` and a bare `021000021` as phone numbers — an SSN, an EIN and
   a routing number — so a user who asked for phone numbers would have three other
   identifiers blacked out by a rule they never wrote. `PhoneNumberMatcher` enumerates the
   forms instead. Where the detector is used, its span is trimmed
   (`StreetAddressMatcher.endingAtPostcode`): on an unpunctuated form line it reads one word
   past the postcode and calls the next field's label the city.
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

**Built.** Rules parsing (§4). The matcher layer (§5.3): exact matches plus SSN, EIN and
other tax IDs, credit card (with CVV and expiry), account (with SWIFT/BIC), passport,
driver's licence, email address, phone number, postal address, date of birth, secrets
(API keys, tokens, passwords, URL credentials, PEM blocks), IP address, health information
(plan and record numbers, labelled diagnoses and ICD codes) and employee ID.
`SourceText` normalization. Vision text recognition (`BlacklineOCR`), used to place redaction
boxes and to read rendered pages back.
Redaction with rasterization (§5.4), metadata scrubbing (§5.5) and the verification pass
(§5.6), with the render-and-read-back loop on top. The on-device model tier. Two CLIs,
`blackline-preview` and `blackline-redact`. The app: menu bar, background job queue with
progress and cancellation, notifications, and the review window. The Go loop described
below, with `globalrules.md` and the per-document plan.

**Not built.** Content-stream surgery, so redacted pages lose selectable text. OCR-based
*detection*: recognition is used for placement and verification, but a page with no text
layer is still copied through unexamined rather than read. Encrypted-PDF passwords. The
Finder service, Share extension and App Intent. The rules editor and "add rules from this
document".

**Categories with no detector:** person names. Names need tier 2's NER, and NLTagger was
measured on the synthetic corpus before deciding not to ship it as a tier-1 detector: it
missed a third of the names (Raghunathan, Sørensen, Yoshida, Tanaka) while reporting `HR`,
`WA`, `PIP` and `Supplier` as people. That is neither a pattern nor a boundary anyone can
state. Quoted rules are the answer (`samples/redact.example.txt` says so), and in Deep runs
the model covers them; `MatcherFactory.unsupportedCategories` reports the category so a run
never implies it checked something it did not.

**A date of birth is a labelled date.** `DateOfBirthMatcher` matches a date beside `DOB` /
`Date of birth` / `Born`, or under such a header in a pipe table, and no other date on the
page — a form is full of dates and almost none of them identify anyone.

**A column header is a label.** `AccountNumberMatcher`'s label window reaches one line up,
which is one line short of a table header on every row but the first and stops dead at a
markdown `|---|` separator; measured on the synthetic corpus, two bank accounts in a
five-column table went unfound while the same numbers in running text were caught.
`PipeTable` reads the columns where the text carries them (`|`-drawn tables only — a table
extracted from a PDF page arrives as rows of words with no column structure, and gets
nothing here, which is the honest answer) and `ColumnLabeledMatcher` lets a labelled
matcher accept a whole cell under a header it would accept as a label.

### The synthetic corpus

`Tests/BlacklineKitTests/Fixtures/synthetic-proprietary-packet.md` is a fictional company's
internal packet with one of everything, and `synthetic-proprietary-packet.redact.txt` is
the rules file a user there would write: every category, plus quoted rules for the people
and the code names. `SyntheticCorpusTests` holds the first pass to a single standard —
**with that rules file, nothing proprietary survives it** — and to the opposite one: the
money, the dates, the ticket numbers, the words beside a label all stay on the page. Every
value in the fixture is inert (900-series SSNs, 555 exchanges, test PANs, `FAKE`-padded
keys). When a detector is added or changed, run this suite before the unit suite: it is
what found `license application` → *application* and `Palo Alto PA-3260` as an address.

What the first pass cannot find, and the corpus does not pretend it can: the financial
figures, the guidance, the formulation, the source code, the contract clauses. Nothing about
their shape says what they are. Quoted rules cover the ones with a name; the rest is the
model tier's, and on a return the model is told not to touch figures at all.

## The Go loop

Redaction is a loop the user drives, rather than one shot followed by a review:

```
Redact a PDF…
  ↓   the model reads it (~10s/page)
<document>.md  — the plan, opened for editing. Nothing redacted yet.
  ↓   edit it, press Go
<document> redacted.pdf   + the review window
  ↓   edit the plan again, press Go
<document> redacted.pdf   — the same file, replaced
```

### Three files

| File | Who reads it | What it is |
|---|---|---|
| `redact.txt` | the detectors | unchanged: the §4 grammar, quoted literals and categories |
| `globalrules.md` | the model | free-form prose, applying to every document |
| `<document>.md` | both | this document's plan: what was found, and what to remove |

They stay separate on purpose. `redact.txt`'s grammar is what drives the regex detectors —
SSN, EIN, card, account — which run without the model, give the same answer twice, and are
the floor the read-back verification checks against. Prose can only instruct the model.
Folding one into the other would put everything at the mercy of the model.

`globalrules.md` is reached from **Fine tune…** in the menu bar; `<document>.md` from the
run it belongs to.

**`globalrules.md` has a size limit, and it is small.** The model's context window holds the
instructions, the guidance, the page text *and* the reply — about 4,000 tokens for all four.
A 24 KB policy document pasted into the file was measured at 5,508 tokens, and every page of
every document then failed with `exceededContextWindowSize`: `ModelProposer` halves the
*page* on that error, which cannot help when the guidance is what overflowed, so the run
degraded to the detectors alone without saying so. `GlobalRules.promptBudget` (3,000
characters) trims at a line boundary and `omittedCharacterCount` reports what was dropped,
which the review window states as a gap. The file is for the operative rules — what to find,
what to leave alone; a policy document belongs beside it, not in it.

### `<document>.md` holds personal information in the clear

It lists the values found — the SSNs, the EINs, the names — and sits beside the source PDF,
which is what makes it easy to edit and easy to keep with the document. It is also a
plaintext index of exactly what the user is protecting, in the folder they are about to
share from, where Spotlight will index it and a backup will copy it. This was a deliberate
choice, taken knowing that. What follows from it:

- The app must say so where the file is offered, not bury it.
- Deleting the plan must be one action from the review window, next to deleting the copy.
- It must never be written anywhere the user did not put the original.

### Each Go replaces the same file

Iterating must not leave `redacted 2.pdf`, `redacted 3.pdf` behind. A run started from a
plan writes to that plan's output path and replaces it. The §3 promise not to overwrite
still holds for everything else: the first run picks a free name, and only Blackline's own
output for this document is ever replaced.

### How it hangs together

`AnalysisJob` reads a document and writes its plan; it redacts nothing, so a run no longer
always ends in a file. `DocumentPlan` reads and writes `<document>.md` and is the single
source of what a Go removes — detectors and the model write the first draft, and after that
the file decides. `AppModel.go(_:)` turns the ticked values into `ExactTextMatcher`s, which
is what makes an untick stick: the detectors do not get a second say.

Two floors stand under that, because a plan is a hand-editable file and a literal rule is a
substring search. `DocumentPlan.minimumValueLength` refuses a ticked value shorter than
three characters, or one with no letter or digit in it, and `refusedValues` reports them so
the caller can say what it ignored. Then `PDFRedactor.maximumMatchesPerRulePerPage` refuses
any rule that hits one page more than forty times — an EIN heads every page of a return and
a shareholder's name can appear a dozen times on a K-1, but nothing that identifies anybody
appears fifty times on one page. It is refused for that page and named in the result's
problems, because blacking the page out and reporting success is worse, and so is going
quiet.

**Edit plan** and **Go** sit in the review window as well as the menu bar, beside the page
being looked at, because the loop lives or dies on how cheap it is to change your mind. The
ticked count is re-read on `didBecomeActive`, since the plan is edited in another program
and the window would otherwise show a stale number.

The review window is keyed by the **document**, not the run: going again replaces the run,
so a window keyed by run id would go stale and a second window would open beside the first.

A Go passes `writingTo:` so the copy replaces the one the last Go made. `ModelProposer`
takes the prose from `globalrules.md` as `guidance`, placed after the scope it was given and
before the prohibitions, so standing instructions can refine what to look for but cannot
talk the model into reporting money.

Re-reading a document keeps the decisions already made: `DocumentPlan.merged(with:)` carries
ticks across, keeps lines typed by hand, and brings anything new in ticked — so a document
that has changed is still described accurately without discarding the user's judgement.

**A plan item is one line, normalized.** A postal address matches across the line break the
form printed it on, so the value arriving from a matcher carries a newline; written straight
out it ends the markdown line halfway through and the plan loses both that value and the rest
of the line. `DocumentPlan.Item` normalizes through `SourceText.normalize`, which is also
what keeps the value usable — `ExactTextMatcher` normalizes its needle identically, so the
folded value still finds the wrapped original.

**Verifying a plan-driven run cannot be done by searching the file's bytes.** A redacted
page is rasterized, so its text layer is gone whether a value was covered or left alone;
byte-searching cannot tell "removed" from "still there in the picture". The tests read the
finished page back with `PageOCR` instead, which is the only check that can tell the
difference.

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
