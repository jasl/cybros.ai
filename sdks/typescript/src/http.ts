import { APIError, BadRequest, CancelledError, Conflict, Forbidden, InvalidRequest, MalformedResponse, NotFound, RateLimited, RedirectError, ServerError, TimeoutError, TransportError, Unauthorized } from "./errors.js";
import { nonempty, object } from "./json.js";
import type { CredentialPlane, JsonValue } from "./json.js";

export interface RequestOptions { signal?: AbortSignal; timeoutMs?: number; }
export interface MutationOptions extends RequestOptions { idempotencyKey: string; }
export interface ResponseMetadata { status: number; replayed: boolean; requestId: string | null; }
export type Receipt<T> = T & ResponseMetadata;
export interface Download extends ResponseMetadata {
  body: ReadableStream<Uint8Array> | null;
  etag: string | null; contentType: string | null; contentRange: string | null; contentLength: string | null;
}
export interface DownloadOptions extends RequestOptions { range?: string; ifNoneMatch?: string; }
export type Fetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
export type CredentialProvider = () => string | Promise<string>;
export interface ConnectionOptions { baseURL: string; timeoutMs?: number; fetch?: Fetch; }
export type ClientOptions = ConnectionOptions & (
  { credential: string; credentialProvider?: never } | { credential?: never; credentialProvider: CredentialProvider }
);
export type Query = object;
export interface CallOptions extends RequestOptions {
  method?: string; body?: unknown; query?: Query; idempotencyKey?: string;
  headers?: HeadersInit; success?: readonly number[]; allowEmpty?: boolean;
}
export interface ResponseBody extends ResponseMetadata { data: unknown; headers: Headers; }

