import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { Client } from '../src/index.js';

const fixtures = JSON.parse(readFileSync(new URL('../../../contracts/nexus/v1/history.json', import.meta.url), 'utf8'));
function client(body: unknown) {
  const requests: URL[] = [];
  const member = new Client({ baseURL: 'http://nexus.example', credential: 'member', fetch: async input => { requests.push(new URL(String(input))); return Response.json(body); } });
  return { member, requests };
}

test('search preserves the archive vocabulary, answerer and opaque excerpt location', async () => {
  const { member, requests } = client(fixtures.search_fixture);
  const page = await member.workspace('workspace').conversations.search({ query: '人工智能', archived: 'only', answering_user_public_id: 'answerer', after: 'previous' });
  expect(page.matches[0]?.location).toBe(fixtures.search_fixture.matches[0].location);
  expect(Object.fromEntries(requests[0]!.searchParams)).toEqual({ query: '人工智能', archived: 'only', answering_user_public_id: 'answerer', after: 'previous' });
});

test('field windows retain the exact candidate, text and explicit continuation', async () => {
  const { member, requests } = client(fixtures.field_fixture);
  const turns = member.workspace('workspace').conversation('conversation').turns;
  const page = await turns.field('turn', 'variant/id', 'steers', { location: 'opaque-location' });
  expect(requests[0]!.pathname).toBe('/agent_api/v1/workspaces/workspace/conversations/conversation/turns/turn/variants/variant%2Fid/fields/steers');
  expect(Object.fromEntries(requests[0]!.searchParams)).toEqual({ location: 'opaque-location' });
  expect(page.text).toBe(fixtures.field_fixture.text);
  expect(page.variant_public_id).toBe(fixtures.field_fixture.variant_public_id);
  expect(page.next_after).toBe(fixtures.field_fixture.pagination.next_after);
  await turns.field('turn', 'variant/id', 'steers', { after: page.next_after! });
  expect(Object.fromEntries(requests[1]!.searchParams)).toEqual({ after: page.next_after });
  expect(requests).toHaveLength(2);
});
