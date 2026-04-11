import SwiftUI

/// Thin top bar: tappable Debil only (VPN-style — no extra chrome on the right).
struct DebilHeaderBar: View {
    var onBrandTap: () -> Void
    var brandAccessibilityLabel: String = "Back"

    var body: some View {
        HStack {
            DebilBrandButton(action: onBrandTap, accessibilityLabelText: brandAccessibilityLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.border.opacity(0.45)).frame(height: 1)
        }
    }
}
