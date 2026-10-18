import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { Client, PlatformClient, MalformedResponse } from '../src/index.js';
import type { WorkAnalysis, PlatformUsageAnalysis, PlatformBudget, PlatformBudgetLedgerEntry } from '../src/index.js';

function fixture<T>(family: string, key: string): T {
  return (JSON.parse(readFileSync(new URL(`../../../contracts/nexus/v1/${family}.json`, import.meta.url), 'utf8')) as Record<string, T>)[key]!;
}
function clients(body: unknown, status = 200) {
  const requests: { url: URL; init: RequestInit | undefined }[] = [];
  const config = { baseURL: 'http://nexus.example', credential: 'credential', fetch: async (input: string | URL | Request, init?: RequestInit) => {
    requests.push({ url: new URL(String(input)), init });
    return Response.json(body, { status });
  } };
  return { member: new Client(config), platform: new PlatformClient(config), requests };
}

test('member analysis projects exact costs, independent missing samples and execution coverage', async () => {
  const body = fixture<{ analysis: WorkAnalysis }>('analyses', 'valid_member_fixture');
  const { member, requests } = clients(body);
  const query = { from: '2026-10-15T00:00:00.123456Z', to: '2026-10-16T00:00:00.654321Z', workspace_public_id: 'workspace', agent_public_id: 'agent', provider_id: 'dev', catalog_model_ref: 'dev/text', workload: 'text_generation', status: 'discarded' as const, group_by: 'provider_id' as const, rank_by: 'cost_amount' as const, limit: 3 };
  const analysis = await member.work.analysis(query);
  expect(analysis).toEqual(body.analysis);
  expect(analysis.model_usage.totals.cost_amount).toBe('0.040500000000000001');
  expect(analysis.model_usage.totals.cost_complete).toBe(false);
  expect(analysis.model_usage.totals.amount_sample_count).toBe(2);
  expect(analysis.model_usage.latency.duration_ms.p50).toBe(0);
  expect(analysis.model_usage.latency.time_to_first_token_ms.p50).toBeNull();
  expect(analysis.execution.tools.error_result_count).toBe(1);
  expect(requests[0]?.url.pathname).toBe('/agent_api/v1/work_analysis');
  for (const [key, value] of Object.entries(query)) expect(requests[0]?.url.searchParams.get(key)).toBe(String(value));
});

test('administrator analysis preserves its infrastructure-only response', async () => {
  const body = fixture<{ analysis: PlatformUsageAnalysis }>('analyses', 'valid_admin_fixture');
  const { platform, requests } = clients(body);
  expect(await platform.modelUsage.analysis()).toEqual(body.analysis);
  expect(requests[0]?.url.pathname).toBe('/api/v1/admin/model_usage/analysis');
  expect(requests[0]?.url.search).toBe('');
});

test('analysis group, rank and status maps carry unknown server values', async () => {
  const group = fixture<{ analysis: WorkAnalysis }>('analyses', 'unknown_group_fixture');
  expect((await clients(group).member.work.analysis()).model_usage.breakdown.group_by).toBe(group.analysis.model_usage.breakdown.group_by);
  const rank = fixture<{ analysis: PlatformUsageAnalysis }>('analyses', 'unknown_rank_fixture');
  expect((await clients(rank).platform.modelUsage.analysis()).model_usage.breakdown.rank_by).toBe(rank.analysis.model_usage.breakdown.rank_by);
  const status = fixture<{ analysis: WorkAnalysis }>('analyses', 'unknown_status_fixture');
  const analysis = await clients(status).member.work.analysis();
  expect(analysis.model_usage.status_counts).toEqual(status.analysis.model_usage.status_counts);
  expect(analysis.execution.status_counts).toEqual(status.analysis.execution.status_counts);
  expect(analysis.execution.tools.status_counts).toEqual(status.analysis.execution.tools.status_counts);
  expect(analysis.execution.tools.groups[0]?.status_counts).toEqual(status.analysis.execution.tools.groups[0]?.status_counts);
});

test('analysis validates required cost evidence, nullable percentiles and integer maps', async () => {
  for (const change of [
    (body: Record<string, any>) => { delete body.analysis.model_usage.totals.amount_sample_count; },
    (body: Record<string, any>) => { delete body.analysis.model_usage.latency.duration_ms.p95; },
    (body: Record<string, any>) => { body.analysis.execution.status_counts.future = '3'; },
    (body: Record<string, any>) => { body.analysis.execution.tools.groups[0].status_counts.future = 0.5; },
    (body: Record<string, any>) => { body.analysis.model_usage.totals.cost_amount = 0.0405; },
  ]) {
    const body = fixture<Record<string, any>>('analyses', 'valid_member_fixture');
    change(body);
    await expect(clients(body).member.work.analysis()).rejects.toBeInstanceOf(MalformedResponse);
  }
});

