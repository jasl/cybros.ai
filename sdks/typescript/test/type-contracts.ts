import { Client, ExecutorClient, PlatformClient, Steps } from '../src/index.js';
import type { CreateInput, InlineBlock, OperationRequest, ToolAlias, VariantRead } from '../src/index.js';
export function compileContracts(client: Client, executor: ExecutorClient, platform: PlatformClient) {
  const chat = client.workspace('workspace').conversation('conversation');
  void client.schedules.list({ workspace_public_id: 'workspace', status: 'paused' });
  const variantRead: Promise<VariantRead> = chat.turns.variant('turn', 'variant');
  void variantRead;
  void client.work.analysis({ workspace_public_id: 'workspace', group_by: 'status', rank_by: 'cost_amount' });
  void platform.modelUsage.analysis({ status: 'abandoned', limit: 5 });
  void platform.agents.agent('agent').budgets.open({ amount: '0.000000000000000001', starts_at: '2026-10-15T00:00:00Z' }, { idempotencyKey: 'allowance' });
  // @ts-expect-error Analysis windows are exact and have no time bucket unit.
  void client.work.analysis({ unit: 'day' });
  // @ts-expect-error Administrator analysis cannot select a consumer identity.
  void platform.modelUsage.analysis({ agent_public_id: 'agent' });
  // @ts-expect-error Human profile budgets expose reads only.
  void client.profile.budgets.open({ amount: '1', starts_at: '2026-10-15T00:00:00Z' }, { idempotencyKey: 'budget' });
  // @ts-expect-error Human platform profile budgets expose reads only.
  void platform.profile.budgets.adjust('budget', { kind: 'credit', amount: '1' }, { idempotencyKey: 'budget' });
  // @ts-expect-error Precise budget amounts must remain decimal strings.
  void platform.agents.agent('agent').budgets.adjust('budget', { kind: 'credit', amount: 1 }, { idempotencyKey: 'budget' });
  void chat.update({ lock_version: 1, cost_limit: null });
  // @ts-expect-error Cost limits preserve exact decimal strings, never floating-point numbers.
  void chat.update({ lock_version: 1, cost_limit: 1.25 });
  void chat.inputs.create({ kind: 'message', role: 'system', text: 'Instruction' }, { idempotencyKey: 'stable' });
  void chat.inputs.create({ kind: 'message', role: 'tool', entries: [{ type: 'text', text: 'Result' }] }, { idempotencyKey: 'stable' });
  // @ts-expect-error The application must choose a stable mutation key.
  void chat.inputs.create({ kind: 'message', text: 'Hello' }, {});
  // @ts-expect-error Immutable Input kind is not an update field.
  void chat.inputs.update('input', { kind: 'direct_reply' });
  // @ts-expect-error Standalone Run Inputs have no direct_reply materialization lane.
  void client.workspace('workspace').run('run').inputs.create({ kind: 'direct_reply', text: 'No' }, { idempotencyKey: 'stable' });
  // @ts-expect-error A standalone Run does not expose Conversation materialization.
  void client.workspace('workspace').run('run').inputs.materialization('input');
  // @ts-expect-error Model selection intent uses source, not mode.
  const wrongIntent: CreateInput = { kind: 'direct_reply', model_selection: { mode: 'auto' } };
  // @ts-expect-error Slot overrides cannot also choose a placement.
  const wrongInline: InlineBlock = { slot: 'system_prompt', position: 'tail', text: 'No' };
  // @ts-expect-error Positioned inline text cannot introduce an assistant message.
  const wrongRole: InlineBlock = { role: 'assistant', text: 'No' };
  // @ts-expect-error MCP steps require a concrete connection.
  Steps.tool({ name: 'remote', route: { kind: 'mcp' } });
  // @ts-expect-error Explicit null is not a default Runner selection.
  Steps.tool({ name: 'read', route: { kind: 'runner', runner_executor_public_id: null } });
  Steps.tool({ name: 'read', route: { kind: 'runner' } });
  Steps.tool({ name: 'search', route: { kind: 'mcp', connection_public_id: 'connection' } });
  const operation: OperationRequest = { kind: 'append_steps', steps: [{ tool: { name: 'read' } }] };
  const alias: ToolAlias = { type: 'function', function: { name: 'ask' }, canonical: 'nexus.human.ask', params: { prompt: { maps_to: 'question' } } };
  // @ts-expect-error Model steps do not accept a task timeout field.
  Steps.model({ prompt: 'Hello', timeout_ms: 1000 });
  // @ts-expect-error Environment is kernel-owned, not a model authoring wire field.
  Steps.model({ prompt: 'Hello', environment: {} });
  // @ts-expect-error Results name task references, not arbitrary JSON.
  Steps.model({ prompt: 'Hello', results: { task: 'r1' } });
  // @ts-expect-error Closed failure vocabulary follows Step WIRE_FIELDS.
  Steps.tool({ name: 'read', on_failure: 'ignore' });
  // @ts-expect-error Closed visibility vocabulary.
  Steps.ask({ prompt: 'Continue?', visibility: 'secret' });
  // @ts-expect-error Fan failure handling is absorb or propagate.
  Steps.model({ prompt: 'Hello', fan_on_failure: 'halt' });
  // @ts-expect-error Parallel loser policy is cancel or run_out.
  Steps.parallel([], { losers: 'keep' });
  // @ts-expect-error Append resolution uses task, not the HTTP route's task_key.
  void client.workspace('workspace').run('run').append({ steps: [], resolve: [{ task_key: 'await' }] }, { idempotencyKey: 'append' });
  // @ts-expect-error Append can settle only completed outcomes.
  void client.workspace('workspace').run('run').append({ steps: [], resolve: [{ task: 'await', outcome: 'failed' }] }, { idempotencyKey: 'append' });
  // @ts-expect-error Input template trials belong only to context estimates.
  void chat.inputs.create({ kind: 'direct_reply', template: {} }, { idempotencyKey: 'input' });
  // @ts-expect-error Input entries are opaque objects, never scalar JSON values.
  void chat.inputs.create({ kind: 'message', entries: [1] }, { idempotencyKey: 'input' });
  // @ts-expect-error A standalone Run admits no model or assembly edit.
  void client.workspace('workspace').run('run').inputs.update('input', { model: { model: 'provider/model' } });
  // @ts-expect-error Context estimates do not accept raw context_mode.
  void chat.estimateInput({ context_mode: 'raw' });
  // @ts-expect-error Schedules do not accept per-input inline assembly.
  void chat.schedules.create({ prompt: 'Hello', rule: { kind: 'once', run_at: '2026-10-15T12:00:00Z' }, inline: null }, { idempotencyKey: 'schedule' });
  // @ts-expect-error Schedule origin is immutable after creation.
  void chat.schedules.update('schedule', { expected_lock_version: 1, source_run_public_id: 'run' });
  // @ts-expect-error Cross-workspace lists expose working conversations only.
  void client.conversations.list({ side: true });
  // @ts-expect-error Workspace lists have a separate archive collection.
  void client.workspace('workspace').conversations.list({ archived: true });
  // @ts-expect-error Every process frame proves the claim that originated it.
  void executor.reportProgress({ conversation_public_id: 'conversation', process_id: 'process', lines: [] });
  // @ts-expect-error A process frame addresses exactly one host.
  void executor.reportProgress({ conversation_public_id: 'conversation', run_public_id: 'run', process_id: 'process', source: { run_public_id: 'source', task_key: 'task', claim_token: 'claim' } });
  // @ts-expect-error Every served tool declares its complete effect profile.
  void executor.announce({ services: { runner: { tools: [{ name: 'read' }] } } });
  return { wrongIntent, wrongInline, wrongRole, operation, alias };
}
