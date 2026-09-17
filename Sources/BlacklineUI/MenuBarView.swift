import SwiftUI
import BlacklineRedactor

/// The menu bar popover: what is running, what is queued, what has finished.
///
/// A deep run takes minutes, so this is the surface that has to answer "is it stuck?" —
/// which it does by naming the current step rather than spinning.
public struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let job = model.current {
                RunningJobCard(job: job)
            }

            if let reading = model.analysing {
                ReadingCard(job: reading)
            }

            if !model.pending.isEmpty {
                SectionLabel("Ready for you")
                ForEach(model.pending) { waiting in
                    PendingPlanCard(waiting: waiting)
                }
            }

            if let problem = model.lastProblem {
                ProblemCard(message: problem)
            }

            if !model.queue.isEmpty {
                SectionLabel("Waiting")
                ForEach(model.queue, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "clock")
                        .lineLimit(1)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                }
            }

            if !model.runs.isEmpty {
                Divider().padding(.vertical, 4)
                SectionLabel("Recent")
                ForEach(model.runs.prefix(4)) { run in
                    RecentRow(run: run) { openWindow(id: "review", value: run.sourceURL.path) }
                }
            }

            Divider().padding(.vertical, 4)

            MenuRow(title: "Redact a PDF…", systemImage: "doc.badge.ellipsis", prominent: true) {
                model.chooseFiles()
            }
            MenuRow(title: "Edit redaction rules…", systemImage: "list.bullet.rectangle", trailing: model.rulesSummary) {
                NSWorkspace.shared.activateFileViewerSelecting([model.rulesURL])
            }
            MenuRow(title: "Fine tune…", systemImage: "slider.horizontal.3", trailing: "global rules") {
                model.editGlobalRules()
            }
            DepthPicker()
            MenuRow(title: "Quit Blackline", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 420)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 11)
            .padding(.top, 4)
    }
}

/// A document being read. Nothing is redacted during this phase, and the card says so —
/// otherwise a long pause looks like redaction happening unsupervised.
private struct ReadingCard: View {
    let job: AnalysisJob

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.sourceURL.lastPathComponent)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text("Reading — nothing redacted yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { job.cancel() }.controlSize(.small)
            }
            ProgressView(value: job.fraction).progressViewStyle(.linear)
            Text(job.phase.label)
                .font(.system(size: 11.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
    }
}

/// A document that has been read and is waiting on a decision.
private struct PendingPlanCard: View {
    @Environment(AppModel.self) private var model
    let waiting: PendingPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(waiting.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text("\(waiting.selectedCount) item\(waiting.selectedCount == 1 ? "" : "s") ticked in \(waiting.planURL.lastPathComponent)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Button("Go") { model.go(waiting) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.current != nil || waiting.selectedCount == 0)
                Button("Edit plan") { model.editPlan(waiting) }
                    .controlSize(.small)
                Spacer()
                Button("Discard") { model.forget(waiting) }
                    .controlSize(.small)
            }
        }
        .padding(11)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
    }
}

private struct RunningJobCard: View {
    let job: RedactionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.sourceURL.lastPathComponent)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(job.depth.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { job.cancel() }
                    .controlSize(.small)
            }

            ProgressView(value: job.fraction)
                .progressViewStyle(.linear)

            // Naming the step is the whole point: the model pass can sit for ten seconds a
            // page, and an unlabelled bar reads as a hang.
            HStack(spacing: 7) {
                if case .consultingModel = job.phase {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                }
                Text(job.phase.label)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Nothing leaves this Mac")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(11)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
    }
}

private struct ProblemCard: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(Theme.warnFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.warnBorder))
    }
}

private struct RecentRow: View {
    let run: CompletedRun
    let open: () -> Void

    var body: some View {
        let unexamined = run.result.unexaminedPages

        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: unexamined.isEmpty ? "checkmark" : "exclamationmark.triangle.fill")
                    .foregroundStyle(unexamined.isEmpty ? Theme.ok : Theme.warn)
                    .frame(width: 14)
                Text(run.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if unexamined.isEmpty {
                    Text("\(run.result.redactedItemCount)")
                        .foregroundStyle(.tertiary)
                } else {
                    // A run with an unexamined page keeps saying so wherever it appears.
                    Text("\(unexamined.count) page\(unexamined.count == 1 ? "" : "s") not checked")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.warn)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(unexamined.isEmpty ? .clear : Theme.warnFill, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MenuRow: View {
    let title: String
    let systemImage: String
    var trailing: String?
    var prominent = false
    let action: () -> Void

    init(
        title: String,
        systemImage: String,
        trailing: String? = nil,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).frame(width: 15)
                Text(title)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Theme.accent : .primary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(prominent ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DepthPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 9) {
            Image(systemName: "checkmark.shield").frame(width: 15)
            Picker("Checking", selection: $model.depth) {
                ForEach(Depth.allCases) { depth in
                    Text(depth.title).tag(depth)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text(model.depth.summary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}
