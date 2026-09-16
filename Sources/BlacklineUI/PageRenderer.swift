import AppKit
import PDFKit
import Observation

/// Renders pages of a PDF to images for the review window, and remembers them.
///
/// The review window shows the redacted page and, while the user holds to compare, the
/// original in the same position. Both come from here so they are rendered identically —
/// a comparison between two differently-scaled images would invent differences.
@MainActor
@Observable
public final class PageRenderer {
    private struct Key: Hashable {
        let path: String
        let index: Int
        let width: Int
    }

    private var cache: [Key: NSImage] = [:]
    private var documents: [String: PDFDocument] = [:]

    public func image(of url: URL, page index: Int, width: CGFloat) -> NSImage? {
        let key = Key(path: url.path, index: index, width: Int(width.rounded()))
        if let hit = cache[key] { return hit }

        let document: PDFDocument
        if let open = documents[url.path] {
            document = open
        } else {
            guard let opened = PDFDocument(url: url) else { return nil }
            documents[url.path] = opened
            document = opened
        }

        guard index < document.pageCount, let page = document.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0 else { return nil }

        let scale = width / bounds.width
        let size = NSSize(width: width, height: (bounds.height * scale).rounded())
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            return true
        }

        cache[key] = image
        return image
    }
}
