import { HttpError } from "./http";

export const MAX_DEVICE_IDENTIFIER_CHARS = 128;

const encoder = new TextEncoder();
const MAX_CLIENT_IP_ADDRESS_CHARS = 128;
const DOUBLE_UUID_V4_TOKEN_CHARS = 72;
const MAGIC_LINK_TOKEN_CHARS = DOUBLE_UUID_V4_TOKEN_CHARS;
const SESSION_TOKEN_CHARS = DOUBLE_UUID_V4_TOKEN_CHARS;
const DEVICE_IDENTIFIER_PATTERN = /^[A-Za-z0-9._:-]+$/;
const UUID_V4_SOURCE = "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
const DOUBLE_UUID_V4_TOKEN_PATTERN = new RegExp(`^${UUID_V4_SOURCE}${UUID_V4_SOURCE}$`);
const MAGIC_LINK_TOKEN_PATTERN = DOUBLE_UUID_V4_TOKEN_PATTERN;
const SESSION_TOKEN_PATTERN = DOUBLE_UUID_V4_TOKEN_PATTERN;

export async function sessionTokenHashFromRequest(request: Request): Promise<string> {
  const token = sessionTokenFromRequest(request);
  return await sha256Hex(token);
}

function sessionTokenFromRequest(request: Request): string {
  const authHeader = request.headers.get("authorization") || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice("Bearer ".length).trim() : "";
  if (!token) {
    throw new HttpError(401, "Missing session token.");
  }

  if (token.length !== SESSION_TOKEN_CHARS || !SESSION_TOKEN_PATTERN.test(token)) {
    throw new HttpError(401, "Invalid or expired session.");
  }

  return token;
}

export async function requiredDeviceHashFromRequest(request: Request): Promise<string> {
  const deviceHash = await optionalDeviceHashFromRequest(request);
  if (!deviceHash) {
    throw new HttpError(400, "Device id is required.");
  }
  return deviceHash;
}

export async function optionalDeviceHashFromRequest(request: Request): Promise<string | null> {
  const deviceIdentifier = deviceIdentifierFromRequest(request);
  return deviceIdentifier ? await sha256Hex(deviceIdentifier) : null;
}

export function deviceIdentifierFromRequest(request: Request): string | null {
  const deviceIdentifier = request.headers.get("X-Spider-Device-ID")?.trim();
  if (!deviceIdentifier) {
    return null;
  }

  if (
    deviceIdentifier.length > MAX_DEVICE_IDENTIFIER_CHARS
    || !DEVICE_IDENTIFIER_PATTERN.test(deviceIdentifier)
  ) {
    throw new HttpError(400, "Device id is invalid.");
  }

  return deviceIdentifier;
}

export function clientIPAddressFromRequest(request: Request): string | null {
  const ipAddress = request.headers.get("CF-Connecting-IP")?.trim();
  if (!ipAddress) {
    return null;
  }

  if (ipAddress.length > MAX_CLIENT_IP_ADDRESS_CHARS) {
    throw new HttpError(400, "Client IP header is invalid.");
  }

  return ipAddress;
}

export function magicLinkTokenFromURL(url: URL): string {
  const queryEntries = [...url.searchParams.entries()];
  const tokenValues = url.searchParams.getAll("token");
  if (tokenValues.length === 0) {
    throw new HttpError(400, "Missing token.");
  }
  if (queryEntries.length !== 1 || tokenValues.length !== 1) {
    throw new HttpError(400, "Magic link URL is invalid.");
  }

  const token = tokenValues[0];

  if (token.length !== MAGIC_LINK_TOKEN_CHARS || !MAGIC_LINK_TOKEN_PATTERN.test(token)) {
    throw new HttpError(400, "Magic link token is invalid.");
  }

  return token;
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return bytesToHex(new Uint8Array(digest));
}

export async function hmacSHA256Hex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const digest = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return bytesToHex(new Uint8Array(digest));
}

export async function timingSafeEqual(left: string, right: string): Promise<boolean> {
  const [leftDigest, rightDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);

  if (typeof crypto.subtle.timingSafeEqual === "function") {
    return crypto.subtle.timingSafeEqual(leftDigest, rightDigest);
  }

  return fixedLengthBytesEqual(new Uint8Array(leftDigest), new Uint8Array(rightDigest));
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function fixedLengthBytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  let result = left.byteLength ^ right.byteLength;
  const length = Math.max(left.byteLength, right.byteLength);
  for (let index = 0; index < length; index += 1) {
    result |= (left[index] || 0) ^ (right[index] || 0);
  }
  return result === 0;
}
