import { HttpError } from "./http";

export function invalidGuideResponse(): never {
  throw new HttpError(502, "OpenAI returned an invalid guide response.");
}

export function boundedGuideString(value: unknown, maxLength: number, requireNonEmpty = false): string {
  if (typeof value !== "string" || value.includes("\u0000") || value.length > maxLength) {
    invalidGuideResponse();
  }
  const trimmedValue = value.trim();
  if (requireNonEmpty && !trimmedValue) {
    invalidGuideResponse();
  }
  return value;
}

export function optionalBoundedGuideString(value: unknown, maxLength: number): string | null {
  if (value === null || value === undefined) {
    return null;
  }
  return boundedGuideString(value, maxLength);
}

export function normalizedGuideText(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}
