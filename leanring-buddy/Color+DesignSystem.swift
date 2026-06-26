//
//  Color+DesignSystem.swift
//  leanring-buddy
//
//  Color construction and adjustment helpers used by Spider design tokens.
//

import AppKit
import SwiftUI

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let componentR = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let componentG = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let componentB = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: componentR, green: componentG, blue: componentB)
    }

    /// Returns a lighter version of this color by blending toward white.
    func blendedWithWhite(fraction: Double) -> Color {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let componentR = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let componentG = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let componentB = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: componentR, green: componentG, blue: componentB)
    }
}
