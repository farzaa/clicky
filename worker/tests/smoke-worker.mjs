import {
  guidePoint,
  paidUserRow,
  semanticGroundingElement,
  semanticGroundingForPointLabels,
  semanticGroundingTarget,
  testElementId,
  unpaidUserRow,
  validGuideOutput,
  validVisionGuideBody,
} from "./guideFixtures.mjs";
import { registerAuthSessionAssertions } from "./authSessionAssertions.mjs";
import { registerAIRouteGatewayAssertions } from "./aiRouteGatewayAssertions.mjs";
import { registerAIRouteSecurityAssertions } from "./aiRouteSecurityAssertions.mjs";
import { registerBillingCheckoutPortalAssertions } from "./billingCheckoutPortalAssertions.mjs";
import { registerGroundingTelemetryAuditAssertions } from "./groundingTelemetryAuditAssertions.mjs";
import { registerGroundingReplayAssertions } from "./groundingReplayAssertions.mjs";
import { registerHttpSurfaceAssertions } from "./httpSurfaceAssertions.mjs";
import { registerMetaKnowledgeAssertions } from "./metaKnowledgeAssertions.mjs";
import { registerMetaAdsPlatformAssertions } from "./metaAdsPlatformAssertions.mjs";
import { registerMetaAdsPromptAssertions } from "./metaAdsPromptAssertions.mjs";
import { registerMacOSGuidePointAssertions } from "./macOSGuidePointAssertions.mjs";
import { registerMacOSOutcomeVerifierAssertions } from "./macOSOutcomeVerifierAssertions.mjs";
import { registerMacOSProductSurfaceAssertions } from "./macOSProductSurfaceAssertions.mjs";
import { registerMacOSSensorFusionAssertions } from "./macOSSensorFusionAssertions.mjs";
import { registerMacOSTelemetryAssertions } from "./macOSTelemetryAssertions.mjs";
import { registerMacOSVoiceSurfaceAssertions } from "./macOSVoiceSurfaceAssertions.mjs";
import { registerMacOSVisionClientAssertions } from "./macOSVisionClientAssertions.mjs";
import { registerOpenAIContractAssertions } from "./openAIContractAssertions.mjs";
import { registerOpenAIResponseValidationAssertions } from "./openAIResponseValidationAssertions.mjs";
import { registerOperationalRetentionAssertions } from "./operationalRetentionAssertions.mjs";
import { registerStripeWebhookAssertions } from "./stripeWebhookAssertions.mjs";
import { registerVisionGuideManualBoundaryAssertions } from "./visionGuideManualBoundaryAssertions.mjs";
import { registerVisionGuidePayloadAssertions } from "./visionGuidePayloadAssertions.mjs";
import { registerVisionGuidePointSafetyAssertions } from "./visionGuidePointSafetyAssertions.mjs";
import { registerVisionGuidePromptResponseAssertions } from "./visionGuidePromptResponseAssertions.mjs";
import { registerWorkerArchitectureAssertions } from "./workerArchitectureAssertions.mjs";
import { registerWorktreeReviewAssertions } from "./worktreeReviewAssertions.mjs";
import {
  baseEnv,
  capturedHeader,
  fetchVisionGuideWithMockedGuideOutput,
  fetchWorker,
  MockD1Database,
  request,
  runSmokeTests,
  sha256HexForTest,
  stripeSignatureHeader,
  TEST_MAGIC_LINK_TOKEN,
  TEST_SESSION_TOKEN,
  test,
  TestExecutionContext,
  worker,
  workerRoot,
} from "./smokeHarness.mjs";
import { registerVisualGroundingRedTeamAssertions } from "./visualGroundingRedTeamAssertions.mjs";

registerMetaKnowledgeAssertions({ test, workerRoot });
registerHttpSurfaceAssertions({ test, baseEnv, fetchWorker, request });
registerMacOSProductSurfaceAssertions({ test, workerRoot });
registerWorkerArchitectureAssertions({ test, workerRoot });
registerWorktreeReviewAssertions({ test, workerRoot });
registerMacOSGuidePointAssertions({ test, workerRoot });
registerMacOSTelemetryAssertions({ test, workerRoot });
registerGroundingTelemetryAuditAssertions({ test, workerRoot });
registerMacOSOutcomeVerifierAssertions({ test, workerRoot });
registerMacOSSensorFusionAssertions({ test, workerRoot });
registerMacOSVisionClientAssertions({ test, workerRoot });
registerMacOSVoiceSurfaceAssertions({ test, workerRoot });
registerVisualGroundingRedTeamAssertions({ test, workerRoot });
registerMetaAdsPlatformAssertions({ test, workerRoot });
registerMetaAdsPromptAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validGuideOutput,
  validVisionGuideBody,
});
registerAIRouteSecurityAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validVisionGuideBody,
});
registerAIRouteGatewayAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  MockD1Database,
  TEST_SESSION_TOKEN,
  unpaidUserRow,
  validVisionGuideBody,
});
registerOpenAIContractAssertions({
  test,
  baseEnv,
  capturedHeader,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validGuideOutput,
  validVisionGuideBody,
});
registerOpenAIResponseValidationAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validVisionGuideBody,
});
registerVisionGuidePayloadAssertions({
  test,
  fetchVisionGuideWithMockedGuideOutput,
  validGuideOutput,
  guidePoint,
  testElementId,
});
registerVisionGuidePointSafetyAssertions({
  test,
  baseEnv,
  fetchVisionGuideWithMockedGuideOutput,
  validGuideOutput,
  validVisionGuideBody,
  guidePoint,
  testElementId,
  semanticGroundingElement,
  semanticGroundingForPointLabels,
  semanticGroundingTarget,
});
registerVisionGuideManualBoundaryAssertions({
  test,
  fetchVisionGuideWithMockedGuideOutput,
  validGuideOutput,
  guidePoint,
  testElementId,
});
registerVisionGuidePromptResponseAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validGuideOutput,
  validVisionGuideBody,
  guidePoint,
  testElementId,
  semanticGroundingElement,
  semanticGroundingForPointLabels,
  semanticGroundingTarget,
});

registerGroundingReplayAssertions({ test, workerRoot });

registerAuthSessionAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  MockD1Database,
  TEST_MAGIC_LINK_TOKEN,
  TEST_SESSION_TOKEN,
  paidUserRow,
  sha256HexForTest,
  validVisionGuideBody,
});

registerBillingCheckoutPortalAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  MockD1Database,
  TEST_SESSION_TOKEN,
  paidUserRow,
  unpaidUserRow,
});

registerStripeWebhookAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  stripeSignatureHeader,
});

registerOperationalRetentionAssertions({
  test,
  baseEnv,
  TestExecutionContext,
  worker,
});

await runSmokeTests();
