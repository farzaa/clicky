'use strict';
/*
 * Multi-monitor screenshots for the model. Mirrors CompanionScreenCaptureUtility.swift:
 * every display, JPEG q0.8, longest side <= 1280, cursor screen first-class.
 */
const { screenshotSizeForDisplay, buildScreenLabel } = require('./screen-math');

function createCapture({ screen, desktopCapturer }) {
  async function captureAllScreens() {
    const displays = screen.getAllDisplays();
    const cursor = screen.getCursorScreenPoint();
    const cursorDisplay = screen.getDisplayNearestPoint(cursor);
    // Cursor screen first, like the Mac app, then the others left-to-right.
    const ordered = displays.slice().sort((a, b) => {
      if (a.id === cursorDisplay.id) return -1;
      if (b.id === cursorDisplay.id) return 1;
      return a.bounds.x - b.bounds.x;
    });
    const sizes = ordered.map((d) =>
      screenshotSizeForDisplay(Math.round(d.size.width * d.scaleFactor), Math.round(d.size.height * d.scaleFactor))
    );
    const maxW = Math.max(...sizes.map((s) => s.width));
    const maxH = Math.max(...sizes.map((s) => s.height));
    const sources = await desktopCapturer.getSources({
      types: ['screen'],
      thumbnailSize: { width: maxW, height: maxH },
    });
    const captures = [];
    ordered.forEach((display, i) => {
      let source = sources.find((s) => String(s.display_id) === String(display.id));
      if (!source) source = sources[displays.indexOf(display)] || sources[i];
      if (!source || source.thumbnail.isEmpty()) return;
      const size = sizes[i];
      let image = source.thumbnail;
      const cur = image.getSize();
      if (cur.width !== size.width || cur.height !== size.height) {
        image = image.resize({ width: size.width, height: size.height, quality: 'best' });
      }
      const jpeg = image.toJPEG(80);
      const isCursorScreen = display.id === cursorDisplay.id;
      captures.push({
        index: i,
        displayId: display.id,
        jpeg,
        bounds: { x: display.bounds.x, y: display.bounds.y, width: display.bounds.width, height: display.bounds.height },
        scaleFactor: display.scaleFactor,
        screenshotWidth: size.width,
        screenshotHeight: size.height,
        isCursorScreen,
        label: buildScreenLabel(i, ordered.length, isCursorScreen, size.width, size.height),
      });
    });
    if (!captures.length) throw new Error('Could not capture the screen.');
    return captures;
  }
  return { captureAllScreens };
}

module.exports = { createCapture };
