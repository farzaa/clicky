import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerMacOSVisionClientAssertions({ test, workerRoot }) {
  test("macOS Vision guide contracts stay separate from Worker HTTP transport", () => {
    const contractsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "OpenAIAPI.swift"),
      "utf8"
    );
    const guideContentLimitsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGuideContentLimits.swift"),
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
    const clientSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "OpenAIVisionGuideClient.swift"),
      "utf8"
    );
    const sanitizationSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderGuideResponseSanitization.swift"),
      "utf8"
    );

    assert.match(contractsSource, /struct SpiderGuideResponse: Codable, Equatable/);
    assert.match(contractsSource, /enum OpenAIVisionGuideClientError: Error/);
    assert.doesNotMatch(contractsSource, /final class OpenAIVisionGuideClient/);
    assert.doesNotMatch(contractsSource, /URLSessionConfiguration/);
    assert.doesNotMatch(contractsSource, /func sanitizedForUse\(\) throws -> SpiderGuideResponse/);
    assert.doesNotMatch(contractsSource, /func sanitizedForLocalStorage\(\) -> SpiderArtifact\?/);
    assert.doesNotMatch(contractsSource, /enum SpiderContentLimits/);
    assert.doesNotMatch(contractsSource, /struct SpiderPlatformContext/);
    assert.doesNotMatch(contractsSource, /struct SpiderGuideSemanticGrounding/);

    assert.match(guideContentLimitsSource, /enum SpiderContentLimits/);
    assert.match(guideCoreContractsSource, /struct SpiderPlatformContext: Encodable, Equatable/);
    assert.match(guideCoreContractsSource, /enum SpiderGuideExpectedOutcome: String, Codable, Equatable/);
    assert.match(guideGroundingContractsSource, /struct SpiderGuideSemanticGrounding: Codable, Equatable/);
    assert.match(guideGroundingContractsSource, /struct SpiderGuidePoint: Codable, Equatable/);

    assert.match(clientSource, /final class OpenAIVisionGuideClient/);
    assert.match(clientSource, /tokenProvider\(\)\.flatMap\(SpiderWorkerTokenValidator\.normalizedDoubleUUIDV4Token\)/);
    assert.match(clientSource, /let payload = SpiderVisionGuideRequest/);
    assert.match(clientSource, /adMissionSnapshot: adMissionSnapshot\?\.guideSnapshot\(\)/);
    assert.match(clientSource, /boundedConversationHistory/);
    assert.match(clientSource, /maxGuideRequestBytes/);
    assert.match(clientSource, /maxGuideResponseBytes/);
    assert.doesNotMatch(clientSource, /api\.openai\.com/);

    assert.match(sanitizationSource, /func sanitizedForUse\(\) throws -> SpiderGuideResponse/);
    assert.match(sanitizationSource, /func sanitizedForLocalStorage\(\) -> SpiderArtifact\?/);
    assert.match(sanitizationSource, /missingRequiredGuidanceText/);
    assert.doesNotMatch(sanitizationSource, /URLSessionConfiguration/);
  });
}
