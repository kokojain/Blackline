import Foundation
import PDFKit
import Observation
import BlacklineKit
import BlacklineIntelligence

/// Reads a document and writes the plan for it. Redacts nothing.
///
/// This is the first half of the Go loop: the model and the detectors between them describe
/// what is in the document, that description is written beside it as `<document>.md`, and
/// the run stops there. Nothing is removed until a person has looked at the plan and pressed
/// Go, so the decision about what leaves the document is always theirs.
@MainActor
@Observable
public final class AnalysisJob: Identifiable {
    public enum Phase: Equatable {
        case waiting
        case reading(page: Int, of: Int)
        case consultingModel(page: Int, of: Int)
        case finished(planURL: URL)
        case failed(String)
        case cancelled

        public var label: String {
            switch self {
            case .waiting: "Waiting…"
            case .reading(let page, let total): "Reading page \(page) of \(total)"
            case .consultingModel(let page, let total):
                "Asking the on-device model about page \(page) of \(total)…"
            case .finished: "Ready for you to review"
            case .failed(let message): message
            case .cancelled: "Cancelled"
            }
        }
    }

    public let id = UUID()
    public let sourceURL: URL
    public private(set) var phase: Phase = .waiting
    public private(set) var pagesDone = 0
    public private(set) var pageCount = 0
    public private(set) var plan: DocumentPlan?
    public private(set) var modelFailedPages: [Int] = []
    public private(set) var modelUnavailable: String?

    private var task: Task<Void, Never>?

    public var fraction: Double {
        pageCount > 0 ? min(1, Double(pagesDone) / Double(pageCount)) : 0
    }

    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    public func cancel() { task?.cancel() }

    public func run(
        matchers: [any Matcher],
        wanted: [String],
        guidance: String,
        usesModel: Bool,
        globalRulesPath: String?,
        onFinish: @escaping @MainActor (AnalysisJob) -> Void
    ) {
        task = Task { [weak self] in
            guard let self else { return }
            await self.execute(
                matchers: matchers,
                wanted: wanted,
                guidance: guidance,
                usesModel: usesModel,
                globalRulesPath: globalRulesPath
            )
            onFinish(self)
        }
    }

    private func execute(
        matchers: [any Matcher],
        wanted: [String],
        guidance: String,
        usesModel: Bool,
        globalRulesPath: String?
    ) async {
        guard let document = PDFDocument(url: sourceURL) else {
            phase = .failed("Could not open \(sourceURL.lastPathComponent) as a PDF.")
            return
        }
        guard !document.isLocked else {
            phase = .failed("\(sourceURL.lastPathComponent) is encrypted; password handling is not built yet.")
            return
        }

        var useModel = usesModel
        if useModel {
            if #available(macOS 26.0, *) {
                if case .failure(let reason) = ModelProposer.checkAvailability() {
                    modelUnavailable = reason.errorDescription
                    useModel = false
                }
            } else {
                modelUnavailable = "the on-device model needs macOS 26"
                useModel = false
            }
        }

        pageCount = document.pageCount
        var items: [DocumentPlan.Item] = []
        var seen: Set<String> = []

        for index in 0 ..< document.pageCount {
            if Task.isCancelled { phase = .cancelled; return }
            guard let page = document.page(at: index) else { continue }

            let pageText = page.string ?? ""
            phase = .reading(page: index + 1, of: document.pageCount)

            func add(_ value: String, _ label: String) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
                items.append(.init(value: trimmed, label: label, page: index + 1))
            }

            /// What the rules found here, to keep the model from widening it.
            var foundByRules: [String] = []

            for match in matchers.flatMap({ $0.matches(in: SourceText(pageText)) }) {
                add(match.matchedText, match.source.ruleDescription)
                foundByRules.append(SourceText.normalize(match.matchedText))
            }

            if useModel, #available(macOS 26.0, *),
               !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                phase = .consultingModel(page: index + 1, of: document.pageCount)
                do {
                    let proposed = try await ModelProposer()
                        .proposals(forPage: pageText, wanted: wanted, guidance: guidance)
                    // Only values that genuinely appear can ever be removed, so a proposal
                    // that cannot be located is not worth putting in front of the user.
                    let located = ProposalLocator()
                        .locate(proposed, in: SourceText(pageText)).located
                    for hit in located {
                        // A proposal that contains a value a rule already found is the same
                        // finding with more of the page attached — "Routing 021000021" for
                        // the account number beside it. The rule's span is the tighter of
                        // the two and is already in the plan, so this one would only widen
                        // the box over the caption.
                        let text = SourceText.normalize(hit.proposal.text)
                        guard !foundByRules.contains(where: {
                            ProposalFilter.isRuleHitWithCaption(text, ruleValue: $0)
                        }) else { continue }
                        add(hit.proposal.text, hit.proposal.kind)
                    }
                } catch is CancellationError {
                    phase = .cancelled
                    return
                } catch {
                    modelFailedPages.append(index + 1)
                }
            }

            pagesDone = index + 1
        }

        // A plan the user has already edited keeps its decisions; anything new arrives ticked.
        let fresh = DocumentPlan(sourceName: sourceURL.lastPathComponent, items: items)
        let merged = DocumentPlan.load(for: sourceURL)?.merged(with: fresh) ?? fresh
        plan = merged

        do {
            let url = try merged.write(for: sourceURL, globalRulesPath: globalRulesPath)
            phase = .finished(planURL: url)
        } catch {
            phase = .failed("Could not write the plan: \(error.localizedDescription)")
        }
    }
}
