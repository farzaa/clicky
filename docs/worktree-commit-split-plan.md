# Spider Worktree Commit Split Plan

Purpose: turn the current large worktree into senior-reviewable commits without
changing product behavior. Do not use this plan as approval to commit. Stage
each group only after explicit confirmation.

Current constraints:
- No UX changes.
- No dot rule changes.
- No OpenAI stack changes.
- No click automation, autopublish, budget increase, billing edits, pause, or delete.
- Keep Spider screen-first.
- Keep telemetry and logs free of screenshots, transcripts, prompts, model responses,
  emails, tokens, and visible text.
- Keep v2 channel-agnostic ads work out of this diff except future-safe boundaries.

Exact path list command:

```bash
node scripts/worktree_review_groups.mjs --paths --group=<group-id>
```

Safe staging command after manual approval:

```bash
node scripts/worktree_review_groups.mjs --paths --null --group=<group-id> \
  | git add --pathspec-from-file=- --pathspec-file-nul
```

Review order:
1. `telemetry-privacy`
2. `guided-setup-dot-sensor-fusion`
3. `worker-backend`
4. `app-macos-core`
5. `tests`
6. `docs-scripts-release`
7. `repo-metadata`
8. `xcode-assets-deletions`

## 1. telemetry-privacy

Commit name: `telemetry-privacy-boundaries`

Responsibility:
- Privacy-safe analytics shim.
- Grounding telemetry event contracts.
- Payload allowlist and sanitizer.
- Audit CLI parser, privacy checks, self-tests, and summaries.

Main risks:
- Accidentally allowing visible text, screenshots, prompts, model output, emails,
  tokens, or raw target IDs into metrics.
- Breaking local telemetry summaries used to review dot quality.
- Weakening fail-closed behavior in audit tooling.

Validation:
- `node scripts/grounding_telemetry_audit.mjs --self-test`
- Positive synthetic grounding telemetry audit.
- Negative synthetic audit with `visibleText` must fail.
- `npm run check` from `worker`
- `xcodebuild test ... -only-testing:leanring-buddyTests`

Files:
- `leanring-buddy/SpiderAnalytics.swift`
- `leanring-buddy/SpiderGroundingAnalytics.swift`
- `leanring-buddy/SpiderGroundingPrivacy.swift`
- `leanring-buddy/SpiderGroundingTelemetry.swift`
- `leanring-buddy/SpiderGroundingTelemetryEmitter.swift`
- `leanring-buddy/SpiderGroundingTelemetryPayloadBuilder.swift`
- `leanring-buddy/SpiderGroundingTelemetrySanitizer.swift`
- `scripts/groundingTelemetryAuditParser.mjs`
- `scripts/groundingTelemetryAuditPrivacy.mjs`
- `scripts/groundingTelemetryAuditSelfTest.mjs`
- `scripts/groundingTelemetryAuditSummary.mjs`
- `scripts/grounding_telemetry_audit.mjs`

## 2. guided-setup-dot-sensor-fusion

Commit name: `guided-setup-dot-sensor-fusion`

Responsibility:
- Guided setup ephemeral state and polling policy.
- Dot eligibility and point safety boundaries.
- Vision-first sensor fusion contracts, signal collection, timing, and decision resolution.
- Pre-dot verification and repeated-failure memory.
- Local preview helpers for pointer rendering.

Main risks:
- Showing a dot for `loading`, `unknown`, or `blocked`.
- Moving the dot rule out of fail-closed behavior.
- Changing screen-first guidance behavior while pretending it is refactor.
- Logging or storing screen text through evidence/debug paths.

Validation:
- `swiftc -parse` on touched Swift domains.
- `xcodebuild test ... -only-testing:leanring-buddyTests`
- `xcodebuild build ...`
- `npm run check` from `worker`
- Manual review of dot policy invariants before staging.

