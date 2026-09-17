import AppKit
import SwiftUI

/// The menu bar icon: a white page with a black redaction bar across it.
///
/// Deliberately **not** a template image. A template renders as one flat colour that
/// inverts with the menu bar, which would turn the page and the bar into the same shade and
/// lose the whole idea. Drawing it in real colours keeps a white page with a black bar in
/// both light and dark menu bars; the thin border is what stops the white body from
/// disappearing into a light menu bar.
public enum MenuBarIcon {
    /// Menu bar artwork is sized in points, matched to the bar's height.
    static let size = NSSize(width: 18, height: 18)

    public static func image(working: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let page = CGRect(x: 2.5, y: 1.5, width: 13, height: 15)
            let corner: CGFloat = 1.6

            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: page, cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.fillPath()

            // Without an edge the page vanishes against a light menu bar.
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.75))
            context.setLineWidth(1)
            context.addPath(CGPath(
                roundedRect: page.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: corner, cornerHeight: corner, transform: nil
            ))
            context.strokePath()

            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: page.minX + 2, y: page.midY - 1.6, width: page.width - 4, height: 3.2))

            // A second, shorter bar while a document is being redacted, so the bar does not
            // have to animate to show the app is busy.
            if working {
                context.fill(CGRect(x: page.minX + 2, y: page.minY + 2.4, width: page.width - 7, height: 2.2))
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = working ? "Blackline — redacting" : "Blackline"
        return image
    }
}

extension Image {
    /// Keeps the artwork's own colours; SwiftUI would otherwise tint it like a symbol.
    public static func blacklineMenuBar(working: Bool) -> some View {
        Image(nsImage: MenuBarIcon.image(working: working))
            .renderingMode(.original)
    }
}
