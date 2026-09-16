import SwiftUI
import AppKit
import BlacklineRedactor

/// The review window.
///
/// Its job is not to present a finished file but to make looking at one cheap and directed.
/// Under-redaction is invisible in a summary and obvious on the page, so the page is the
/// centre, comparison with the original is one key away, and anything that could not be
/// checked is stated beside the redaction count rather than beneath it.
public struct ReviewView: View {
    public let runID: UUID

    public init(runID: UUID) { self.runID = runID }

    @Environment(AppModel.self) private var model
    @State private var renderer = PageRenderer()
    @State private var selectedPage = 0
    @State private var peeking = false
    @State private var revealValues = false

    public var body: some View {
        if let run = model.run(id: runID) {
            content(run)
                .onAppear { selectedPage = firstPageWorthSeeing(run) }
        } else {
            ContentUnavailableView("This run is no longer available", systemImage: "doc.questionmark")
        }
    }

    private func content(_ run: CompletedRun) -> some View {
        VStack(spacing: 0) {
            Toolbar(run: run)
            Divider()

            HStack(spacing: 0) {
                PageRail(run: run, renderer: renderer, selected: $selectedPage)
                    .frame(width: Theme.railWidth)
                Divider()

                PageStage(
                    run: run,
                    renderer: renderer,
                    pageIndex: selectedPage,
                    peeking: $peeking
                )
                .frame(maxWidth: .infinity)

                Divider()
                FindingsPane(
                    run: run,
                    selectedPage: $selectedPage,
                    revealValues: $revealValues
                )
                .frame(width: Theme.findingsWidth)
            }

            Divider()
            StatusBar(run: run)
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    /// Opens on the page that most needs looking at: an unexamined one if there is one, since
    /// that is the page a summary would otherwise let pass.
    private func firstPageWorthSeeing(_ run: CompletedRun) -> Int {
        if let unexamined = run.result.pages.first(where: {
            if case .notExamined = $0.status { return true }
            return false
        }) {
            return unexamined.index
        }
        if let redacted = run.result.pages.first(where: {
            if case .redacted = $0.status { return true }
            return false
        }) {
            return redacted.index
        }
        return 0
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    let run: CompletedRun
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield.fill")
                Text(run.depth.title)
            }
            .chip(Theme.accent)

            Text(run.depth.summary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                Notifier.reveal(run.result.outputURL)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete copy", systemImage: "trash")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .confirmationDialog(
            "Delete \(run.name)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete redacted copy", role: .destructive) {
                try? FileManager.default.removeItem(at: run.result.outputURL)
                dismiss()
            }
        } message: {
            Text("The original is untouched and stays where it is.")
        }
    }
}

// MARK: - Page rail

struct PageRail: View {
    let run: CompletedRun
    let renderer: PageRenderer
    @Binding var selected: Int

    var body: some View {
        ScrollView {
            // Not lazy: a PDF has tens of pages, not thousands, and a lazy stack does not
            // lay out when the view is rendered offscreen for snapshots.
            VStack(alignment: .leading, spacing: 10) {
                Text("PAGES")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)

                ForEach(run.result.pages, id: \.index) { page in
                    PageThumb(
                        page: page,
                        image: renderer.image(of: run.result.outputURL, page: page.index, width: 150),
                        isSelected: selected == page.index
                    )
                    .onTapGesture { selected = page.index }
                }
            }
            .padding(10)
        }
        .background(.quaternary.opacity(0.35))
    }
}

struct PageThumb: View {
    let page: PDFRedactor.PageOutcome
    let image: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.white)
                }
            }
            .frame(height: 96)
            .clipped()
            .overlay(Rectangle().strokeBorder(Theme.hairline))

            HStack(spacing: 5) {
                Text("\(page.index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                badge
            }
        }
        .padding(6)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
        .contentShape(Rectangle())
    }

    /// Status is always a glyph plus words. Colour alone would be unreadable for anyone who
    /// cannot see it, and "not checked" is the one thing that must never be missed.
    @ViewBuilder private var badge: some View {
        switch page.status {
        case .redacted(let items, _):
            HStack(spacing: 4) {
                Image(systemName: "checkmark").foregroundStyle(Theme.ok)
                Text("\(items) redacted").foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5))
        case .noMatches:
            HStack(spacing: 4) {
                Text("—").foregroundStyle(.tertiary)
                Text("no matches").foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5))
        case .notExamined:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("not checked").fontWeight(.semibold)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.warn)
        }
    }

    private var isUnexamined: Bool {
        if case .notExamined = page.status { return true }
        return false
    }

    private var background: Color {
        if isUnexamined { return Theme.warnFill }
        return isSelected ? Theme.accent.opacity(0.12) : .clear
    }

    private var borderColor: Color {
        if isUnexamined { return Theme.warn }
        return isSelected ? Theme.accent : .clear
    }

    private var borderWidth: CGFloat {
        if isUnexamined { return isSelected ? 2 : 1 }
        return isSelected ? 1.5 : 0
    }
}

// MARK: - Page stage

private struct PageStage: View {
    let run: CompletedRun
    let renderer: PageRenderer
    let pageIndex: Int
    @Binding var peeking: Bool

    @FocusState private var focused: Bool

