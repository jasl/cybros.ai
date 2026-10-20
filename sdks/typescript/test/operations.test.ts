import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { Client, ExecutorClient, PlatformClient, Sessions } from '../src/index.js';
import type { Fetch } from '../src/http.js';
interface Operation { id: string; plane: string; method: string; path: string; sdk_supported: boolean; }
const inventory = JSON.parse(readFileSync(new URL('../../../contracts/nexus/v1/operations.json', import.meta.url), 'utf8')) as { operations: Operation[] };
const requests: { method: string; path: string; headers: Headers; body: string | null }[] = [];
const fetcher: Fetch = async (input, init) => {
  const url = new URL(String(input)); requests.push({ method: init?.method ?? 'GET', path: url.pathname, headers: new Headers(init?.headers), body: typeof init?.body === 'string' ? init.body : null });
  return new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } });
};
const config = { baseURL: 'http://nexus.example', credential: 'test-only', fetch: fetcher };
const client = new Client(config), executor = new ExecutorClient(config), platform = new PlatformClient(config);
const workspace = client.workspace('id'), chat = workspace.conversation('id'), run = workspace.run('id'), task = run.task('id');
const mutation = { idempotencyKey: 'explicit-key' };
const version = { lock_version: 0 }, expected = { expected_lock_version: null };
const calls: (() => Promise<unknown>)[] = [];
const add = (...operations: (() => Promise<unknown>)[]) => calls.push(...operations);
add(() => client.work.runs(), () => client.work.attention(), () => client.work.report(), () => client.work.analysis(), () => client.schedules.list());
add(() => client.profile.fetch(), () => client.profile.declareConfiguration({ configuration: {} }), () => client.profile.registerIngressSpeaker({ channel_key: 'chat', external_id: 'speaker', display_name: 'Person' }));
add(() => client.profile.agents.list(), () => client.profile.agents.declare('id', { scope: 'instance', description: 'Review', configuration: {} }), () => client.profile.agents.remove('id'));
for (const memory of [client.profile.memory, client.profile.agents.memory('id'), workspace.memory, chat.memory()]) {
  add(() => memory.list(), () => memory.read('agent/file'), () => memory.grep({ pattern: 'word' }), () => memory.write({ path: 'agent/file', content: 'text', expected_public_id: null, expected_lock_version: null }), () => memory.edit({ path: 'agent/file', old_text: 'old', new_text: 'new', expected_public_id: 'id', expected_lock_version: 0 }), () => memory.delete('agent/file', { expected_public_id: 'id', expected_lock_version: 0 }));
}
for (const documents of [client.profile.promptDocuments, workspace.promptDocuments]) add(() => documents.list(), () => documents.read('id'), () => documents.write('id', { content: 'text' }), () => documents.delete('id'));
for (const entries of [client.profile.storeEntries, workspace.storeEntries, chat.storeEntries]) add(() => entries.list(), () => entries.fetch('id'), () => entries.create({ namespace: 'app', key: 'value', value: null }, mutation), () => entries.update('id', { ...version, value: null }), () => entries.delete('id', version));
add(() => client.workspaces.list(), () => client.workspaces.fetch('id'), () => client.workspaces.create({ name: 'Workspace' }, mutation), () => workspace.update({ ...version, name: 'Renamed' }), () => workspace.updateAccessMode({ ...version, access_mode: 'private' }), () => workspace.messaging(), () => workspace.setMessaging({ ...version, agents: [] }), () => workspace.setToolProviderOverrides({ ...version, overrides: {} }), () => workspace.transferOwnership({ ...version, target_user_public_id: 'id' }), () => workspace.archive(version), () => workspace.restore(version), () => workspace.delete(version), () => workspace.principals(), () => workspace.schedules.list());
add(() => client.conversations.list(), () => workspace.conversations.list(), () => workspace.conversations.archived(), () => workspace.conversations.search({ query: 'word' }), () => workspace.conversations.create({}, mutation), () => chat.fetch(), () => chat.update({ ...version, title: 'New' }), () => chat.archive(), () => chat.unarchive(), () => chat.delete(), () => chat.cancel(), () => chat.children(), () => chat.history(), () => chat.setMemoryContext({}), () => chat.setDefaultRunner(null), () => chat.setAccess({ default: 'full' }), () => chat.fork({ side: true }, mutation), () => chat.estimateInput({}), () => chat.compact(), () => chat.events());
for (const inputs of [chat.inputs, run.inputs]) add(() => inputs.list(), () => inputs.create({ kind: 'message', text: 'Hello' }, mutation), () => inputs.update('id', { text: 'Hello', expected_lock_version: 0 }), () => inputs.delete('id'), () => inputs.reorder(['id']));
add(() => chat.inputs.materialization('id'), () => chat.export());
const turns = chat.turns;
add(() => turns.variant('id', 'id'));
add(() => turns.field('id', 'id', 'steers'));
add(() => turns.list(), () => turns.fetch('id'), () => turns.setViewState('id', { concealed: false }), () => turns.delete('id'), () => turns.edit('id', { text: 'New' }), () => turns.regenerate('id', {}, mutation), () => turns.regenerationReceipt('key'), () => turns.variants('id'), () => turns.request('id', 'id'), () => turns.reasoning('id', 'id'), () => turns.activate('id', 'id'), () => turns.setVariantViewState('id', 'id', { concealed: true }));
const schedules = chat.schedules;
add(() => schedules.list(), () => schedules.fetch('id'), () => schedules.create({ prompt: 'Hello', rule: { kind: 'daily', local_time: '09:00', time_zone: 'UTC' } }, mutation), () => schedules.update('id', { expected_lock_version: 0, name: 'Daily' }), () => schedules.pause('id'), () => schedules.resume('id'), () => schedules.cancel('id'), () => schedules.run('id'), () => schedules.executions('id'));
add(() => workspace.runs.list(), () => workspace.runs.create({ steps: [{ tool: { name: 'echo' } }], approval_mode: 'bypass' }, mutation), () => run.fetch(), () => run.setDefaultRunner(null), () => run.append({ steps: [{ tool: { name: 'echo' } }] }, mutation), () => run.events(), () => run.transcript(), () => run.graph(), () => run.phases(), () => run.start(), () => run.pause(), () => run.resume(), () => run.stop(), () => run.delete());
add(() => task.realtime(), () => task.answerRealtime({ connection_id: "connection", sdp: "answer" }), () => task.fetch(), () => task.resolve({ content: 'done' }), () => task.retry(), () => task.abandon(), () => task.cancel(), () => task.approve(), () => task.deny(), () => task.compact(), () => task.request());
const inference = workspace.inferenceRequests;
const inferenceInput = { workload: 'text_generation' as const, model: { model: 'dev/mock-text' }, input: 'Hello' };
add(() => inference.list(), () => inference.fetch('id'), () => inference.create(inferenceInput, mutation), () => inference.estimateInput(inferenceInput), () => inference.events('id'), () => inference.cancel('id'), () => inference.delete('id'), () => inference.download('id', 0));
add(() => client.uploads.create(new Blob(['bytes']), 'test.txt'), () => client.uploads.fetch('id'), () => client.uploads.bytes('id'), () => client.uploads.thumbnail('id'), () => client.uploads.preview('id'), () => client.models.list(), () => client.modelProviders.list(), () => client.tools.list(), () => client.tools.assemble(), () => client.executors.list(), () => client.executors.fetch('id'), () => client.mcpConnections.list(), () => client.mcpConnections.fetch('id'));
add(() => executor.executor(), () => executor.announce({ tools: [] }), () => executor.inbox.list(), () => executor.uploads.create(new Blob(['bytes']), 'test.txt'), () => executor.reportProgress({ run_public_id: 'id', task_key: 'key', claim_token: 'claim', text_tail: 'working' }));
const inbox = executor.inboxTask('id', 'id');
add(() => inbox.realtime("claim"), () => inbox.offerRealtime("claim", { connection_id: "connection", sdp: "offer" }), () => inbox.claim(), () => inbox.claimStatus('claim'), () => inbox.attachment('id', 'claim'), () => inbox.attachmentBytes('id', 'claim'), () => inbox.extend({ claim_token: 'claim', timeout_ms: 1000 }), () => inbox.commit({ claim_token: 'claim', content: 'done' }), () => inbox.operations('claim'), () => inbox.submit({ claim_token: 'claim', operation: { key: 'op', request: { type: 'tool' } } }), () => inbox.observe({ claim_token: 'claim', after: 0 }));
add(() => new Sessions({ baseURL: config.baseURL, fetch: fetcher }).create({ email: 'test@example.com', password: 'test' }), () => platform.session.fetch(), () => platform.session.revoke(), () => platform.profile.fetch(), () => platform.persona.read(), () => platform.persona.write({ content: 'Persona' }), () => platform.persona.delete(), () => platform.costUnit.fetch(), () => platform.costUnit.configure('credits'), () => platform.retention.fetch(), () => platform.retention.update(null), () => platform.models.list(), () => platform.modelProviders.list());
const provider = platform.modelProviders.provider('id');
add(() => provider.fetch(), () => provider.setDefinition({ ...expected, definition: {} }), () => provider.resetDefinition(expected), () => provider.setModelDefinition({ ...expected, model: 'model', definition: {} }), () => provider.removeModelDefinition({ ...expected, model: 'model' }), () => provider.resetModelDefinition({ ...expected, model: 'model' }), () => provider.discoverModels(expected), () => provider.setEnabled({ ...expected, enabled: true }), () => provider.setModelVisibility({ ...expected, model: 'model', visible: true }), () => provider.setModelAvailability({ ...expected, model: 'model', available: true }), () => provider.testModel({ ...expected, model: 'model' }), () => provider.installApiKey('key'), () => provider.removeApiKey(), () => provider.authorization.fetch(), () => provider.authorization.start(), () => provider.authorization.clear(), () => provider.authorization.session('id'));
add(() => platform.agents.list(), () => platform.agents.create('Agent'));
const agent = platform.agents.agent('id'), runner = agent.privateRunners.runner('id');
add(() => platform.runners.list(), () => platform.runners.fetch('id'), () => agent.configuration());
add(() => agent.fetch(), () => agent.revokeConnection(), () => agent.remove(), () => agent.restore(), () => agent.privateRunners.list(), () => agent.privateRunners.create('Runner'), () => runner.fetch());
for (const keys of [agent.apiKeys, agent.executorApiKeys, runner.apiKeys]) add(() => keys.list(), () => keys.create({ name: 'key' }), () => keys.revoke('id'));
const mcp = platform.mcpConnections;
add(() => mcp.list(), () => mcp.fetch('id'), () => mcp.create({ name: 'Tools', endpoint_url: 'https://tools.example/mcp', auth_type: 'none' }), () => mcp.update('id', { ...version, name: 'New' }), () => mcp.refreshCatalog('id', version), () => mcp.startAuthorization('id', version), () => mcp.rotateCredential('id', { ...version, bearer_token: 'key' }), () => mcp.clearCredential('id', version));
const budgets = platform.budgets('id');
for (const readable of [client.profile.budgets, platform.profile.budgets, budgets, agent.budgets]) {
  add(() => readable.list(), () => readable.fetch('id'), () => readable.entries('id'));
}
add(() => agent.budgets.open({ amount: '1', starts_at: '2026-10-15T00:00:00Z' }, mutation), () => agent.budgets.adjust('id', { kind: 'credit', amount: '0.1' }, mutation), () => agent.budgets.revoke('id', {}, mutation), () => platform.modelUsage.analysis());
add(() => budgets.open({ amount: '1', starts_at: '2026-10-15T00:00:00Z' }, mutation), () => budgets.adjust('id', { kind: 'credit', amount: '0.1' }, mutation), () => budgets.revoke('id', {}, mutation), () => platform.modelUsage.report({ from: '2026-10-14', to: '2026-10-15' }));
const deployment = platform.deployment, upgrade = deployment.operation('id');
add(() => deployment.fetch(), () => deployment.checkRelease(), () => deployment.upgrade({ candidate: { release: 'fixture', images: [] } }, mutation), () => upgrade.fetch(), () => upgrade.log(), async () => { for await (const _event of upgrade.stream()) { /* Bounded window. */ } });

test('every supported operation is issued by an actual public SDK method', async () => {
  const observed = new Set<string>();
  for (const call of calls) {
    const before = requests.length;
    try { const result = await call(); if (result && typeof result === 'object' && 'body' in result && result.body instanceof ReadableStream) await result.body.cancel(); } catch { /* This test observes serialization; contract tests validate successful fixtures. */ }
    expect(requests.length).toBe(before + 1);
    const request = requests[before]!;
    observed.add(request.method + ' ' + request.path);
    if (request.path !== '/api/v1/session' || request.method !== 'POST') expect(request.headers.get('authorization')).toBe('Bearer test-only');
  }
  const expected = inventory.operations.filter(operation => operation.sdk_supported).map(operation => operation.method + ' ' + operation.path.replace(/\{([^}]+)\}/g, (_, name: string) => name === 'index' ? '0' : name === 'field' ? 'steers' : 'id'));
  expect([...observed].sort()).toEqual([...new Set(expected)].sort());
  expect(observed.size).toBe(274);
  expect(inventory.operations.filter(operation => !operation.sdk_supported).map(operation => operation.id)).toEqual(['POST /api/v1/admin/users/{user_public_id}/removal']);
});
