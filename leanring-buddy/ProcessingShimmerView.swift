//
//  ProcessingShimmerView.swift
//  leanring-buddy
//
//  Apple-Intelligence-style screen-edge shimmer rendered while the AI
//  is processing a request. A multi-color angular gradient (purple,
//  magenta, cyan, green) fills a full-screen rectangle, masked so only
//  a soft glow at the screen edges is visible — the interior of the
//  screen stays untouched. The gradient continuously rotates so the
//  colors flow around the perimeter, giving the same "the system is
//  thinking" feedback Apple uses on iOS/macOS.
//
//  Visual recipe (see comments inline for the math):
//    1. Render an angular gradient on a rectangle that fills the screen.
//    2. Apply a heavy blur so the colors bleed and feel atmospheric.
//    3. Mask with a stroked rectangle (thick stroke + blur) so only the
//       edge band shows, fading toward the center.
//    4. Animate the gradient's start angle around 360° with a linear
//       repeat-forever timer for the continuous "shimmer" loop.
//

import SwiftUI

struct ProcessingShimmerView: View {
    /// Drives the angular gradient's rotation. Animated from 0 → 360 in
    /// a linear repeating loop on appear.
    @State private var rotationDegrees: Double = 0

    /// Multi-stop gradient palette inspired by Apple Intelligence:
    /// purple → magenta → cyan → green → back to purple. The duplicated
    /// purple at the end ensures a seamless loop when the gradient
    /// rotates through 360°.
    private static let shimmerColors: [Color] = [
        Color(red: 0.62, green: 0.10, blue: 1.0),  // bright purple
        Color(red: 1.0, green: 0.20, blue: 0.85),  // magenta
        Color(red: 0.10, green: 0.85, blue: 1.0),  // cyan
        Color(red: 0.20, green: 1.0, blue: 0.55),  // green
        Color(red: 0.62, green: 0.10, blue: 1.0)   // purple (loops)
    ]

    /// Width of the gradient stroke at the screen edge. Combined with
    /// `edgeGlowBlurRadius`, this controls how far inside the screen
    /// the glow reaches: visible glow extends roughly
    /// `strokeWidth + blurRadius` from the screen's outer edge.
    private static let strokeWidth: CGFloat = 6

    /// Blur applied to the stroked rectangle. Soft, but not so soft
    /// that the glow bleeds far into the workspace. With these values
    /// the visible glow caps at ~22px from the screen edge.
    private static let edgeGlowBlurRadius: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            // The whole effect is just: stroke the screen rectangle with
            // an angular gradient, blur lightly, animate the rotation.
            // No mask, no compositing group, no inner padding tricks —
            // a thin gradient line + soft blur is the entire shimmer.
            Rectangle()
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: Self.shimmerColors),
                        center: .center,
                        angle: .degrees(rotationDegrees)
                    ),
                    lineWidth: Self.strokeWidth
                )
                .blur(radius: Self.edgeGlowBlurRadius)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .transition(.opacity)
                .onAppear {
                    // Continuous linear rotation. 6s per full loop keeps
                    // the motion noticeable without being distracting.
                    withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                        rotationDegrees = 360
                    }
                }
        }
        .ignoresSafeArea()
    }
}
