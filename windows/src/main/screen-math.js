'use strict';
/*
 * Coordinate mapping between what the model sees (labeled screenshots) and the
 * desktop (global DIP coordinates, top-left origin, as used by Electron).
 *
 * capture = { bounds:{x,y,width,height} (DIP), screenshotWidth, screenshotHeight, isCursorScreen }
 * space   = 'normalized' (model answers on a 0..1000 grid) | 'pixels' (screenshot pixels)
 */

const MAX_SCREENSHOT_DIMENSION = 1280;
const NORMALIZED_GRID = 1000;

function clamp(v, lo, hi) {
  return Math.min(Math.max(v, lo), hi);
}

function screenshotSizeForDisplay(width, height, max = MAX_SCREENSHOT_DIMENSION) {
  const longest = Math.max(width, height);
  if (longest <= max) return { width: Math.round(width), height: Math.round(height) };
  const scale = max / longest;
  return { width: Math.round(width * scale), height: Math.round(height * scale) };
}

function coordinateSpaceSize(capture, space) {
  if (space === 'normalized') return { width: NORMALIZED_GRID, height: NORMALIZED_GRID };
  return { width: capture.screenshotWidth, height: capture.screenshotHeight };
}

function mapModelPointToGlobal(point, capture, space = 'normalized') {
  const size = coordinateSpaceSize(capture, space);
  const fx = clamp(point.x, 0, size.width) / size.width;
  const fy = clamp(point.y, 0, size.height) / size.height;
  return {
    x: Math.round(capture.bounds.x + fx * capture.bounds.width),
    y: Math.round(capture.bounds.y + fy * capture.bounds.height),
  };
}

// DIP per model unit (horizontal), for radii / lengths.
function modelLengthScale(capture, space = 'normalized') {
  const size = coordinateSpaceSize(capture, space);
  return capture.bounds.width / size.width;
}

function pickTargetCapture(captures, screenNumber) {
  if (screenNumber && screenNumber >= 1 && screenNumber <= captures.length) return captures[screenNumber - 1];
  return captures.find((c) => c.isCursorScreen) || captures[0] || null;
}

function buildScreenLabel(index, total, isCursorScreen, width, height) {
  const n = index + 1;
  const base =
    total === 1
      ? 'user\'s screen (cursor is here)'
      : isCursorScreen
        ? `screen ${n} of ${total} — cursor is on this screen (primary focus)`
        : `screen ${n} of ${total} — secondary screen`;
  return `${base} (image dimensions: ${width}x${height} pixels)`;
}

// Inverse of mapModelPointToGlobal: global DIP point -> model coordinates of a capture.
function globalToModelPoint(point, capture, space = 'normalized') {
  const size = coordinateSpaceSize(capture, space);
  return {
    x: Math.round(clamp((point.x - capture.bounds.x) / capture.bounds.width, 0, 1) * size.width),
    y: Math.round(clamp((point.y - capture.bounds.y) / capture.bounds.height, 0, 1) * size.height),
  };
}

// Converts a parsed DRAW tag (model coordinates) into global DIP geometry.
function mapDrawToGlobal(draw, captures, space = 'normalized') {
  const cap = pickTargetCapture(captures, draw.screen);
  if (!cap) return null;
  const n = draw.nums;
  const pt = (x, y) => mapModelPointToGlobal({ x, y }, cap, space);
  const out = { kind: draw.kind, label: draw.label, points: [], r: 0, bounds: cap.bounds };
  switch (draw.kind) {
    case 'circle':
      out.points = [pt(n[0], n[1])];
      out.r = Math.max(6, (n[2] || 30) * modelLengthScale(cap, space));
      break;
    case 'text':
    case 'step':
      out.points = [pt(n[0], n[1])];
      break;
    case 'path': {
      for (let i = 0; i + 1 < n.length; i += 2) out.points.push(pt(n[i], n[i + 1]));
      if (out.points.length < 2) return null;
      break;
    }
    default:
      out.points = [pt(n[0], n[1]), pt(n[2], n[3])];
  }
  return out;
}

function pointInRect(p, r) {
  return p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + r.height;
}

function globalToLocal(p, bounds) {
  return { x: p.x - bounds.x, y: p.y - bounds.y };
}

// Physical-pixel rect (UI Automation) -> model coordinate space of a capture.
function physicalRectToModelSpace(rect, capture, scaleFactor, space = 'normalized') {
  const size = coordinateSpaceSize(capture, space);
  const dipX = rect.x / scaleFactor;
  const dipY = rect.y / scaleFactor;
  const dipW = rect.width / scaleFactor;
  const dipH = rect.height / scaleFactor;
  const sx = size.width / capture.bounds.width;
  const sy = size.height / capture.bounds.height;
  return {
    x: Math.round((dipX - capture.bounds.x) * sx),
    y: Math.round((dipY - capture.bounds.y) * sy),
    width: Math.round(dipW * sx),
    height: Math.round(dipH * sy),
  };
}

module.exports = {
  MAX_SCREENSHOT_DIMENSION,
  NORMALIZED_GRID,
  clamp,
  screenshotSizeForDisplay,
  coordinateSpaceSize,
  mapModelPointToGlobal,
  globalToModelPoint,
  mapDrawToGlobal,
  modelLengthScale,
  pickTargetCapture,
  buildScreenLabel,
  pointInRect,
  globalToLocal,
  physicalRectToModelSpace,
};
