import SwiftUI

/// Deb brand mark (glyph only).
struct CursorMarkView: View {
    var size: CGFloat = 24

    var body: some View {
        Image("deb-logo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(DS.foreground)
    }
}

// MARK: - Chip + logo (shared by in-app chrome and screen buddy)

enum DebBuddyMarkPalette {
    /// Same silhouette as `DebilBrandButton`: neutral chip + logo.
    case inApp
    /// Full-screen buddy: floating logo + glow (`DS.Colors.overlayCursorBlue`).
    case screenOverlay
}

/// Deb buddy mark shared across in-app and overlay contexts.
struct DebBuddyMarkView: View {
    var palette: DebBuddyMarkPalette
    var rotationDegrees: Double = -35
    var scale: CGFloat = 1
    /// Extra glow radius on top of the base overlay shadow (flight “swoop”).
    var glowRadiusExtension: CGFloat = 0
    var chipSide: CGFloat = 34
    var iconMaxSize: CGFloat = 22

    private var inAppIconSize: CGFloat {
        min(iconMaxSize, chipSide * 0.65)
    }

    private var overlayIconSize: CGFloat {
        max(iconMaxSize, chipSide)
    }

    /// Matches `DebilBrandButton` (8pt radius at 34pt chip).
    private var cornerRadius: CGFloat {
        chipSide * (8.0 / 34.0)
    }

    private var iconColor: Color {
        switch palette {
        case .inApp:
            return DS.foreground
        case .screenOverlay:
            return .white
        }
    }

    private var usesInAppChip: Bool {
        switch palette {
        case .inApp:
            return true
        case .screenOverlay:
            return false
        }
    }

    var body: some View {
        ZStack {
            if usesInAppChip {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DS.accent.opacity(0.5))
                    .frame(width: chipSide, height: chipSide)
            }
            Image("deb-logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(
                    width: usesInAppChip ? inAppIconSize : overlayIconSize,
                    height: usesInAppChip ? inAppIconSize : overlayIconSize
                )
                .foregroundStyle(iconColor)
        }
        .rotationEffect(.degrees(rotationDegrees))
        .scaleEffect(scale)
        .shadow(
            color: palette == .screenOverlay ? DS.Colors.overlayCursorBlue : .clear,
            radius: palette == .screenOverlay ? 8 + glowRadiusExtension : 0,
            x: 0,
            y: 0
        )
    }
}
