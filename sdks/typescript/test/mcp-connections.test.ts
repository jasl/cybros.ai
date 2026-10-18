import { readFileSync } from 'node:fs';
import { expect, test } from 'vitest';
import { Conflict, PlatformClient } from '../src/index.js';
import type { PlatformMcpAuthorization, PlatformMcpConnection } from '../src/index.js';

const pack = JSON.parse(readFileSync(new URL('../../../contracts/nexus/v1/mcp_connections.json', import.meta.url), 'utf8')) as {
  oauth_owner_fixture: { mcp_connection: PlatformMcpConnection };
  unknown_authorization_status_fixture: { mcp_connection: PlatformMcpConnection };
  authorization_fixture: { authorization: PlatformMcpAuthorization };
};

test('OAuth creation and authorization use the owner command and typed public response', async () => {
  const calls: { method: string; path: string; body: unknown }[] = [];
  const responses = [
    { status: 201, body: pack.oauth_owner_fixture },
    { status: 200, body: pack.authorization_fixture },
  ];
  const connections = new PlatformClient({ baseURL: 'http://nexus.example', credential: 'fixture-human', fetch: async (url, options) => {
    calls.push({ method: options?.method ?? 'GET', path: new URL(String(url)).pathname, body: JSON.parse(String(options?.body)) });
    const response = responses.shift()!;
    return Response.json(response.body, { status: response.status });
  } }).mcpConnections;
  const input = { name: 'Work', endpoint_url: 'https://tools.example/mcp', auth_type: 'oauth' as const };
  const connection = await connections.create(input);
  expect(connection.auth_type).toBe('oauth');
  expect(connection.authorization_status).toBe('authorized');
  expect(connection.authorization_expires_at).toBe(pack.oauth_owner_fixture.mcp_connection.authorization_expires_at);
  const authorization = await connections.startAuthorization(connection.public_id, { lock_version: 3 });
  expect(authorization).toEqual(pack.authorization_fixture.authorization);
  expect(calls).toEqual([
    { method: 'POST', path: '/api/v1/mcp_connections', body: { mcp_connection: input } },
    { method: 'POST', path: `/api/v1/mcp_connections/${connection.public_id}/authorization`, body: { command: { lock_version: 3 } } },
  ]);
});

test('owner reads preserve future authorization states and clear nullable OAuth state', async () => {
  const cleared = { ...pack.oauth_owner_fixture.mcp_connection, authorization_status: 'not_authorized', authorization_expires_at: null, credential_configured: false, available: false, lock_version: 4 };
  const calls: { method: string; body: unknown }[] = [];
  const responses = [pack.unknown_authorization_status_fixture, { mcp_connection: cleared }];
  const connections = new PlatformClient({ baseURL: 'http://nexus.example', credential: 'fixture-human', fetch: async (_url, options) => {
    calls.push({ method: options?.method ?? 'GET', body: options?.body ? JSON.parse(String(options.body)) : null });
    return Response.json(responses.shift());
  } }).mcpConnections;
  expect((await connections.fetch('connection')).authorization_status).toBe('future_status');
  expect(await connections.clearCredential('connection', { lock_version: 3 })).toEqual(cleared);
  expect(calls[1]).toEqual({ method: 'DELETE', body: { command: { lock_version: 3 } } });
});

test('authorization version conflicts are returned without retry', async () => {
  let count = 0;
  const connections = new PlatformClient({ baseURL: 'http://nexus.example', credential: 'fixture-human', fetch: async () => {
    count += 1;
    return Response.json({ error: { code: 'stale_object' } }, { status: 409 });
  } }).mcpConnections;
  await expect(connections.startAuthorization('connection', { lock_version: 2 })).rejects.toBeInstanceOf(Conflict);
  expect(count).toBe(1);
});
