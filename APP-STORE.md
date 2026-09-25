# Shipping Blackline on the Mac App Store

The path from the repo as it stands to a paid listing, in order. The Apple steps are
short; the Blackline-specific work is in §2 and §3.

## 1. Accounts and agreements (a day, mostly waiting)

- [ ] **Apple Developer Program** — $99/yr at developer.apple.com. Enroll as an individual
      or as the LLC (an LLC needs a D-U-N-S number; individual is faster).
- [ ] In App Store Connect, accept the **Paid Apps Agreement** and complete the **banking
      and tax forms** (W-9 for a US entity). No price can be set until this is approved,
      which takes a few days.
- [ ] Create the app record: bundle ID `com.knob.blackline` (already in `Scripts/make-app.sh`),
      name "Blackline" — App Store names are globally unique, so check availability first.

## 2. Move from SwiftPM to an Xcode app target

Submission requires an archive built by Xcode from an app target. `make-app.sh`
hand-assembles a bundle with ad-hoc signing — fine locally, unusable for submission.

- [ ] Create an Xcode project with a macOS App target that depends on the local Swift
      package. The app target links `BlacklineUI`; `BlacklineKit`, `BlacklineOCR`,
      `BlacklineRedactor` and `BlacklineIntelligence` stay in the package. The two CLIs
      remain package products and do not ship.
- [ ] Move the `Info.plist` keys from the script into the target: `LSUIElement`,
      `LSMinimumSystemVersion` 14.0, copyright string.
- [ ] Signing: Automatic, App Store distribution profile.

## 3. App Sandbox — mandatory, and it touches the core flow

Every Mac App Store app is sandboxed. No network and on-device only already fit; three
things need work.

- [ ] **Writing `statement redacted.pdf` beside the original.** The sandbox grants access
      to files the user picked. The open panel / drag-and-drop covers the *input*; a
      *sibling* output is not automatically allowed. Options:
      (a) declare the output a related item — `NSIsRelatedItemType` plus
          `com.apple.security.files.user-selected.read-write` — which works for a
          same-directory file with a matching base name and keeps the spec's "one action,
          zero configuration" promise. **Try this first.**
      (b) a save panel defaulting to the sibling path.
- [ ] **`~/Documents/redact.txt` and `globalrules.md`.** The app cannot read Documents
      without a grant. Ask once via an open panel and keep a **security-scoped bookmark**
      (least change to the product), or move the rules into the app container / a Settings
      window.
- [ ] **Finder Quick Action.** Under the sandbox this is an **Action Extension** target;
      `NSServices` entries in the main app's Info.plist also work for the Services menu.
      Share sheet and App Intent are further extension targets. None are required for v1 —
      the menu bar open panel and drag-and-drop are enough to ship.

Entitlements: `com.apple.security.app-sandbox`,
`com.apple.security.files.user-selected.read-write`. Nothing for network — leave it off
and say so in the listing.

## 4. What App Review actually checks

- [ ] **Visible behaviour on launch.** A menu-bar-only (`LSUIElement`) app is allowed, but
      apps that "appear to do nothing" get rejected. Make the menu bar icon obvious and
      consider a one-time welcome window saying where the app lives.
- [ ] **macOS 26-only features degrade cleanly.** `BlacklineIntelligence` is
      `@available(macOS 26)` behind FoundationModels. On macOS 14–15 the Deep option must be
      hidden or explained, never crash. Minimum is 14.0; reviewers test on current.
- [ ] **Privacy nutrition label:** Data Not Collected. Lead with it in the description.
- [ ] **Review notes:** attach a test PDF and a `redact.txt` so the reviewer can watch a
      redaction happen. `Tests/BlacklineKitTests/Fixtures/synthetic-proprietary-packet.md`
      exported to PDF, with its `.redact.txt`, is exactly this.
- [ ] No private APIs — PDFKit, Vision, UserNotifications, FoundationModels are all public.

## 5. Listing assets

- [ ] App icon: 1024×1024 plus the macOS icon set.
- [ ] 3–10 screenshots at 1280×800 or 2560×1600 — the review window and a before/after.
- [ ] Description, keywords, support URL.
- [ ] Privacy policy URL — required even for "no data collected"; one paragraph is fine.
- [ ] Price tier. The pitch is "Acrobat Pro is expensive," so a one-time price
      ($9.99–$29.99) fits better than a subscription.

## 6. Before submitting

- [ ] Bump `CFBundleShortVersionString` to `1.0`.
- [ ] `swift test` green (334 tests at time of writing), then a real-document smoke test on
      a **sandboxed** build — sandboxing is where "worked in dev" fails.
- [ ] Archive → Distribute → App Store Connect → Submit for Review. First review is
      typically 1–3 days; expect one rejection round on a first submission.

## The alternative

If sandbox friction (sibling writes, Documents access, Quick Action as an extension) is
painful, selling outside the App Store is legitimate for a Mac app: Developer ID signing +
notarization (no sandbox), sold through Paddle or Lemon Squeezy, which handle VAT and
tax. Many privacy-focused Mac utilities do this. Both channels at once is also fine.

## Recommended order

Do §1 and §2 now (mechanical). Then spend a day on §3 with a sandboxed build to learn
whether the sibling-file write works via related items — that single question decides
whether the App Store version keeps the one-click promise.
