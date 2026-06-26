//
//  GuidedSetupSession.swift
//  leanring-buddy
//
//  Ephemeral state for the screen-guidance polling loop. This state never
//  stores screenshots or user-entered values; it only keeps local metadata
//  needed to keep the companion from repeating stale guidance.
//

import Foundation

struct GuidedSetupSession {
    let sessionId: UUID
    let platformId: SpiderAdPlatformID
    var currentScreenState: SpiderGuideScreenState
    var currentScreenId: String
    var currentStageId: String
    var confidence: SpiderGuideConfidence
    var lastScreenSignature: String?
    var lastSemanticSignature: String?
    var lastGroundingRevision: GroundingRevision?
    var lastPoint: SpiderGuidePoint?
    var pendingPointOutcome: PendingGuidePointOutcome?
    var pendingPreDotVerification: PendingPreDotVerification?
    var negativeMemories: [GroundingNegativeMemoryEntry]
    var lastFailedPointOutcome: PendingGuidePointOutcome?
    var lastGroundingOutcomeDecision: GroundingOutcomeDecision?
    var lastPointOutcomeStatus: GuidedPointOutcomeStatus?
    var lastDisplayText: String
    var pollIndex: Int
    var consecutiveLoadingCount: Int
    var consecutiveUnknownCount: Int
    var consecutiveUnchangedCount: Int
    var consecutiveChangedLoadingCount: Int
    let startedAt: Date
    var lastRecognizedAt: Date?

    init(
        sessionId: UUID = UUID(),
        platformId: SpiderAdPlatformID,
        startedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.platformId = platformId
        self.currentScreenState = .unknown
        self.currentScreenId = "unknown_screen"
        self.currentStageId = "unknown_stage"
        self.confidence = .low
        self.lastScreenSignature = nil
        self.lastSemanticSignature = nil
        self.lastGroundingRevision = nil
        self.lastPoint = nil
        self.pendingPointOutcome = nil
        self.pendingPreDotVerification = nil
        self.negativeMemories = []
        self.lastFailedPointOutcome = nil
        self.lastGroundingOutcomeDecision = nil
        self.lastPointOutcomeStatus = nil
        self.lastDisplayText = ""
        self.pollIndex = 1
        self.consecutiveLoadingCount = 0
        self.consecutiveUnknownCount = 0
        self.consecutiveUnchangedCount = 0
        self.consecutiveChangedLoadingCount = 0
        self.startedAt = startedAt
        self.lastRecognizedAt = nil
    }

    var shouldForceLoadingReclassification: Bool {
        consecutiveChangedLoadingCount >= 2
    }

    mutating func nextPollIndex(maximumAutomaticPolls: Int) -> Int? {
        guard pollIndex <= maximumAutomaticPolls else {
            return nil
        }

        defer { pollIndex += 1 }
        return pollIndex
    }

    func screenChanged(for screenSignature: String) -> Bool {
        lastScreenSignature.map { $0 != screenSignature } ?? true
    }

