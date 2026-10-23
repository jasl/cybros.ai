import { describe, expect, test } from 'vitest';
import { Steps } from '../src/steps.js';
import { readFileSync } from 'node:fs';
import { Client, ExecutorClient, PlatformClient, Sessions, DeviceFlow, ApplicationOAuth, AuthorizationLost, MalformedResponse } from '../src/index.js';
function fixture(family: string, key: string): unknown { return (JSON.parse(readFileSync(new URL(`../../../contracts/nexus/v1/${family}.json`, import.meta.url), 'utf8')) as Record<string, unknown>)[key]; }
function transport(data: unknown, status = 200): import("../src/http.js").Fetch { return (async () => new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })); }
const config = (data: unknown, status = 200) => ({ baseURL: 'http://nexus.example', credential: 'test-only', fetch: transport(data, status) });
const member = (family: string, key: string, status = 200) => new Client(config(fixture(family, key), status));
const platform = (family: string, key: string, status = 200) => new PlatformClient(config(fixture(family, key), status));
const chat = (family: string, key: string) => member(family, key).workspace('workspace').conversation('conversation');
const run = (key: string) => member('runs', key).workspace('workspace').run('run');
test('Run listings preserve the Workspace public identifier', async () => {
  const client = new Client(config({ runs: [{ public_id: 'run', workspace_public_id: 'workspace', status: 'running' }], pagination: { next_after: null } }));
  const page = await client.workspace('workspace').runs.list();
  expect(page.items[0]?.workspace_public_id).toBe('workspace');
  expect((await run('valid_request_run_fixture').fetch()).workspace_public_id).toBeNull();
});
describe('Shared Nexus response contracts through public resources', () => {
  const cases: [string, () => Promise<unknown>][] = [
    ['profile', () => member('profiles', 'agent_api').profile.fetch()],
    ['named agents', () => member('profiles', 'named_agents_fixture').profile.agents.list()],
    ['ingress speaker', () => member('profiles', 'valid_ingress_speaker_fixture', 201).profile.registerIngressSpeaker({ channel_key: 'chat', external_id: 'speaker', display_name: 'Person' })],
    ['workspace', () => member('workspaces', 'valid_full_fixture').workspaces.fetch('id')],
    ['workspace page', () => member('workspaces', 'valid_list_fixture').workspaces.list()],
    ['workspace messaging', () => member('workspaces', 'valid_messaging_fixture').workspace('id').messaging()],
    ['principals', () => member('workspaces', 'valid_principals_fixture').workspace('id').principals()],
    ['store', () => member('store_entries', 'valid_fixture').profile.storeEntries.fetch('id')],
    ['store page', () => member('store_entries', 'valid_list_fixture').profile.storeEntries.list()],
    ['memory collection', () => member('memory_collections', 'valid_fixture').memoryCollections.fetch('collection')],
    ['memory collections', () => member('memory_collections', 'valid_list_fixture').memoryCollections.list()],
    ['memory', () => member('memory_documents', 'valid_fixture').memoryCollections.documents('collection').read('agent/file')],
    ['memory page', () => member('memory_documents', 'valid_list_fixture').memoryCollections.documents('collection').list()],
    ['memory grep', () => member('memory_documents', 'valid_grep_fixture').memoryCollections.documents('collection').grep({ pattern: 'x' })],
    ['prompt', () => member('prompt_documents', 'valid_fixture').profile.promptDocuments.read('system_prompt')],
    ['prompt page', () => member('prompt_documents', 'valid_list_fixture').profile.promptDocuments.list()],
    ['conversation', () => chat('conversations', 'valid_fixture').fetch()],
    ['conversation page', () => member('conversations', 'valid_list_fixture').conversations.list()],
    ['turns', () => chat('conversations', 'valid_turns_fixture').turns.list()],
    ['variants', () => chat('conversations', 'valid_variants_fixture').turns.variants('turn')],
    ['inputs', () => chat('conversations', 'valid_inputs_fixture').inputs.list()],
    ['materialization', () => chat('conversations', 'valid_materialization_fixture').inputs.materialization('input')],
    ['events', () => chat('conversations', 'valid_events_fixture').events()],
    ['context estimate', () => chat('conversations', 'valid_estimate_fixture').estimateInput({})],
    ['rendered context', () => chat('conversations', 'valid_rendered_estimate_fixture').estimateInput({ render: true })],
    ['request', () => chat('conversations', 'valid_request_fixture').turns.request('turn', 'variant')],
    ['regeneration receipt', () => chat('conversations', 'valid_regeneration_fixture').turns.regenerationReceipt('key')],
    ['history', () => chat('history', 'read_fixture').history()],
    ['history execution', () => chat('history', 'execution_fixture').history({ include_execution: true })],
    ['history search', () => member('history', 'search_fixture').workspace('workspace').conversations.search({ query: 'word' })],
    ['schedule', () => chat('schedules', 'valid_fixture').schedules.fetch('id')],
    ['schedule page', () => chat('schedules', 'valid_list_fixture').schedules.list()],
    ['schedule executions', () => chat('schedules', 'valid_executions_fixture').schedules.executions('id')],
    ['run', () => run('valid_request_run_fixture').fetch()],
    ['run task', () => run('valid_task_detail_fixture').task('task').fetch()],
    ['run graph', () => run('valid_graph_fixture').graph()],
    ['run phases', () => run('valid_phases_fixture').phases()],
    ['run transcript', () => run('valid_thread_page_fixture').transcript()],
    ['inference', () => member('inference_requests', 'valid_fixture').workspace('id').inferenceRequests.fetch('id')],
    ['inference events', () => member('inference_requests', 'valid_events_fixture').workspace('id').inferenceRequests.events('id')],
    ['models', () => member('models', 'valid_fixture').models.list()],
    ['providers', () => member('models', 'valid_providers_fixture').modelProviders.list()],
    ['tools', () => member('tools', 'valid_listing_fixture').tools.list()],
    ['tool assembly', () => member('tools', 'valid_assembly_fixture').tools.assemble()],
    ['executor discovery', () => new Client(config({executor: fixture('executors', 'discovery_fixture')})).executors.fetch('id')],
    ['executor self', () => new ExecutorClient(config(fixture('executors', 'valid_fixture'))).executor()],
    ['inbox', () => new ExecutorClient(config(fixture('executor_inbox', 'valid_fixture'))).inbox.list()],
    ['realtime', () => new ExecutorClient(config(fixture('executor_inbox', 'realtime_fixture'))).inboxTask('run', 'task').realtime('claim')],
    ['claim', () => new ExecutorClient(config(fixture('executor_inbox', 'claim_fixture'))).inboxTask('run', 'task').claim()],
    ['upload', () => member('uploads', 'valid_fixture').uploads.fetch('id')],
    ['MCP member', () => member('mcp_connections', 'member_fixture').mcpConnections.fetch('id')],
    ['MCP platform', () => platform('mcp_connections', 'owner_fixture').mcpConnections.fetch('id')],
    ['MCP OAuth platform', () => platform('mcp_connections', 'oauth_owner_fixture').mcpConnections.fetch('id')],
    ['MCP authorization', () => platform('mcp_connections', 'authorization_fixture').mcpConnections.startAuthorization('id', { lock_version: 3 })],
    ['session', () => platform('sessions', 'valid_show_fixture').session.fetch()],
    ['Agent', () => platform('platform_agents', 'valid_agent_detail_fixture').agents.agent('id').fetch()],
    ['Agent configuration', () => platform('platform_agents', 'valid_agent_configuration_fixture').agents.agent('id').configuration()],
    ['Managed runners', () => platform('platform_runners', 'valid_runners_fixture').runners.list()],
    ['Managed runner', () => platform('platform_runners', 'valid_runner_fixture').runners.fetch('id')],
    ['Agents', () => platform('platform_agents', 'valid_agents_fixture').agents.list()],
    ['keys', () => platform('platform_agents', 'valid_member_keys_fixture').agents.agent('id').apiKeys.list()],
    ['key grant', () => platform('platform_agents', 'valid_executor_key_grant_fixture', 201).agents.agent('id').executorApiKeys.create({ name: 'key' })],
    ['budget', () => platform('platform_budgets', 'valid_open_fixture', 201).budgets('user').open({ amount: '1.000000000000000001', starts_at: '2026-10-15T00:00:00Z' }, { idempotencyKey: 'key' })],
    ['budget adjustment', () => platform('platform_budgets', 'valid_adjust_fixture').budgets('user').adjust('budget', { kind: 'credit', amount: '0.1' }, { idempotencyKey: 'key' })],
    ['deployment state', () => platform('platform_deployment', 'valid_state_fixture').deployment.fetch()],
    ['deployment operation', () => platform('platform_deployment', 'valid_upgrade_fixture').deployment.operation('id').fetch()],
    ['deployment log', () => platform('platform_deployment', 'valid_log_fixture').deployment.operation('id').log()],
    ['usage', () => platform('platform_usage', 'valid_report_fixture').modelUsage.report({ from: '2026-10-14', to: '2026-10-15' })],
  ];
  for (const [label, call] of cases) test(label, async () => { expect(await call()).toBeDefined(); });
  for (const key of ['unknown_plane_fixture', 'unknown_token_type_fixture']) test(`reject OAuth ${key}`, async () => {
    const oauth = new DeviceFlow({ baseURL: 'http://nexus.example', fetch: transport(fixture('oauth', key)) });
    await expect(oauth.rotate('refresh')).rejects.toBeInstanceOf(AuthorizationLost);
  });
  for (const branch of ['agent', 'runner'] as const) test(`OAuth accepts the canonical ${branch} grant`, async () => {
    const oauth = new DeviceFlow({ baseURL: 'http://nexus.example', fetch: transport(fixture('oauth', `valid_${branch}_token_fixture`)) });
    const result = await oauth.poll({ device_code: 'device', user_code: 'CODE', verification_uri: 'http://nexus.example', verification_uri_complete: 'http://nexus.example', expires_in: 900, interval: 5, deadline: performance.now() + 900000, branch });
    expect(result.state).toBe('authorized');

  });
  for (const key of ['unknown_plane_fixture', 'unknown_scope_fixture', 'unknown_token_type_fixture', 'unknown_child_plane_fixture']) test(`reject Application OAuth ${key}`, async () => {
    const oauth = new ApplicationOAuth({ baseURL: 'http://nexus.example', fetch: transport(fixture('application_oauth', key)) });
    await expect(oauth.rotate('refresh')).rejects.toBeInstanceOf(AuthorizationLost);
  });
  test('Application OAuth lineages are independent', async () => {
    const oauth = new ApplicationOAuth({ baseURL: 'http://nexus.example', fetch: transport(fixture('application_oauth', 'valid_runtime_fixture')) });
    const result = await oauth.rotate('refresh'); expect(result.platform_access_token).toBeTypeOf('string'); expect(result.access_token).toBeNull(); expect(result.agent?.access_token).toBeTypeOf('string'); expect(result.runner?.executor_access_token).toBeTypeOf('string');
  });
  test('unknown member credential plane is rejected', async () => { await expect(member('profiles', 'unknown_credential_plane_fixture').profile.fetch()).rejects.toBeInstanceOf(MalformedResponse); });
  test('unknown Platform credential plane is rejected', async () => { await expect(platform('profiles', 'unknown_platform_credential_plane_fixture').profile.fetch()).rejects.toBeInstanceOf(MalformedResponse); });
  test('session token_type rejects unknown values', async () => { await expect(new Sessions({ baseURL: 'http://nexus.example', fetch: transport(fixture('sessions', 'unknown_token_type_fixture'), 201) }).create({ email: 'test@example.com', password: 'test' })).rejects.toBeInstanceOf(MalformedResponse); });
});

