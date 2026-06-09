//
//  ScreenshotPreviewView.swift
//  Yapr
//
//  Renders the user's most-recent iPhone screenshot inside a card. When
//  Claude includes a `[POINT:x,y]` tag in its response, this view animates
//  a pulsing blue dot at the parsed location so the user can see exactly
//  where Yapr is pointing.
//
//  Coordinates from Claude are in the screenshot's *pixel* space, so we
//  divide by the natural pixel dimensions and multiply by the displayed
//  frame to land the dot in the right place no matter what size the
//  preview ends up at.
//

import SwiftUI
import UIKit

struct ScreenshotPreviewView: View {
    let fetchedScreenshot: RecentScreenshotProvider.FetchedScreenshot?
    let pointingTarget: PointingParseResult?

    /// Drives the pulsing dot animation once the pointing target lands.
    @State private var pointingDotPulsePhase: CGFloat = 0

    var body: some View {
        Group {
            if let fetchedScreenshot {
                screenshotCard(for: fetchedScreenshot)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Subviews

    private func screenshotCard(for fetchedScreenshot: RecentScreenshotProvider.FetchedScreenshot) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Image(uiImage: fetchedScreenshot.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )

                if let pointingTarget,
                   let pointingCoordinateInPixels = pointingTarget.coordinate {
                    pointingDot(
                        atPixelCoordinate: pointingCoordinateInPixels,
                        pixelWidth: CGFloat(fetchedScreenshot.pixelWidth),
                        pixelHeight: CGFloat(fetchedScreenshot.pixelHeight),
                        availableSize: geometry.size
                    )
                }
            }
        }
        .aspectRatio(
            CGFloat(fetchedScreenshot.pixelWidth) / max(CGFloat(fetchedScreenshot.pixelHeight), 1),
            contentMode: .fit
        )
        .onChange(of: pointingTarget?.coordinate) { _, newPointingCoordinate in
            guard newPointingCoordinate != nil else { return }
            pointingDotPulsePhase = 0
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pointingDotPulsePhase = 1
            }
        }
    }

    private func pointingDot(
        atPixelCoordinate pointingCoordinateInPixels: CGPoint,
        pixelWidth: CGFloat,
        pixelHeight: CGFloat,
        availableSize: CGSize
    ) -> some View {
        // Map the pixel coordinate into the displayed frame's coordinate space,
        // accounting for `aspectRatio(contentMode: .fit)` letterboxing inside
        // the card so the dot doesn't drift on non-matching aspect ratios.
        let imageAspect = pixelWidth / max(pixelHeight, 1)
        let frameAspect = availableSize.width / max(availableSize.height, 1)

        let displayedImageWidth: CGFloat
        let displayedImageHeight: CGFloat
        if imageAspect > frameAspect {
            displayedImageWidth = availableSize.width
            displayedImageHeight = availableSize.width / imageAspect
        } else {
            displayedImageHeight = availableSize.height
            displayedImageWidth = availableSize.height * imageAspect
        }

        let horizontalLetterbox = (availableSize.width - displayedImageWidth) / 2
        let verticalLetterbox = (availableSize.height - displayedImageHeight) / 2

        let normalizedX = pointingCoordinateInPixels.x / max(pixelWidth, 1)
        let normalizedY = pointingCoordinateInPixels.y / max(pixelHeight, 1)

        let dotCenterX = horizontalLetterbox + (normalizedX * displayedImageWidth)
        let dotCenterY = verticalLetterbox + (normalizedY * displayedImageHeight)

        return ZStack {
            Circle()
                .fill(DS.Colors.brandBlue.opacity(0.30))
                .frame(width: 64, height: 64)
                .scaleEffect(0.7 + (pointingDotPulsePhase * 0.6))
                .opacity(1.0 - (pointingDotPulsePhase * 0.6))

            Circle()
                .fill(DS.Colors.brandBlue)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.85), lineWidth: 2)
                )
                .shadow(color: DS.Colors.brandBlue.opacity(0.7), radius: 12)
        }
        .position(x: dotCenterX, y: dotCenterY)
        .accessibilityLabel(pointingTarget?.elementLabel.map { "Pointing at \($0)" } ?? "Pointing")
    }

    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )

            VStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(DS.Colors.textTertiary)
                Text("take a screenshot, then come back")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                Text("press the side button + volume up — yapr will use your most recent one.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(24)
        }
        .aspectRatio(9.0/19.5, contentMode: .fit)
    }
}
