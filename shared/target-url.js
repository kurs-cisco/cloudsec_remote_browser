export function normalizeTargetUrl(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) {
    throw new Error("Enter a URL to isolate.");
  }

  const candidate = /^[a-z]+:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  const url = new URL(candidate);
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new Error("Only http and https URLs are supported.");
  }
  return url.toString();
}