Files:
- `leanring-buddy/CompanionGuidePointEvaluator.swift`
- `leanring-buddy/CompanionGuidePointOverlayPresenter.swift`
- `leanring-buddy/CompanionGuidePointSensorFusionRunner.swift`
- `leanring-buddy/CompanionGuidePointTelemetryRecorder.swift`
- `leanring-buddy/CompanionPreDotVerificationCoordinator.swift`
- `leanring-buddy/GroundingAccessibilitySensor.swift`
- `leanring-buddy/GroundingContextClassifier.swift`
- `leanring-buddy/GroundingCursorMetadataSensor.swift`
- `leanring-buddy/GroundingDotEligibilityPolicy.swift`
- `leanring-buddy/GroundingLocalOCRSensor.swift`
- `leanring-buddy/GroundingPointProjector.swift`
- `leanring-buddy/GroundingRegionQualityEvaluator.swift`
- `leanring-buddy/GroundingSensorFusion.swift`
- `leanring-buddy/GroundingSensorFusionContracts.swift`
- `leanring-buddy/GroundingSensorFusionDecisionResolver.swift`
- `leanring-buddy/GroundingSensorFusionSignalCollector.swift`
- `leanring-buddy/GroundingSensorFusionTiming.swift`
- `leanring-buddy/GroundingTargetIdentity.swift`
- `leanring-buddy/GroundingTelemetryMetadata.swift`
- `leanring-buddy/GroundingTelemetryRecorder.swift`
- `leanring-buddy/GuidePointOverlayPlacement.swift`
- `leanring-buddy/GuideResponsePresentationPolicy.swift`
- `leanring-buddy/GuidedSetupNegativeMemory.swift`
- `leanring-buddy/GuidedSetupOutcomeContracts.swift`
- `leanring-buddy/GuidedSetupOutcomeDecisionBuilder.swift`
- `leanring-buddy/GuidedSetupOutcomeStatusResolver.swift`
- `leanring-buddy/GuidedSetupPollScheduler.swift`
- `leanring-buddy/GuidedSetupPollingPolicy.swift`
- `leanring-buddy/GuidedSetupPreDotVerification.swift`
- `leanring-buddy/GuidedSetupPromptComposer.swift`
- `leanring-buddy/GuidedSetupPromptContext.swift`
- `leanring-buddy/GuidedSetupRetryPolicy.swift`
- `leanring-buddy/GuidedSetupScreenIdentityResolver.swift`
- `leanring-buddy/GuidedSetupSemanticOutcomeEvaluator.swift`
- `leanring-buddy/GuidedSetupSession.swift`
- `leanring-buddy/OpenAIVisionGuideClient.swift`
- `leanring-buddy/SpiderGuideContentLimits.swift`
- `leanring-buddy/SpiderGuideConversationHistory.swift`
- `leanring-buddy/SpiderGuideCoreContracts.swift`
- `leanring-buddy/SpiderGuideGroundingContracts.swift`
- `leanring-buddy/SpiderGuidePointRejectionReason.swift`
- `leanring-buddy/SpiderGuidePointSafetyPolicy.swift`
- `leanring-buddy/SpiderGuideResponseSanitization.swift`
- `scripts/render_mission_pointer_preview.sh`
- `scripts/render_mission_pointer_preview.swift`

## 3. worker-backend

Commit name: `worker-routing-auth-openai-safety`

Responsibility:
- Worker route decomposition.
- Auth session storage and device binding.
- Entitlement, quota, audit rows, and operational retention.
- Stripe billing and webhook boundaries.
- OpenAI Vision and Realtime proxy safety.
- Guide request/response validation and platform packs.
- Meta knowledge files and grounding eval harness.

Main risks:
- Calling OpenAI before entitlement/quota/session checks.
- Storing user content in D1/audit/logs.
- Accepting client-provided model overrides.
- Weakening Stripe webhook idempotency or entitlement reconciliation.
- Mixing future v2 platform automation into current v1 guidance.

Validation:
- `npm run check` from `worker`
- Worker smoke tests must pass.
- Manual review of route order for auth, entitlement, quota, audit, and OpenAI calls.

