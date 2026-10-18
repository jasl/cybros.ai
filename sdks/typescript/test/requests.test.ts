import { expect, test } from 'vitest';
import { Client, ExecutorClient, MalformedResponse, PlatformClient, Steps } from '../src/index.js';
import type { Fetch } from '../src/index.js';
const calls: { url: URL; body: unknown; headers: Headers }[] = [];
const fetcher: Fetch = async (url, options) => { calls.push({ url: new URL(String(url)), body: typeof options?.body === 'string' ? JSON.parse(options.body) : options?.body, headers: new Headers(options?.headers) }); return Response.json({}, { status: options?.method === 'POST' && String(url).endsWith('/inputs') ? 202 : options?.method === 'POST' && String(url).endsWith('/conversations') ? 201 : 200 }); };
const config = { baseURL: 'http://nexus.example', credential: 'secret', fetch: fetcher };
const client = new Client(config), chat = client.workspace('workspace').conversation('conversation');
async function sent(call: Promise<unknown>) { try { await call; } catch (error) { if (!(error instanceof MalformedResponse)) throw error; } return calls.at(-1)!; }
test('Run list carries the work filters', async () => {
  const filters = { from: '2026-09-01T00:00:00Z', to: '2026-10-01T00:00:00Z', answering_user_public_id: 'answerer', kind: 'conversation' as const };
  const request = await sent(client.workspace('workspace').runs.list(filters));
  for (const [key, value] of Object.entries(filters)) expect(request.url.searchParams.get(key)).toBe(value);
});
test('Input payload preserves omission, null, arbitrary JSON and every legal message role', async () => {
  for (const role of ['user', 'assistant', 'system', 'tool'] as const) {
    const request = await sent(chat.inputs.create({ kind: 'message', role, text: 'Hello', configuration: null, agent_configuration: { custom_snake_key: { untouchedCamel: true } } }, { idempotencyKey: 'mutation-key' }));
    expect(request.body).toEqual({ input: { kind: 'message', role, text: 'Hello', configuration: null, agent_configuration: { custom_snake_key: { untouchedCamel: true } } } });
    expect(request.headers.get('Idempotency-Key')).toBe('mutation-key');
  }
});
test('assembly and route requests use the kernel grammar without field rewriting', async () => {
  const input = { kind: 'direct_reply' as const, text: 'Hello', history: { max_entries: 10, token_budget_share: 0.5 }, reasoning_replay: { mode: 'last_turn' as const }, inline: [{ slot: 'system_prompt' as const, text: 'Role', role: 'system' as const }, { role: 'developer' as const, text: 'Tail', position: 'tail' as const }], model_selection: { source: 'explicit' as const, model: 'local/model', constraint: 'model' as const, alternatives: [] }, fallback_models: [], steps: [Steps.tool({ name: 'read', route: { kind: 'runner' } }), Steps.tool({ name: 'search', route: { kind: 'mcp', connection_public_id: 'connection' } })] };
  expect((await sent(chat.inputs.create(input, { idempotencyKey: 'key' }))).body).toEqual({ input });
});
test('Executor operations retain their opaque kind request and Conversation side uses 1', async () => {
  const request = { kind: 'append_steps', steps: [{ tool: { name: 'read', input: { custom_payload: null } } }] };
  const input = { claim_token: 'claim', operation: { key: 'operation', request } };
  expect((await sent(new ExecutorClient(config).inboxTask('run', 'task').submit(input))).body).toEqual(input);
  expect((await sent(client.workspace('workspace').conversations.list({ side: true }))).url.searchParams.get('side')).toBe('1');
});
test('JavaScript mutation calls without an idempotency key are refused before HTTP', async () => {
  const before = calls.length;
  await expect(chat.inputs.create({ kind: 'message', text: 'Hello' }, {} as never)).rejects.toThrow('idempotencyKey');
  expect(calls.length).toBe(before);
});
test('append resolutions use the key-addressed array grammar', async () => {
  const input = { steps: [], resolve: ['first', { task: 'second', content: [{ type: 'text', text: 'Continue' }], outcome: 'completed' as const }], expected_revision: 3 };
  const request = await sent(client.workspace('workspace').run('run').append(input, { idempotencyKey: 'append' }));
  expect(request.body).toEqual(input); expect(request.headers.get('Idempotency-Key')).toBe('append');
});

