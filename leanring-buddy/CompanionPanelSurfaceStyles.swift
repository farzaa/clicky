//
//  CompanionPanelSurfaceStyles.swift
//  leanring-buddy
//
//  Shared panel surfaces and AppKit edge helpers for the menu bar panel.
//

import AppKit
import SwiftUI

enum CompanionPanelSurface {
    static var assetDivider: some View {
        Divider()
            .background(DS.SpiderPanel.Colors.divider)
    }

    static var assetCard: some View {
        let shape = RoundedRectangle(cornerRadius: DS.SpiderPanel.Radius.card, style: .continuous)
        let shadow = DS.SpiderPanel.Shadows.card

        return shape
            .fill(DS.SpiderPanel.Colors.assetSurface)
            .companionPanelLiquidGlass(in: shape, tint: DS.SpiderPanel.Colors.assetGlassTint, interactive: true)
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.06),
                            Color.black.opacity(0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: DS.SpiderPanel.Stroke.hairline
                )
            )
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    static var primaryActionCard: some View {
        let shape = RoundedRectangle(cornerRadius: DS.SpiderPanel.Radius.card, style: .continuous)
        let shadow = DS.SpiderPanel.Shadows.primaryCard

        return shape
            .fill(DS.SpiderPanel.Colors.primaryActionSurface)
            .companionPanelLiquidGlass(
                in: shape,
                tint: DS.SpiderPanel.Colors.primaryActionTint.opacity(0.18),
                interactive: true
            )
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.24),
                            DS.SpiderPanel.Colors.accent.opacity(0.14),
                            Color.black.opacity(0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: DS.SpiderPanel.Stroke.hairline
                )
            )
            .shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }

    static var secondaryPillBackground: some View {
        let shape = Capsule(style: .continuous)

        return shape
            .fill(DS.SpiderPanel.Colors.secondaryControlSurface)
            .companionPanelLiquidGlass(
                in: shape,
                tint: DS.SpiderPanel.Colors.secondaryControlTint,
                interactive: true
            )
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: DS.SpiderPanel.Stroke.pill))
    }

    static var liquidCircleBackground: some View {
        let shape = Circle()

        return shape
            .fill(DS.SpiderPanel.Colors.iconSurface)
            .companionPanelLiquidGlass(in: shape, tint: DS.SpiderPanel.Colors.iconTint, interactive: true)
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: DS.SpiderPanel.Stroke.circle))
    }

    static func primaryPillBackground(isEnabled: Bool) -> some View {
        let shape = Capsule(style: .continuous)
        let enabledTint = DS.SpiderPanel.Colors.accent.opacity(0.72)
        let disabledTint = DS.SpiderPanel.Colors.accent.opacity(0.28)

        return shape
            .fill(isEnabled ? DS.SpiderPanel.Colors.accent : DS.SpiderPanel.Colors.accent.opacity(0.45))
            .companionPanelLiquidGlass(in: shape, tint: isEnabled ? enabledTint : disabledTint, interactive: isEnabled)
            .overlay(
                shape.stroke(Color.white.opacity(isEnabled ? 0.30 : 0.14), lineWidth: DS.SpiderPanel.Stroke.pill)
            )
    }

    static func signInPillBackground(isEnabled: Bool) -> some View {
        let shape = Capsule(style: .continuous)
        let tint = Color.white.opacity(isEnabled ? 0.72 : 0.28)

        return shape
            .fill(Color.white.opacity(isEnabled ? 0.92 : 0.42))
            .companionPanelLiquidGlass(in: shape, tint: tint, interactive: isEnabled)
            .overlay(
                shape.stroke(Color.white.opacity(isEnabled ? 0.34 : 0.12), lineWidth: DS.SpiderPanel.Stroke.pill)
            )
    }

    static func panelHighlight(in shape: RoundedRectangle) -> some View {
        shape
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.26),
                        Color.white.opacity(0.07),
                        Color.black.opacity(0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: DS.SpiderPanel.Stroke.hairline
            )
            .overlay(
                shape
                    .stroke(Color.white.opacity(0.06), lineWidth: DS.SpiderPanel.Stroke.softGlow)
                    .blur(radius: 1.6)
                    .offset(y: 1)
            )
    }
}

extension View {
    func panelDragHandle() -> some View {
        overlay(PanelDragHandleView())
    }

    @ViewBuilder
    func companionPanelLiquidGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(companionPanelGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.8))
        }
    }

    @available(macOS 26.0, *)
    private func companionPanelGlass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular.tint(tint)
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

private struct PanelDragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PanelDragHandleNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class PanelDragHandleNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
