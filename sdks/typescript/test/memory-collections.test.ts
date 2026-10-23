import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { Client, Conflict } from '../src/index.js';
import type { Fetch, MemorySelection } from '../src/index.js';
const fixture = JSON.parse(readFileSync(new URL('../../../contracts/nexus/v1/memory_collections.json', import.meta.url), 'utf8'));
function client(script: { status: number; body?: unknown }[]) {
  const calls: { path: string; method: string; body?: unknown }[] = [];
  const fetch: Fetch = async (input, init) => {
    calls.push({ path: new URL(String(input)).pathname, method: init?.method ?? 'GET', body: typeof init?.body === 'string' ? JSON.parse(init.body) : undefined });
    const reply = script.shift()!;
    return reply.status === 204 ? new Response(null, { status: 204 }) : Response.json(reply.body, { status: reply.status });
  };
  return { api: new Client({ baseURL: 'http://nexus.example', credential: 'fixture', fetch }), calls };
}
test('collection operations preserve UUID, metadata version and relative document path', async () => {
  const { api, calls } = client([
    { status: 200, body: fixture.valid_list_fixture },
    ...Array.from({ length: 4 }, () => ({ status: 200, body: fixture.valid_fixture })),
    { status: 201, body: fixture.valid_document_fixture },
    { status: 204 },
  ]);
  const uuid = (await api.memoryCollections.list()).items[0]!.public_id;
  expect((await api.memoryCollections.fetch(uuid)).scope).toBe('workspace');
  await api.memoryCollections.update(uuid, { name: 'Updated', lock_version: 2 });
  await api.memoryCollections.archive(uuid, { lock_version: 3 });
  await api.memoryCollections.restore(uuid, { lock_version: 4 });
  const document = await api.memoryCollections.documents(uuid).write(fixture.valid_write_request.memory);
  expect(document.collection_public_id).toBe(uuid);
  expect(document.path).toBe('notes.md');
  await api.memoryCollections.delete(uuid, { lock_version: 5 });
  expect(calls.map(call => call.method)).toEqual(['GET', 'GET', 'PATCH', 'POST', 'POST', 'POST', 'DELETE']);
  expect(calls[5]!.body).toEqual(fixture.valid_write_request);
  expect(calls[6]!.body).toEqual({ memory_collection: { lock_version: 5 } });
});
test('owner creation carries an explicit Speaker default request', async () => {
  const { api, calls } = client([{ status: 200, body: fixture.valid_fixture }]);
  await api.profile.agents.memoryCollections('reviewer').create({ default: true, speaker_public_id: 'speaker' });
  expect(calls).toEqual([{ path: '/agent_api/v1/profile/agents/reviewer/memory_collections', method: 'POST', body: { memory_collection: { default: true, speaker_public_id: 'speaker' } } }]);
});
test('an absent path still pins its collection and stale writes never re-read or retry', async () => {
  const uuid = fixture.valid_fixture.memory_collection.public_id;
  const resolved = { bindings: [{ name: 'notes', source: { collection_public_id: uuid }, scope: 'workspace', access: 'read_write', collection_public_id: uuid, owner_public_id: 'workspace', speaker_public_id: null, state: 'active' }] };
  const { api, calls } = client([{ status: 200, body: { memory: [], memory_context: resolved } }, { status: 409, body: { error: { code: 'stale_object', message: 'Changed' } } }]);
  const memory = api.workspace('workspace').conversation('conversation').memory('speaker');
  expect(await memory.bindings()).toEqual(resolved);
  const input = { path: 'notes/new.md', content: 'old proposal', expected_collection_public_id: uuid, expected_public_id: null, expected_lock_version: null };
  await expect(memory.write(input)).rejects.toBeInstanceOf(Conflict);
  expect(calls).toHaveLength(2);
  expect(calls[1]!.body).toEqual({ memory: { ...input, speaker_public_id: 'speaker' } });
});
test('the source union serializes both exact UUID and relative selection unchanged', async () => {
  const selection: MemorySelection = { bindings: [{ name: 'notes', source: { collection_public_id: 'collection' }, access: 'read' }, { name: 'speaker', source: { scope: 'speaker', speaker_public_id: 'speaker' }, access: 'read_write' }] };
  const { api, calls } = client([{ status: 409, body: { error: { code: 'stale_object', message: 'Changed' } } }]);
  await expect(api.workspace('workspace').conversation('conversation').setMemoryContext(selection)).rejects.toBeInstanceOf(Conflict);
  expect(calls[0]!.body).toEqual({ memory_context: selection });
});

test('default metadata permits unnamed and undescribed collections and filters by subject', async () => {
  const urls: URL[] = [];
  const fetch: Fetch = async input => {
    urls.push(new URL(String(input)));
    return Response.json({ memory_collections: [fixture.valid_default_fixture.memory_collection], pagination: { next_after: null } });
  };
  const api = new Client({ baseURL: 'http://nexus.example', credential: 'fixture', fetch });
  const row = (await api.profile.memoryCollections.list({ default: true, speaker_public_id: 'speaker' })).items[0]!;
  expect(row.name).toBeNull();
  expect(row.description).toBeNull();
  expect(urls[0]!.searchParams.get('default')).toBe('true');
  expect(urls[0]!.searchParams.get('speaker_public_id')).toBe('speaker');
});
