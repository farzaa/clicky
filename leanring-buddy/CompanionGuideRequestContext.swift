//
//  CompanionGuideRequestContext.swift
//  leanring-buddy
//
//  Builds metadata-only request context for Spider guide calls. This keeps
//  screen identity and guided polling context out of CompanionManager.
//

import CryptoKit
import Foundation

struct CompanionGuideRequestContext {
    let screenSignature: String
    let screenChanged: Bool
    let outboundTranscript: String
    let guidedSessionContext: SpiderGuidedSessionContext?
}

enum CompanionGuideRequestContextBuilder {
    static func build(
        transcript: String,
        screenCaptures: [CompanionScreenCapture],
        guidedSetupSession: GuidedSetupSession?,
        guidedSetupPollIndex: Int?
    ) -> CompanionGuideRequestContext {
        let screenSignature = screenSignature(for: screenCaptures)
        let screenChanged = guidedSetupPollIndex.map { _ in
            guidedSetupSession?.screenChanged(for: screenSignature) ?? true
        } ?? true
        let outboundTranscript = guidedSetupPollIndex.map {
            GuidedSetupPromptComposer.transcript(
                transcript,
                addingSessionContextFrom: guidedSetupSession,
                screenSignature: screenSignature,
                pollIndex: $0
            )
        } ?? transcript

        return CompanionGuideRequestContext(
            screenSignature: screenSignature,
            screenChanged: screenChanged,
            outboundTranscript: outboundTranscript,
            guidedSessionContext: GuidedSetupPromptComposer.sessionContext(
                from: guidedSetupSession,
                screenSignature: screenSignature
            )
        )
    }

    static func screenSignature(for screenCaptures: [CompanionScreenCapture]) -> String {
        screenCaptures.map { capture in
            let digest = SHA256.hash(data: capture.imageData)
            let digestPrefix = digest.prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            return [
                capture.label,
                "\(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels)",
                digestPrefix,
            ].joined(separator: ":")
        }
        .joined(separator: "|")
    }
}
