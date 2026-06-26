import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerMacOSOutcomeVerifierAssertions({ test, workerRoot }) {
  test("macOS outcome verifier blocks repeated failed targets until new evidence", () => {
    const managerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManager.swift"),
      "utf8"
    );
    const guidedSetupActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerGuidedSetupActions.swift"),
      "utf8"
    );
    const visionGuideActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerVisionGuideActions.swift"),
      "utf8"
    );
    const analyticsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderAnalytics.swift"),
      "utf8"
    );
    const groundingTelemetrySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingTelemetry.swift"),
      "utf8"
    );
    const guidedSetupSessionSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupSession.swift"),
      "utf8"
    );
    const screenIdentityResolverSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupScreenIdentityResolver.swift"),
      "utf8"
    );
    const negativeMemorySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupNegativeMemory.swift"),
      "utf8"
    );
    const preDotVerificationSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupPreDotVerification.swift"),
      "utf8"
    );
    const semanticOutcomeEvaluatorSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupSemanticOutcomeEvaluator.swift"),
      "utf8"
    );
    const outcomeDecisionBuilderSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupOutcomeDecisionBuilder.swift"),
      "utf8"
    );
    const outcomeStatusResolverSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupOutcomeStatusResolver.swift"),
      "utf8"
    );
    const retryPolicySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupRetryPolicy.swift"),
      "utf8"
    );
    const guidedSetupPromptContextSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupPromptContext.swift"),
      "utf8"
    );
    const outcomeContractsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GuidedSetupOutcomeContracts.swift"),
      "utf8"
    );
    const openAISource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "OpenAIAPI.swift"),
      "utf8"
    );
    const guideCoreContractsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGuideCoreContracts.swift"),
      "utf8"
    );
    const guideGroundingContractsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGuideGroundingContracts.swift"),
      "utf8"
    );
    const visionPayloadSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderVisionGuidePayload.swift"),
      "utf8"
    );
    const groundingTelemetryRecorderSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingTelemetryRecorder.swift"),
      "utf8"
    );
    const groundingTelemetryMetadataSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "GroundingTelemetryMetadata.swift"),
      "utf8"
    );
    const groundingTelemetryPayloadBuilderSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGroundingTelemetryPayloadBuilder.swift"),
      "utf8"
    );

    assert.match(outcomeContractsSource, /struct ExpectedOutcomeEvidence: Equatable/);
    assert.match(outcomeContractsSource, /enum GroundingExpectedOutcomeKind: String, Equatable/);
    assert.match(outcomeContractsSource, /case tileSelected/);
    assert.match(outcomeContractsSource, /case modalOpened/);
    assert.match(outcomeContractsSource, /case modalClosed/);
    assert.match(outcomeContractsSource, /case dropdownOpened/);
    assert.match(outcomeContractsSource, /case fieldFocused/);
    assert.match(outcomeContractsSource, /case fieldFilled/);
    assert.match(outcomeContractsSource, /case buttonEnabled/);
    assert.match(outcomeContractsSource, /case buttonDisabled/);
    assert.match(outcomeContractsSource, /case wizardAdvanced/);
    assert.match(outcomeContractsSource, /case warningAppeared/);
    assert.match(outcomeContractsSource, /case warningCleared/);
    assert.match(outcomeContractsSource, /case screenAdvanced/);
    assert.match(outcomeContractsSource, /targetFingerprint: TargetFingerprint\?/);
    assert.match(outcomeContractsSource, /startingGroundingRevision: GroundingRevision\?/);
    assert.match(outcomeContractsSource, /struct ActualOutcomeEvidence: Equatable/);
    assert.match(outcomeContractsSource, /struct GroundingRetryPolicy: Equatable/);
    assert.match(outcomeContractsSource, /struct GroundingOutcomeDecision: Equatable/);
    assert.match(outcomeContractsSource, /struct PendingPreDotVerification: Equatable/);
    assert.match(outcomeContractsSource, /struct GroundingNegativeMemoryEntry: Equatable/);
    assert.match(outcomeContractsSource, /expectedStageChange/);
    assert.match(outcomeContractsSource, /expectedSemanticSignatureChange/);
    assert.match(outcomeContractsSource, /targetReappeared/);
    assert.match(outcomeContractsSource, /targetStillSame/);
    assert.match(outcomeContractsSource, /modalVisible/);
    assert.match(outcomeContractsSource, /selectedTargetVisible/);
    assert.match(outcomeContractsSource, /focusedFieldVisible/);
    assert.match(outcomeContractsSource, /filledFieldVisible/);
    assert.match(outcomeContractsSource, /enabledButtonVisible/);
    assert.match(outcomeContractsSource, /disabledButtonVisible/);
    assert.match(outcomeContractsSource, /dropdownVisible/);
    assert.match(outcomeContractsSource, /modalClosed/);
    assert.match(outcomeContractsSource, /warningVisible/);
    assert.match(outcomeContractsSource, /warningCleared/);
    assert.match(outcomeContractsSource, /blockedOrUnknownAfterAction/);
    assert.doesNotMatch(guidedSetupSessionSource, /struct ExpectedOutcomeEvidence: Equatable/);
    assert.doesNotMatch(guidedSetupSessionSource, /struct PendingPreDotVerification: Equatable/);
    assert.doesNotMatch(guidedSetupSessionSource, /struct GroundingNegativeMemoryEntry: Equatable/);
    assert.doesNotMatch(guidedSetupSessionSource, /func promptContext\(/);
    assert.match(negativeMemorySource, /extension GuidedSetupSession/);
    assert.match(negativeMemorySource, /func shouldRejectNegativeMemory\(/);
    assert.match(negativeMemorySource, /mutating func rememberNegativeTarget\(/);
    assert.match(negativeMemorySource, /mutating func rememberNegativeOutcome\(/);
    assert.match(negativeMemorySource, /private mutating func appendNegativeMemory/);
    assert.match(negativeMemorySource, /negativeMemories\.count > 24/);
    assert.doesNotMatch(guidedSetupSessionSource, /func shouldRejectNegativeMemory\(/);
    assert.doesNotMatch(guidedSetupSessionSource, /mutating func rememberNegativeTarget\(/);
    assert.doesNotMatch(guidedSetupSessionSource, /mutating func rememberNegativeOutcome\(/);
    assert.match(preDotVerificationSource, /extension GuidedSetupSession/);
    assert.match(preDotVerificationSource, /mutating func resolvePreDotVerification\(/);
    assert.match(preDotVerificationSource, /targetMatchesPendingPreDot/);
    assert.match(preDotVerificationSource, /regionCanCarryDot/);
    assert.doesNotMatch(guidedSetupSessionSource, /mutating func resolvePreDotVerification\(/);
    assert.match(semanticOutcomeEvaluatorSource, /struct GuidedSetupSemanticOutcomeEvidence/);
    assert.match(semanticOutcomeEvaluatorSource, /enum GuidedSetupSemanticOutcomeEvaluator/);
    assert.match(semanticOutcomeEvaluatorSource, /static func evaluate\(/);
    assert.match(outcomeDecisionBuilderSource, /enum GuidedSetupOutcomeDecisionBuilder/);
    assert.match(outcomeDecisionBuilderSource, /static func decision\(/);
    assert.match(outcomeDecisionBuilderSource, /GuidedSetupSemanticOutcomeEvaluator\.evaluate/);
    assert.match(outcomeDecisionBuilderSource, /GuidedSetupOutcomeStatusResolver\.resolve/);
    assert.match(outcomeDecisionBuilderSource, /GuidedSetupRetryPolicy\.resolve/);
    assert.match(outcomeDecisionBuilderSource, /nextScreenId != expectedOutcomeEvidence\.startingScreenId \|\| stageChanged/);
    assert.match(outcomeDecisionBuilderSource, /&& !semanticChanged/);
    assert.match(outcomeDecisionBuilderSource, /targetReappeared/);
    assert.match(guidedSetupSessionSource, /GuidedSetupOutcomeDecisionBuilder\.decision/);
    assert.doesNotMatch(guidedSetupSessionSource, /GuidedSetupSemanticOutcomeEvaluator\.evaluate/);
    assert.doesNotMatch(guidedSetupSessionSource, /private static func semanticOutcomeEvidence/);
    assert.match(outcomeStatusResolverSource, /enum GuidedSetupOutcomeStatusResolver/);
    assert.match(outcomeStatusResolverSource, /static func resolve\(/);
    assert.match(outcomeStatusResolverSource, /screenChanged && resolvedScreenState == \.blocked/);
    assert.match(outcomeStatusResolverSource, /case \.dropdownOpened/);
    assert.match(outcomeStatusResolverSource, /case \.warningCleared/);
    assert.match(outcomeStatusResolverSource, /private static func status/);
    assert.doesNotMatch(guidedSetupSessionSource, /GuidedSetupOutcomeStatusResolver\.resolve/);
    assert.doesNotMatch(guidedSetupSessionSource, /switch expectedOutcomeEvidence\.verificationKind/);
    assert.match(guidedSetupPromptContextSource, /extension GuidedSetupSession/);
    assert.match(guidedSetupPromptContextSource, /func promptContext\(/);
    assert.match(guidedSetupPromptContextSource, /Guided setup session metadata:/);
    assert.match(guidedSetupPromptContextSource, /pendingPreDotVerificationReasons/);
    assert.match(retryPolicySource, /enum GuidedSetupRetryPolicy/);
    assert.match(retryPolicySource, /static func resolve\(/);
    assert.match(retryPolicySource, /doNotRepeatUntilSignatureChanges: true/);
    assert.match(retryPolicySource, /requiresUserConfirmationAfterFailure: true/);
    assert.match(retryPolicySource, /reason: \.noVisualChangeAfterAction/);
    assert.match(retryPolicySource, /reason: actualOutcomeEvidence\.blockedOrUnknownAfterAction/);
    assert.doesNotMatch(guidedSetupSessionSource, /GuidedSetupRetryPolicy\.resolve/);
    assert.doesNotMatch(guidedSetupSessionSource, /private static func retryPolicy/);
    assert.match(screenIdentityResolverSource, /enum GuidedSetupScreenIdentityResolver/);
    assert.match(screenIdentityResolverSource, /static func currentIdentity/);
    assert.match(screenIdentityResolverSource, /static func sanitizedOutcomeIdentity/);
    assert.match(guidedSetupSessionSource, /GuidedSetupScreenIdentityResolver\.currentIdentity/);
    assert.match(outcomeDecisionBuilderSource, /GuidedSetupScreenIdentityResolver\.sanitizedOutcomeIdentity/);
    assert.doesNotMatch(guidedSetupSessionSource, /GuidedSetupScreenIdentityResolver\.sanitizedOutcomeIdentity/);
    assert.doesNotMatch(guidedSetupSessionSource, /private func fallbackScreenId/);
    assert.doesNotMatch(guidedSetupSessionSource, /private func fallbackStageId/);
    assert.match(guidedSetupSessionSource, /stageChanged \|\| semanticSignatureChanged/);
    assert.doesNotMatch(guidedSetupSessionSource, /semanticOutcomeEvidence/);
    assert.match(guidedSetupSessionSource, /return false/);
    assert.match(guidedSetupSessionSource, /SpiderGroundingPrivacy\.targetElementIdHash\(for: point\.targetElementId\)/);
    assert.doesNotMatch(guidedSetupSessionSource, /sameLabel/);
    assert.doesNotMatch(guidedSetupSessionSource, /pointLabel/);

    assert.match(guidedSetupActionsSource, /acceptedPointMetadata: GroundingTelemetryRecorder\.PointAcceptanceMetadata\?/);
    assert.match(guidedSetupActionsSource, /acceptedPointTargetElementIdHash: acceptedPointMetadata\?\.targetElementIdHash/);
    assert.match(guidedSetupActionsSource, /acceptedPointTargetFingerprint: acceptedPointMetadata\?\.targetFingerprint/);
    assert.match(visionGuideActionsSource, /CompanionGuidePointTelemetryRecorder\.recordAccepted/);
    assert.doesNotMatch(managerSource, /CompanionGuidePointTelemetryRecorder\.recordAccepted/);
    assert.match(
      groundingTelemetryMetadataSource,
      /targetElementIdHash: SpiderGroundingPrivacy\.targetElementIdHash\(for: guidePoint\.targetElementId\)/
    );
    assert.match(guidedSetupActionsSource, /retryPolicy: outcomeDecision\.retryPolicy/);
    assert.match(visionGuideActionsSource, /CompanionGuidePointTelemetryRecorder\.recordRejected/);
    assert.match(visionGuideActionsSource, /retryPolicy: pointRejectionReason == \.outcomeFailed/);
    assert.doesNotMatch(managerSource, /CompanionGuidePointTelemetryRecorder\.recordRejected/);
    assert.match(visionPayloadSource, /struct SpiderGuidedSessionContext: Encodable/);
    assert.match(visionPayloadSource, /struct PendingPointOutcome: Encodable/);
    assert.match(visionPayloadSource, /targetElementIdHash: String\?/);
    assert.match(visionPayloadSource, /retryAllowed: Bool\?/);
    assert.match(visionPayloadSource, /requiresUserConfirmationAfterFailure: Bool\?/);
    assert.match(visionPayloadSource, /doNotRepeatUntilSignatureChanges: Bool\?/);
    assert.doesNotMatch(openAISource, /struct SpiderGuidedSessionContext: Encodable/);
    assert.match(guideGroundingContractsSource, /struct TargetFingerprint: Codable, Equatable/);
    assert.match(guideGroundingContractsSource, /struct GroundingRevision: Codable, Equatable/);
    assert.match(guideGroundingContractsSource, /struct RegionQuality: Codable, Equatable/);
    assert.match(guideCoreContractsSource, /case dropdownOpened = "dropdown_opened"/);
    assert.match(guideCoreContractsSource, /case modalClosed = "modal_closed"/);
    assert.match(guideCoreContractsSource, /case tileSelected = "tile_selected"/);
    assert.match(guideCoreContractsSource, /case fieldFocused = "field_focused"/);
    assert.match(guideCoreContractsSource, /case buttonDisabled = "button_disabled"/);
    assert.match(guideCoreContractsSource, /case warningCleared = "warning_cleared"/);
    assert.match(groundingTelemetrySource, /retryPolicy: GroundingRetryPolicy\?/);
    assert.match(groundingTelemetryPayloadBuilderSource, /retryAllowed/);
    assert.match(groundingTelemetryPayloadBuilderSource, /retryReason/);
    assert.match(groundingTelemetryPayloadBuilderSource, /requiresUserConfirmationAfterFailure/);
    assert.match(groundingTelemetryPayloadBuilderSource, /doNotRepeatUntilSignatureChanges/);
  });
}
