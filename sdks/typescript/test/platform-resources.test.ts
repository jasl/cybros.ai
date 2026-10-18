import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { PlatformClient } from '../src/index.js';
import type { PlatformAgentConfiguration, PlatformAgentDetail, PlatformRunnerDetail } from '../src/index.js';

function fixture(family: string, key: string): unknown {
  return (JSON.parse(readFileSync(new URL(`../../../contracts/nexus/v1/${family}.json`, import.meta.url), 'utf8')) as Record<string, unknown>)[key];
}

function client(body: unknown) {
  const requests: { url: URL; method: string; body: unknown }[] = [];
  const platform = new PlatformClient({ baseURL: 'http://nexus.example', credential: 'test-only', fetch: async (input, init) => {
    requests.push({ url: new URL(String(input)), method: init?.method ?? 'GET', body: typeof init?.body === 'string' ? JSON.parse(init.body) : null });
    return Response.json(body);
  } });
  return { platform, requests };
}

test('Agent detail preserves the serving owner independently of its own declaration', async () => {
  const detail = fixture('platform_agents', 'valid_agent_detail_fixture') as { agent: PlatformAgentDetail };
  const { platform } = client(detail);
  expect(await platform.agents.agent('agent').fetch()).toEqual(detail.agent);
  const declaration = fixture('platform_agents', 'valid_agent_configuration_fixture') as PlatformAgentConfiguration;
  const actual = await client(declaration).platform.agents.agent('agent').configuration();
  expect(actual.agent).toEqual(declaration.agent);
  expect(actual.configuration.default_model).toBe(declaration.configuration.default_model);
  expect(actual.prompt_documents[0]?.content).toBe(declaration.prompt_documents[0]?.content);
  expect(actual.agent_updated_at).toBe(declaration.agent_updated_at);
  expect(actual.measured_at).toBe(declaration.measured_at);
});

test('managed Runner reads preserve management, eligibility, announcements and measurement time', async () => {
  const listing = fixture('platform_runners', 'valid_runners_fixture') as { runners: PlatformRunnerDetail[]; measured_at: string };
  const { platform, requests } = client(listing);
  const page = await platform.runners.list({ kind: 'runner', status: 'revoked', after: 'cursor', limit: 5 });
  expect(page.items[0]?.manager_public_id).toBe(listing.runners[0]?.manager_public_id);
  expect(page.items[0]?.eligible_for_current_user).toBe(false);
  expect(page.items[0]?.credential_readiness).toBe('ready');
  expect(page.measured_at).toBe(listing.measured_at);
  expect(requests[0]?.url.searchParams.get('kind')).toBe('runner');
  expect(requests[0]?.url.searchParams.get('status')).toBe('revoked');
  expect(requests[0]?.url.searchParams.get('after')).toBe('cursor');
  const detail = fixture('platform_runners', 'valid_runner_fixture') as { runner: PlatformRunnerDetail; measured_at: string };
  const actual = await client(detail).platform.runners.fetch('runner');
  expect(actual.runner.served_tools[0]?.input_schema).toEqual(detail.runner.served_tools[0]?.input_schema);
  expect(actual.runner.served_documents).toEqual(detail.runner.served_documents);
  expect(actual.runner.environment).toEqual(detail.runner.environment);
  expect(actual.measured_at).toBe(detail.measured_at);
});