Files:
- `worker/package-lock.json`
- `worker/package.json`
- `worker/src/index.ts`
- `worker/wrangler.toml`
- `worker/evals/cases/.gitignore`
- `worker/evals/cases/README.md`
- `worker/evals/fixtures/.gitignore`
- `worker/evals/fixtures/README.md`
- `worker/evals/replay-grounding.mjs`
- `worker/evals/reports/.gitignore`
- `worker/evals/run-grounding-evals.mjs`
- `worker/knowledge/meta_72h_review_playbook.json`
- `worker/knowledge/meta_ad_review_rules.json`
- `worker/knowledge/meta_campaign_objectives.json`
- `worker/knowledge/meta_creative_policy_risks.json`
- `worker/knowledge/meta_decision_types.json`
- `worker/knowledge/meta_guided_setup_steps.json`
- `worker/knowledge/meta_preflight_checks.json`
- `worker/knowledge/meta_tracking_readiness_checks.json`
- `worker/knowledge/source_registry.json`
- `worker/migrations/0001_spider_core.sql`
- `worker/migrations/0002_subscription_state.sql`
- `worker/migrations/0003_stripe_event_processing.sql`
- `worker/migrations/0004_session_device_binding.sql`
- `worker/migrations/0005_operational_retention_indexes.sql`
- `worker/src/auditEventStore.ts`
- `worker/src/authRoutes.ts`
- `worker/src/authSessionStore.ts`
- `worker/src/billingRoutes.ts`
- `worker/src/entitlementPolicy.ts`
- `worker/src/env.d.ts`
- `worker/src/guideLimits.ts`
- `worker/src/guidePointParsing.ts`
- `worker/src/guidePointSafety.ts`
- `worker/src/guideRequestValidation.ts`
- `worker/src/guideResponseContract.ts`
- `worker/src/guideResponseExtras.ts`
- `worker/src/guideResponseParsing.ts`
- `worker/src/guideResponseSchema.ts`
- `worker/src/guideResponseValidation.ts`
- `worker/src/guideScreenSafety.ts`
- `worker/src/guideSemanticGrounding.ts`
- `worker/src/guideTypes.ts`
- `worker/src/guideValidationContext.ts`
- `worker/src/http.ts`
- `worker/src/identitySecurity.ts`
- `worker/src/meteringStore.ts`
- `worker/src/openAIGuideClient.ts`
- `worker/src/openAIGuideRequest.ts`
- `worker/src/openAIGuideResponse.ts`
- `worker/src/operationalRetentionStore.ts`
- `worker/src/payloadSecurity.ts`
- `worker/src/platforms/metaAdsBestPractices.ts`
- `worker/src/platforms/metaAdsPack.ts`
- `worker/src/platforms/platformRegistry.ts`
- `worker/src/platforms/sharedSafety.ts`
- `worker/src/platforms/types.ts`
- `worker/src/platforms/unknownPlatformPack.ts`
- `worker/src/productFeatures.ts`
- `worker/src/realtimeRoutes.ts`
- `worker/src/runtimeConfig.ts`
- `worker/src/stripeClient.ts`
- `worker/src/stripeEventStore.ts`
- `worker/src/stripeWebhookRoutes.ts`
- `worker/src/structuredValues.ts`
- `worker/src/validationPrimitives.ts`
- `worker/src/visionGuidePrompt.ts`
- `worker/src/visionGuidePromptContracts.ts`
- `worker/src/visionGuideRoutes.ts`
- `worker/src/workerRoutes.ts`
- `worker/tsconfig.json`
- `worker/worker-configuration.d.ts`

## 4. app-macos-core

Commit name: `macos-core-boundaries`

Responsibility:
- App lifecycle and menu-bar shell.
- Companion manager decomposition.
- Account, billing, permissions, panel, dictation, speech, overlay, and Ad Mission boundaries.
- Keychain/session and local state integration.
- Product feature flags and local app configuration.

