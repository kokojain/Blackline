import Foundation
import Observation
import BlacklineKit
import BlacklineRedactor
import BlacklineIntelligence

/// How thoroughly a document is checked.
///
/// The names describe what the run *verifies*, not how fast it is, because that is the part
/// a user has to reason about when deciding whether to trust the output.
public enum Depth: String, CaseIterable, Identifiable, Sendable {
    /// Rules only, over the text layer. Verification cannot see a rasterized page.
    case fast
    /// Rules, plus reading every rendered page back to confirm nothing is still legible.
    case thorough
    /// Adds the on-device model, which catches identifiers no rule describes.
    case deep

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fast: "Fast"
        case .thorough: "Thorough"
        case .deep: "Deep check"
        }
    }

    public var summary: String {
        switch self {
        case .fast: "rules only"
        case .thorough: "rules · read-back"
        case .deep: "rules · read-back · on-device model"
        }
    }

    public var readsPagesBack: Bool { self != .fast }
    public var usesModel: Bool { self == .deep }
}

/// One document being redacted.
@MainActor
@Observable
public final class RedactionJob: Identifiable {
    public enum Phase: Equatable {
        case waiting
        case scanning(page: Int, of: Int)
        case locating(page: Int)
        case rendering(page: Int, pass: Int)
        case reading(page: Int, pass: Int)
        case consultingModel(page: Int, pass: Int)
        case caught(page: Int, items: [String])
        case verifying
        case finished
        case failed(String)
        case cancelled

        /// What the user is told is happening. A multi-minute pause with no explanation
        /// reads as a hang, so the model step names itself rather than showing a spinner.
        public var label: String {
            switch self {
            case .waiting: "Waiting…"
            case .scanning(let page, let total): "Reading page \(page) of \(total)"
            case .locating(let page): "Locating the text on page \(page)"
            case .rendering(_, let pass): "Rendering · pass \(pass)"
            case .reading(_, let pass): "Reading the rendered page back · pass \(pass)"
            case .consultingModel: "Asking the on-device model what is still visible…"
            case .caught(_, let items):
                "Still visible: \(items.map { "“\($0)”" }.joined(separator: ", "))"
            case .verifying: "Verifying the finished document…"
            case .finished: "Done"
            case .failed(let message): message
            case .cancelled: "Cancelled"
            }
        }

        public var isTerminal: Bool {
            switch self {
            case .finished, .failed, .cancelled: true
            default: false
            }
        }
    }

    public let id = UUID()
    public let sourceURL: URL
    public let depth: Depth

    public private(set) var phase: Phase = .waiting
    public private(set) var pagesDone = 0
    public private(set) var pageCount = 0
    public private(set) var result: PDFRedactor.Result?
    /// Set when deep was asked for but the on-device model is not available here. Degrading
    /// silently would misrepresent what was checked.
    public private(set) var modelUnavailable: String?

    private var task: Task<Void, Never>?

    public var fraction: Double {
        guard pageCount > 0 else { return 0 }
        return min(1, Double(pagesDone) / Double(pageCount))
    }

    public init(sourceURL: URL, depth: Depth) {
        self.sourceURL = sourceURL
        self.depth = depth
    }

    public func cancel() {
        task?.cancel()
    }

    public func run(matchers: [any Matcher], onFinish: @escaping @MainActor (RedactionJob) -> Void) {
        task = Task { [weak self] in
            guard let self else { return }
            await self.execute(matchers: matchers)
            onFinish(self)
        }
    }

    private func execute(matchers: [any Matcher]) async {
        var usesModel = depth.usesModel
        if usesModel {
            if #available(macOS 26.0, *) {
                if case .failure(let reason) = ModelProposer.checkAvailability() {
                    modelUnavailable = reason.errorDescription
                    usesModel = false
                }
            } else {
                modelUnavailable = "the on-device model needs macOS 26"
                usesModel = false
            }
        }

        // Progress arrives from a background context; the job is main-actor state.
        let sink: @Sendable (PDFRedactor.Progress) -> Void = { [weak self] step in
            Task { @MainActor in self?.apply(step) }
        }

        var inspector: PDFRedactor.VisibleTextInspector?
        if usesModel, #available(macOS 26.0, *) {
            let proposer = ModelProposer()
            inspector = { text in try await proposer.residue(inVisibleText: text).map(\.text) }
        }

        // A document that cannot be proven clean is kept and shown rather than thrown
        // away: the engine's check is not the last word, and discarding the work leaves
        // nothing to look at and no way to see what the problem was.
        let redactor = PDFRedactor(
            verifiesByReading: depth.readsPagesBack,
            holdsUnverifiedOutputForReview: true
        )
        let source = sourceURL

        do {
            let outcome = try await redactor.redact(
                documentAt: source,
                matchers: matchers,
                additionalMatches: try await firstPassProposals(usesModel: usesModel),
                inspectVisibleText: inspector,
                progress: sink
            )
            result = outcome
            pagesDone = outcome.pageCount
            phase = .finished
        } catch is CancellationError {
            phase = .cancelled
        } catch let failure as PDFRedactor.Failure {
            phase = .failed(failure.errorDescription ?? "Redaction failed")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The model's first look, over the document's own text. It reads an unredacted page far
    /// more accurately than a redacted one, so this pass is where it earns its keep; the
    /// read-back inspector is a different, narrower question.
    private func firstPassProposals(usesModel: Bool) async throws -> [Int: [Match]] {
        guard usesModel, #available(macOS 26.0, *) else { return [:] }
        return try await ModelFirstPass.proposals(for: sourceURL) { [weak self] page, total in
            Task { @MainActor in self?.apply(.scanning(page: page, of: total)) }
        }
    }

    private func apply(_ step: PDFRedactor.Progress) {
        switch step {
        case .scanning(let page, let total):
            pageCount = total
            pagesDone = max(pagesDone, page - 1)
            phase = .scanning(page: page, of: total)
        case .locating(let page):
            phase = .locating(page: page)
        case .rendering(let page, let pass):
            phase = .rendering(page: page, pass: pass)
        case .reading(let page, let pass):
            phase = .reading(page: page, pass: pass)
        case .consultingModel(let page, let pass):
            phase = .consultingModel(page: page, pass: pass)
        case .residueFound(let page, _, let items):
            phase = .caught(page: page, items: items)
        case .pageSettled(let page, _):
            pagesDone = max(pagesDone, page)
        case .verifyingDocument:
            pagesDone = pageCount
            phase = .verifying
        }
    }
}
