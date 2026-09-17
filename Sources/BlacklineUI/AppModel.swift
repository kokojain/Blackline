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

/// A document that has been read and is waiting for the user to press Go.
///
/// The plan beside it is the only thing that decides what a Go removes, so this holds no
/// findings of its own. `outputURL` is remembered after the first Go so that later ones
/// replace the same file rather than accumulating copies.
@MainActor
@Observable
public final class PendingPlan: Identifiable {
    public let id = UUID()
    public let sourceURL: URL
    public let planURL: URL
    public internal(set) var outputURL: URL?
    public let modelFailedPages: [Int]
    public let modelUnavailable: String?

    public init(
        sourceURL: URL,
        planURL: URL,
        modelFailedPages: [Int] = [],
        modelUnavailable: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.planURL = planURL
        self.modelFailedPages = modelFailedPages
        self.modelUnavailable = modelUnavailable
    }

    public var name: String { sourceURL.lastPathComponent }

    public var plan: DocumentPlan? { DocumentPlan.load(for: sourceURL) }

    /// How many items the plan will remove as it currently stands, re-read each time so the
    /// count follows edits made outside the app.
    public var selectedCount: Int { plan?.selectedValues.count ?? 0 }
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

    /// Free-form guidance for the model, edited through "Fine tune…".
    public var globalRulesURL: URL {
        didSet { UserDefaults.standard.set(globalRulesURL.path, forKey: "globalRulesURL") }
    }

    public private(set) var current: RedactionJob?
    /// The document being read, before any plan exists.
    public private(set) var analysing: AnalysisJob?
    /// Documents read and waiting for a Go.
    public private(set) var pending: [PendingPlan] = []
    public private(set) var queue: [URL] = []
    public private(set) var runs: [CompletedRun] = []
    /// Set when a run could not start or produced nothing, for the menu bar to show.
    public private(set) var lastProblem: String?

    /// Raised when a finished run should be shown, identified by the document it came from.
    ///
    /// Keyed by the source rather than the run, so that going again from the review window
    /// updates the window already open instead of stacking another one beside it.
    public var reviewToOpen: String?

    public init() {
        let defaults = UserDefaults.standard
        depth = Depth(rawValue: defaults.string(forKey: "depth") ?? "") ?? .deep
        if let saved = defaults.string(forKey: "rulesURL") {
            rulesURL = URL(fileURLWithPath: saved)
        } else {
            rulesURL = URL(fileURLWithPath: NSString(string: "~/Documents/redact.txt").expandingTildeInPath)
        }
        if let saved = defaults.string(forKey: "globalRulesURL") {
            globalRulesURL = URL(fileURLWithPath: saved)
        } else {
            globalRulesURL = URL(fileURLWithPath: NSString(string: "~/Documents/globalrules.md").expandingTildeInPath)
        }
    }

    /// Opens the global rules for editing, creating them from the starter text on first use.
    public func editGlobalRules() {
        if !FileManager.default.fileExists(atPath: globalRulesURL.path) {
            try? GlobalRules.starter.write(to: globalRulesURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(globalRulesURL)
    }

    public func editPlan(_ pending: PendingPlan) {
        NSWorkspace.shared.open(pending.planURL)
    }

    public func forget(_ pending: PendingPlan) {
        DocumentPlan.delete(for: pending.sourceURL)
        self.pending.removeAll { $0.id == pending.id }
    }

    public var rulesSummary: String {
        guard let parsed = try? RulesParser().parse(contentsOf: rulesURL) else { return "no rules file" }
        let count = parsed.ruleSet.ruleCount
        return "\(count) rule\(count == 1 ? "" : "s")"
    }

    /// The most recent run for a document.
    public func run(forSource path: String) -> CompletedRun? {
        runs.first { $0.sourceURL.path == path }
    }

    /// The plan a document is working from, if it still has one.
    public func plan(forSource path: String) -> PendingPlan? {
        pending.first { $0.sourceURL.path == path }
    }

    /// Adds a finished run without having performed it. Used by snapshots and previews so
    /// the review window can be rendered from a real result.
    public func register(_ run: CompletedRun) {
        runs.insert(run, at: 0)
    }

    /// Adds a waiting plan without having read the document. Used by snapshots and previews.
    public func registerPending(_ waiting: PendingPlan) {
        pending.append(waiting)
    }

    // MARK: - Starting work

    public func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls.filter { $0.pathExtension.lowercased() == "pdf" })
        startNextAnalysisIfIdle()
    }