Main risks:
- Changing panel UX or onboarding behavior while doing structural cleanup.
- Breaking push-to-talk, overlay visibility, permissions, or session state.
- Persisting email/session data in the wrong store.
- Reintroducing disabled providers or direct client-side OpenAI uploads.

Validation:
- `swiftc -parse` on touched Swift files where practical.
- `xcodebuild test ... -only-testing:leanring-buddyTests`
- `xcodebuild build ...`
- Manual review of Keychain/UserDefaults boundaries.

Files:
- `leanring-buddy/AppBundleConfiguration.swift`
- `leanring-buddy/AppleSpeechTranscriptionProvider.swift`
- `leanring-buddy/BuddyDictationManager.swift`
- `leanring-buddy/BuddyTranscriptionProvider.swift`
- `leanring-buddy/CompanionManager.swift`
- `leanring-buddy/CompanionPanelView.swift`
- `leanring-buddy/CompanionScreenCaptureUtility.swift`
- `leanring-buddy/DesignSystem.swift`
- `leanring-buddy/GlobalPushToTalkShortcutMonitor.swift`
- `leanring-buddy/Info.plist`
- `leanring-buddy/MenuBarPanelManager.swift`
- `leanring-buddy/OpenAIAPI.swift`
- `leanring-buddy/OverlayWindow.swift`
- `leanring-buddy/WindowPositionManager.swift`
- `leanring-buddy/leanring_buddyApp.swift`
- `leanring-buddy/AdMissionArtifactApplier.swift`
- `leanring-buddy/AdMissionCampaignPlanner.swift`
- `leanring-buddy/AdMissionDomain.swift`
- `leanring-buddy/AdMissionLifecyclePolicy.swift`
- `leanring-buddy/AdMissionLocalPersistence.swift`
- `leanring-buddy/AdMissionStartBuilder.swift`
- `leanring-buddy/AdMissionUpdateApplier.swift`
- `leanring-buddy/AdPlatformGuideConfiguration.swift`
- `leanring-buddy/BuddyDictationAudioPowerMeter.swift`
- `leanring-buddy/BuddyDictationContracts.swift`
- `leanring-buddy/BuddyDictationDraftComposer.swift`
- `leanring-buddy/BuddyDictationErrorPresentationPolicy.swift`
- `leanring-buddy/BuddyDictationKeytermBuilder.swift`
- `leanring-buddy/BuddyPushToTalkShortcut.swift`
- `leanring-buddy/Color+DesignSystem.swift`
- `leanring-buddy/CompanionAccountLocalStateStore.swift`
- `leanring-buddy/CompanionAuthPresentationPolicy.swift`
- `leanring-buddy/CompanionBillingPresentationPolicy.swift`
- `leanring-buddy/CompanionGuidanceStatusBubbleController.swift`
- `leanring-buddy/CompanionGuidePipelineClock.swift`
- `leanring-buddy/CompanionGuideRequestContext.swift`
- `leanring-buddy/CompanionGuideResponseRecorder.swift`
- `leanring-buddy/CompanionInteractionReadinessPolicy.swift`
- `leanring-buddy/CompanionKeyboardShortcutPolicy.swift`
- `leanring-buddy/CompanionManagerAccountActions.swift`
- `leanring-buddy/CompanionManagerAdMissionActions.swift`
- `leanring-buddy/CompanionManagerCursorActions.swift`
- `leanring-buddy/CompanionManagerDebugActions.swift`
- `leanring-buddy/CompanionManagerGuidedSetupActions.swift`
- `leanring-buddy/CompanionManagerLifecycle.swift`
- `leanring-buddy/CompanionManagerOnboardingActions.swift`
- `leanring-buddy/CompanionManagerPermissionActions.swift`
- `leanring-buddy/CompanionManagerPermissionState.swift`
- `leanring-buddy/CompanionManagerPresentationActions.swift`
- `leanring-buddy/CompanionManagerVisionGuideActions.swift`
- `leanring-buddy/CompanionOnboardingDemoGuideRunner.swift`
- `leanring-buddy/CompanionOnboardingMusicController.swift`
- `leanring-buddy/CompanionOnboardingPromptController.swift`
- `leanring-buddy/CompanionOnboardingVideoController.swift`
- `leanring-buddy/CompanionPanelAccountAccessView.swift`
- `leanring-buddy/CompanionPanelAdMissionPresentationPolicy.swift`
- `leanring-buddy/CompanionPanelChromeViews.swift`
- `leanring-buddy/CompanionPanelCopy.swift`
- `leanring-buddy/CompanionPanelFormControls.swift`
- `leanring-buddy/CompanionPanelMissionDraft.swift`
- `leanring-buddy/CompanionPanelMissionMoneyPolicy.swift`
- `leanring-buddy/CompanionPanelMissionOptions.swift`
- `leanring-buddy/CompanionPanelMissionWizardViews.swift`
- `leanring-buddy/CompanionPanelSettingsViews.swift`
- `leanring-buddy/CompanionPanelStatusPresentationPolicy.swift`
- `leanring-buddy/CompanionPanelSurfaceStyles.swift`
- `leanring-buddy/CompanionPermissionState.swift`
- `leanring-buddy/CompanionPermissionTelemetryRecorder.swift`
- `leanring-buddy/CompanionScreenContentPermissionProbe.swift`
- `leanring-buddy/CompanionSpeechPlaybackController.swift`
- `leanring-buddy/CompanionSpeechPolicy.swift`
- `leanring-buddy/CompanionSystemSpeechPlayer.swift`
- `leanring-buddy/CompanionTransientOverlayHideController.swift`
- `leanring-buddy/CompanionVisionGuideErrorPresentationPolicy.swift`
- `leanring-buddy/CompanionVisionGuideRequestRunner.swift`
- `leanring-buddy/DSButtonStyles.swift`
- `leanring-buddy/DesignSystemCursorBridges.swift`
- `leanring-buddy/GuideClickTargetView.swift`
- `leanring-buddy/OnboardingVideoPlayerView.swift`
- `leanring-buddy/OpenAIRealtimeTranscriptionProvider.swift`
- `leanring-buddy/OpenAIRealtimeVoiceClient.swift`
- `leanring-buddy/OverlayWindowManager.swift`
- `leanring-buddy/OverlayWindowPreferences.swift`
- `leanring-buddy/OverlayWindowShell.swift`
- `leanring-buddy/SpiderAccountSessionPolicy.swift`
- `leanring-buddy/SpiderAuthClient.swift`
- `leanring-buddy/SpiderCursorBubbleView.swift`
- `leanring-buddy/SpiderCursorNavigationMode.swift`
- `leanring-buddy/SpiderCursorOrbView.swift`
- `leanring-buddy/SpiderCursorVoiceStateViews.swift`
- `leanring-buddy/SpiderDiagnostics.swift`
- `leanring-buddy/SpiderProductFeatures.swift`
- `leanring-buddy/SpiderSessionStore.swift`
- `leanring-buddy/SpiderTextSanitization.swift`
- `leanring-buddy/SpiderVisionGuidePayload.swift`
- `leanring-buddy/SpiderWorkerClientError.swift`

