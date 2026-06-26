//
//  CompanionGuideRequestContextTests.swift
//  leanring-buddyTests
//
//  Tests for metadata-only guide request context assembly.
//

import CoreGraphics
import Foundation
import Testing
@testable import Spider

struct CompanionGuideRequestContextTests {
    @Test func screenSignatureUsesOnlyCaptureMetadataAndImageDigestPrefix() {
        let captures = [
            screenCapture(
                imageData: Data([0x01, 0x02]),
                label: "cursor-screen",
                screenshotWidthInPixels: 200,
                screenshotHeightInPixels: 120
            ),
            screenCapture(
                imageData: Data([0x03, 0x04]),
                label: "secondary-screen",
                screenshotWidthInPixels: 300,
                screenshotHeightInPixels: 160
            ),
        ]

        #expect(
            CompanionGuideRequestContextBuilder.screenSignature(for: captures)
            == "cursor-screen:200x120:a12871fee210fb86|secondary-screen:300x160:0ce3940bebf2b22a"
        )
    }

    @Test func nonPollingRequestKeepsTranscriptAndHasNoSessionContext() {
        let context = CompanionGuideRequestContextBuilder.build(
            transcript: "What should I click next?",
            screenCaptures: [screenCapture()],
            guidedSetupSession: nil,
            guidedSetupPollIndex: nil
        )

        #expect(context.outboundTranscript == "What should I click next?")
        #expect(context.screenChanged)
        #expect(context.guidedSessionContext?.currentScreenSignature == nil)
    }

    @Test func pollingRequestAddsGuidedSessionContextAndPreservesScreenChangedFlag() {
        let captures = [screenCapture(imageData: Data([0x01, 0x02]))]
        let screenSignature = CompanionGuideRequestContextBuilder.screenSignature(for: captures)
        var guidedSetupSession = GuidedSetupSession(platformId: .metaAds)
        guidedSetupSession.lastScreenSignature = screenSignature

        let context = CompanionGuideRequestContextBuilder.build(
            transcript: "Poll the current screen.",
            screenCaptures: captures,
            guidedSetupSession: guidedSetupSession,
            guidedSetupPollIndex: 2
        )

        #expect(!context.screenChanged)
        #expect(context.outboundTranscript.contains("Poll the current screen."))
        #expect(context.outboundTranscript.contains("pollIndex=2"))
        #expect(context.outboundTranscript.contains("screenChanged=false"))
        #expect(context.outboundTranscript.contains("forceLoadingReclassification"))
        #expect(context.guidedSessionContext?.currentScreenSignature == screenSignature)
        #expect(context.guidedSessionContext?.screenChanged == false)
    }

    private func screenCapture(
        imageData: Data = Data([0x01, 0x02]),
        label: String = "cursor-screen",
        screenshotWidthInPixels: Int = 200,
        screenshotHeightInPixels: Int = 120
    ) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: imageData,
            label: label,
            isCursorScreen: true,
            displayWidthInPoints: 200,
            displayHeightInPoints: 120,
            displayFrame: CGRect(x: 0, y: 0, width: 200, height: 120),
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels
        )
    }
}
