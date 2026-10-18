import { setTimeout as delay } from 'node:timers/promises';
import { expect, test } from 'vitest';
import { APIKeyCredentials, ApplicationOAuth, AuthorizationLost, CancelledError, ConnectionSuperseded, DeviceFlow, NotDurable, OAuthCredentials, PlaneUnavailable, Published } from '../src/index.js';
import type { CredentialDocument, CredentialStore, OAuthAuthority, OAuthCredentialsBundle } from '../src/index.js';
const bundle = (suffix = '1', expires = 3600): OAuthCredentialsBundle => ({ refresh_token: `refresh-${suffix}`, access_token: `member-${suffix}`, executor_access_token: `executor-${suffix}`, platform_access_token: null, token_type: 'Bearer', expires_in: expires, runner: null, agent: null, user: null, agent_public_id: null });
class Store implements CredentialStore {
  value: CredentialDocument | null = null; writes = 0; fail = false; published = false;
  #tail: Promise<unknown> = Promise.resolve();
  async read() { return this.value; }
  async write(value: CredentialDocument) { this.writes++; if (this.fail) throw new Error('disk unavailable'); this.value = structuredClone(value); if (this.published) throw new Published('published before sync error'); }
  async delete() { this.value = null; }
  withLock<T>(work: () => Promise<T>): Promise<T> { const result = this.#tail.then(work); this.#tail = result.catch(() => {}); return result; }
}
const authority = (rotate: OAuthAuthority['rotate']): OAuthAuthority => ({ rotate, revoke: async () => {} });
test('refresh is single-flight, persisted before completion, and shared holders adopt the newer rotation', async () => {
  const store = new Store(); let calls = 0;
  const source = authority(async token => { expect(token).toBe('refresh-1'); calls++; await delay(5); return bundle('2'); });
  const one = await OAuthCredentials.issue({ credentials: bundle(), authority: source, store });
  const two = (await OAuthCredentials.load({ authority: source, store }))!;
  await Promise.all([one.refresh({ after: 0 }), one.refresh({ after: 0 }), two.refresh({ after: 0 })]);
  expect(calls).toBe(1); expect(one.rotation).toBe(1); expect(two.rotation).toBe(1);
  expect(await two.memberCredential()).toBe('member-2'); expect(store.value?.access_token).toBe('member-2');
});
test('new issuance replaces an old connection atomically and supersedes its owner', async () => {
  const store = new Store(), source = authority(async () => bundle('rotated'));
  const old = await OAuthCredentials.issue({ credentials: bundle(), authority: source, store });
  const current = await OAuthCredentials.issue({ credentials: bundle('new'), authority: source, store });
  expect(await current.memberCredential()).toBe('member-new');
  await expect(old.refresh()).rejects.toBeInstanceOf(ConnectionSuperseded);
});
test('failed first publication retains a recoverable credential manager', async () => {
  const store = new Store(); store.fail = true;
  try { await OAuthCredentials.issue({ credentials: bundle(), authority: authority(async () => bundle('2')), store }); throw new Error('expected publication failure'); }
  catch (error) {
    expect(error).toBeInstanceOf(NotDurable); const failure = error as NotDurable;
    expect(await failure.credentials!.memberCredential()).toBe('member-1');
    store.fail = false; await failure.credentials!.persist(); expect(store.value?.access_token).toBe('member-1');
  }
});
test('failed reissue can publish over its unchanged predecessor, but never a newer connection', async () => {
  for (const replaced of [false, true]) {
    const store = new Store(), source = authority(async () => bundle('rotated'));
    await OAuthCredentials.issue({ credentials: bundle('A'), authority: source, store });
    store.fail = true;
    let retained!: OAuthCredentials;
    try { await OAuthCredentials.issue({ credentials: bundle('B'), authority: source, store }); }
    catch (error) { expect(error).toBeInstanceOf(NotDurable); retained = (error as NotDurable).credentials!; }
    store.fail = false;
    if (replaced) {
      await OAuthCredentials.issue({ credentials: bundle('C'), authority: source, store });
      await expect(retained.persist()).rejects.toBeInstanceOf(ConnectionSuperseded);
      expect(store.value?.access_token).toBe('member-C');
    } else {
      await expect(retained.revoke()).rejects.toBeInstanceOf(ConnectionSuperseded);
      expect(store.value?.access_token).toBe('member-A');
      await retained.persist(); expect(store.value?.access_token).toBe('member-B');
    }
  }
});
test('a removed connection cannot be republished by a stale holder', async () => {
  const store = new Store(), credentials = await OAuthCredentials.issue({ credentials: bundle(), authority: authority(async () => bundle('2')), store });
  await store.delete(); await expect(credentials.persist()).rejects.toBeInstanceOf(ConnectionSuperseded); expect(store.value).toBeNull();
});
test('failed rotation publication never resends the spent refresh token', async () => {
  const store = new Store(); let calls = 0;
  const credentials = await OAuthCredentials.issue({ credentials: bundle(), store, authority: authority(async () => { calls++; return bundle('2'); }) });
  store.fail = true; await expect(credentials.refresh()).rejects.toBeInstanceOf(NotDurable);
  expect(await credentials.memberCredential()).toBe('member-2');
  await expect(credentials.refresh()).rejects.toBeInstanceOf(NotDurable); expect(calls).toBe(1);
  store.fail = false; await credentials.persist(); expect(store.value?.access_token).toBe('member-2');
});
test('Published means the new document is durable, despite a post-publication storage error', async () => {
  const store = new Store(); store.published = true;
  const credentials = await OAuthCredentials.issue({ credentials: bundle(), store, authority: authority(async () => bundle('2')) });
  await credentials.refresh(); expect(credentials.rotation).toBe(1); expect(store.value?.access_token).toBe('member-2');
});
test('local cancellation cannot split refresh exchange and publication; drain waits for both', async () => {
  const store = new Store(); let release!: () => void;
  const started = new Promise<void>(resolve => { release = resolve; });
  const credentials = await OAuthCredentials.issue({ credentials: bundle(), store, authority: authority(async () => { await started; return bundle('2'); }) });
  const controller = new AbortController(), pending = credentials.refresh({ signal: controller.signal });
  controller.abort(); await expect(pending).rejects.toBeInstanceOf(CancelledError);
  release(); await credentials.drain(); expect(store.value?.access_token).toBe('member-2');
});
test('ambiguous refresh outcome latches authorization loss without retry', async () => {
  let calls = 0; const flow = new DeviceFlow({ baseURL: 'http://nexus.example', fetch: async () => { calls++; throw new Error('connection lost after send'); } });
  const credentials = await OAuthCredentials.issue({ credentials: bundle(), store: new Store(), authority: flow });
  await expect(credentials.refresh()).rejects.toBeInstanceOf(AuthorizationLost);
  await expect(credentials.memberCredential()).rejects.toBeInstanceOf(AuthorizationLost); expect(calls).toBe(1);
});
test('API keys have no refresh lifecycle and refuse missing planes', () => {
  const keys = new APIKeyCredentials({ version: 2, authentication_kind: 'api_key', connection: 'manual', access_token: 'key' });
  expect(keys.memberCredential()).toBe('key'); expect(() => keys.executorCredential()).toThrow(PlaneUnavailable);
});
const grant = () => ({ token_type: 'Bearer', plane: 'member', access_token: 'member', executor_access_token: 'executor', refresh_token: 'refresh', expires_in: 3600, runner: { token_type: 'Bearer', plane: 'executor_transport', access_token: 'runner', refresh_token: 'runner-refresh', expires_in: 1800 } });
test('nested Runner grants validate their own authority and preserve their own expiry', async () => {
  const value = grant();
  const flow = new DeviceFlow({ baseURL: 'http://nexus.example', fetch: async () => Response.json(value) });
  const parsed = await flow.rotate('refresh'); expect(parsed.runner?.expires_in).toBe(1800); expect(parsed.runner?.executor_access_token).toBe('runner');
  for (const field of ['plane', 'token_type', 'expires_in'] as const) {
    const malformed = structuredClone(value) as unknown as { runner: Record<string, unknown> }; malformed.runner[field] = 'unknown';
    const invalid = new DeviceFlow({ baseURL: 'http://nexus.example', fetch: async () => Response.json(malformed) });
    await expect(invalid.rotate('refresh')).rejects.toBeInstanceOf(AuthorizationLost);
  }
});
test('device throttling respects Retry-After, and PKCE uses S256 with a fresh state', async () => {
  const flow = new DeviceFlow({ baseURL: 'http://nexus.example', fetch: async () => Response.json({ error: 'slow_down' }, { status: 429, headers: { 'Retry-After': '17' } }) });
  const result = await flow.poll({ device_code: 'device', user_code: 'USER', verification_uri: 'http://nexus.example', verification_uri_complete: 'http://nexus.example', expires_in: 100, interval: 5, deadline: performance.now() + 100000, branch: 'agent' });
  expect(result).toEqual({ state: 'throttled', retry_after: 17 });
  const pkce = await ApplicationOAuth.pkce(), another = await ApplicationOAuth.pkce();
  const expected = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(pkce.code_verifier))).toString('base64url');
  expect(pkce.code_challenge).toBe(expected); expect(another.state).not.toBe(pkce.state);
});