## 5. tests

Commit name: `domain-tests-and-smoke-coverage`

Responsibility:
- Swift domain tests replacing the previous giant test file.
- Worker smoke test decomposition by behavior and security boundary.
- Fixtures and architecture assertions that prevent monolith relapse.

Main risks:
- Tests asserting source text too tightly and becoming maintenance drag.
- False confidence if tests only check file names, not behavior.
- Splitting tests away from the implementation commit that needs them.

Validation:
- `xcodebuild test ... -only-testing:leanring-buddyTests`
- `npm run check` from `worker`
- Manual review that critical behavior tests live with the corresponding implementation PR when practical.

Files:
- `leanring-buddyTests/leanring_buddyTests.swift`
- `leanring-buddyTests/AccountSessionPolicyTests.swift`
- `leanring-buddyTests/AdMissionTests.swift`
- `leanring-buddyTests/BuddyDictationPolicyTests.swift`
- `leanring-buddyTests/CompanionAccountLocalStateStoreTests.swift`
- `leanring-buddyTests/CompanionAuthPresentationPolicyTests.swift`
- `leanring-buddyTests/CompanionBillingPresentationPolicyTests.swift`
- `leanring-buddyTests/CompanionGuidanceStatusBubblePolicyTests.swift`
- `leanring-buddyTests/CompanionGuidePipelineClockTests.swift`
- `leanring-buddyTests/CompanionGuidePointEvaluatorTests.swift`
- `leanring-buddyTests/CompanionGuidePointOverlayPresenterTests.swift`
- `leanring-buddyTests/CompanionGuidePointTelemetryRecorderTests.swift`
- `leanring-buddyTests/CompanionGuideRequestContextTests.swift`
- `leanring-buddyTests/CompanionGuideResponseRecorderTests.swift`
- `leanring-buddyTests/CompanionInteractionReadinessPolicyTests.swift`
- `leanring-buddyTests/CompanionKeyboardShortcutPolicyTests.swift`
- `leanring-buddyTests/CompanionOnboardingMusicPolicyTests.swift`
- `leanring-buddyTests/CompanionOnboardingPromptPolicyTests.swift`
- `leanring-buddyTests/CompanionOnboardingVideoPolicyTests.swift`
- `leanring-buddyTests/CompanionPanelAdMissionPresentationPolicyTests.swift`
- `leanring-buddyTests/CompanionPanelCopyTests.swift`
- `leanring-buddyTests/CompanionPanelMissionDraftTests.swift`
- `leanring-buddyTests/CompanionPanelMissionMoneyPolicyTests.swift`
- `leanring-buddyTests/CompanionPanelMissionOptionsTests.swift`
- `leanring-buddyTests/CompanionPanelStatusPresentationPolicyTests.swift`
- `leanring-buddyTests/CompanionPermissionStateTests.swift`
- `leanring-buddyTests/CompanionPreDotVerificationCoordinatorTests.swift`
- `leanring-buddyTests/CompanionScreenContentPermissionProbeTests.swift`
- `leanring-buddyTests/CompanionSpeechPolicyTests.swift`
- `leanring-buddyTests/CompanionTransientOverlayHideControllerTests.swift`
- `leanring-buddyTests/CompanionVisionGuideErrorPresentationPolicyTests.swift`
- `leanring-buddyTests/GroundingSensorFusionTests.swift`
- `leanring-buddyTests/GroundingTelemetryRecorderTests.swift`
- `leanring-buddyTests/GuidePointOverlayPlacementTests.swift`
- `leanring-buddyTests/GuidePointSafetyPolicyTests.swift`
- `leanring-buddyTests/GuidedSetupPolicyTests.swift`
- `leanring-buddyTests/GuidedSetupPollSchedulerTests.swift`
- `leanring-buddyTests/GuidedSetupScreenIdentityResolverTests.swift`
- `leanring-buddyTests/GuidedSetupSessionOutcomeTests.swift`
- `leanring-buddyTests/SpiderGuideConversationHistoryTests.swift`
- `leanring-buddyTests/SpiderTestFixtures.swift`
- `leanring-buddyTests/WindowPositionManagerTests.swift`
- `worker/tests/aiRouteGatewayAssertions.mjs`
- `worker/tests/aiRouteSecurityAssertions.mjs`
- `worker/tests/authSessionAssertions.mjs`
- `worker/tests/authStatusAccessAssertions.mjs`
- `worker/tests/billingCheckoutPortalAssertions.mjs`
- `worker/tests/groundingReplayAssertions.mjs`
- `worker/tests/groundingTelemetryAuditAssertions.mjs`
- `worker/tests/guideFixtures.mjs`
- `worker/tests/httpSurfaceAssertions.mjs`
- `worker/tests/knowledgeAssertions.mjs`
- `worker/tests/macOSGuidePointAssertions.mjs`
- `worker/tests/macOSOutcomeVerifierAssertions.mjs`
- `worker/tests/macOSProductSurfaceAssertions.mjs`
- `worker/tests/macOSSensorFusionAssertions.mjs`
- `worker/tests/macOSTelemetryAssertions.mjs`
- `worker/tests/macOSVisionClientAssertions.mjs`
- `worker/tests/macOSVoiceSurfaceAssertions.mjs`
- `worker/tests/magicLinkConfirmBridgeAssertions.mjs`
- `worker/tests/magicLinkStartAssertions.mjs`
- `worker/tests/metaAdsPlatformAssertions.mjs`
- `worker/tests/metaAdsPromptAssertions.mjs`
- `worker/tests/metaKnowledgeAssertions.mjs`
- `worker/tests/openAIContractAssertions.mjs`
- `worker/tests/openAIResponseValidationAssertions.mjs`
- `worker/tests/operationalRetentionAssertions.mjs`
- `worker/tests/smoke-worker.mjs`
- `worker/tests/smokeHarness.mjs`
- `worker/tests/stripeWebhookAssertions.mjs`
- `worker/tests/visionGuideManualBoundaryAssertions.mjs`
- `worker/tests/visionGuidePayloadAssertions.mjs`
- `worker/tests/visionGuidePointSafetyAssertions.mjs`
- `worker/tests/visionGuidePromptResponseAssertions.mjs`
- `worker/tests/visualGroundingRedTeamAssertions.mjs`
- `worker/tests/workerArchitectureAssertions.mjs`
- `worker/tests/workerAuthSecurityArchitectureAssertions.mjs`
- `worker/tests/workerBillingRuntimeArchitectureAssertions.mjs`
- `worker/tests/workerGuideArchitectureAssertions.mjs`
- `worker/tests/worktreeReviewAssertions.mjs`

