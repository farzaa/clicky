import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerMetaAdsPlatformAssertions({ test, workerRoot }) {
  test("Meta Ads platform pack declares essential guidance screens", async () => {
    const metaPackSource = readFileSync(
      path.join(workerRoot, "src", "platforms", "metaAdsPack.ts"),
      "utf8"
    );
    const productFeatureSource = readFileSync(
      path.join(workerRoot, "src", "productFeatures.ts"),
      "utf8"
    );
    const essentialScreenIds = [
      "login",
      "two_factor_auth_checkpoint",
      "account_picker",
      "business_selection",
      "ads_manager_dashboard",
      "campaign_table",
      "create_campaign_entry",
      "objective_selection",
      "campaign_settings",
      "budget_and_schedule",
      "audience_and_placements",
      "creative_and_destination",
      "tracking_conversion_event",
      "review_publish",
      "billing_payment",
      "account_quality_policy",
      "reporting_delivery",
    ];

    for (const screenId of essentialScreenIds) {
      assert.match(metaPackSource, new RegExp(`screenId: "${screenId}"`));
    }
    assert.match(productFeatureSource, /first_step_guided_setup/);
    assert.match(productFeatureSource, /availability: "available"/);
    assert.match(productFeatureSource, /preflight_audit/);
    assert.match(productFeatureSource, /review_72h/);
    assert.match(productFeatureSource, /availability: "locked"/);
    assert.match(metaPackSource, /productFeaturePolicyRules/);
    assert.match(metaPackSource, /productFeatureSupportedActions/);
    assert.match(metaPackSource, /productFeatureUnsupportedActions/);
    assert.match(metaPackSource, /productFeatureCapabilities/);
    assert.match(metaPackSource, /semanticRole/);
    assert.match(metaPackSource, /visualIntentCues/);
    assert.match(metaPackSource, /semanticDecisionHints/);
    assert.match(metaPackSource, /safetyTreatment/);
    assert.match(metaPackSource, /pointingPolicy/);
    assert.match(metaPackSource, /blocked_publish_boundary/);
    assert.match(metaPackSource, /blocked_billing_boundary/);
    assert.match(metaPackSource, /blocked_spend_boundary/);
    assert.doesNotMatch(metaPackSource, /\b(?:top|bottom|left|right) (?:corner|side)|blue button|pixel[- ](?:position|coordinate|perfect)|css selector|xpath/i);
    assert.doesNotMatch(metaPackSource, /id: "preflight_audit",\n\s+description: "Conservative safety gate/);
  });

  test("Meta Ads best practices are semantic stage-scoped decision rules", () => {
    const bestPracticeSource = readFileSync(
      path.join(workerRoot, "src", "platforms", "metaAdsBestPractices.ts"),
      "utf8"
    );

    const requiredRuleIds = [
      "objective_match_mission",
      "budget_is_manual_boundary",
      "audience_keep_signal_concentrated",
      "creative_offer_cta_destination_alignment",
      "tracking_event_match_mission",
      "review_stop_before_publish",
      "billing_payment_blocked",
      "auth_checkpoint_blocked",
    ];

    for (const ruleId of requiredRuleIds) {
      assert.match(bestPracticeSource, new RegExp(`id: "${ruleId}"`));
    }

    assert.match(bestPracticeSource, /Safety policy overrides Meta best practices/);
    assert.match(bestPracticeSource, /sourceIds/);
    assert.match(bestPracticeSource, /stageIds/);
    assert.match(bestPracticeSource, /evidenceNeeded/);
    assert.match(bestPracticeSource, /neverDo/);
    assert.match(bestPracticeSource, /manual_boundary/);
    assert.match(bestPracticeSource, /blocked/);
    assert.doesNotMatch(bestPracticeSource, /\b(?:top|bottom|left|right) (?:corner|side)|blue button|pixel[- ](?:position|coordinate|perfect)|css selector|xpath|x:\s*\d|y:\s*\d/i);
  });
}