/** Internal dispatch: public resource methods alone choose authenticated paths. */
export class Transport {
  readonly baseURL: string;
  readonly #credential: CredentialProvider | null;
  readonly #fetch: Fetch;
  readonly #timeoutMs: number;
  constructor(options: ClientOptions | ConnectionOptions, readonly plane: CredentialPlane, anonymous = false) {
    const url = new URL(options.baseURL);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || (url.pathname !== '/' && url.pathname !== '')) throw new TypeError("baseURL must be an HTTP(S) origin");
    this.baseURL = url.origin;
    const auth = options as Partial<ClientOptions>;
    if (!anonymous && (auth.credential === undefined) === (auth.credentialProvider === undefined)) throw new TypeError("Provide exactly one credential or credentialProvider");
    this.#credential = anonymous ? null : auth.credentialProvider ?? (() => nonempty(auth.credential!, "credential"));
    this.#fetch = options.fetch ?? globalThis.fetch;
    this.#timeoutMs = options.timeoutMs ?? 30_000;
    validateTimeout(this.#timeoutMs);
  }
  async call(path: string, options: CallOptions = {}): Promise<ResponseBody> {
    const { response, release, signal } = await this.open(path, options);
    try {
      const metadata = responseMetadata(response);
      if (response.status === 204 && isSuccess(response.status, options.success)) return { ...metadata, headers: response.headers, data: null };
      const text = await response.text();
      if (text.length === 0 && options.allowEmpty && isSuccess(response.status, options.success)) return { ...metadata, headers: response.headers, data: null };
      let data: unknown;
      try { data = JSON.parse(text); }
      catch (cause) {
        if (!isSuccess(response.status, options.success)) throw apiError(response, null, text);
        throw new MalformedResponse("Successful response was not JSON", { cause });
      }
      if (!isSuccess(response.status, options.success)) throw apiError(response, data, text);
      object(data);
      return { ...metadata, headers: response.headers, data };
    } catch (error) { throw normalizeError(error, signal); }
    finally { release(); }
  }
  async download(path: string, options: DownloadOptions & { query?: Query; headers?: HeadersInit } = {}): Promise<Download> {
    const headers = new Headers(options.headers);
    if (options.range !== undefined) headers.set("Range", options.range);
    if (options.ifNoneMatch !== undefined) headers.set("If-None-Match", options.ifNoneMatch);
    const { response, release, signal } = await this.open(path, { ...options, headers });
    if (![200, 206, 304].includes(response.status)) {
      try {
        const text = await response.text();
        let data: unknown = null;
        try { data = JSON.parse(text); } catch { /* Proxies may return non-JSON errors. */ }
        throw apiError(response, data, text);
      } catch (error) { throw normalizeError(error, signal); }
      finally { release(); }
    }
    let body: ReadableStream<Uint8Array> | null = null;
    if (response.body) {
      const reader = response.body.getReader();
      body = new ReadableStream<Uint8Array>({
        async pull(controller) {
          try {
            const result = await reader.read();
            if (result.done) { release(); controller.close(); }
            else controller.enqueue(result.value);
          } catch (error) { release(); controller.error(normalizeError(error, signal)); }
        },
        async cancel(reason) { try { await reader.cancel(reason); } finally { release(); } },
      });
    } else release();
    return { ...responseMetadata(response), body, etag: response.headers.get("etag"), contentType: response.headers.get("content-type"), contentRange: response.headers.get("content-range"), contentLength: response.headers.get("content-length") };
  }
  private async open(path: string, options: CallOptions) {
    if (!path.startsWith('/') || path.startsWith('//')) throw new TypeError("Invalid internal resource path");
    const url = new URL(path, this.baseURL);
    if (url.origin !== this.baseURL) throw new TypeError("Resource origin mismatch");
    for (const [key, value] of Object.entries(options.query ?? {})) {
      if (value === undefined || value === null) continue;
      url.searchParams.set(key, Array.isArray(value) ? value.join(',') : typeof value === 'object' ? JSON.stringify(value) : String(value));
    }
    const timeoutMs = options.timeoutMs ?? this.#timeoutMs;
    validateTimeout(timeoutMs);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new TimeoutError("Request deadline exceeded")), timeoutMs);
    const abort = () => controller.abort(new CancelledError("Request cancelled", { cause: options.signal?.reason }));
    if (options.signal?.aborted) abort();
    else options.signal?.addEventListener('abort', abort, { once: true });
    const release = () => { clearTimeout(timer); options.signal?.removeEventListener('abort', abort); };
    try {
      controller.signal.throwIfAborted();
      const credential = this.#credential ? await withinSignal(Promise.resolve().then(this.#credential), controller.signal) : null;
      controller.signal.throwIfAborted();
      const headers = new Headers(options.headers);
      if (credential !== null) headers.set('Authorization', `Bearer ${nonempty(credential, 'credential')}`);
      if (!headers.has('Accept')) headers.set('Accept', 'application/json');
      if (options.idempotencyKey !== undefined) headers.set('Idempotency-Key', nonempty(options.idempotencyKey, 'idempotencyKey'));
      let body: BodyInit | undefined;
      if (options.body instanceof FormData || options.body instanceof URLSearchParams || options.body instanceof Blob) body = options.body;
      else if (options.body !== undefined) { headers.set('Content-Type', 'application/json'); body = JSON.stringify(options.body); }
      const response = await this.#fetch(url, { method: options.method ?? 'GET', headers, ...(body === undefined ? {} : { body }), redirect: 'manual', signal: controller.signal });
      if (response.status >= 300 && response.status < 400 && response.status !== 304) {
        await response.body?.cancel();
        throw new RedirectError("Nexus redirects are not followed");
      }
      return { response, release, signal: controller.signal };
    } catch (error) { release(); throw normalizeError(error, controller.signal); }
  }
}
function validateTimeout(value: number) { if (!Number.isFinite(value) || value <= 0) throw new TypeError('timeoutMs must be finite and positive'); }
function isSuccess(status: number, allowed?: readonly number[]) { return allowed ? allowed.includes(status) : status >= 200 && status < 300; }
function responseMetadata(response: Response): ResponseMetadata { return { status: response.status, replayed: response.headers.get('Idempotency-Replayed') === 'true', requestId: response.headers.get('x-request-id') }; }
function normalizeError(error: unknown, signal: AbortSignal): Error {
  if (signal.aborted) return signal.reason instanceof Error ? signal.reason : new CancelledError('Request cancelled');
  return error instanceof APIError || error instanceof MalformedResponse || error instanceof TransportError ? error : new TransportError('HTTP transport failed', { cause: error });
}
function apiError(response: Response, data: unknown, raw?: string): APIError {
  const envelope = data !== null && typeof data === 'object' ? (data as { error?: unknown }).error : undefined;
  const detail = envelope !== null && typeof envelope === 'object' ? envelope as Record<string, unknown> : {};
  const code = typeof detail.code === 'string' ? detail.code : null;
  const message = typeof detail.message === 'string' ? detail.message : `Nexus HTTP ${response.status}`;
  const ErrorClass = ({ 400: BadRequest, 401: Unauthorized, 403: Forbidden, 404: NotFound, 409: Conflict, 422: InvalidRequest, 429: RateLimited } as Record<number, typeof APIError>)[response.status] ?? (response.status >= 500 ? ServerError : APIError);
  return new ErrorClass(message, response.status, code, (detail.details ?? null) as JsonValue, response.headers.get('retry-after'), response.headers.get('x-request-id'), raw === undefined ? null : raw.slice(0, 4096));
}

export function withinSignal<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    signal.addEventListener('abort', abort, { once: true });
    void promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
  });
}
