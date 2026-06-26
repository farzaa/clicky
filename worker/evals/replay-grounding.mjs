#!/usr/bin/env node

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

const args = parseArgs(process.argv.slice(2));
const screenshotPath = args.screenshot;
const guidePath = args.guide;
const outputPath = args.out || path.join("worker", "evals", "reports", "latest.html");

if (!screenshotPath || !guidePath) {
  process.stderr.write(
    "Usage: node worker/evals/replay-grounding.mjs --screenshot /tmp/screen.png --guide /tmp/guide.json [--out worker/evals/reports/latest.html]\n"
  );
  process.exit(1);
}

const screenshotBytes = readFileSync(screenshotPath);
const guide = JSON.parse(readFileSync(guidePath, "utf8"));
const semanticGrounding = guide.semanticGrounding || {};
const point = guide.point || null;
const imageSize = imageDimensions(screenshotBytes, screenshotPath)
  || inferredDimensions(semanticGrounding, point);
const mimeType = mimeTypeForPath(screenshotPath);
const encodedImage = screenshotBytes.toString("base64");
const safeTargets = Array.isArray(semanticGrounding.interactiveTargets)
  ? semanticGrounding.interactiveTargets
  : [];
const blockedTargets = Array.isArray(semanticGrounding.blockedTargets)
  ? semanticGrounding.blockedTargets
  : [];
const sceneGraphElements = Array.isArray(semanticGrounding.elements)
  ? semanticGrounding.elements
  : [];
const matchedTarget = point
  ? safeTargets.find((target) => targetMatchesPoint(target, point))
  : null;

mkdirSync(path.dirname(outputPath), { recursive: true });
writeFileSync(outputPath, renderReport({
  screenshotPath,
  guidePath,
  encodedImage,
  mimeType,
  width: imageSize.width,
  height: imageSize.height,
  guide,
  semanticGrounding,
  sceneGraphElements,
  safeTargets,
  blockedTargets,
  matchedTarget,
  point,
  rejectionReason: args.reason || guide.rejectionReason || (point ? null : "No point returned"),
}));

process.stdout.write(`${outputPath}\n`);

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--")) {
      continue;
    }
    parsed[key.slice(2)] = argv[index + 1];
    index += 1;
  }
  return parsed;
}

function renderReport(input) {
  const elementOverlays = input.sceneGraphElements
    .filter((element) => element.region)
    .map((element) => rectOverlay(element, "scene-element", element.occluded ? "Occluded scene element" : "Scene element"))
    .join("\n");
  const safeOverlays = input.safeTargets
    .filter((target) => target.region)
    .map((target) => rectOverlay(target, "safe-target", target === input.matchedTarget ? "Matched safe target" : "Safe target"))
    .join("\n");
  const blockedOverlays = input.blockedTargets
    .filter((target) => target.region)
    .map((target) => rectOverlay(target, "blocked-target", "Blocked target"))
    .join("\n");
  const pointOverlay = input.point
    ? `<circle class="final-dot" cx="${numberAttr(input.point.x)}" cy="${numberAttr(input.point.y)}" r="10" />`
    : "";
  const summary = {
    screenState: input.guide.screenState || "unknown",
    screenConfidence: input.guide.screenConfidence || "unknown",
    groundingRevision: input.semanticGrounding.groundingRevision || "missing",
    semanticSignature: input.semanticGrounding.semanticSignature || "missing",
    point: input.point,
    rejectionReason: input.rejectionReason || null,
  };

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Spider Grounding Replay</title>
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
      background: #0b0c0f;
    }
    main {
      max-width: 1280px;
      margin: 0 auto;
    }
    h1 {
      margin: 0 0 12px;
      font-size: 20px;
      font-weight: 700;
      letter-spacing: 0;
    }
    .meta {
      display: grid;
      gap: 8px;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      margin-bottom: 16px;
      color: #cbd2dc;
      font-size: 13px;
    }
    .stage {
      position: relative;
      width: min(100%, ${input.width}px);
      aspect-ratio: ${input.width} / ${input.height};
      background: #11151c;
      border: 1px solid rgba(255,255,255,0.16);
      overflow: hidden;
    }
    .stage img,
    .stage svg {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
    }
    .safe-target {
      fill: rgba(52, 211, 153, 0.16);
      stroke: #34d399;
      stroke-width: 3;
    }
    .blocked-target {
      fill: rgba(248, 113, 113, 0.18);
      stroke: #f87171;
      stroke-width: 3;
    }
    .scene-element {
      fill: rgba(96, 165, 250, 0.1);
      stroke: #60a5fa;
      stroke-width: 2;
      stroke-dasharray: 8 6;
    }
    .matched-safe-target {
      fill: rgba(250, 204, 21, 0.2);
      stroke: #facc15;
      stroke-width: 4;
    }
    .final-dot {
      fill: #050505;
      stroke: rgba(255,255,255,0.9);
      stroke-width: 4;
      filter: drop-shadow(0 0 8px rgba(255,255,255,0.5));
    }
    pre {
      margin: 16px 0 0;
      padding: 16px;
      overflow: auto;
      border: 1px solid rgba(255,255,255,0.14);
      background: #11151c;
      color: #dce3ec;
      font-size: 12px;
      line-height: 1.5;
    }
  </style>