## 6. docs-scripts-release

Commit name: `docs-scripts-release-gates`

Responsibility:
- Repo operating contract.
- Public/private beta docs.
- Release scripts and preflight gates.
- Worktree review tooling and this commit split plan.

Main risks:
- Documentation drifting from actual app behavior.
- Release script changes touching signing/notarization without proof.
- Review tooling hiding paths or putting risky files in the wrong group.

Validation:
- `node scripts/worktree_review_groups.mjs --self-test`
- `node scripts/worktree_review_groups.mjs --summary`
- Manual read of release scripts before staging.
- `git diff --check`

Files:
- `AGENTS.md`
- `README.md`
- `leanring-buddy/AGENTS.md`
- `scripts/README.md`
- `scripts/release.sh`
- `SPIDER_APPLE_DEVELOPER_PROGRAM_RUNBOOK.md`
- `SPIDER_SECURITY_RELEASE_DECISIONS.md`
- `docs/DESIGN_SYSTEM.md`
- `docs/ads-product-architecture.md`
- `docs/private-beta-runbook.md`
- `docs/private-beta-tester-guide.md`
- `docs/worktree-commit-split-plan.md`
- `scripts/configure_release.sh`
- `scripts/release.env.example`
- `scripts/release_preflight.sh`
- `scripts/worker_deploy_preflight.sh`
- `scripts/worker_remote_preflight.sh`
- `scripts/worktreeReviewGroupsArgs.mjs`
- `scripts/worktreeReviewGroupsClassifier.mjs`
- `scripts/worktreeReviewGroupsConfig.mjs`
- `scripts/worktreeReviewGroupsGit.mjs`
- `scripts/worktreeReviewGroupsRenderer.mjs`
- `scripts/worktreeReviewGroupsSelfTest.mjs`
- `scripts/worktree_review_groups.mjs`

