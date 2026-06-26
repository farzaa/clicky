//
//  DesignSystem.swift
//  leanring-buddy
//
//  Centralized design tokens for Spider. Concrete button styles, cursor
//  bridges, and color helpers live in sibling design-system files.
//

import SwiftUI

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────
        // Layered surfaces from deepest to most elevated.
        // Higher surfaces are lighter, creating a sense of depth.

        /// The deepest background — used for the main app window fill.
        static let background = Color(hex: "#101211")

        /// First elevation layer — used for cards, sidebar, top bar backgrounds.
        static let surface1 = Color(hex: "#171918")

        /// Second elevation layer — used for input fields, elevated cards, chat bubbles.
        static let surface2 = Color(hex: "#202221")

        /// Third elevation layer — used for hover backgrounds on interactive elements.
        static let surface3 = Color(hex: "#272A29")

        /// Fourth elevation layer — used for active/pressed states on interactive elements.
        static let surface4 = Color(hex: "#2E3130")

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — used for card outlines, dividers, input field borders.
        static let borderSubtle = Color(hex: "#373B39")

        /// Strong border — used for focused inputs, hovered card outlines.
        static let borderStrong = Color(hex: "#444947")

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = Color(hex: "#ECEEED")

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = Color(hex: "#ADB5B2")

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = Color(hex: "#6B736F")

        /// Text used on top of the green accent fill, like primary button labels.
        static let textOnAccent: Color = .white

        // ── Spider Green Scale ──────────────────────────────────────
        // Green is the only product accent family. Keep panels, controls,
        // overlays, status indicators, and highlights in this range.
        //
        // Usage guide:
        //   50–100  → Very subtle tinted backgrounds (selected rows, hover fills on dark surfaces)
        //   200–300 → Light text/icons on dark backgrounds, disabled states
        //   400     → Bright accent text, links, icons, chat user bubbles
        //   500     → Mid-tone fills, badges, secondary buttons
        //   600     → Primary action fills (buttons, toggles) — main accent
        //   700     → Hover/pressed state for primary actions
        //   800–900 → Deep backgrounds, dark overlays, header bars
        //   950     → Deepest green — near-black tinted backgrounds

        static let green50  = Color(hex: "#F0FFF3")
        static let green100 = Color(hex: "#DDFEE4")
        static let green200 = Color(hex: "#BDFFC7")
        static let green300 = Color(hex: "#A6F3B2")
        static let green400 = Color(hex: "#7FE391")
        static let green500 = Color(hex: "#51C96C")
        static let green600 = Color(hex: "#33A84F")
        static let green700 = Color(hex: "#237B3B")
        static let green800 = Color(hex: "#1A5C30")
        static let green900 = Color(hex: "#10391F")
        static let green950 = Color(hex: "#081F12")

        // ── Accent (derived from Spider green) ──────────────────────

        /// Accent fill — used for solid button backgrounds and active guidance.
        static let accent = green200

        /// Accent hover — slightly deeper green for hover state.
        static let accentHover = green300

        /// Accent text — bright green used for links, active controls, and highlights.
        static let accentText = green300

        /// Very subtle accent tint — used for selected item backgrounds (e.g. current step
        /// in the sidebar). Low opacity so it doesn't overpower.
        static let accentSubtle = green500.opacity(0.12)

        // ── Semantic Colors ──────────────────────────────────────────

        /// Destructive/error actions — delete buttons, error messages, close button hover.
        static let destructive = Color(hex: "#E5484D")        // Radix Red 9

        /// Destructive hover state.
        static let destructiveHover = Color(hex: "#F2555A")   // Radix Red 10

        /// Destructive used for text on dark backgrounds (brighter for readability).
        static let destructiveText = Color(hex: "#FF6369")    // Radix Red 11

        /// Success — checkmarks, granted status, completion indicators.
        static let success = green400

        /// Warning — caution messages, manual verification failure explanations.
        static let warning = Color(hex: "#FFB224")            // Radix Amber 9

        /// Warning text — brighter variant for text on dark backgrounds.
        static let warningText = Color(hex: "#F1A10D")        // Radix Amber 11

        /// Info/feature highlight — used for prompt card headers and code highlights.
        static let info = Color(hex: "#9AF0A8")

        /// Inline code text color — slightly brighter green for monospace code snippets.
        static let codeText = Color(hex: "#C6FFD0")

        // ── Overlay Pointer ─────────────────────────────────────────

        /// The cursor/bubble color used in OverlayWindow.
        static let overlayPointer = accent

        // ── Help Chat ──────────────────────────────────────────────

        /// User message bubble background in the help chat.
        static let helpChatUserBubble = green800

        /// Slightly lighter variant for hover/pressed states on user bubbles.
        static let helpChatUserBubbleHover = green700

        /// Footer/backdrop behind the floating help chat.
        /// Slightly lighter than the main window background so the chat zone reads
        /// as a distinct docked surface even before the pill input is visible.
        static let helpChatBackdrop = Color(hex: "#212121")

        // ── Disabled State ───────────────────────────────────────────
        // Following Material Design 3's disabled pattern:
        // Container: onSurface at 12% opacity
        // Content: onSurface at 38% opacity

        /// Disabled button/container background.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            textPrimary.opacity(0.38)
        }
    }

    // MARK: - Spacing (for reference, not enforced)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Small elements like tags, badges.
        static let small: CGFloat = 6
        /// Buttons, input fields, small cards.
        static let medium: CGFloat = 8
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = 10
        /// Large panels, permission cards.
        static let extraLarge: CGFloat = 12
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }

    // MARK: - State Layer Opacities
    // Based on Material Design 3's state layer system.
    // A "state layer" overlays the button's content color at these opacities.

    enum StateLayer {
        /// Hover: subtle highlight to indicate interactivity.
        static let hover: Double = 0.08
        /// Focus: keyboard navigation indicator (slightly stronger than hover).
        static let focus: Double = 0.12
        /// Pressed: active press feedback (same strength as focus).
        static let pressed: Double = 0.12
        /// Dragged: strongest overlay (rarely used).
        static let dragged: Double = 0.16
    }

    // MARK: - Typography

    enum Typography {
        /// App typography is system-native. Do not ship custom fonts unless
        /// there is a brand reason strong enough to justify bundle weight.
        static let fontFamily = "SF Pro"

        static let panelBrand = Font.system(size: 14, weight: .medium)
        static let panelTitle = Font.system(size: 21, weight: .bold)
        static let panelHeader = Font.system(size: 20, weight: .bold)
        static let cardTitle = Font.system(size: 17, weight: .bold)
        static let rowTitle = Font.system(size: 16, weight: .bold)
        static let rowBody = Font.system(size: 14, weight: .medium)
        static let button = Font.system(size: 13, weight: .bold)
        static let caption = Font.system(size: 12, weight: .medium)
        static let micro = Font.system(size: 10, weight: .semibold)
        static let icon = Font.system(size: 20, weight: .semibold)
        static let iconLarge = Font.system(size: 24, weight: .semibold)
    }

    // MARK: - Effects

    struct ShadowToken {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    // MARK: - Spider Panel Tokens

    enum SpiderPanel {
        enum Layout {
            static let width: CGFloat = 360
            static let padding: CGFloat = 20
            static var contentWidth: CGFloat {
                width - (padding * 2)
            }
            static let stackSpacing: CGFloat = 16
            static let compactStackSpacing: CGFloat = 14
            static let actionStackSpacing: CGFloat = 12
            static let textStackSpacing: CGFloat = 4
            static let titleBodySpacing: CGFloat = 8
            static let lineSpacing: CGFloat = 1
            static let tightTitleLineSpacing: CGFloat = -1

            static let cardPadding: CGFloat = 18
            static let listHorizontalPadding: CGFloat = 18
            static let listVerticalPadding: CGFloat = 4
            static let settingsListVerticalPadding: CGFloat = 6

            static let campaignGoalRowSpacing: CGFloat = 2
            static let campaignGoalVerticalPadding: CGFloat = 10
            static let campaignGoalDividerIndent: CGFloat = 39
            static let campaignGoalRowHeight: CGFloat = 62

            static let valueRowHeight: CGFloat = 55
            static let settingsRowHeight: CGFloat = 48
            static let primaryActionHeight: CGFloat = 86
            static let secondaryActionHeight: CGFloat = 72
            static let footerButtonWidth: CGFloat = 100
            static let footerButtonHeight: CGFloat = 38
            static let primaryPillWidth: CGFloat = 84
            static let primaryPillHeight: CGFloat = 40
            static let textFieldHeight: CGFloat = 44
            static let headerDragHeight: CGFloat = 28
            static let wizardDragHeight: CGFloat = 32
        }

        enum Radius {
            static let chrome: CGFloat = 30
            static let card: CGFloat = 18
            static let control: CGFloat = 12
            static let compactControl: CGFloat = 6
        }

        enum Stroke {
            static let hairline: CGFloat = 0.8
            static let pill: CGFloat = 0.6
            static let circle: CGFloat = 0.7
            static let softGlow: CGFloat = 1.2
        }

        enum Colors {
            static let chromeTint = Color(hex: "#1A241C").opacity(0.42)
            static let accent = DS.Colors.green200
            static let accentText = Color(hex: "#1A2E21")
            static let primaryActionTint = Color(hex: "#66946F")
            static let primaryActionSurface = Color(hex: "#546B59").opacity(0.38)

            static let textPrimary = Color(hex: "#E8EDE8")
            static let textMuted = Color(hex: "#999F99")
            static let textFaint = Color(hex: "#5C635C")

            static let divider = Color.white.opacity(0.07)
            static let assetSurface = Color.white.opacity(0.035)
            static let assetGlassTint = Color.white.opacity(0.04)
            static let secondaryControlSurface = Color.white.opacity(0.05)
            static let secondaryControlTint = Color.white.opacity(0.05)
            static let iconSurface = Color.white.opacity(0.08)
            static let iconTint = Color.white.opacity(0.08)
            static let disabledOverlay = Color.white.opacity(0.42)
        }

        enum Shadows {
            static let chromePrimary = ShadowToken(
                color: Color.black.opacity(0.36),
                radius: 28,
                x: 0,
                y: 18
            )
            static let chromeSecondary = ShadowToken(
                color: Color.black.opacity(0.22),
                radius: 4,
                x: 0,
                y: 2
            )
            static let card = ShadowToken(
                color: Color.black.opacity(0.14),
                radius: 12,
                x: 0,
                y: 8
            )
            static let primaryCard = ShadowToken(
                color: Color.black.opacity(0.12),
                radius: 12,
                x: 0,
                y: 8
            )
        }
    }
}
