import SwiftUI

/// Matches cozy-letter-lab `index.css` dark theme (HSL → SwiftUI).
enum DS {
    static let background = Color(red: 0, green: 0, blue: 0)
    static let foreground = Color(red: 0.95, green: 0.95, blue: 0.95)
    static let card = Color(red: 0.06, green: 0.06, blue: 0.06)
    static let secondary = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let mutedForeground = Color(red: 0.55, green: 0.55, blue: 0.55)
    static let accent = Color(red: 0.15, green: 0.15, blue: 0.15)
    static let border = Color(red: 0.18, green: 0.18, blue: 0.18)
    static let success = Color(red: 0.2, green: 0.65, blue: 0.38)
    static let warning = Color(red: 0.95, green: 0.75, blue: 0.2)
    static let destructive = Color(red: 0.85, green: 0.35, blue: 0.35)
    static let cornerRadius: CGFloat = 12
}