    private var outcome: PDFRedactor.PageOutcome? {
        run.result.pages.first { $0.index == pageIndex }
    }

    private var isUnexamined: Bool {
        if case .notExamined = outcome?.status { return true }
        return false
    }

    var body: some View {
        ZStack {
            Theme.pageBacking

            GeometryReader { geometry in
                let width = min(520, geometry.size.width - 60)
                let source = peeking ? run.sourceURL : run.result.outputURL

                VStack {
                    Spacer(minLength: 0)
                    if let image = renderer.image(of: source, page: pageIndex, width: width) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                            .overlay(alignment: .top) {
                                if isUnexamined { UnexaminedBanner() }
                            }
                            .overlay {
                                if isUnexamined {
                                    Rectangle().strokeBorder(Theme.warn, lineWidth: 3)
                                }
                            }
                            // Press and hold anywhere on the page to compare.
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in peeking = true }
                                    .onEnded { _ in peeking = false }
                            )
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            }

            VStack {
                Spacer()
                PeekPill(peeking: peeking)
                    .padding(.bottom, 18)
            }
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        // Flicker-comparing in the same position is what makes a misplaced box obvious;
        // a side-by-side at half width is how one gets missed.
        .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
            peeking = press.phase == .down
            return .handled
        }
    }
}

private struct PeekPill: View {
    let peeking: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: peeking ? "eye.fill" : "eye")
            if peeking {
                Text("Showing the original")
            } else {
                Text("Hold")
                Text("space")
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1.5)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                Text("to compare with the original")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(.black.opacity(0.82), in: Capsule())
    }
}

private struct UnexaminedBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("This page was not checked")
                    .font(.system(size: 12, weight: .bold))
                Text("It has no text layer, so nothing on it was examined or removed. Everything you can see here is still in the file.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn)
    }
}

// MARK: - Findings

struct FindingsPane: View {
    let run: CompletedRun
    @Binding var selectedPage: Int
    @Binding var revealValues: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !run.gaps.isEmpty {
                GapsPanel(gaps: run.gaps)
                    .padding(10)
            }

            HStack {
                Text("What was removed")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                // The list is a catalogue of exactly what the user is protecting, so it does
                // not sit on screen in the clear by default.
                Toggle(isOn: $revealValues) {
                    Label("Reveal", systemImage: revealValues ? "eye.fill" : "eye")
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, run.gaps.isEmpty ? 12 : 2)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(run.result.findings.enumerated()), id: \.offset) { _, finding in
                        FindingRow(finding: finding, revealed: revealValues)
                            .onTapGesture { selectedPage = finding.pageIndex }
                    }
                }
                .padding(10)
            }
        }
        .background(.quaternary.opacity(0.25))
    }
}

private struct GapsPanel: View {
    let gaps: [(title: String, detail: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(gaps.count) thing\(gaps.count == 1 ? "" : "s") \(gaps.count == 1 ? "was" : "were") not checked")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Theme.warn)

            ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                VStack(alignment: .leading, spacing: 1) {
                    Text(gap.title).font(.system(size: 11, weight: .semibold))
                    Text(gap.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warnFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.warnBorder))
    }
}

struct FindingRow: View {
    let finding: PDFRedactor.Finding
    let revealed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(revealed ? collapsed : masked)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("p.\(finding.pageIndex + 1)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                // A quoted rule IS the value, so masking the text but printing the rule
                // would hand it straight back.
                Text(visibleRuleText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                switch finding.origin {
                case .rule:
                    EmptyView()
                case .proposal:
                    Text("on-device model").chip(Theme.accent)
                case .caughtOnRecheck:
                    Text("found on re-read").chip(Theme.warn)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// What the rule column actually shows, exposed so the masking rule can be tested.
    var visibleRuleText: String {
        revealed || !finding.ruleIsLiteral ? finding.ruleDescription : "exact rule"
    }

    private var collapsed: String {
        finding.text.split(whereSeparator: \.isNewline).joined(separator: "⏎")
    }

    private var masked: String {
        String(repeating: "•", count: min(max(collapsed.count, 4), 18))
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    let run: CompletedRun

    var body: some View {
        let unexamined = run.result.unexaminedPages

        HStack(spacing: 10) {
            if unexamined.isEmpty {
                Image(systemName: "checkmark").foregroundStyle(Theme.ok)
                Text(run.depth.readsPagesBack
                     ? "Every redacted page was rendered, read back and came up clean"
                     : "Verified against the text layer — a rasterized page cannot be checked that way")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(unexamined.count) of \(run.result.pageCount) pages was not examined — a clean result here does not mean \(unexamined.count == 1 ? "that page is" : "those pages are") clean")
                    .fontWeight(.semibold)
            }

            Spacer()

            if !run.result.residueCaughtOnRecheck.isEmpty {
                Text("\(Set(run.result.residueCaughtOnRecheck).count) caught on re-read")
            }
            Text("up to \(run.result.verificationPasses) pass\(run.result.verificationPasses == 1 ? "" : "es") per page")
            Text("original untouched")
        }
        .font(.system(size: 11))
        .foregroundStyle(unexamined.isEmpty ? .secondary : Theme.warn)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(unexamined.isEmpty ? AnyShapeStyle(.bar) : AnyShapeStyle(Theme.warnFill))
    }
}
