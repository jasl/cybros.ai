import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { Client } from '../src/index.js';
import type { Schedule, ScheduleExecution, Variant } from '../src/index.js';

function fixture<T>(family: string, key: string): T { return JSON.parse(readFileSync(new URL(`../../../contracts/nexus/v1/${family}.json`, import.meta.url), 'utf8'))[key] as T; }
function client(body: unknown) {
  const requests: URL[] = [];
  const member = new Client({ baseURL: 'http://nexus.example', credential: 'member', fetch: async input => { requests.push(new URL(String(input))); return Response.json(body); } });
  return { member, requests };
}

test('global and scoped Schedule listings preserve Workspace and execution Variant with status filters', async () => {
  const body = fixture<{ schedules: Schedule[] }>('schedules', 'valid_list_fixture');
  const { member, requests } = client(body);
  const chat = member.workspace('workspace').conversation('conversation');
  for (const scope of [member.schedules, member.workspace('workspace').schedules, chat.schedules]) {
    const result = await scope.list({ status: 'paused', after: 'cursor', limit: 4 });
    expect(result.items[0]?.workspace_public_id).toBe(body.schedules[0]?.workspace_public_id);
    expect(result.items[0]?.last_execution?.variant_public_id).toBe(body.schedules[0]?.last_execution?.variant_public_id);
  }
  expect(requests.map(url => url.pathname)).toEqual(['/agent_api/v1/schedules', '/agent_api/v1/workspaces/workspace/schedules', '/agent_api/v1/workspaces/workspace/conversations/conversation/schedules']);
  for (const url of requests) { expect(url.searchParams.get('status')).toBe('paused'); expect(url.searchParams.get('after')).toBe('cursor'); }
});

test('Schedule execution pages retain nullable Variant references', async () => {
  const body = fixture<{ executions: ScheduleExecution[] }>('schedules', 'valid_executions_fixture');
  const resources = client(body);
  const page = await resources.member.workspace('workspace').conversation('conversation').schedules.executions('schedule');
  expect(page.items[0]?.variant_public_id).toBe(body.executions[0]?.variant_public_id);
  body.executions[0]!.variant_public_id = null;
  expect((await client(body).member.workspace('workspace').conversation('conversation').schedules.executions('schedule')).items[0]?.variant_public_id).toBeNull();
});

test('global Schedule listings send the selected Workspace alongside status and pagination', async () => {
  const { member, requests } = client(fixture('schedules', 'valid_list_fixture'));
  await member.schedules.list({ workspace_public_id: 'workspace', status: 'active', after: 'cursor', limit: 3 });
  expect(requests[0]?.pathname).toBe('/agent_api/v1/schedules');
  expect(Object.fromEntries(requests[0]!.searchParams)).toEqual({ workspace_public_id: 'workspace', status: 'active', after: 'cursor', limit: '3' });
});

test('a retained execution result uses the exact Variant read resource', async () => {
  const body = fixture<{ variant: Variant; turn: { public_id: string; inherited: boolean } }>('conversations', 'valid_variant_read_fixture');
  const { member, requests } = client(body);
  for (const inherited of [false, true]) {
    body.turn.inherited = inherited;
    const read = await member.workspace('workspace').conversation('conversation').turns.variant('turn', 'variant/id');
    expect(read.variant.content).toBe(body.variant.content);
    expect(read.variant.public_id).toBe(body.variant.public_id);
    expect(read.variant.details_pruned_at).toBe(body.variant.details_pruned_at ?? null);
    expect(read.turn_public_id).toBe(body.turn.public_id);
    expect(read.turn_inherited).toBe(inherited);
  }
  expect(requests[0]?.pathname).toBe('/agent_api/v1/workspaces/workspace/conversations/conversation/turns/turn/variants/variant%2Fid');
});