test('Executor commit projects the settled Task while preserving tool error content independently', async () => {
  const response = fixture('runs', 'valid_task_detail_fixture') as { task: Record<string, unknown> };
  response.task.status = 'completed'; response.task.result = { is_error: true, content: [{ type: 'text', text: 'The tool refused this operation' }] };
  const result = await new ExecutorClient(config(response)).inboxTask('run', 'task').commit({ claim_token: 'claim', outcome: 'completed', is_error: true, content: [{ type: 'text', text: 'The tool refused this operation' }] });
  expect(result.status).toBe('completed'); expect(result.result?.is_error).toBe(true); expect(result.result?.content).toEqual([{ type: 'text', text: 'The tool refused this operation' }]);
});

test('memory grep returns canonical text and line_number projections', async () => {
  const result = await member('memory_documents', 'valid_grep_fixture').memoryCollections.documents('collection').grep({ pattern: 'preferences' });
  const expected = fixture('memory_documents', 'valid_grep_fixture') as { matches: { path: string; line_number: number; text: string }[] };
  expect(result.matches).toEqual(expected.matches); expect(typeof result.matches[0]!.text).toBe('string'); expect(Number.isSafeInteger(result.matches[0]!.line_number)).toBe(true);
});

test('Conversation cost limit and reached state retain their typed public values', async () => {
  const source = fixture('conversations', 'valid_fixture') as { conversation: Record<string, unknown> };
  for (const cost_limit of ['0.123456789012345678', null]) {
    const cost_limit_reached = cost_limit !== null;
    const client = new Client(config({ conversation: { ...source.conversation, cost_limit, cost_limit_reached } }));
    const conversation = await client.workspace('workspace').conversation('conversation').fetch();
    expect(conversation.cost_limit).toBe(cost_limit);
    expect(conversation.cost_limit_reached).toBe(cost_limit_reached);
  }
});

test('typed ask fields survive inbox decoding and resolutions preserve false and zero', async () => {
  const ask = fixture('executor_inbox', 'structured_ask_fixture') as Record<string, unknown>;
  const inbox = await new ExecutorClient(config({ tasks: [ask], pagination: { next_after: null } })).inbox.list();
  expect(inbox.items[0]?.fields).toEqual(ask.fields);
  let body: unknown;
  const client = new Client({ baseURL: 'http://nexus.example', credential: 'test-only', fetch: async (_url, init) => {
    body = JSON.parse(String(init?.body));
    return Response.json(fixture('runs', 'valid_ask_task_detail_fixture'));
  } });
  await client.workspace('workspace').run('run').task('question').resolve({ answer: { enabled: false, count: 0 } });
  expect(body).toEqual({ answer: { enabled: false, count: 0 } });
});

test('an authored coordination ask carries an explicit indefinite wait', () => {
  expect(Steps.ask({ prompt: 'Wait for coordinator', indefinite: true })).toEqual({
    ask: { prompt: 'Wait for coordinator', indefinite: true },
  });
});
