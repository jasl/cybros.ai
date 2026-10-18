import type { JsonValue } from "./json.js";
export class SDKError extends Error {}
export class MalformedResponse extends SDKError {}
export class TransportError extends SDKError {}
export class TimeoutError extends TransportError {}
export class CancelledError extends TransportError {}
export class RedirectError extends TransportError {}
export class APIError extends SDKError {
  constructor(message: string, readonly status: number, readonly code: string | null,
    readonly details: JsonValue, readonly retryAfter: string | null, readonly requestId: string | null, readonly responseBody: string | null = null) { super(message); }
}
export class BadRequest extends APIError {}
export class Unauthorized extends APIError {}
export class Forbidden extends APIError {}
export class NotFound extends APIError {}
export class Conflict extends APIError {}
export class InvalidRequest extends APIError {}
export class RateLimited extends APIError {}
export class ServerError extends APIError {}
export class AuthorizationLost extends SDKError {}
export class NotDurable extends SDKError { constructor(message: string, readonly cause: unknown, readonly credentials?: import("./credentials.js").OAuthCredentials) { super(message); } }
/** A store may throw this only after the complete document was atomically published. */
export class Published extends SDKError {}
export class RetentionGap extends SDKError { constructor(readonly watermark: number, readonly sequence: number) { super("Event retention requires explicit state recovery"); } }
export class BufferOverflow extends SDKError {}
export class RealtimeDisconnected extends SDKError {}