</head>
<body>
  <main>
    <h1>Spider Grounding Replay</h1>
    <section class="meta">
      <div><strong>Screenshot:</strong> ${escapeHtml(input.screenshotPath)}</div>
      <div><strong>Guide JSON:</strong> ${escapeHtml(input.guidePath)}</div>
      <div><strong>Image:</strong> ${input.width}x${input.height}</div>
      <div><strong>Reason:</strong> ${escapeHtml(input.rejectionReason || "point accepted")}</div>
    </section>
    <section class="stage" aria-label="Grounding overlay">
      <img alt="" src="data:${input.mimeType};base64,${input.encodedImage}">
      <svg viewBox="0 0 ${input.width} ${input.height}" role="img" aria-label="Grounding regions">
        ${elementOverlays}
        ${safeOverlays}
        ${blockedOverlays}
        ${pointOverlay}
      </svg>
    </section>
    <pre>${escapeHtml(JSON.stringify(summary, null, 2))}</pre>
  </main>
</body>
</html>
`;
}

function rectOverlay(target, className, title) {
  const region = target.region;
  const finalClassName = title === "Matched safe target" ? "matched-safe-target" : className;
  return `<rect class="${finalClassName}" x="${numberAttr(region.x)}" y="${numberAttr(region.y)}" width="${numberAttr(region.width)}" height="${numberAttr(region.height)}">
  <title>${escapeHtml(`${title}: ${target.label || "unlabeled"}`)}</title>
</rect>`;
}

function targetMatchesPoint(target, point) {
  if (!target || !point?.label || !target.region) {
    return false;
  }
  const label = normalize(point.label);
  const targetText = normalize([
    target.label,
    target.semanticIntent,
    target.parentLabel,
    ...(Array.isArray(target.nearestText) ? target.nearestText : []),
    ...(Array.isArray(target.evidence) ? target.evidence : []),
  ].filter(Boolean).join(" "));
  return targetText.includes(label)
    && point.x >= target.region.x
    && point.y >= target.region.y
    && point.x <= target.region.x + target.region.width
    && point.y <= target.region.y + target.region.height;
}

function inferredDimensions(semanticGrounding, point) {
  const regions = [
    ...(Array.isArray(semanticGrounding.interactiveTargets) ? semanticGrounding.interactiveTargets : []),
    ...(Array.isArray(semanticGrounding.blockedTargets) ? semanticGrounding.blockedTargets : []),
  ].map((target) => target.region).filter(Boolean);
  const maxRegionX = regions.reduce((max, region) => Math.max(max, region.x + region.width), 0);
  const maxRegionY = regions.reduce((max, region) => Math.max(max, region.y + region.height), 0);
  return {
    width: Math.max(1, Math.ceil(Math.max(maxRegionX, point?.x || 0))),
    height: Math.max(1, Math.ceil(Math.max(maxRegionY, point?.y || 0))),
  };
}

function imageDimensions(bytes, filePath) {
  if (bytes.length >= 24 && bytes.toString("ascii", 1, 4) === "PNG") {
    return {
      width: bytes.readUInt32BE(16),
      height: bytes.readUInt32BE(20),
    };
  }
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    return jpegDimensions(bytes);
  }
  const width = Number.parseInt(process.env.SPIDER_REPLAY_WIDTH || "", 10);
  const height = Number.parseInt(process.env.SPIDER_REPLAY_HEIGHT || "", 10);
  if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
    return { width, height };
  }
  process.stderr.write(`Could not infer dimensions for ${filePath}; falling back to region bounds.\n`);
  return null;
}

function jpegDimensions(bytes) {
  let offset = 2;
  while (offset < bytes.length) {
    if (bytes[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    const marker = bytes[offset + 1];
    const length = bytes.readUInt16BE(offset + 2);
    if (marker >= 0xc0 && marker <= 0xc3) {
      return {
        height: bytes.readUInt16BE(offset + 5),
        width: bytes.readUInt16BE(offset + 7),
      };
    }
    offset += 2 + length;
  }
  return null;
}

function mimeTypeForPath(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === ".png") {
    return "image/png";
  }
  if (ext === ".webp") {
    return "image/webp";
  }
  return "image/jpeg";
}

function normalize(value) {
  return String(value).trim().toLowerCase().replace(/\s+/g, " ");
}

function numberAttr(value) {
  return Number.isFinite(value) ? String(value) : "0";
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
