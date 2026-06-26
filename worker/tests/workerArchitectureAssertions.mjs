import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { registerWorkerAuthSecurityArchitectureAssertions } from "./workerAuthSecurityArchitectureAssertions.mjs";
import { registerWorkerBillingRuntimeArchitectureAssertions } from "./workerBillingRuntimeArchitectureAssertions.mjs";
import { registerWorkerGuideArchitectureAssertions } from "./workerGuideArchitectureAssertions.mjs";

export function registerWorkerArchitectureAssertions({ test, workerRoot }) {
  test("worker HTTP response policy stays outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const httpSource = readFileSync(path.join(workerRoot, "src", "http.ts"), "utf8");

    assert.match(indexSource, /from "\.\/http"/);
    assert.match(httpSource, /export class HttpError extends Error/);
    assert.match(httpSource, /export function jsonResponse/);
    assert.match(httpSource, /export function preflightResponse/);
    assert.match(httpSource, /export function withCORS/);
    assert.match(httpSource, /export function htmlHeaders/);
    assert.match(httpSource, /export function escapeHTMLAttribute/);
    assert.match(httpSource, /"cache-control": "no-store"/);
    assert.match(httpSource, /"x-content-type-options": "nosniff"/);
    assert.match(httpSource, /"access-control-allow-headers": "authorization,content-type,stripe-signature,x-spider-device-id"/);
    assert.match(httpSource, /"content-security-policy"/);
    assert.doesNotMatch(indexSource, /function jsonResponse\(/);
    assert.doesNotMatch(indexSource, /function corsHeadersForRequest\(/);
    assert.doesNotMatch(indexSource, /class HttpError extends Error/);
  });

  test("worker entrypoint delegates domain routing outside the runtime handler", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const routesSource = readFileSync(path.join(workerRoot, "src", "workerRoutes.ts"), "utf8");

    assert.match(indexSource, /from "\.\/workerRoutes"/);
    assert.match(indexSource, /routeWorkerRequest\(request, env\)/);
    assert.match(routesSource, /const workerRoutes: WorkerRoute\[\]/);
    assert.match(routesSource, /export async function routeWorkerRequest/);
    assert.match(routesSource, /from "\.\/authRoutes"/);
    assert.match(routesSource, /from "\.\/billingRoutes"/);
    assert.match(routesSource, /from "\.\/visionGuideRoutes"/);
    assert.match(routesSource, /from "\.\/realtimeRoutes"/);
    assert.match(routesSource, /from "\.\/stripeWebhookRoutes"/);
    assert.match(routesSource, /pathname: "\/vision\/guide"/);
    assert.match(routesSource, /pathname: "\/realtime\/client-secret"/);
    assert.match(routesSource, /pathname: "\/stripe\/webhook"/);
    assert.match(routesSource, /jsonResponse\(\{ error: "Not found" \}, 404\)/);
    assert.doesNotMatch(indexSource, /from "\.\/authRoutes"/);
    assert.doesNotMatch(indexSource, /from "\.\/billingRoutes"/);
    assert.doesNotMatch(indexSource, /from "\.\/visionGuideRoutes"/);
    assert.doesNotMatch(indexSource, /from "\.\/realtimeRoutes"/);
    assert.doesNotMatch(indexSource, /from "\.\/stripeWebhookRoutes"/);
    assert.doesNotMatch(indexSource, /url\.pathname ===/);
  });

  test("worker payload security stays outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const visionGuideRoutesSource = readFileSync(path.join(workerRoot, "src", "visionGuideRoutes.ts"), "utf8");
    const payloadSecuritySource = readFileSync(path.join(workerRoot, "src", "payloadSecurity.ts"), "utf8");

    assert.match(visionGuideRoutesSource, /from "\.\/payloadSecurity"/);
    assert.match(payloadSecuritySource, /export async function readJSONRequest/);
    assert.match(payloadSecuritySource, /export async function readBoundedRequestText/);
    assert.match(payloadSecuritySource, /export async function readBoundedResponseText/);
    assert.match(payloadSecuritySource, /export function parseJSONText/);
    assert.match(payloadSecuritySource, /headers\.get\("content-length"\)/);
    assert.match(payloadSecuritySource, /await reader\.cancel\(\)/);
    assert.match(payloadSecuritySource, /throw new HttpError\(status, tooLargeMessage\)/);
    assert.match(payloadSecuritySource, /JSON\.parse\(value\)/);
    assert.doesNotMatch(indexSource, /from "\.\/payloadSecurity"/);
    assert.doesNotMatch(indexSource, /function readBoundedTextBody\(/);
    assert.doesNotMatch(indexSource, /function readJSONRequest\(/);
    assert.doesNotMatch(indexSource, /function parseJSONText\(/);
    assert.doesNotMatch(indexSource, /new TextDecoder\(\)/);
  });

  test("worker primitive validation stays outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const requestValidationSource = readFileSync(path.join(workerRoot, "src", "guideRequestValidation.ts"), "utf8");
    const validationSource = readFileSync(path.join(workerRoot, "src", "validationPrimitives.ts"), "utf8");

    assert.match(requestValidationSource, /from "\.\/validationPrimitives"/);
    assert.match(validationSource, /export function isValidBase64/);
    assert.match(validationSource, /export function assertPositiveBoundedNumber/);
    assert.match(validationSource, /export function assertOptionalStringLimit/);
    assert.match(validationSource, /const BASE64_PATTERN/);
    assert.match(validationSource, /Number\.isFinite\(value\)/);
    assert.match(validationSource, /throw new HttpError\(400, `\$\{label\} is invalid\.`\)/);
    assert.match(validationSource, /throw new HttpError\(413, `\$\{label\} is too large\.`\)/);
    assert.doesNotMatch(indexSource, /const BASE64_PATTERN/);
    assert.doesNotMatch(indexSource, /function isValidBase64\(/);
    assert.doesNotMatch(indexSource, /function assertPositiveBoundedNumber\(/);
    assert.doesNotMatch(indexSource, /function assertOptionalStringLimit\(/);
  });

  test("worker structured value coercion stays outside the route monolith", () => {
    const indexSource = readFileSync(path.join(workerRoot, "src", "index.ts"), "utf8");
    const promptSource = readFileSync(path.join(workerRoot, "src", "visionGuidePrompt.ts"), "utf8");
    const structuredValuesSource = readFileSync(path.join(workerRoot, "src", "structuredValues.ts"), "utf8");

    assert.match(promptSource, /from "\.\/structuredValues"/);
    assert.match(structuredValuesSource, /export function asRecord/);
    assert.match(structuredValuesSource, /export function stringOrNull/);
    assert.match(structuredValuesSource, /export function stringOrUndefined/);
    assert.match(structuredValuesSource, /export function stringArrayOrEmpty/);
    assert.match(structuredValuesSource, /export function numberOrNull/);
    assert.match(structuredValuesSource, /Array\.isArray\(value\)/);
    assert.match(structuredValuesSource, /Number\.isFinite\(value\)/);
    assert.doesNotMatch(indexSource, /from "\.\/structuredValues"/);
    assert.doesNotMatch(indexSource, /function asRecord\(/);
    assert.doesNotMatch(indexSource, /function stringOrNull\(/);
    assert.doesNotMatch(indexSource, /function stringOrUndefined\(/);
    assert.doesNotMatch(indexSource, /function stringArrayOrEmpty\(/);
    assert.doesNotMatch(indexSource, /function numberOrNull\(/);
  });

  registerWorkerGuideArchitectureAssertions({ test, workerRoot });
  registerWorkerAuthSecurityArchitectureAssertions({ test, workerRoot });
  registerWorkerBillingRuntimeArchitectureAssertions({ test, workerRoot });
}
