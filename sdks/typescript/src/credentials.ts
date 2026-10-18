import { AuthorizationLost, MalformedResponse, NotDurable, Published, SDKError } from './errors.js';
import { object } from './json.js';
import { awaitOwned } from './oauth.js';
import type { OAuthAuthority, OAuthCredentialsBundle } from './oauth.js';
import type { CredentialPlane } from './json.js';
export class PlaneUnavailable extends SDKError {}
export class ConnectionSuperseded extends SDKError {}
interface TokenDocument { version: 2; connection: string; access_token?: string; executor_access_token?: string; platform_access_token?: string; }
export interface OAuthDocument extends TokenDocument { authentication_kind: 'oauth'; rotation: number; refresh_token: string; expires_at: string; }
export interface APIKeyDocument extends TokenDocument { authentication_kind: 'api_key'; }
export type CredentialDocument = OAuthDocument | APIKeyDocument;
/** The application owns atomic publication and exclusive mutation across its chosen storage. */
export interface CredentialStore {
  read(): Promise<unknown | null>;
  write(document: CredentialDocument): Promise<void>;
  delete(): Promise<void>;
  withLock<T>(operation: () => Promise<T>): Promise<T>;
}
export function decodeCredentialDocument(value: unknown): CredentialDocument {
  const body = object(value, 'credential document');
  if (body.version !== 2) throw new MalformedResponse('Unsupported credential document version');
  const base: TokenDocument = { version: 2, connection: string(body.connection, 'connection') };
  for (const key of ['access_token', 'executor_access_token', 'platform_access_token'] as const) if (body[key] !== undefined) base[key] = string(body[key], key);
  if (!base.access_token && !base.executor_access_token && !base.platform_access_token) throw new MalformedResponse('Credential document has no token plane');
  if (body.authentication_kind === 'api_key') return { ...base, authentication_kind: 'api_key' };
  if (body.authentication_kind !== 'oauth') throw new MalformedResponse('Unsupported authentication kind');
  if (!Number.isSafeInteger(body.rotation) || Number(body.rotation) < 0) throw new MalformedResponse('Invalid credential rotation');
  const expires_at = string(body.expires_at, 'expires_at');
  if (!Number.isFinite(Date.parse(expires_at))) throw new MalformedResponse('Invalid credential expiry');
  return { ...base, authentication_kind: 'oauth', rotation: body.rotation as number, refresh_token: string(body.refresh_token, 'refresh_token'), expires_at };
}
export class OAuthCredentials {
  #document: OAuthDocument;
  #lost: AuthorizationLost | undefined;
  #notDurable: NotDurable | undefined;
  #rotation: Promise<void> | undefined;
  #predecessor: CredentialDocument | null | undefined;
  #owned = new Set<Promise<unknown>>();
  constructor(private readonly configuration: { authority: OAuthAuthority; store: CredentialStore; document: OAuthDocument; clock?: () => number }) { this.#document = decodeCredentialDocument(configuration.document) as OAuthDocument; if (this.#document.authentication_kind !== 'oauth') throw new TypeError('Expected OAuth document'); }
  static async load(input: { authority: OAuthAuthority; store: CredentialStore; clock?: () => number }): Promise<OAuthCredentials | null> {
    const raw = await input.store.read(); if (raw === null) return null;
    const document = decodeCredentialDocument(raw); if (document.authentication_kind !== 'oauth') throw new TypeError('Store contains API keys');
    return new OAuthCredentials({ ...input, document });
  }
  static async issue(input: { credentials: OAuthCredentialsBundle; authority: OAuthAuthority; store: CredentialStore; clock?: () => number }): Promise<OAuthCredentials> {
    const manager = new OAuthCredentials({ ...input, document: issued(input.credentials, crypto.randomUUID(), 0, (input.clock ?? Date.now)()) });
    await manager.own(input.store.withLock(async () => {
      const predecessor = await input.store.read();
      manager.#predecessor = predecessor === null ? null : decodeCredentialDocument(predecessor);
      await manager.publish();
    })); return manager;
  }
  get rotation() { return this.#document.rotation; }
  get expiresAt() { return this.#document.expires_at; }
  get authenticationKind() { return 'oauth' as const; }
  provider(plane: CredentialPlane): () => Promise<string> { return () => this.credential(plane); }
  async credential(plane: CredentialPlane): Promise<string> {
    if (this.#lost) throw this.#lost;
    if (this.expiring()) {
      if (this.#notDurable) throw this.#notDurable;
      await this.rotate(false);
    }
    return present(this.#document, plane);
  }
  memberCredential() { return this.credential('member'); }
  executorCredential() { return this.credential('executor'); }
  platformCredential() { return this.credential('platform'); }
  refresh(options: { after?: number; signal?: AbortSignal } = {}): Promise<void> { return awaitOwned(this.rotate(true, options.after), options.signal); }
  /** Retry publication of the retained live pair; this never sends the spent refresh token. */
  persist(): Promise<void> {
    return this.own(this.configuration.store.withLock(async () => { await this.assertConnection(true); await this.publish(); }));
  }
  revoke(): Promise<void> {
    return this.own(this.configuration.store.withLock(async () => { await this.assertConnection(); if (!this.#lost) await this.configuration.authority.revoke(this.#document.refresh_token); await this.configuration.store.delete(); this.#lost = new AuthorizationLost('Credentials revoked'); }));
  }
  async drain(): Promise<void> { await Promise.allSettled([...this.#owned]); }
  private rotate(force: boolean, after?: number): Promise<void> {
    if (this.#rotation) return this.#rotation;
    const promise = this.own(this.configuration.store.withLock(async () => {
      await this.assertConnection();
      if (this.#lost) throw this.#lost;
      if (this.#notDurable) throw this.#notDurable;
      if (after !== undefined && this.#document.rotation > after || !force && !this.expiring()) return;
      let credentials: OAuthCredentialsBundle;
      try { credentials = await this.configuration.authority.rotate(this.#document.refresh_token); }
      catch (error) { if (error instanceof AuthorizationLost) this.#lost = error; throw error; }
      this.#document = issued(credentials, this.#document.connection, this.#document.rotation + 1, this.now());
      await this.publish();
    }));
    this.#rotation = promise;
    void promise.finally(() => { if (this.#rotation === promise) this.#rotation = undefined; }).catch(() => {});
    return promise;
  }
  private async publish() {
    try { await this.configuration.store.write(this.#document); this.#notDurable = undefined; this.#predecessor = undefined; }
    catch (error) {
      if (error instanceof Published) { this.#notDurable = undefined; this.#predecessor = undefined; return; }
      this.#notDurable = new NotDurable('Live credentials are retained but storage publication failed; call persist before another rotation', error, this);
      throw this.#notDurable;
    }
  }
  private async assertConnection(allowPredecessor = false) {
    const value = await this.configuration.store.read();
    const stored = value === null ? null : decodeCredentialDocument(value);
    if (allowPredecessor && this.#predecessor !== undefined && JSON.stringify(stored) === JSON.stringify(this.#predecessor)) return;
    if (stored === null) throw new ConnectionSuperseded('Connection was removed from storage');
    if (stored.connection !== this.#document.connection || stored.authentication_kind !== 'oauth') throw new ConnectionSuperseded('Store now contains another connection');
    if (stored.rotation > this.#document.rotation && !this.#notDurable) this.#document = stored;
  }
  private expiring() { return this.now() >= Date.parse(this.#document.expires_at) - 60_000; }
  private now() { return (this.configuration.clock ?? Date.now)(); }
  private own<T>(promise: Promise<T>): Promise<T> { this.#owned.add(promise); void promise.finally(() => this.#owned.delete(promise)).catch(() => {}); return promise; }
}
export class APIKeyCredentials {
  readonly #document: APIKeyDocument;
  constructor(document: APIKeyDocument) { const parsed = decodeCredentialDocument(document); if (parsed.authentication_kind !== 'api_key') throw new TypeError('Expected API key document'); this.#document = parsed; }
  get authenticationKind() { return 'api_key' as const; }
  provider(plane: CredentialPlane): () => string { return () => present(this.#document, plane); }
  memberCredential() { return present(this.#document, 'member'); }
  executorCredential() { return present(this.#document, 'executor'); }
  platformCredential() { return present(this.#document, 'platform'); }
}
function issued(bundle: OAuthCredentialsBundle, connection: string, rotation: number, now: number): OAuthDocument {
  return { version: 2, authentication_kind: 'oauth', connection, rotation, refresh_token: bundle.refresh_token, expires_at: new Date(now + bundle.expires_in * 1000).toISOString(), ...(bundle.access_token ? { access_token: bundle.access_token } : {}), ...(bundle.executor_access_token ? { executor_access_token: bundle.executor_access_token } : {}), ...(bundle.platform_access_token ? { platform_access_token: bundle.platform_access_token } : {}) };
}
function present(document: TokenDocument, plane: CredentialPlane): string { const token = plane === 'member' ? document.access_token : plane === 'executor' ? document.executor_access_token : document.platform_access_token; if (!token) throw new PlaneUnavailable(`Connection has no ${plane} credential`); return token; }
function string(value: unknown, field: string): string { if (typeof value !== 'string' || !value) throw new MalformedResponse(`Expected credential ${field}`); return value; }
