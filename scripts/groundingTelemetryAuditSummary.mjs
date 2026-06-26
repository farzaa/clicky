import { assertPrivacySafe } from "./groundingTelemetryAuditPrivacy.mjs";

function increment(map, key) {
  map.set(key, (map.get(key) || 0) + 1);
}

function numericField(fields, key) {
  const value = Number(fields[key]);
  return Number.isFinite(value) ? value : null;
}

function percentile(values, percentileValue) {
  if (values.length === 0) {
    return null;
  }
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.floor((percentileValue / 100) * sorted.length));
  return sorted[index];
}

function createStageStats() {
  return {
    accepted: 0,
    rejected: 0,
    suppressed: 0,
    outcomeConfirmed: 0,
    outcomeNotConfirmed: 0,
    staleTargetBlocked: 0,
    sensorContradictions: 0,
    falseBlockProxy: 0,
  };
}

function createAuditAccumulator() {
  return {
    byStage: new Map(),
    fusionDecisions: new Map(),
    outcomes: new Map(),
    rejections: new Map(),
    shadowRejections: new Map(),
    actionRisks: new Map(),
    calibrationDecisions: new Map(),
    latencies: [],
    timeToDotLatencies: [],
    sensorLatencies: {
      screenshotCaptureLatencyMs: [],
      visionRequestLatencyMs: [],
      workerValidationLatencyMs: [],
      sensorFusionLatencyMs: [],
      ocrLatencyMs: [],
      axLatencyMs: [],
      browserMetadataLatencyMs: [],
      preDotVerificationLatencyMs: [],
    },
    stageStats: new Map(),
    sensorFusionEvents: 0,
    sensorContradictions: 0,
    staleTargetBlocked: 0,
    outcomeNotConfirmed: 0,
    falseBlockProxy: 0,
    shadowCandidates: 0,
    preDotVerificationRequired: 0,
    preDotVerificationTimeout: 0,
    dotSuppressedByLatency: 0,
    fastPathAccepted: 0,
    fastPathBlocked: 0,
  };
}

function statsForStage(stageStats, stageId) {
  const key = stageId || "unknown_stage";
  if (!stageStats.has(key)) {
    stageStats.set(key, createStageStats());
  }
  return stageStats.get(key);
}

function recordEvent(state, event) {
  assertPrivacySafe(event);
  const stageId = event.fields.stageId || "unknown_stage";
  const stats = statsForStage(state.stageStats, stageId);
  increment(state.byStage, stageId);
  if (event.name === "grounding_point_accepted") {
    stats.accepted += 1;
  }
  if (event.name === "grounding_point_rejected") {
    stats.rejected += 1;
  }
  if (event.name === "grounding_point_suppressed") {
    stats.suppressed += 1;
  }
  if (event.name === "grounding_shadow_candidate") {
    state.shadowCandidates += 1;
    increment(state.shadowRejections, event.fields.rejectionReason || "unknown");
  }
  if (event.name === "grounding_sensor_fusion_evaluated") {
    state.sensorFusionEvents += 1;
  }
  if (event.fields.actionRisk) {
    increment(state.actionRisks, event.fields.actionRisk);
  }
  if (event.fields.calibrationDecision) {
    increment(state.calibrationDecisions, event.fields.calibrationDecision);
  }
  if (event.fields.requiresPreDotVerification === "true") {
    state.preDotVerificationRequired += 1;
  }
  if (event.fields.rejectionReason === "pre_dot_verification_timeout") {
    state.preDotVerificationTimeout += 1;
  }
  if (event.fields.dotSuppressedByLatency === "true") {
    state.dotSuppressedByLatency += 1;
  }
  if (event.fields.fastPathDecision === "accepted") {
    state.fastPathAccepted += 1;
  }
  if (event.fields.fastPathDecision === "blocked") {
    state.fastPathBlocked += 1;
  }
  if (event.fields.fusionDecision) {
    increment(state.fusionDecisions, event.fields.fusionDecision);
  }
  const hasContradiction = event.fields.fusionDecision === "contradicted"
    || Boolean(event.fields.contradictedSources)
    || Boolean(event.fields.contradictionReason);
  if (hasContradiction) {
    state.sensorContradictions += 1;
    stats.sensorContradictions += 1;
  }
  const staleReason = [
    event.fields.rejectionReason || "",
    event.fields.contradictionReason || "",
  ].join(",");
  if (/stale|screen_change|target_stale_after_screen_change/i.test(staleReason)) {
    state.staleTargetBlocked += 1;
    stats.staleTargetBlocked += 1;
  }
  if (
    event.name === "grounding_point_rejected"
    && event.fields.rejectionReason === "sensor_fusion_contradicted"
    && event.fields.fusionShouldBlockPoint === "true"
  ) {
    state.falseBlockProxy += 1;
    stats.falseBlockProxy += 1;
  }
  if (event.fields.outcomeStatus) {
    increment(state.outcomes, event.fields.outcomeStatus);
    if (event.fields.outcomeStatus === "outcome_confirmed") {
      stats.outcomeConfirmed += 1;
    } else {
      state.outcomeNotConfirmed += 1;
      stats.outcomeNotConfirmed += 1;
    }
  }
  if (event.fields.rejectionReason) {
    increment(state.rejections, event.fields.rejectionReason);
  }
  const latency = numericField(event.fields, "totalPointDecisionLatencyMs")
    ?? numericField(event.fields, "latencyMs");
  if (latency !== null) {
    state.latencies.push(latency);
  }
  const timeToDot = numericField(event.fields, "timeToDotMs");
  if (timeToDot !== null) {
    state.timeToDotLatencies.push(timeToDot);
  }
  for (const sensorLatencyKey of Object.keys(state.sensorLatencies)) {
    const sensorLatency = numericField(event.fields, sensorLatencyKey);
    if (sensorLatency !== null) {
      state.sensorLatencies[sensorLatencyKey].push(sensorLatency);
    }
  }
}

