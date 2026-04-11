import SwiftUI

/// Lucide `MousePointer2` equivalent — cursor buddy mark (glyph only).
struct CursorMarkView: View {
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: size * 0.85, weight: .medium))
            .foregroundStyle(DS.foreground)
            .symbolRenderingMode(.monochrome)
    }
}

// MARK: - Chip + cursor (shared by in-app chrome and screen buddy)

enum DebBuddyMarkPalette {
    /// Same silhouette as `DebilBrandButton`: neutral chip + light arrow.
    case inApp
    /// Full-screen buddy: green chip + glow (`DS.Colors.overlayCursorBlue`).
    case screenOverlay
}

/// Rounded chip + SF Symbol `cursorarrow` — the canonical Deb “buddy” mark.
struct DebBuddyMarkView: View {
    var palette: DebBuddyMarkPalette
    var rotationDegrees: Double = -35
    var scale: CGFloat = 1
    /// Extra glow radius on top of the base overlay shadow (flight “swoop”).
    var glowRadiusExtension: CGFloat = 0
    var chipSide: CGFloat = 34
    var iconMaxSize: CGFloat = 22

    private var iconSize: CGFloat {
        min(iconMaxSize, chipSide * 0.65)
    }

    /// Matches `DebilBrandButton` (8pt radius at 34pt chip).
    private var cornerRadius: CGFloat {
        chipSide * (8.0 / 34.0)
    }

    private var chipFill: Color {
        switch palette {
        case .inApp:
            return DS.accent.opacity(0.5)
        case .screenOverlay:
            return DS.Colors.overlayCursorBlue.opacity(0.5)
        }
    }

    private var iconColor: Color {
        switch palette {
        case .inApp:
            return DS.foreground
        case .screenOverlay:
            return .white
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(chipFill)
                .frame(width: chipSide, height: chipSide)
            Image(systemName: "cursorarrow")
                .font(.system(size: iconSize * 0.85, weight: .medium))
                .foregroundStyle(iconColor)
                .symbolRenderingMode(.monochrome)
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
