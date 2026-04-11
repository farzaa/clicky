import SwiftUI

/// Tappable cursor + “Deb” — use for back / home / sign-out instead of a separate trailing control.
struct DebilBrandButton: View {
    var action: () -> Void
    /// Sized to sit inside the 34pt accent chip (same family as section icons on My Courses / New course).
    var markSize: CGFloat = 20
    var titleSize: CGFloat = 14
    /// e.g. "Sign out" on dashboard, "Back" elsewhere.
    var accessibilityLabelText: String = "Back"

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DebBuddyMarkView(
                    palette: .inApp,
                    rotationDegrees: 0,
                    scale: 1,
                    glowRadiusExtension: 0,
                    chipSide: 34,
                    iconMaxSize: min(markSize, 22)
                )
                Text("Deb")
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(DS.foreground)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.trailing, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabelText)
    }
}