    public func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to read. Nothing is redacted until you review the plan."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }

    public func cancelCurrent() {
        current?.cancel()
        analysing?.cancel()
    }

    /// Reads the next document and writes its plan. Redacts nothing.
    private func startNextAnalysisIfIdle() {
        guard analysing == nil, current == nil, !queue.isEmpty else { return }
        guard let rules = loadRules() else { return }

        let url = queue.removeFirst()
        let built = MatcherFactory().makeMatchers(for: rules.ruleSet)
        let job = AnalysisJob(sourceURL: url)
        analysing = job
        lastProblem = nil

        job.run(
            matchers: built.matchers,
            wanted: rules.ruleSet.categories.map(\.canonicalName),
            guidance: GlobalRules.load(from: globalRulesURL).guidance,
            usesModel: depth.usesModel,
            globalRulesPath: globalRulesURL.path
        ) { [weak self] finished in
            guard let self else { return }
            if case .finished(let planURL) = finished.phase {
                let waiting = PendingPlan(
                    sourceURL: finished.sourceURL,
                    planURL: planURL,
                    modelFailedPages: finished.modelFailedPages,
                    modelUnavailable: finished.modelUnavailable
                )
                self.pending.append(waiting)
                // The plan is the whole point of this phase, so it opens for editing rather
                // than waiting to be found.
                NSWorkspace.shared.open(planURL)
                Notifier.post(
                    title: finished.sourceURL.lastPathComponent,
                    body: "Read and described in \(planURL.lastPathComponent). Nothing redacted yet — review it and press Go.",
                    reveal: planURL
                )
            } else if case .failed(let message) = finished.phase {
                self.lastProblem = message
            }
            self.analysing = nil
            self.startNextAnalysisIfIdle()
        }
    }

    /// Redacts a document according to its plan, replacing any copy an earlier Go produced.
    public func go(_ waiting: PendingPlan) {
        guard current == nil, analysing == nil else { return }
        guard let rules = loadRules() else { return }

        guard let plan = DocumentPlan.load(for: waiting.sourceURL), !plan.isEmpty else {
            lastProblem = "\(waiting.planURL.lastPathComponent) has nothing ticked, so nothing would be removed."
            return
        }

        // The plan decides, not the detectors: an item the user unticked must stay in the
        // document however confidently it was found.
        let matchers: [any Matcher] = plan.selectedValues.map { ExactTextMatcher(literal: $0) }

        let job = RedactionJob(
            sourceURL: waiting.sourceURL,
            depth: depth,
            wantedCategories: rules.ruleSet.categories.map(\.canonicalName)
        )
        current = job
        lastProblem = nil

        job.run(
            matchers: matchers,
            writingTo: waiting.outputURL,
            consultsModelFirst: false
        ) { [weak self] finished in
            guard let self else { return }
            if let result = finished.result {
                waiting.outputURL = result.outputURL
                let completed = CompletedRun(
                    sourceURL: finished.sourceURL,
                    result: result,
                    depth: finished.depth,
                    modelUnavailable: finished.modelUnavailable ?? waiting.modelUnavailable,
                    modelFailedPages: waiting.modelFailedPages,
                    modelReadBackFailures: finished.modelReadBackFailures,
                    unsupportedCategories: []
                )
                self.runs.removeAll { $0.sourceURL == finished.sourceURL }
                self.runs.insert(completed, at: 0)
                self.notify(completed)
                self.reviewToOpen = completed.sourceURL.path
            } else if case .failed(let message) = finished.phase {
                self.lastProblem = message
            }
            self.current = nil
        }
    }

    private func loadRules() -> RulesParser.Result? {
        do {
            let parsed = try RulesParser().parse(contentsOf: rulesURL)
            return parsed
        } catch let error as RulesParser.FileError {
            lastProblem = error.errorDescription
            return nil
        } catch {
            lastProblem = "Could not read \(rulesURL.lastPathComponent)."
            return nil
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
