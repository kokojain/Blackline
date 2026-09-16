import Foundation
import PDFKit
import BlacklineKit
import BlacklineIntelligence

/// Runs the on-device model over a document's own text before any redaction happens, and
/// locates what it proposes.
///
/// Kept apart from ``RedactionJob`` because it is availability-gated and because it is a
/// genuinely different question from the read-back inspector: here the model is reading a
/// clean page and naming what is sensitive, which it does well.
@available(macOS 26.0, *)
enum ModelFirstPass {
    struct Outcome: Sendable {
        var located: [Int: [Match]] = [:]
        /// Pages the model could not read — usually the context window, on a dense page.
        /// Counted rather than swallowed: a page the model skipped was not checked by it,
        /// and the run has to be able to say so.
        var failedPages: [Int] = []
    }

    static func proposals(
        for url: URL,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> Outcome {
        guard let document = PDFDocument(url: url), !document.isLocked else { return Outcome() }

        let proposer = ModelProposer()
        let locator = ProposalLocator()
        var outcome = Outcome()

        for index in 0 ..< document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index),
                  let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            progress(index + 1, document.pageCount)

            // A page the model fails on still gets the deterministic rules; losing the whole
            // document because one page overflowed the context window would be worse.
            let proposed: [Proposal]
            do {
                proposed = try await proposer.proposals(forPage: text)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome.failedPages.append(index + 1)
                continue
            }

            let (hits, _) = locator.locate(proposed, in: SourceText(text))
            var spans: Set<Range<String.Index>> = []
            outcome.located[index] = hits.flatMap(\.matches).filter { spans.insert($0.range).inserted }
        }
        return outcome
    }
}
