import { HttpError } from "./http";

const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

export function isValidBase64(value: string): boolean {
  return value.length > 0
    && value.length % 4 === 0
    && BASE64_PATTERN.test(value);
}

export function assertPositiveBoundedNumber(value: unknown, label: string, maxValue: number): void {
  if (
    typeof value !== "number"
    || !Number.isFinite(value)
    || value <= 0
    || value > maxValue
  ) {
    throw new HttpError(400, `${label} is invalid.`);
  }
}

export function assertOptionalStringLimit(value: unknown, label: string, maxLength: number): void {
  if (value === undefined || value === null) {
    return;
  }
  if (typeof value !== "string") {
    throw new HttpError(400, `${label} is invalid.`);
  }
  if (value.length > maxLength) {
    throw new HttpError(413, `${label} is too large.`);
  }
}
