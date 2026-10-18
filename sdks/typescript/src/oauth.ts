import { AuthorizationLost, CancelledError, MalformedResponse, SDKError, TransportError } from './errors.js';
import { bearer, object } from './json.js';
import { Transport } from './http.js';
import { delay } from './feeds.js';
import type { ConnectionOptions, RequestOptions } from './http.js';
export class OAuthError extends SDKError { constructor(readonly code: string, readonly status: number, readonly retryAfter: number | null = null) { super(`OAuth ${code}`); } }
export class InitializationRequired extends OAuthError { constructor(readonly initializationURI: string) { super('initialization_required', 409); } }
export interface OAuthCredentialsBundle {
  refresh_token: string; expires_in: number; token_type: 'Bearer';
  access_token: string | null; executor_access_token: string | null; platform_access_token: string | null;
  runner: OAuthCredentialsBundle | null; agent: OAuthCredentialsBundle | null;
  user: { public_id: string; display_name: string; role: string } | null;
  agent_public_id: string | null;
}
export interface DeviceAuthorization {
  device_code: string; user_code: string; verification_uri: string; verification_uri_complete: string;
  expires_in: number; interval: number; deadline: number; branch: 'agent' | 'runner' | 'combined' | 'application';
}
export interface AgentClaims { agent_identifier: string; agent_display_name: string; executor_display_name: string; registration_identifier?: string; runner_display_name?: string; }
export interface RunnerClaims { registration_identifier: string; runner_display_name: string; executor_kind: 'runner' | 'tool_provider'; assignment_agent_public_id?: string; }
export type PollResult = { state: 'pending' } | { state: 'slow_down' } | { state: 'throttled'; retry_after: number } | { state: 'authorized'; credentials: OAuthCredentialsBundle };
export interface OAuthAuthority { rotate(refreshToken: string): Promise<OAuthCredentialsBundle>; revoke(token: string): Promise<void>; }
/** OAuth machine requests do not carry an existing bearer or follow redirects. */
export class DeviceFlow implements OAuthAuthority {
  protected readonly transport: Transport;
  protected readonly clientId: string;
  protected readonly origin: string;
  #owned = new Set<Promise<unknown>>();
  #waits = new Map<string, Promise<OAuthCredentialsBundle>>();
  constructor(options: ConnectionOptions, clientId = 'cybros-first-party-connector') {
    this.transport = new Transport({ timeoutMs: 120_000, ...options }, 'member', true);
    this.origin = this.transport.baseURL; this.clientId = clientId;
  }
  requestAuthorization(claims: AgentClaims): Promise<DeviceAuthorization> { return this.start(claims, claims.registration_identifier === undefined ? 'agent' : 'combined'); }
  requestRunnerAuthorization(claims: RunnerClaims): Promise<DeviceAuthorization> { return this.start(claims, 'runner'); }
  protected async start(claims: object, branch: DeviceAuthorization['branch']): Promise<DeviceAuthorization> {
    const started = performance.now();
    const response = await this.post('/oauth/device_authorization', claims);
    if (response.status !== 200) throw this.failure(response.status, response.data);
    const body = object(response.data);
    const expires = positive(body.expires_in, 'expires_in');
    return { device_code: text(body.device_code, 'device_code'), user_code: text(body.user_code, 'user_code'), verification_uri: httpURL(body.verification_uri), verification_uri_complete: httpURL(body.verification_uri_complete), interval: positive(body.interval, 'interval'), expires_in: expires, deadline: started + expires * 1000, branch };
  }
  async poll(authorization: DeviceAuthorization): Promise<PollResult> {
    const remaining = authorization.deadline - performance.now();
    if (remaining <= 0) throw new OAuthError('expired_token', 400);
    const response = await this.post('/oauth/token', { grant_type: 'urn:ietf:params:oauth:grant-type:device_code', device_code: authorization.device_code }, { timeoutMs: Math.min(120_000, remaining) });
    if (response.status === 200) {
      let credentials: OAuthCredentialsBundle;
      try { credentials = this.decode(response.data); this.validateInitial(credentials, authorization.branch); }
      catch (cause) { throw new AuthorizationLost('Device token response was invalid; reconnect required', { cause }); }
      return { state: 'authorized', credentials };
    }
    const body = object(response.data);
    if (response.status === 429) return { state: 'throttled', retry_after: retrySeconds(response.headers.get('retry-after')) ?? (typeof body.retry_after === 'number' ? body.retry_after : 5) };
    if (body.error === 'authorization_pending') return { state: 'pending' };
    if (body.error === 'slow_down') return { state: 'slow_down' };
    throw this.failure(response.status, body);
  }
  /** Cancellation stops this caller's wait; the owned bounded ceremony can be recovered by calling again. */
  awaitCredentials(authorization: DeviceAuthorization, options: Pick<RequestOptions, 'signal'> = {}): Promise<OAuthCredentialsBundle> {
    let promise = this.#waits.get(authorization.device_code);
    if (!promise) {
      promise = this.own(this.pollUntilReady(authorization));
      this.#waits.set(authorization.device_code, promise);
    }
    return awaitOwned(promise, options.signal);
  }
  async cancelAuthorization(authorization: DeviceAuthorization): Promise<'cancelled' | 'too_late'> {
    const response = await this.post('/oauth/device_authorization/cancellation', { device_code: authorization.device_code }, { allowEmpty: true });
    if (response.status === 200) return 'cancelled';
    if (response.status === 409 && object(response.data).error === 'too_late') return 'too_late';
    throw this.failure(response.status, response.data);
  }
  async rotate(refreshToken: string): Promise<OAuthCredentialsBundle> {
    try {
      const response = await this.post('/oauth/token', { grant_type: 'refresh_token', refresh_token: refreshToken });
      if (response.status >= 500) throw new AuthorizationLost('Refresh outcome is unknown; reconnect required');
      if (response.status !== 200) {
        const failure = this.failure(response.status, response.data);
        if (failure.code === 'invalid_grant') throw new AuthorizationLost('Refresh authority was lost; reconnect required');
        throw failure;
      }
      try { return this.decode(response.data); } catch (cause) { throw new AuthorizationLost('Refresh response was invalid; reconnect required', { cause }); }
    } catch (cause) {
      if (cause instanceof TransportError || cause instanceof MalformedResponse) throw new AuthorizationLost('Refresh outcome is unknown; reconnect required', { cause });
      throw cause;
    }
  }
  async revoke(token: string): Promise<void> { const response = await this.post('/oauth/revoke', { token }, { allowEmpty: true }); if (response.status !== 200) throw this.failure(response.status, response.data); }
  async drain(): Promise<void> { await Promise.allSettled([...this.#owned]); }
  protected own<T>(promise: Promise<T>): Promise<T> {
    this.#owned.add(promise); void promise.finally(() => this.#owned.delete(promise)).catch(() => {}); return promise;
  }
  protected async post(path: string, fields: object, options: RequestOptions & { allowEmpty?: boolean } = {}) {
    const body = new URLSearchParams({ client_id: this.clientId });
    for (const [key, value] of Object.entries(fields)) if (value !== undefined && value !== null) body.set(key, String(value));
    return this.transport.call(path, { ...options, method: 'POST', body, success: [200, 400, 401, 403, 409, 422, 429, 500, 502, 503, 504] });
  }
  protected failure(status: number, data: unknown): OAuthError {
    const body = data !== null && typeof data === 'object' ? object(data) : {};
    return new OAuthError(status >= 500 ? 'server_error' : typeof body.error === 'string' ? body.error : 'invalid_response', status);
  }
  protected decode(data: unknown): OAuthCredentialsBundle { return decodeConnection(data); }
  protected validateInitial(bundle: OAuthCredentialsBundle, branch: DeviceAuthorization['branch']) {
    const member = bundle.access_token !== null, executor = bundle.executor_access_token !== null, runner = bundle.runner !== null;
    if (!(branch === 'agent' && member && executor && !runner || branch === 'combined' && member && executor && runner || branch === 'runner' && !member && executor && !runner)) throw new MalformedResponse('Credential branch mismatch');
  }
  private async pollUntilReady(authorization: DeviceAuthorization): Promise<OAuthCredentialsBundle> {
    let interval = authorization.interval * 1000, transient = 0;
    while (true) {
      let result: PollResult;
      try { result = await this.poll(authorization); transient = 0; }
      catch (error) {
        if (!(error instanceof TransportError || error instanceof OAuthError && error.status >= 500) || ++transient > 3) throw error;
        await delay(Math.min(5000, Math.max(0, authorization.deadline - performance.now()))); continue;
      }
      if (result.state === 'authorized') return result.credentials;
      if (result.state === 'slow_down') interval += 5000;
      const wait = result.state === 'throttled' ? Math.max(interval, result.retry_after * 1000) : interval;
      await delay(Math.min(wait, Math.max(0, authorization.deadline - performance.now())));
    }
  }
}
export interface ApplicationClaims { agent_identifier?: string; agent_display_name?: string; executor_display_name?: string; registration_identifier?: string; runner_display_name?: string; executor_kind?: 'runner' | 'tool_provider'; assignment_agent_public_id?: string; }
export class ApplicationOAuth extends DeviceFlow {
  #exchanges = new Map<string, Promise<OAuthCredentialsBundle>>();
  override requestAuthorization(claims: AgentClaims) { return this.requestDeviceAuthorization(claims); }
  override requestRunnerAuthorization(claims: RunnerClaims) { return this.requestDeviceAuthorization(claims); }
  constructor(options: ConnectionOptions) { super(options, 'cybros-application'); }
  requestDeviceAuthorization(claims: ApplicationClaims, connectionMode: 'connect' | 'login' = 'connect') { return this.start({ ...claims, scope: 'application', connection_mode: connectionMode }, 'application'); }
  authorizationURL(input: { redirect_uri: string; state: string; code_challenge: string; claims: ApplicationClaims; connection_mode?: 'connect' | 'login' }): string {
    const url = new URL('/oauth/authorize', this.origin);
    const fields = { ...input.claims, redirect_uri: input.redirect_uri, state: input.state, code_challenge: input.code_challenge, connection_mode: input.connection_mode ?? 'connect', client_id: this.clientId, scope: 'application', response_type: 'code', code_challenge_method: 'S256' };
    for (const [key, value] of Object.entries(fields)) if (value !== undefined) url.searchParams.set(key, value);
    return url.toString();
  }
  exchangeCode(input: { code: string; redirect_uri: string; code_verifier: string }, options: Pick<RequestOptions, 'signal'> = {}) {
    let promise = this.#exchanges.get(input.code);
    if (!promise) { promise = this.own((async () => {
      try {
        const response = await this.post('/oauth/token', { ...input, grant_type: 'authorization_code' });
        if (response.status !== 200) throw this.failure(response.status, response.data);
        return this.decode(response.data);
      } catch (cause) { if (cause instanceof TransportError || cause instanceof MalformedResponse) throw new AuthorizationLost('Code exchange outcome is unknown; sign in again', { cause }); throw cause; }
    })()); this.#exchanges.set(input.code, promise); }
    return awaitOwned(promise, options.signal);
  }
  protected override failure(status: number, data: unknown): OAuthError { if (status === 409 && object(data).error === 'initialization_required') return new InitializationRequired(this.origin + '/setup'); return super.failure(status, data); }
  protected override validateInitial(bundle: OAuthCredentialsBundle) { if (!bundle.platform_access_token) throw new MalformedResponse('Application grant requires platform authority'); }
  protected override decode(data: unknown): OAuthCredentialsBundle {
    const body = object(data);
    if (body.plane !== 'platform' || body.scope !== 'application') throw new MalformedResponse('Invalid application authority');
    const user = object(body.user);
    if (body.agent != null && object(body.agent).plane !== 'member') throw new MalformedResponse('Application Agent requires member authority');
    if (body.runner != null && object(body.runner).plane !== 'executor_transport') throw new MalformedResponse('Application Runner requires executor authority');
    return { ...baseBundle(body), platform_access_token: text(body.access_token, 'access_token'), user: { public_id: text(user.public_id, 'public_id'), display_name: text(user.display_name, 'display_name'), role: text(user.role, 'role') }, agent_public_id: body.agent_public_id == null ? null : text(body.agent_public_id, 'agent_public_id'), agent: body.agent == null ? null : decodeConnection(body.agent), runner: body.runner == null ? null : decodeConnection(body.runner) };
  }
  static async pkce(): Promise<{ code_verifier: string; code_challenge: string; state: string }> {
    const code_verifier = base64URL(crypto.getRandomValues(new Uint8Array(32)));
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(code_verifier));
    return { code_verifier, code_challenge: base64URL(new Uint8Array(digest)), state: base64URL(crypto.getRandomValues(new Uint8Array(24))) };
  }
}
function baseBundle(body: Record<string, unknown>): OAuthCredentialsBundle { return { refresh_token: text(body.refresh_token, 'refresh_token'), expires_in: positive(body.expires_in, 'expires_in'), token_type: bearer(body.token_type), access_token: null, executor_access_token: null, platform_access_token: null, runner: null, agent: null, user: null, agent_public_id: null }; }
function decodeConnection(data: unknown): OAuthCredentialsBundle {
  const body = object(data), bundle = baseBundle(body);
  if (body.plane === 'member') {
    bundle.access_token = text(body.access_token, 'access_token');
    bundle.executor_access_token = body.executor_access_token == null ? null : text(body.executor_access_token, 'executor_access_token');
    if (body.runner != null) {
      // First-party combined grants omit metadata shared with their parent.
      // Explicit child metadata still passes the same closed authority checks.
      const runner = { plane: 'executor_transport', token_type: bundle.token_type, expires_in: bundle.expires_in, ...object(body.runner) };
      if (runner.plane !== 'executor_transport') throw new MalformedResponse('Runner grant requires executor authority');
      bundle.runner = decodeConnection(runner);
    }
  } else if (body.plane === 'executor_transport') {
    if (body.executor_access_token != null || body.runner != null) throw new MalformedResponse('Executor grant cannot carry additional executor authority');
    bundle.executor_access_token = text(body.access_token, 'access_token');
  } else throw new MalformedResponse('Unsupported OAuth credential plane');
  return bundle;
}
function text(value: unknown, field: string): string { if (typeof value !== 'string' || !value) throw new MalformedResponse(`Expected ${field}`); return value; }
function positive(value: unknown, field: string): number { if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) throw new MalformedResponse(`Expected positive ${field}`); return value; }
function httpURL(value: unknown): string { const result = text(value, 'verification URI'); const url = new URL(result); if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new MalformedResponse('Invalid verification URI'); return result; }
function base64URL(bytes: Uint8Array): string { return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
export function awaitOwned<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(new CancelledError('Waiting cancelled'));
  return new Promise((resolve, reject) => {
    const abort = () => reject(new CancelledError('Waiting cancelled'));
    signal.addEventListener('abort', abort, { once: true });
    void promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
  });
}

function retrySeconds(value: string | null): number | null { if (value === null) return null; const number = Number(value); if (Number.isFinite(number) && number >= 0) return number; const date = Date.parse(value); return Number.isFinite(date) ? Math.max(0, (date - Date.now()) / 1000) : null; }
