const DEFAULT_VIEWPORT_MAX_WIDTH = 1920;
const DEFAULT_VIEWPORT_MAX_HEIGHT = 1080;
const DEFAULT_VIEWER_TOPBAR_HEIGHT = 88;
const DEFAULT_VIEWPORT_REFRESH_PIXEL_TOLERANCE = 48;
const MIN_VIEWPORT_WIDTH = 640;
const MIN_VIEWPORT_HEIGHT = 480;

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value));
}

function roundToEven(value) {
  const rounded = Math.max(2, Math.round(value));
  return rounded % 2 === 0 ? rounded : rounded - 1;
}

function normalizeMaxDimension(value, fallback, minimum) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.max(minimum, Math.round(parsed));
}

export function computeViewportForFrame({
  frameWidth,
  frameHeight,
  maxWidth = DEFAULT_VIEWPORT_MAX_WIDTH,
  maxHeight = DEFAULT_VIEWPORT_MAX_HEIGHT,
  deviceScaleFactor = 1,
} = {}) {
  const safeFrameWidth = Number(frameWidth);
  const safeFrameHeight = Number(frameHeight);
  if (!(safeFrameWidth > 0) || !(safeFrameHeight > 0)) {
    return null;
  }

  const normalizedMaxWidth = normalizeMaxDimension(
    maxWidth,
    DEFAULT_VIEWPORT_MAX_WIDTH,
    MIN_VIEWPORT_WIDTH,
  );
  const normalizedMaxHeight = normalizeMaxDimension(
    maxHeight,
    DEFAULT_VIEWPORT_MAX_HEIGHT,
    MIN_VIEWPORT_HEIGHT,
  );
  const frameAspect = safeFrameWidth / safeFrameHeight;
  if (!Number.isFinite(frameAspect) || frameAspect <= 0) {
    return null;
  }

  let width = normalizedMaxWidth;
  let height = normalizedMaxHeight;
  if (normalizedMaxWidth / normalizedMaxHeight > frameAspect) {
    width = roundToEven(normalizedMaxHeight * frameAspect);
  } else {
    height = roundToEven(normalizedMaxWidth / frameAspect);
  }

  width = clamp(roundToEven(width), MIN_VIEWPORT_WIDTH, normalizedMaxWidth);
  height = clamp(roundToEven(height), MIN_VIEWPORT_HEIGHT, normalizedMaxHeight);

  return {
    width,
    height,
    deviceScaleFactor: Math.max(1, Number(deviceScaleFactor) || 1),
  };
}

export function computeViewportForWindow({
  innerWidth,
  innerHeight,
  topbarHeight = DEFAULT_VIEWER_TOPBAR_HEIGHT,
  maxWidth = DEFAULT_VIEWPORT_MAX_WIDTH,
  maxHeight = DEFAULT_VIEWPORT_MAX_HEIGHT,
  deviceScaleFactor = 1,
} = {}) {
  const safeHeight = Math.max(0, Number(innerHeight) - Number(topbarHeight || 0));
  return computeViewportForFrame({
    frameWidth: innerWidth,
    frameHeight: safeHeight,
    maxWidth,
    maxHeight,
    deviceScaleFactor,
  });
}

export function viewportNeedsRefresh(
  currentViewport,
  preferredViewport,
  {
    // Ignore small width/height jitter between the launch page and the viewer
    // chrome so we do not churn the session during initial handoff.
    pixelTolerance = DEFAULT_VIEWPORT_REFRESH_PIXEL_TOLERANCE,
    aspectTolerance = 0.03,
  } = {},
) {
  if (!currentViewport || !preferredViewport) {
    return false;
  }

  const currentWidth = Number(currentViewport.width);
  const currentHeight = Number(currentViewport.height);
  const preferredWidth = Number(preferredViewport.width);
  const preferredHeight = Number(preferredViewport.height);
  if (!(currentWidth > 0) || !(currentHeight > 0) || !(preferredWidth > 0) || !(preferredHeight > 0)) {
    return false;
  }

  const currentAspect = currentWidth / currentHeight;
  const preferredAspect = preferredWidth / preferredHeight;
  return (
    Math.abs(currentWidth - preferredWidth) > pixelTolerance ||
    Math.abs(currentHeight - preferredHeight) > pixelTolerance ||
    Math.abs(currentAspect - preferredAspect) > aspectTolerance
  );
}
