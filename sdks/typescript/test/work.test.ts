import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { Client, MalformedResponse } from '../src/index.js';
import type { AttentionItem, Run, WorkReport } from '../src/index.js';

const pack = JSON.parse(readFileSync(new URL('../../../contracts/nexus/v1/work.json', import.meta.url), 'utf8')) as Record<string, unknown>;
function client(body: unknown) {
  const requests: URL[] = [];
  const member = new Client({ baseURL: 'http://nexus.example', credential: 'member', fetch: async (input) => {
    requests.push(new URL(String(input)));
    return Response.json(body);
  } });
  return { work: member.work, requests };
}

test('global Runs keep the Workspace and serialize work filters', async () => {
  const fixture = pack.valid_runs_fixture as { runs: Run[] };
  const { work, requests } = client(fixture);
  const query = { workspace_public_id: 'workspace', agent_public_id: 'agent', executor_public_id: 'executor', from: '2026-10-14T00:00:00Z', to: '2026-10-15T00:00:00Z', answering_user_public_id: 'answerer', kind: 'conversation' as const, status: ['running', 'paused'], attention: 'any', order: 'desc' as const, after: 'cursor', limit: 5 };
  const page = await work.runs(query);
  expect(page.items[0]?.workspace_public_id).toBe(fixture.runs[0]?.workspace_public_id);
  expect(requests[0]?.pathname).toBe('/agent_api/v1/runs');
  for (const [key, value] of Object.entries(query)) expect(requests[0]?.searchParams.get(key)).toBe(String(value));
});

test('Attention preserves Task projections and the following view', async () => {
  const fixture = pack.valid_attention_fixture as { items: AttentionItem[] };
  const { work, requests } = client(fixture);
  const page = await work.attention({ view: 'following', workspace_public_id: 'workspace', after: 'cursor' });
  expect(page.items[0]?.task.key).toBe(fixture.items[0]?.task.key);
  expect(page.items[0]?.run_public_id).toBe(fixture.items[0]?.run_public_id);
  expect(page.items[0]?.conversation_public_id).toBeNull();
  expect(requests[0]?.pathname).toBe('/agent_api/v1/attention');
  expect(requests[0]?.searchParams.get('view')).toBe('following');
  expect(requests[0]?.searchParams.get('workspace_public_id')).toBe('workspace');
});

test('Work report keeps current counts, periods and precise partial cost', async () => {
  const fixture = pack.valid_report_fixture as { report: WorkReport };
  const { work, requests } = client(fixture);
  const report = await work.report({ workspace_public_id: 'workspace', agent_public_id: 'agent', from: '2026-10-14T00:00:00Z', to: '2026-10-15T00:00:00Z', unit: 'day' });
  expect(requests[0]?.searchParams.get('agent_public_id')).toBe('agent');
  expect(report.agent_public_id).toBe(fixture.report.agent_public_id);
  expect(report.current).toEqual(fixture.report.current);
  expect(report.totals.conversation_usage).toEqual(fixture.report.totals.conversation_usage);
  expect(report.totals.conversation_usage.cost_complete).toBe(false);
  expect(report.series[0]?.bucket_start_at).toBe(fixture.report.series[0]?.bucket_start_at);
  expect(report.previous).toEqual(fixture.report.previous);
  expect(requests[0]?.pathname).toBe('/agent_api/v1/work_report');
  expect(requests[0]?.searchParams.get('unit')).toBe('day');
});

test('Work report requires cost evidence and preserves unknown response units', async () => {
  const malformed = structuredClone(pack.valid_report_fixture) as { report: { totals: { conversation_usage: Record<string, unknown> } } };
  delete malformed.report.totals.conversation_usage.cost_complete;
  await expect(client(malformed).work.report()).rejects.toBeInstanceOf(MalformedResponse);
  const fixture = pack.unknown_unit_fixture as { report: WorkReport };
  const { work, requests } = client(fixture);
  expect((await work.report()).unit).toBe(fixture.report.unit);
  expect(requests[0]?.search).toBe('');
});
