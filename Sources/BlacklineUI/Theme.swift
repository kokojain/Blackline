import SwiftUI

/// The app's palette and metrics.
///
/// Deliberately close to the system's own: Blackline is a small utility that lives in the
/// menu bar, and a utility that invents its own chrome reads as untrustworthy. Semantic
/// colours carry meaning that must survive for someone who cannot see them, so every place
/// one is used pairs it with a glyph and a word — never colour alone.
public enum Theme {
    static let accent = Color(nsColor: .controlAccentColor)

    /// Something was examined and came back clean.
    static let ok = Color(red: 0.24, green: 0.55, blue: 0.35)
    /// Something was NOT checked. Reserved for that meaning alone, so it keeps its force.
    static let warn = Color(red: 0.60, green: 0.40, blue: 0.05)
    static let warnFill = Color(red: 0.99, green: 0.96, blue: 0.89)
    static let warnBorder = Color(red: 0.89, green: 0.78, blue: 0.55)

    static let pageBacking = Color(nsColor: .underPageBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    static let railWidth: CGFloat = 186
    static let findingsWidth: CGFloat = 316
}

extension View {
    /// A control-sized capsule used for the small status chips in the toolbar and rows.
    func chip(_ tint: Color, filled: Bool = true) -> some View {
        font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(filled ? tint.opacity(0.13) : .clear, in: Capsule())
    }
}