test('all budget readers retain subject, measured time, current window and precise headroom', async () => {
  const body = fixture<{ budgets: PlatformBudget[]; current_budget: PlatformBudget; measured_at: string; user_public_id: string; user_kind: string; cost_unit: string }>('platform_budgets', 'valid_list_fixture');
  const { member, platform, requests } = clients(body);
  const scopes = [member.profile.budgets, platform.profile.budgets, platform.budgets('human'), platform.agents.agent('agent').budgets];
  const paths = ['/agent_api/v1/profile/budgets', '/api/v1/profile/budgets', '/api/v1/admin/users/human/budgets', '/api/v1/agents/agent/budgets'];
  for (const [index, scope] of scopes.entries()) {
    const page = await scope.list({ after: 'cursor', limit: 2, order: 'asc' });
    expect(page.items).toEqual(body.budgets);
    expect(page.current_budget).toEqual(body.current_budget);
    expect(page.current_budget?.headroom).toBe('9.875000000000000001');
    expect(page.measured_at).toBe(body.measured_at);
    expect(page.user_public_id).toBe(body.user_public_id);
    expect(page.user_kind).toBe(body.user_kind);
    expect(page.cost_unit).toBe(body.cost_unit);
    expect(page.next_after).toBeNull();
    expect(requests[index]?.url.pathname).toBe(paths[index]);
    expect(requests[index]?.url.searchParams.get('after')).toBe('cursor');
  }
});

test('a missing current budget remains distinct from a missing projection', async () => {
  const body = fixture<Record<string, unknown>>('platform_budgets', 'valid_uncapped_fixture');
  expect((await clients(body).member.profile.budgets.list()).current_budget).toBeNull();
  delete body.current_budget;
  await expect(clients(body).member.profile.budgets.list()).rejects.toBeInstanceOf(MalformedResponse);
});

test('budget reads retain measurement and ledger entry metadata without operation keys', async () => {
  const body = fixture<{ budget: PlatformBudget; measured_at: string }>('platform_budgets', 'valid_show_fixture');
  const { member, requests } = clients(body);
  expect(await member.profile.budgets.fetch('budget/id')).toEqual(body);
  expect(requests[0]?.url.pathname).toBe('/agent_api/v1/profile/budgets/budget%2Fid');
  const entries = fixture<{ entries: PlatformBudgetLedgerEntry[] }>('platform_budgets', 'valid_entries_fixture');
  const ledger = clients(entries);
  const page = await ledger.platform.agents.agent('agent').budgets.entries('budget', { after: 'cursor', limit: 1 });
  expect(page.items).toEqual(entries.entries);
  expect(page.items[0]?.amount).toBe('0.000000000000000001');
  expect(page.items[0]?.kind).toBe('credit_adjustment');
  expect(page.items[0]).not.toHaveProperty('operation_key');
  expect(ledger.requests[0]?.url.pathname).toBe('/api/v1/agents/agent/budgets/budget/entries');
  entries.entries[0]!.kind = 'future_ledger_kind';
  expect((await clients(entries).member.profile.budgets.entries('budget')).items[0]?.kind).toBe('future_ledger_kind');
});

test('Agent allowance mutations use explicit keys and preserve exact money', async () => {
  const input = { amount: '0.000000000000000001', starts_at: '2026-10-15T00:00:00Z' };
  const opened = clients(fixture('platform_budgets', 'valid_open_fixture'), 201);
  const result = await opened.platform.agents.agent('agent').budgets.open(input, { idempotencyKey: 'allowance-open' });
  expect(result.budget.headroom).toBe('9.875000000000000001');
  expect(opened.requests[0]?.url.pathname).toBe('/api/v1/agents/agent/budgets');
  expect(new Headers(opened.requests[0]?.init?.headers).get('Idempotency-Key')).toBe('allowance-open');
  expect(JSON.parse(opened.requests[0]?.init?.body as string)).toEqual({ budget: input });
  const changed = clients(fixture('platform_budgets', 'unknown_entry_kind_fixture'));
  const adjustment = await changed.platform.agents.agent('agent').budgets.adjust('budget', { kind: 'debit', amount: input.amount }, { idempotencyKey: 'allowance-adjust' });
  expect(adjustment.entry.kind).toBe('zz_unknown_value');
  expect(adjustment.entry.operation_key).toBe('fixture-budget-adjustment');
  expect(changed.requests[0]?.init?.method).toBe('PATCH');
  const revoked = clients(fixture('platform_budgets', 'valid_revoke_fixture'));
  await revoked.platform.agents.agent('agent').budgets.revoke('budget', { reason: 'done' }, { idempotencyKey: 'allowance-revoke' });
  expect(revoked.requests[0]?.url.pathname).toBe('/api/v1/agents/agent/budgets/budget/revocation');
});
