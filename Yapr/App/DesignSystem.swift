//
//  DesignSystem.swift
//  Yapr
//
//  Design tokens for the iOS app. Trimmed-down adaptation of the macOS
//  Clicky design system, keeping just the colors and corner radii used
//  by the v1 iOS UI. Brand blue intentionally matches the macOS app
//  so screenshots, marketing, and shared UI elements feel consistent
//  across platforms.
//

import SwiftUI

enum DS {
    enum Colors {
        /// Near-black panel/screen background. Almost matches the macOS
        /// menu bar panel background so the brand reads consistently.
        static let background = Color(red: 0.07, green: 0.07, blue: 0.08)

        /// Slightly lighter surface used for cards (the screenshot preview,
        /// permission gate, etc.) so depth is visible against `background`.
        static let surface = Color(red: 0.11, green: 0.11, blue: 0.13)

        /// The signature Yapr/Clicky blue. Used for the voice orb, the
        /// pointing dot on the screenshot, and primary call-to-action buttons.
        static let brandBlue = Color(red: 0.31, green: 0.59, blue: 1.0)

        /// Same blue with a subtle warmer tint for gradients on the orb.
        static let brandBlueDeep = Color(red: 0.18, green: 0.41, blue: 0.92)

        /// Primary body text — high contrast against `background`.
        static let textPrimary = Color.white

        /// Secondary text used for labels and secondary copy.
        static let textSecondary = Color(red: 0.78, green: 0.80, blue: 0.84)

        /// Tertiary text used for hints, captions, and inactive states.
        static let textTertiary = Color(red: 0.55, green: 0.57, blue: 0.62)

        /// Success indicator color (e.g. permission granted dot).
        static let success = Color(red: 0.31, green: 0.84, blue: 0.51)

        /// Warning indicator color (permission missing).
        static let warning = Color(red: 0.95, green: 0.71, blue: 0.30)

        /// Hairline borders on cards and dividers.
        static let borderSubtle = Color.white.opacity(0.08)
    }

    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 14
        static let large: CGFloat = 20
        static let xlarge: CGFloat = 28
    }
}
