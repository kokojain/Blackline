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
    static func proposals(
        for url: URL,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [Int: [Match]] {
        guard let document = PDFDocument(url: url), !document.isLocked else { return [:] }

        let proposer = ModelProposer()
        let locator = ProposalLocator()
        var located: [Int: [Match]] = [:]

        for index in 0 ..< document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index),
                  let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            progress(index + 1, document.pageCount)

            // A page the model fails on still gets the deterministic rules; losing the whole
            // document because one page tripped a guardrail would be worse.
            guard let proposed = try? await proposer.proposals(forPage: text) else { continue }
            let (hits, _) = locator.locate(proposed, in: SourceText(text))

            var spans: Set<Range<String.Index>> = []
            located[index] = hits.flatMap(\.matches).filter { spans.insert($0.range).inserted }
        }
        return located
    }
}
