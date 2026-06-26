#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parseEvents, parseMetricLine } from "./groundingTelemetryAuditParser.mjs";
import { assertPrivacySafe } from "./groundingTelemetryAuditPrivacy.mjs";
import { buildSummary } from "./groundingTelemetryAuditSummary.mjs";
import { runTelemetryAuditSelfTest } from "./groundingTelemetryAuditSelfTest.mjs";

export {
  assertPrivacySafe,
  buildSummary,
  parseEvents,
  parseMetricLine,
  runTelemetryAuditSelfTest,
};

function readInput(paths = process.argv.slice(2)) {
  if (paths.length > 0) {
    return paths.map((path) => readFileSync(path, "utf8")).join("\n");
  }
  return readFileSync(0, "utf8");
}

export function runTelemetryAuditCLI() {
  const args = process.argv.slice(2);
  if (args.includes("--self-test")) {
    console.log(JSON.stringify(runTelemetryAuditSelfTest(), null, 2));
    return;
  }
  const events = parseEvents(readInput(args));
  console.log(JSON.stringify(buildSummary(events), null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  runTelemetryAuditCLI();
}
