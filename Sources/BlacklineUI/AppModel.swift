import Foundation
import AppKit
import Observation
import BlacklineKit
import BlacklineRedactor

/// A finished run, kept so the menu bar can list it and the review window can open it.
@MainActor
@Observable
public final class CompletedRun: Identifiable {
    public let id = UUID()
    public let sourceURL: URL
    public let result: PDFRedactor.Result
    public let depth: Depth
    public let modelUnavailable: String?
    /// Pages the model could not read, and how often it failed while re-reading.
    public let modelFailedPages: [Int]
    public let modelReadBackFailures: Int
    /// Categories the rules asked for that no detector in this build can find.
    public let unsupportedCategories: [BlacklineKit.Category]

    public init(
        sourceURL: URL,
        result: PDFRedactor.Result,
        depth: Depth,
        modelUnavailable: String?,
        modelFailedPages: [Int] = [],
        modelReadBackFailures: Int = 0,
        unsupportedCategories: [BlacklineKit.Category]
    ) {
        self.sourceURL = sourceURL
        self.result = result
        self.depth = depth
        self.modelUnavailable = modelUnavailable
        self.modelFailedPages = modelFailedPages
        self.modelReadBackFailures = modelReadBackFailures
        self.unsupportedCategories = unsupportedCategories
    }

    /// Where the file is. Always its real, redacted name — an unverified copy is still
    /// written, because a run that produces nothing leaves the user with no way to see what
    /// the objection was.
    public var displayURL: URL { result.outputURL }

    public var name: String { result.outputURL.lastPathComponent }

    public private(set) var wasDeleted = false

    /// The copy exists but could not be proven clean, so it is on the owner to judge it.
    public var isUnverified: Bool { result.isUnverified && !wasDeleted }

    /// What could not be cleared, in the engine's words.
    public var problems: [String] { result.problems }

    /// Removes the copy. The original is untouched either way.
    public func deleteCopy() {
        PDFRedactor.deleteCopy(result)
        wasDeleted = true
    }

    /// Everything this run could not check, in the words the user needs. Surfaced beside the
    /// redaction count rather than below it: a clean-looking total over an unexamined page is
    /// the failure the whole review step exists to prevent.
    public var gaps: [(title: String, detail: String)] {
        var gaps: [(String, String)] = []

        let unexamined = result.unexaminedPages
        if !unexamined.isEmpty {
            let list = unexamined.map(String.init).joined(separator: ", ")
            gaps.append((
                unexamined.count == 1 ? "Page \(list) has no text layer" : "Pages \(list) have no text layer",
                "Scanned or image-only. \(unexamined.count == 1 ? "It was" : "They were") copied through untouched and nothing on \(unexamined.count == 1 ? "it" : "them") was examined."
            ))
        }

        if !unsupportedCategories.isEmpty {
            let names = unsupportedCategories.map(\.canonicalName).joined(separator: ", ")
            gaps.append((
                "No detector for \(names)",
                "Your rules ask for it, but nothing in this build can find one. Quote the value as an exact rule instead."
            ))
        }

        if !modelFailedPages.isEmpty {
            let pages = modelFailedPages.map(String.init).joined(separator: ", ")
            gaps.append((
                "The model could not read page\(modelFailedPages.count == 1 ? "" : "s") \(pages)",
                "Usually too much text for its context window. The rules still ran on \(modelFailedPages.count == 1 ? "that page" : "those pages"); identifiers no rule describes were not looked for there."
            ))
        }

        if modelReadBackFailures > 0 {
            gaps.append((
                "The model could not finish checking \(modelReadBackFailures) rendered page\(modelReadBackFailures == 1 ? "" : "s")",
                "Those pages were still checked by the rules and by recognition, but not by the model."
            ))
        }

        if let modelUnavailable {
            gaps.append((
                "The on-device model did not run",
                "\(modelUnavailable.prefix(1).capitalized + modelUnavailable.dropFirst()). Identifiers no rule describes were not looked for."
            ))
        }

        return gaps
    }
}

/// App-wide state: the queue, the running job, finished runs, and settings.
@MainActor
@Observable
public final class AppModel {
    public var depth: Depth {
        didSet { UserDefaults.standard.set(depth.rawValue, forKey: "depth") }
    }

    public var rulesURL: URL {
        didSet { UserDefaults.standard.set(rulesURL.path, forKey: "rulesURL") }
    }