test('model defaults preserve the complete accepted Step vocabulary', () => {
  const defaults = { model: { model: 'local/model', reasoning_enabled: true }, workload: 'text_generation' as const, configuration: { temperature: 0.2 }, tools: [{ type: 'function' as const, function: { name: 'echo' } }], instructions: 'Answer', compaction: { threshold: 0.8 }, on_failure: 'halt' as const, fan_on_failure: 'absorb' as const, kernel_tools: ['nexus.human.ask'], runner_executor_public_ids: ['runner'], runner_tool_names: [], mcp_tools: [{ connection_public_id: 'connection', tool_name: 'search', name: 'search' }], model_selection: { source: 'explicit' as const, model: 'local/model', constraint: 'model' as const }, fallback_models: [] };
  expect(Steps.tool({ name: 'read', model_defaults: defaults })).toEqual({ tool: { name: 'read', model_defaults: defaults } });
  expect(Steps.model({ prompt: 'Read', results: ['r1', 'r2t0'], workload: 'embedding', visibility: 'collapsed' })).toEqual({ model: { prompt: 'Read', results: ['r1', 'r2t0'], workload: 'embedding', visibility: 'collapsed' } });
});
test('remaining command families preserve their exact owning-controller roots', async () => {
  const workspace = client.workspace('workspace');
  const estimate = { prompt: 'Trial', render: true, template: { sections: [] }, history: { max_entries: 2 }, reasoning_replay: null, inline: null, variables: { name: 'User' } };
  expect((await sent(chat.estimateInput(estimate))).body).toEqual({ context_estimate: estimate });
  expect((await sent(chat.setMemoryContext(null))).body).toEqual({ memory_context: null });
  const schedule = { expected_lock_version: 2, name: 'Daily', tool_names: null, fallback_models: null, rule: { kind: 'interval' as const, every_seconds: 60, starts_at: '2026-10-15T12:00:00Z' } };
  expect((await sent(chat.schedules.update('schedule', schedule))).body).toEqual({ schedule });
  const inference = { workload: 'embedding' as const, model: { model: 'provider/embed' }, input: ['opaque', 'input'], configuration: { dimensions: 5 }, upload_public_ids: ['upload'] };
  expect((await sent(workspace.inferenceRequests.estimateInput(inference))).body).toEqual({ input_estimate: inference });
  const platform = new PlatformClient(config), provider = platform.modelProviders.provider('provider');
  const definition = { expected_lock_version: null, model: 'provider/model', definition: { custom_key: { unmodifiedCamel: true } } };
  expect((await sent(provider.setModelDefinition(definition))).body).toEqual({ command: definition });
  const credential = { lock_version: 3, bearer_token: 'private' };
  expect((await sent(platform.mcpConnections.rotateCredential('connection', credential))).body).toEqual({ credential });
  const release_check = { tag: 'release', backup: false };
  expect((await sent(platform.deployment.checkRelease(release_check))).body).toEqual({ release_check });
  const query = await sent(client.conversations.list({ archived: false, metadata_key: 'application', metadata_value: 'chat' }));
  expect(query.url.searchParams.get('archived')).toBe('false'); expect(query.url.searchParams.get('metadata_value')).toBe('chat');
});
test('process progress sends the source claim and preserves nullable exit', async () => {
  let body: unknown;
  const executor = new ExecutorClient({ baseURL: 'http://nexus.example', credential: 'executor', fetch: async (_url, options) => { body = JSON.parse(String(options?.body)); return new Response(null, { status: 202 }); } });
  const frame = { conversation_public_id: 'conversation', process_id: 'process', source: { run_public_id: 'run', task_key: 'task', claim_token: 'claim' }, lines: ['Listening'], exit: null };
  await executor.reportProgress(frame); expect(body).toEqual({ frame });
});

test('Conversation cost limit preserves omitted, exact decimal and explicit null fields', async () => {
  for (const fields of [{}, { cost_limit: '0.123456789012345678' }, { cost_limit: null }]) {
    expect((await sent(client.workspace('workspace').conversations.create(fields, { idempotencyKey: 'limit' }))).body).toEqual({ conversation: fields });
    const update = { lock_version: 2, title: 'Planning', ...fields };
    expect((await sent(chat.update(update))).body).toEqual({ conversation: update });
  }
});
