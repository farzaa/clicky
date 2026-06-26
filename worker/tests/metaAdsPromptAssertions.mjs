import assert from "node:assert/strict";

export function registerMetaAdsPromptAssertions({
  test,
  baseEnv,
  fetchWorker,
  request,
  TEST_SESSION_TOKEN,
  validGuideOutput,
  validVisionGuideBody,
}) {
  test("vision guide does not let guided poll instructions poison screen-stage detection", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    let openAIRequestBody = {};

    globalThis.fetch = async (_url, init) => {
      openAIRequestBody = JSON.parse(init.body);

      return new Response(JSON.stringify({
        output_text: JSON.stringify(validGuideOutput()),
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };

    try {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "content-type": "application/json",
            "x-spider-device-id": "device_test",
          },
          body: JSON.stringify(validVisionGuideBody({
            userTranscript:
              "Guided setup visual poll. Recognized paid ads screens include login, 2FA/auth checkpoint, account picker, dashboard, campaign table, create campaign, objective, campaign settings, budget, audience, creative, tracking, review/publish, billing/payment, account quality/policy, and reporting.",
            platformContext: {
              candidatePlatformId: "meta_ads",
              source: "app",
            },
          })),
        }),
        env
      );
      const promptText = openAIRequestBody.input[0].content[0].text;
      assert.equal(response.status, 200);
      assert.match(promptText, /"detectedScreenStage":\{"screenId":"unknown_screen","stageId":"unknown_stage","confidence":"low"/);
      assert.doesNotMatch(promptText, /"detectedScreenStage":\{"screenId":"login","stageId":"authenticate"/);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });

  test("vision guide injects only relevant Meta best practices for the detected stage", async () => {
    const env = baseEnv();
    const previousFetch = globalThis.fetch;
    let openAIRequestBody = {};

    globalThis.fetch = async (_url, init) => {
      openAIRequestBody = JSON.parse(init.body);

      return new Response(JSON.stringify({
        output_text: JSON.stringify(validGuideOutput()),
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };

    try {
      const response = await fetchWorker(
        request("/vision/guide", {
          method: "POST",
          headers: {
            authorization: `Bearer ${TEST_SESSION_TOKEN}`,
            "content-type": "application/json",
            "x-spider-device-id": "device_test",
          },
          body: JSON.stringify(validVisionGuideBody({
            platformContext: {
              candidatePlatformId: "meta_ads",
              source: "app",
              visibleURLHost: "adsmanager.facebook.com",
            },
            screenshots: [
              {
                ...validVisionGuideBody().screenshots[0],
                label: "Meta objective selection screen with objective choices",
              },
            ],
            adMissionSnapshot: {
              recommendedChannel: "Meta Ads",
              businessObjective: "Sell a paid offer",
              campaignDirection: {
                recommendedObjective: "Sales",
              },
            },
          })),
        }),
        env
      );
      const promptText = openAIRequestBody.input[0].content[0].text;
      const bestPracticeSectionStart = promptText.indexOf("Relevant Meta Ads best practices");
      const bestPracticeSectionEnd = promptText.indexOf("Active platform knowledge and playbook inventory");
      const bestPracticeSection = promptText.slice(bestPracticeSectionStart, bestPracticeSectionEnd);

      assert.equal(response.status, 200);
      assert.match(promptText, /Relevant Meta Ads best practices/);
      assert.match(promptText, /objective_match_mission/);
      assert.match(promptText, /sales_objective_for_sales_mission/);
      assert.match(promptText, /Safety policy overrides Meta best practices/);
      assert.doesNotMatch(promptText, /audience_keep_signal_concentrated/);
      assert.doesNotMatch(promptText, /creative_offer_cta_destination_alignment/);
      assert.doesNotMatch(promptText, /budget_is_manual_boundary/);
      assert.doesNotMatch(bestPracticeSection, /\b(?:top|bottom|left|right) (?:corner|side)|blue button|pixel[- ](?:position|coordinate|perfect)|css selector|xpath/i);
    } finally {
      globalThis.fetch = previousFetch;
    }
  });
}