    public private(set) var current: RedactionJob?
    public private(set) var queue: [URL] = []
    public private(set) var runs: [CompletedRun] = []
    /// Set when a run could not start or produced nothing, for the menu bar to show.
    public private(set) var lastProblem: String?

    /// Raised when a finished run should be shown. The app's scene observes it.
    public var reviewToOpen: UUID?

    public init() {
        let defaults = UserDefaults.standard
        depth = Depth(rawValue: defaults.string(forKey: "depth") ?? "") ?? .deep
        if let saved = defaults.string(forKey: "rulesURL") {
            rulesURL = URL(fileURLWithPath: saved)
        } else {
            rulesURL = URL(fileURLWithPath: NSString(string: "~/Documents/redact.txt").expandingTildeInPath)
        }
    }

    public var rulesSummary: String {
        guard let parsed = try? RulesParser().parse(contentsOf: rulesURL) else { return "no rules file" }
        let count = parsed.ruleSet.ruleCount
        return "\(count) rule\(count == 1 ? "" : "s")"
    }

    public func run(_ run: CompletedRun) -> CompletedRun? { runs.first { $0.id == run.id } }
    public func run(id: UUID) -> CompletedRun? { runs.first { $0.id == id } }

    /// Adds a finished run without having performed it. Used by snapshots and previews so
    /// the review window can be rendered from a real result.
    public func register(_ run: CompletedRun) {
        runs.insert(run, at: 0)
    }

    // MARK: - Starting work

    public func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls.filter { $0.pathExtension.lowercased() == "pdf" })
        startNextIfIdle()
    }

    public func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to redact. The originals are never modified."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }

    public func cancelCurrent() {
        current?.cancel()
    }

    private func startNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let url = queue.removeFirst()

        let parsed: RulesParser.Result
        do {
            parsed = try RulesParser().parse(contentsOf: rulesURL)
        } catch let error as RulesParser.FileError {
            lastProblem = error.errorDescription
            return
        } catch {
            lastProblem = "Could not read \(rulesURL.lastPathComponent)."
            return
        }

        // Spec §3: a run with nothing to match could only produce an identical copy, which
        // is a privacy failure rather than a success. Refuse before starting.
        guard !parsed.ruleSet.isEmpty else {
            lastProblem = "\(rulesURL.lastPathComponent) has no usable rules, so nothing would be redacted."
            return
        }

        let built = MatcherFactory().makeMatchers(for: parsed.ruleSet)
        // The model is told to look for exactly what the rules ask for. Without this it
        // decides for itself and blacks out every dollar figure on a tax return.
        let job = RedactionJob(
            sourceURL: url,
            depth: depth,
            wantedCategories: parsed.ruleSet.categories.map(\.canonicalName)
        )
        current = job
        lastProblem = nil

        job.run(matchers: built.matchers) { [weak self] finished in
            guard let self else { return }
            if let result = finished.result {
                let completed = CompletedRun(
                    sourceURL: finished.sourceURL,
                    result: result,
                    depth: finished.depth,
                    modelUnavailable: finished.modelUnavailable,
                    modelFailedPages: finished.modelFailedPages,
                    modelReadBackFailures: finished.modelReadBackFailures,
                    unsupportedCategories: built.unsupportedCategories
                )
                self.runs.insert(completed, at: 0)
                self.notify(completed)
                // The copy appears as §3 promises, and the review opens on top of it: the
                // risk is not the file existing, it is the file being sent unexamined.
                self.reviewToOpen = completed.id
            } else if case .failed(let message) = finished.phase {
                self.lastProblem = message
            }
            self.current = nil
            self.startNextIfIdle()
        }
    }

    // MARK: - Completion

    private func notify(_ run: CompletedRun) {
        let count = run.result.redactedItemCount

        // Saved, but unverified. The notification must not let that read as a success.
        guard !run.isUnverified else {
            Notifier.post(
                title: run.sourceURL.lastPathComponent,
                body: "\(count) item\(count == 1 ? "" : "s") redacted — saved, but not verified. Review it before sending.",
                reveal: run.result.outputURL
            )
            return
        }

        var body = "\(count) item\(count == 1 ? "" : "s") redacted"
        if !run.result.unexaminedPages.isEmpty {
            let pages = run.result.unexaminedPages.map(String.init).joined(separator: ", ")
            body += " · page\(run.result.unexaminedPages.count == 1 ? "" : "s") \(pages) not checked"
        }
        Notifier.post(title: run.sourceURL.lastPathComponent, body: body, reveal: run.result.outputURL)
    }
}
