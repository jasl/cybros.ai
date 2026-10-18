import { MalformedResponse } from "./errors.js";
export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };
export type OpenString<T extends string> = T | (string & {});
export type CredentialPlane = "member" | "executor" | "platform";
export function object(value: unknown, label = "response"): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new MalformedResponse(`Expected ${label} object`);
  return value as Record<string, unknown>;
}
export function nonempty(value: string, label: string): string {
  if (typeof value !== "string" || value.length === 0) throw new TypeError(`${label} must be nonempty`);
  return value;
}
export function segment(value: string): string { return encodeURIComponent(nonempty(value, "path segment")); }
export function plane(value: unknown): CredentialPlane {
  if (value !== "member" && value !== "executor" && value !== "platform") throw new MalformedResponse("Unknown credential plane");
  return value;
}
export function bearer(value: unknown): "Bearer" {
  if (value !== "Bearer") throw new MalformedResponse("Expected Bearer token_type");
  return value;
}