function sortedObjectFromMap(map) {
  return Object.fromEntries([...map.entries()].sort());
}

function latencySummary(values) {
  return {
    p50: percentile(values, 50),
    p90: percentile(values, 90),
    p95: percentile(values, 95),
    max: values.length ? Math.max(...values) : null,
  };
}

function sensorLatencyP95Summary(entries) {
  return Object.fromEntries(Object.entries(entries).map(([key, values]) => [
    key.replace(/LatencyMs$/, ""),
    percentile(values, 95),
  ]));
}

function dotAvailabilityByStage(stageStats) {
  return Object.fromEntries([...stageStats.entries()].sort().map(([stageId, stats]) => {
    const decisionCount = stats.accepted + stats.rejected + stats.suppressed;
    return [stageId, decisionCount > 0 ? stats.accepted / decisionCount : null];
  }));
}

export function buildSummary(events) {
  const state = createAuditAccumulator();
  for (const event of events) {
    recordEvent(state, event);
  }

  return {
    events: events.length,
    byStage: sortedObjectFromMap(state.byStage),
    fusionDecisions: sortedObjectFromMap(state.fusionDecisions),
    outcomes: sortedObjectFromMap(state.outcomes),
    rejections: sortedObjectFromMap(state.rejections),
    shadowRejections: sortedObjectFromMap(state.shadowRejections),
    actionRisks: sortedObjectFromMap(state.actionRisks),
    calibrationDecisions: sortedObjectFromMap(state.calibrationDecisions),
    visualIntelligence: {
      sensorContradictionRate: state.sensorFusionEvents > 0
        ? state.sensorContradictions / state.sensorFusionEvents
        : null,
      staleTargetBlocked: state.staleTargetBlocked,
      outcomeNotConfirmed: state.outcomeNotConfirmed,
      falseBlockReviewQueue: state.falseBlockProxy,
      shadowCandidates: state.shadowCandidates,
      preDotVerificationRequired: state.preDotVerificationRequired,
      preDotVerificationTimeout: state.preDotVerificationTimeout,
      dotSuppressedByLatency: state.dotSuppressedByLatency,
      fastPathAccepted: state.fastPathAccepted,
      fastPathBlocked: state.fastPathBlocked,
      dotAvailabilityByStage: dotAvailabilityByStage(state.stageStats),
      stageStats: sortedObjectFromMap(state.stageStats),
    },
    latencyMs: latencySummary(state.latencies),
    timeToDotMs: latencySummary(state.timeToDotLatencies),
    totalPointDecisionLatencyMs: latencySummary(state.latencies),
    sensorLatencyP95: sensorLatencyP95Summary(state.sensorLatencies),
  };
}
