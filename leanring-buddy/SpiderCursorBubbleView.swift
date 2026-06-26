//
//  SpiderCursorBubbleView.swift
//  leanring-buddy
//
//  Shared visual treatment for Spider cursor speech bubbles.
//

import SwiftUI

struct SpiderCursorBubbleView<SizeKey: PreferenceKey>: View where SizeKey.Value == CGSize {
    let text: String
    let opacity: Double
    let position: CGPoint
    let scale: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat

    init(
        text: String,
        opacity: Double,
        position: CGPoint,
        scale: CGFloat = 1.0,
        shadowOpacity: Double = 0.5,
        shadowRadius: CGFloat = 6
    ) {
        self.text = text
        self.opacity = opacity
        self.position = position
        self.scale = scale
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.overlayPointer)
                    .shadow(
                        color: DS.Colors.overlayPointer.opacity(shadowOpacity),
                        radius: shadowRadius,
                        x: 0,
                        y: 0
                    )
            )
            .fixedSize()
            .overlay(
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: SizeKey.self, value: geometry.size)
                }
            )
            .scaleEffect(scale)
            .opacity(opacity)
            .position(position)
    }
}
