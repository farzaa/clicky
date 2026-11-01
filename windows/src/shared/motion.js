/*
 * Shared animation math, ported 1:1 from OverlayWindow.swift (BlueCursorView).
 * UMD: usable from the overlay renderer (window.ClickyMotion) and from node tests.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ClickyMotion = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // Buddy rests 35 px right / 25 px below the real cursor (SwiftUI y-down space).
  const BUDDY_FOLLOW_OFFSET = { x: 35, y: 25 };
  const RESTING_TRIANGLE_ROTATION_DEGREES = -35;
  const BUBBLE_OFFSET = { x: 10, y: 18 };
  const NAVIGATION_TARGET_OFFSET = { x: 8, y: 12 };
  const NAVIGATION_EDGE_CLAMP = 20;

  function clamp(v, lo, hi) {
    return Math.min(Math.max(v, lo), hi);
  }
  function clamp01(v) {
    return clamp(v, 0, 1);
  }

  function distance(a, b) {
    return Math.hypot(b.x - a.x, b.y - a.y);
  }

  // distance / 800 px per second, clamped to 0.6 .. 1.4 s
  function flightDurationSeconds(dist) {
    return clamp(dist / 800, 0.6, 1.4);
  }

  function smoothstep(t) {
    const x = clamp01(t);
    return x * x * (3 - 2 * x);
  }

  // Control point of the quadratic bezier: midpoint lifted by min(dist*0.2, 80).
  function arcControlPoint(start, end) {
    const dist = distance(start, end);
    const arcHeight = Math.min(dist * 0.2, 80);
    return { x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - arcHeight };
  }

  // progress is linear 0..1; easing is applied here.
  function flightFrame(start, end, progress) {
    const linear = clamp01(progress);
    const t = smoothstep(linear);
    const c = arcControlPoint(start, end);
    const omt = 1 - t;
    const x = omt * omt * start.x + 2 * omt * t * c.x + t * t * end.x;
    const y = omt * omt * start.y + 2 * omt * t * c.y + t * t * end.y;
    const tx = 2 * omt * (c.x - start.x) + 2 * t * (end.x - c.x);
    const ty = 2 * omt * (c.y - start.y) + 2 * t * (end.y - c.y);
    const rotationDegrees = (Math.atan2(ty, tx) * 180) / Math.PI + 90;
    const scale = 1 + 0.3 * Math.sin(Math.PI * linear);
    return { x, y, rotationDegrees, scale };
  }

  // Glow radius that pulses during flight.
  function triangleGlowRadius(scale) {
    return 8 + (scale - 1) * 20;
  }

  // Keep the pointing target away from the very edge of the screen.
  function clampNavigationTarget(point, bounds) {
    const x = point.x + NAVIGATION_TARGET_OFFSET.x;
    const y = point.y + NAVIGATION_TARGET_OFFSET.y;
    return {
      x: clamp(x, bounds.x + NAVIGATION_EDGE_CLAMP, bounds.x + bounds.width - NAVIGATION_EDGE_CLAMP),
      y: clamp(y, bounds.y + NAVIGATION_EDGE_CLAMP, bounds.y + bounds.height - NAVIGATION_EDGE_CLAMP),
    };
  }

  // ---- SwiftUI spring emulation (response / dampingFraction) ----
  function createSpring(response, dampingFraction, initial) {
    const omega = (2 * Math.PI) / response;
    return {
      stiffness: omega * omega,
      damping: 2 * dampingFraction * omega,
      x: initial.x,
      y: initial.y,
      vx: 0,
      vy: 0,
    };
  }

  function stepSpring(spring, target, dtSeconds) {
    // sub-step for stability
    const steps = Math.max(1, Math.ceil(dtSeconds / 0.004));
    const h = dtSeconds / steps;
    for (let i = 0; i < steps; i++) {
      const ax = spring.stiffness * (target.x - spring.x) - spring.damping * spring.vx;
      const ay = spring.stiffness * (target.y - spring.y) - spring.damping * spring.vy;
      spring.vx += ax * h;
      spring.vy += ay * h;
      spring.x += spring.vx * h;
      spring.y += spring.vy * h;
    }
    return spring;
  }

  // ---- Listening waveform (BlueCursorWaveformView.barHeight) ----
  const WAVEFORM_PROFILE = [0.4, 0.7, 1.0, 0.7, 0.4];
  // level: smoothed 0..1 audio power; timeSeconds: wall clock seconds
  function waveformBarHeights(level, timeSeconds) {
    return WAVEFORM_PROFILE.map(function (p, i) {
      const phase = timeSeconds * 3.6 + i * 0.35;
      const normalized = Math.max(level - 0.008, 0);
      const eased = Math.pow(Math.min(normalized * 2.85, 1), 0.76);
      const reactive = eased * 10 * p;
      const idlePulse = ((Math.sin(phase) + 1) / 2) * 1.5;
      return 3 + reactive + idlePulse;
    });
  }

  function boostedAudioLevel(rms) {
    return clamp01(rms * 10.2);
  }
  function smoothAudioLevel(rms, previous) {
    return Math.max(boostedAudioLevel(rms), (previous || 0) * 0.72);
  }

  return {
    BUDDY_FOLLOW_OFFSET,
    RESTING_TRIANGLE_ROTATION_DEGREES,
    BUBBLE_OFFSET,
    NAVIGATION_TARGET_OFFSET,
    NAVIGATION_EDGE_CLAMP,
    WAVEFORM_PROFILE,
    clamp,
    clamp01,
    distance,
    flightDurationSeconds,
    smoothstep,
    arcControlPoint,
    flightFrame,
    triangleGlowRadius,
    clampNavigationTarget,
    createSpring,
    stepSpring,
    waveformBarHeights,
    boostedAudioLevel,
    smoothAudioLevel,
  };
});
