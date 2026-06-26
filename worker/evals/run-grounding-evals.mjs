#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const evalRoot = path.dirname(fileURLToPath(import.meta.url));
const workerRoot = path.resolve(evalRoot, "..");
const casesDir = path.join(evalRoot, "cases");
const reportsDir = path.join(evalRoot, "reports");
const replayScript = path.join(evalRoot, "replay-grounding.mjs");

mkdirSync(reportsDir, { recursive: true });

const caseFiles = readdirSync(casesDir)
  .filter((fileName) => fileName.endsWith(".json"))
  .sort();

const results = caseFiles.map((fileName) => runCase(path.join(casesDir, fileName)));
writeFileSync(path.join(reportsDir, "index.html"), renderIndex(results));
process.stdout.write(`${path.join(reportsDir, "index.html")}\n`);

function runCase(casePath) {
  const config = JSON.parse(readFileSync(casePath, "utf8"));
  const caseName = sanitizeSlug(config.name || path.basename(casePath, ".json"));
  const screenshotPath = resolveCasePath(casePath, config.screenshot);
  const guidePath = resolveCasePath(casePath, config.guide);
  const reportPath = path.join(reportsDir, `${caseName}.html`);

  if (!existsSync(screenshotPath) || !existsSync(guidePath)) {
    return {
      name: caseName,
      status: "missing_fixture",
      reportPath,
      reason: "Screenshot or guide JSON is missing",
    };
  }

  const args = [
    replayScript,
    "--screenshot",
    screenshotPath,
    "--guide",
    guidePath,
    "--out",
    reportPath,
  ];
  if (typeof config.reason === "string" && config.reason.length > 0) {
    args.push("--reason", config.reason);
  }

  const result = spawnSync(process.execPath, args, {
    cwd: workerRoot,
    encoding: "utf8",
  });

  return {
    name: caseName,
    status: result.status === 0 ? "ok" : "failed",
    reportPath,
    reason: result.status === 0 ? "" : result.stderr || result.stdout || "Replay failed",
  };
}

function resolveCasePath(casePath, value) {
  if (typeof value !== "string" || value.length === 0) {
    return "";
  }
  return path.isAbsolute(value) ? value : path.resolve(path.dirname(casePath), value);
}

function renderIndex(results) {
  const rows = results.map((result) => {
    const href = path.basename(result.reportPath);
    return `<tr>
  <td>${escapeHtml(result.name)}</td>
  <td>${escapeHtml(result.status)}</td>
  <td>${result.status === "ok" ? `<a href="${escapeHtml(href)}">report</a>` : ""}</td>
  <td>${escapeHtml(result.reason)}</td>
</tr>`;
  }).join("\n");

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Spider Grounding Eval Index</title>
  <style>
    :root {
      color-scheme: dark;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #0b0c0f;
      color: #f4f6f8;
    }
    body {
      margin: 0;
      padding: 24px;
    }
    main {
      max-width: 1080px;
      margin: 0 auto;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      border: 1px solid rgba(255,255,255,0.16);
    }
    th,
    td {
      padding: 10px 12px;
      border-bottom: 1px solid rgba(255,255,255,0.12);
      text-align: left;
      font-size: 13px;
    }
    a {
      color: #93c5fd;
    }
  </style>
</head>
<body>
  <main>
    <h1>Spider Grounding Eval Index</h1>
    <p>Local crash-test reports only. Do not commit real screenshots or guide captures.</p>
    <table>
      <thead>
        <tr><th>Case</th><th>Status</th><th>Report</th><th>Reason</th></tr>
      </thead>
      <tbody>
        ${rows || "<tr><td colspan=\"4\">No local cases found.</td></tr>"}
      </tbody>
    </table>
  </main>
</body>
</html>
`;
}

function sanitizeSlug(value) {
  return String(value).trim().toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-|-$/g, "") || "case";
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