    mutating func record(
        response: SpiderGuideResponse,
        screenSignature: String,
        resolvedScreenState: SpiderGuideScreenState,
        screenChanged: Bool,
        acceptedPoint: SpiderGuidePoint?,
        acceptedPointTargetElementIdHash: String?,
        acceptedPointTargetFingerprint: TargetFingerprint?,
        pollIndex: Int? = nil,
        receivedAt: Date = Date()
    ) {
        consecutiveUnchangedCount = screenChanged ? 0 : consecutiveUnchangedCount + 1

        switch resolvedScreenState {
        case .loading:
            consecutiveLoadingCount += 1
            consecutiveUnknownCount = 0
            if screenChanged {
                consecutiveChangedLoadingCount += 1
            }
        case .unknown:
            consecutiveUnknownCount += 1
            consecutiveLoadingCount = 0
            consecutiveChangedLoadingCount = 0
        case .recognized, .blocked:
            consecutiveLoadingCount = 0
            consecutiveUnknownCount = 0
            consecutiveChangedLoadingCount = 0
        }

        if resolvedScreenState == .recognized {
            lastRecognizedAt = receivedAt
        }

        currentScreenState = resolvedScreenState
        let currentIdentity = GuidedSetupScreenIdentityResolver.currentIdentity(
            from: response,
            resolvedScreenState: resolvedScreenState
        )
        currentScreenId = currentIdentity.screenId
        currentStageId = currentIdentity.stageId
        confidence = response.screenConfidence ?? response.confidence
        lastPoint = response.point
        lastSemanticSignature = response.semanticGrounding?.semanticSignature
        lastDisplayText = response.displayText
        lastScreenSignature = screenSignature
        let currentGroundingRevision = GroundingRevision(
            screenSignature: screenSignature.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
            ),
            semanticSignature: response.semanticGrounding?.semanticSignature?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
            ),
            groundingRevision: response.semanticGrounding?.groundingRevision?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
            ),
            observedAt: receivedAt,
            pollIndex: pollIndex
        )
        lastGroundingRevision = currentGroundingRevision

        if let acceptedPoint {
            let expectedOutcomeEvidence = ExpectedOutcomeEvidence(
                acceptedPoint: acceptedPoint,
                targetElementIdHash: acceptedPointTargetElementIdHash,
                targetFingerprint: acceptedPointTargetFingerprint,
                startingScreenId: currentScreenId,
                startingStageId: currentStageId,
                startingSemanticSignature: response.semanticGrounding?.semanticSignature?.spiderSanitizedSingleLine(
                    maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
                ),
                startingGroundingRevision: currentGroundingRevision
            )
            pendingPointOutcome = PendingGuidePointOutcome(
                expectedOutcomeEvidence: expectedOutcomeEvidence,
                attemptCount: 1
            )
            lastFailedPointOutcome = nil
            lastGroundingOutcomeDecision = nil
            lastPointOutcomeStatus = nil
        }
    }

    mutating func evaluatePendingPointOutcome(
        response: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState,
        screenChanged: Bool
    ) -> GroundingOutcomeDecision? {
        guard let pendingPointOutcome else { return nil }

        let outcomeDecision = GuidedSetupOutcomeDecisionBuilder.decision(
            pendingPointOutcome: pendingPointOutcome,
            response: response,
            resolvedScreenState: resolvedScreenState,
            screenChanged: screenChanged
        )

        switch outcomeDecision.outcomeStatus {
        case .confirmed:
            self.pendingPointOutcome = nil
            lastFailedPointOutcome = nil
            lastGroundingOutcomeDecision = outcomeDecision
        case .failed:
            self.pendingPointOutcome = nil
            lastFailedPointOutcome = pendingPointOutcome
            lastGroundingOutcomeDecision = outcomeDecision
            rememberNegativeOutcome(
                pendingPointOutcome,
                reason: .failedOutcome
            )
        case .stale:
            self.pendingPointOutcome = nil
            lastFailedPointOutcome = pendingPointOutcome
            lastGroundingOutcomeDecision = outcomeDecision
            rememberNegativeOutcome(
                pendingPointOutcome,
                reason: .stale
            )
        case .unclear:
            lastGroundingOutcomeDecision = outcomeDecision
            break
        }

        lastPointOutcomeStatus = outcomeDecision.outcomeStatus
        return outcomeDecision
    }

    func shouldRejectRepeatedFailedPoint(_ response: SpiderGuideResponse) -> Bool {
        guard let failed = lastFailedPointOutcome,
              let retryPolicy = lastGroundingOutcomeDecision?.retryPolicy,
              retryPolicy.doNotRepeatUntilSignatureChanges,
              !retryPolicy.allowRetry,
              let point = response.point else {
            return false
        }

        let expectedEvidence = failed.expectedOutcomeEvidence
        let nextStageId = response.stageId?.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
        ) ?? ""
        let nextSemanticSignature = response.semanticGrounding?.semanticSignature?.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
        )
        let stageChanged = !nextStageId.isEmpty && nextStageId != expectedEvidence.startingStageId
        let semanticSignatureChanged = nextSemanticSignature != nil
            && expectedEvidence.startingSemanticSignature != nil
            && nextSemanticSignature != expectedEvidence.startingSemanticSignature

        if stageChanged || semanticSignatureChanged {
            return false
        }

        let nextTargetElementIdHash = SpiderGroundingPrivacy.targetElementIdHash(for: point.targetElementId)
        if let expectedTargetElementIdHash = expectedEvidence.targetElementIdHash {
            return nextTargetElementIdHash == expectedTargetElementIdHash
        }

        if let expectedTargetFingerprint = expectedEvidence.targetFingerprint,
           let nextTarget = response.semanticGrounding?.target(matching: point),
           let nextTargetFingerprint = TargetFingerprint.make(
               target: nextTarget,
               grounding: response.semanticGrounding,
               stageId: response.stageId,
               expectedOutcome: expectedEvidence.expectedOutcome
           ) {
            return expectedTargetFingerprint.isCompatible(with: nextTargetFingerprint)
        }

        return nextTargetElementIdHash == nil
    }

    func shouldSuppressRepeatedBubble(for response: SpiderGuideResponse, screenChanged: Bool) -> Bool {
        !screenChanged && response.displayText == lastDisplayText
    }
}
