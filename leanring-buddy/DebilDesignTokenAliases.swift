import Combine
import SwiftUI

/// Compatibility aliases so the DebilMac frontend tokens map onto the
/// existing project design system.
extension DS {
    static var background: Color { Colors.background }
    static var foreground: Color { Colors.textPrimary }
    static var card: Color { Colors.surface1 }
    static var secondary: Color { Colors.surface2 }
    static var mutedForeground: Color { Colors.textSecondary }
    static var accent: Color { Colors.surface3 }
    static var border: Color { Colors.borderSubtle }
    static var success: Color { Colors.success }
    static var warning: Color { Colors.warning }
    static var destructive: Color { Colors.destructive }
    static var cornerRadius: CGFloat { CornerRadius.extraLarge }
}