## 7. repo-metadata

Commit name: `repo-metadata-cleanup`

Responsibility:
- Repository ignore/config cleanup.

Main risks:
- Accidentally ignoring source, tests, generated config, or release artifacts that
  should stay visible.

Validation:
- `git status --short`
- Manual read of `.gitignore`

Files:
- `.gitignore`

## 8. xcode-assets-deletions

Commit name: `xcode-assets-legacy-provider-removal`

Responsibility:
- Xcode project metadata.
- Shared scheme metadata.
- Asset relocation/removal.
- Legacy provider and overlay deletions.
- Appcast/demo artifact changes.

Main risks:
- Breaking the Xcode project file or scheme.
- Removing assets still referenced by UI.
- Hiding behavioral deletions inside project metadata.
- Accidentally removing provider code still wired into production.

Validation:
- `xcodebuild test ... -only-testing:leanring-buddyTests`
- `xcodebuild build ...`
- Manual review of project file, asset references, and deleted provider call sites.

Files:
- `appcast.xml`
- `clicky-demo.gif`
- `leanring-buddy.xcodeproj/project.pbxproj`
- `leanring-buddy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift`
- `leanring-buddy/Assets.xcassets/inside-the-makesomething-project-folder.imageset/Contents.json`
- `leanring-buddy/Assets.xcassets/inside-the-makesomething-project-folder.imageset/inside-the-makesomething-project-folder.png`
- `leanring-buddy/Assets.xcassets/makesomething-project-folder-in-downloads.imageset/Contents.json`
- `leanring-buddy/Assets.xcassets/makesomething-project-folder-in-downloads.imageset/makesomething-project-folder-in-downloads.png`
- `leanring-buddy/ClaudeAPI.swift`
- `leanring-buddy/ClickyAnalytics.swift`
- `leanring-buddy/CompanionResponseOverlay.swift`
- `leanring-buddy/ElementLocationDetector.swift`
- `leanring-buddy/ElevenLabsTTSClient.swift`
- `leanring-buddy/OpenAIAudioTranscriptionProvider.swift`
- `Assets/Campaign ready.png`
- `Assets/Frame 5341.png`
- `Assets/Home.png`
- `Assets/Settings - General.png`
- `Assets/Settings - Permissions.png`
- `Assets/Settings.png`
- `Assets/Signup.png`
- `Assets/Test Limit.png`
- `Assets/What should this campaign do.png`
- `Assets/Who is this for_.png`
- `Assets/Your Offer.png`
- `Assets/interfaces/Login with apple.png`
- `leanring-buddy.xcodeproj/xcshareddata/xcschemes/leanring-buddy.xcscheme`

## Gates before any commit

Minimum full gate after staging each risky group:

```bash
swiftc -parse leanring-buddy/SpiderAnalytics.swift \
  leanring-buddy/CompanionPermissionState.swift \
  leanring-buddy/CompanionPermissionTelemetryRecorder.swift

xcodebuild test -quiet -derivedDataPath /tmp/spider-codex-deriveddata \
  -project leanring-buddy.xcodeproj \
  -scheme leanring-buddy \
  -destination 'platform=macOS' \
  -only-testing:leanring-buddyTests \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build -quiet -derivedDataPath /tmp/spider-codex-deriveddata \
  -project leanring-buddy.xcodeproj \
  -scheme leanring-buddy \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

(cd worker && npm run check)

node scripts/grounding_telemetry_audit.mjs --self-test

printf 'Spider metric: grounding_point_accepted:screenState=recognized:targetElementIdHash=target_hash_123:timestamp=2026-06-26T00:00:00Z\n' \
  | node scripts/grounding_telemetry_audit.mjs

printf 'Spider metric: grounding_point_accepted:screenState=recognized:visibleText=leak\n' \
  | node scripts/grounding_telemetry_audit.mjs

git diff --check
```

Expected negative audit result:

```text
Unexpected telemetry key: visibleText
```
