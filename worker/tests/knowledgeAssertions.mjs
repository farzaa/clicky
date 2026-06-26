import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

const KNOWLEDGE_SOURCE_TYPES = new Set([
  "official_rule",
  "official_definition",
  "official_guidance",
  "spider_playbook",
  "user_context",
  "mixed",
]);
const KNOWLEDGE_STATUSES = new Set(["active", "needs_review", "outdated", "deprecated"]);
const KNOWLEDGE_RISK_LEVELS = new Set(["low", "medium", "high", "critical"]);
const KNOWLEDGE_DECISIONS = new Set([
  "safe_to_continue",
  "continue_with_warning",
  "fix_before_publish",
  "needs_more_signal",
  "do_not_publish",
  "manual_confirmation_required",
]);
const OFFICIAL_SOURCE_TYPES = new Set(["official_rule", "official_definition", "official_guidance"]);
const SPIDER_PLAYBOOK_OFFICIAL_LANGUAGE_PATTERN =
  /\b(Meta requires|Meta policy says|officially required|official policy requires|Meta officially requires)\b/i;

const REQUIRED_KNOWLEDGE_FILES = [
  "source_registry.json",
  "meta_ad_review_rules.json",
  "meta_campaign_objectives.json",
  "meta_preflight_checks.json",
  "meta_creative_policy_risks.json",
  "meta_tracking_readiness_checks.json",
  "meta_72h_review_playbook.json",
  "meta_guided_setup_steps.json",
  "meta_decision_types.json",
];

const REQUIRED_KNOWLEDGE_KINDS = [
  "SourceRegistry",
  "PolicyRuleSet",
  "CampaignObjectiveSet",
  "PreflightCheckSet",
  "RiskWarningSet",
  "TrackingReadinessCheckSet",
  "OptimizationDecisionSet",
  "GuidedSetupStepSet",
  "DecisionTypeSet",
];

export function assertMetaKnowledgeCorpus(knowledgeDir) {
  const requiredKinds = new Set(REQUIRED_KNOWLEDGE_KINDS);
  const sourceRegistry = JSON.parse(readFileSync(path.join(knowledgeDir, "source_registry.json"), "utf8"));
  const registeredSourceIds = new Set();

  assert.equal(sourceRegistry.kind, "SourceRegistry");
  assert.equal(sourceRegistry.schema_version, 1);
  assert.equal(sourceRegistry.status, "active");
  assert.match(sourceRegistry.retrieved_at, /^\d{4}-\d{2}-\d{2}$/);
  assert.match(sourceRegistry.last_verified_at, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(Array.isArray(sourceRegistry.sources));
  assert.ok(sourceRegistry.sources.length >= 2);

  for (const source of sourceRegistry.sources) {
    assertSourceRegistryItem(source);
    registeredSourceIds.add(source.id);
  }

  for (const fileName of REQUIRED_KNOWLEDGE_FILES) {
    const parsed = JSON.parse(readFileSync(path.join(knowledgeDir, fileName), "utf8"));
    assert.equal(parsed.schema_version, 1);
    assert.ok(KNOWLEDGE_STATUSES.has(parsed.status), `${fileName} has invalid status`);
    assert.match(parsed.retrieved_at, /^\d{4}-\d{2}-\d{2}$/);
    assert.match(parsed.last_verified_at, /^\d{4}-\d{2}-\d{2}$/);
    requiredKinds.delete(parsed.kind);

    if (fileName === "source_registry.json") {
      continue;
    }

    assert.equal(parsed.platform, "meta_ads");
    if (parsed.kind === "GuidedSetupStepSet") {
      assertGuidedSetupSteps(parsed);
    }
    for (const item of knowledgeItems(parsed)) {
      assertKnowledgeItem(item, fileName, registeredSourceIds);
    }
  }

  assert.deepEqual([...requiredKinds], []);
}

function assertSourceRegistryItem(source) {
  assert.equal(typeof source.id, "string");
  assert.ok(source.id.length > 0);
  assert.equal(typeof source.platform, "string");
  assert.equal(typeof source.title, "string");
  assert.equal(typeof source.source_url, "string");
  assert.match(source.retrieved_at, /^\d{4}-\d{2}-\d{2}$/);
  assert.match(source.last_verified_at, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(KNOWLEDGE_SOURCE_TYPES.has(source.source_type), `${source.id} has invalid source_type`);
  assert.ok(KNOWLEDGE_STATUSES.has(source.status), `${source.id} has invalid status`);
  assert.ok(Array.isArray(source.topics));
  assert.ok(source.topics.length > 0);
}

function knowledgeItems(parsed) {
  const collectionKeys = [
    "rules",
    "objectives",
    "checks",
    "warnings",
    "steps",
    "decisions",
    "decisionTypes",
  ];
  return collectionKeys.flatMap((key) => (Array.isArray(parsed[key]) ? parsed[key] : []));
}

function assertKnowledgeItem(item, fileName, registeredSourceIds) {
  assert.equal(typeof item.id, "string", `${fileName} item missing id`);
  assert.equal(typeof item.platform, "string", `${item.id} missing platform`);
  assert.equal(typeof item.topic, "string", `${item.id} missing topic`);
  assert.equal(typeof item.sourceType, "string", `${item.id} missing sourceType`);
  assert.ok(KNOWLEDGE_SOURCE_TYPES.has(item.sourceType), `${item.id} has invalid sourceType ${item.sourceType}`);
  assert.ok(KNOWLEDGE_STATUSES.has(item.status), `${item.id} has invalid status`);
  assert.equal(typeof item.description, "string", `${item.id} missing description`);

  if (item.retrieved_at !== undefined) {
    assert.match(item.retrieved_at, /^\d{4}-\d{2}-\d{2}$/, `${item.id} has invalid retrieved_at`);
  }
  if (item.last_verified_at !== undefined) {
    assert.match(item.last_verified_at, /^\d{4}-\d{2}-\d{2}$/, `${item.id} has invalid last_verified_at`);
  }
  if (item.riskLevel !== undefined) {
    assert.ok(KNOWLEDGE_RISK_LEVELS.has(item.riskLevel), `${item.id} has invalid riskLevel`);
  }
  if (item.decision !== undefined) {
    assert.ok(KNOWLEDGE_DECISIONS.has(item.decision), `${item.id} has invalid decision`);
  }
  if (item.failureDecision !== undefined) {
    assert.ok(KNOWLEDGE_DECISIONS.has(item.failureDecision), `${item.id} has invalid failureDecision`);
  }

  if (OFFICIAL_SOURCE_TYPES.has(item.sourceType)) {
    assert.equal(typeof item.source_id, "string", `${item.id} official item missing source_id`);
  }

  if (item.source_id !== undefined) {
    assert.ok(registeredSourceIds.has(item.source_id), `${item.id} references unknown source_id ${item.source_id}`);
  }
  if (item.source_ids !== undefined) {
    assert.ok(Array.isArray(item.source_ids), `${item.id} source_ids must be an array`);
    assert.ok(item.source_ids.length > 0, `${item.id} source_ids must not be empty`);
    for (const sourceId of item.source_ids) {
      assert.ok(registeredSourceIds.has(sourceId), `${item.id} references unknown source_id ${sourceId}`);
    }
  }

  if (item.sourceType === "spider_playbook") {
    const itemText = JSON.stringify(item);
    assert.doesNotMatch(itemText, SPIDER_PLAYBOOK_OFFICIAL_LANGUAGE_PATTERN, `${item.id} playbook item uses official-source language`);
  }
}

function assertGuidedSetupSteps(parsed) {
  assert.ok(Array.isArray(parsed.steps));
  assert.ok(parsed.steps.length >= 11);

  const requiredStepIds = new Set([
    "open_ads_manager",
    "open_create_campaign",
    "choose_recommended_objective",
    "choose_sales_for_sales_mission",
    "name_campaign",
    "manual_budget_review",
    "configure_audience",
    "configure_creative",
    "configure_tracking_event",
    "stop_before_publish",
    "run_preflight_audit",
  ]);

  for (const step of parsed.steps) {
    requiredStepIds.delete(step.id);
    assert.equal(typeof step.title, "string", `${step.id} missing title`);
    assert.equal(typeof step.instruction, "string", `${step.id} missing instruction`);
    assert.equal(typeof step.whyThisMatters, "string", `${step.id} missing whyThisMatters`);
    assert.equal(typeof step.riskIfWrong, "string", `${step.id} missing riskIfWrong`);
    assert.equal(typeof step.expectedScreenContext, "string", `${step.id} missing expectedScreenContext`);
    assert.equal(typeof step.nextAction, "string", `${step.id} missing nextAction`);
  }

  assert.deepEqual([...requiredStepIds], []);
}
