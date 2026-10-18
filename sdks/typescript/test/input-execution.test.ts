import { expect, test } from 'vitest';
import { readFileSync } from 'node:fs';
import { InputExecution, InputMaterialization } from '../src/index.js';
import type { Event, EventPage, ExecutionReaders, JsonObject, Run, Variant } from '../src/index.js';
import { shape } from '../src/decode.js';
const fixture = (family: string, key: string) => JSON.parse(readFileSync(new URL(`../../../contracts/nexus/v1/${family}.json`, import.meta.url), 'utf8'))[key] as unknown;
const original = { turn_public_id: 'turn', variant_public_id: 'original', run_public_id: 'run-original' };
const variant = (fields: Partial<Variant>): Variant => ({ ...shape('VariantDeck', fixture('conversations', 'valid_variants_fixture')).items[0]!, ...fields });
const run = (fields: Partial<Run> = {}): Run => ({ ...shape('Run', fixture('runs', 'valid_request_run_fixture'), 'run'), ...fields });
const event = (sequence: number, type: string, payload: JsonObject): Event => ({ public_id: `event-${sequence}`, cursor: `cursor-${sequence}`, sequence, type, payload, resource_type: 'conversation', resource_public_id: 'conversation', occurred_at: '2026-10-15T00:00:00Z' });
function readers(input: { variants?: Variant[]; events?: Event[]; run?: Run }): ExecutionReaders {
  return { materialization: async () => ({ ...original, input_public_id: 'input' }), variants: async () => ({ items: input.variants ?? [], turn_public_id: 'turn', turn_inherited: false }), run: async () => input.run ?? run(), events: async after => { const sequence = after ? Number(after.split('-')[1]) : 0; return { items: (input.events ?? []).filter(item => item.sequence > sequence), next_after: null, watermark: input.events?.at(-1)?.sequence ?? 0 } as EventPage; } };
}
test('one Input keeps its original correlation and follows only automatic fallback descendants', async () => {
  const execution = new InputExecution(readers({ variants: [variant({ public_id: 'original', source: 'run', status: 'failed', active: false, run_public_id: 'run-original' }), variant({ public_id: 'fallback', origin_variant_public_id: 'original', source: 'fallback', status: 'completed', active: false, run_public_id: 'run-fallback', content: 'Recovered answer' }), variant({ public_id: 'manual', origin_variant_public_id: 'fallback', source: 'regeneration', status: 'completed', active: true, run_public_id: 'run-manual', content: 'Another answer' })] }), 'input');
  const snapshot = await execution.recover(); expect(execution.result).toEqual(expect.objectContaining(original));
  expect(snapshot?.execution.variant_public_id).toBe('fallback'); expect(snapshot?.content).toBe('Recovered answer'); expect(snapshot?.terminal).toBe(true);
});
test('retained lifecycle recovers a Run-only observation and newer status clears old failure details', async () => {
  const events = [event(1, 'turn_status', { ...original, status: 'failed', variant_status: 'failed', failure_reason: 'old', failure_reason_key: 'old' }), event(2, 'turn_status', { ...original, status: 'completed' })];
  const execution = new InputExecution(readers({ events }), { ...original, variant_public_id: null });
  const snapshot = await execution.recover(); expect(snapshot?.execution.variant_public_id).toBe('original'); expect(snapshot?.status).toBe('completed'); expect(snapshot?.failure_reason).toBeNull(); expect(snapshot?.failure_reason_key).toBeNull();
});
test('current Variant state wins over retained failure notes; failed fallback is not terminal while Run is active', async () => {
  const events = [event(1, 'turn_status', { ...original, status: 'failed', failure_reason: 'old' })];
  const completed = new InputExecution(readers({ events, variants: [variant({ public_id: 'original', status: 'completed', run_public_id: 'run-original' })] }), original);
  expect((await completed.recover())?.failure_reason).toBeNull();
  const pending = new InputExecution(readers({ events, variants: [variant({ public_id: 'original', status: 'failed', run_public_id: 'run-original' })], run: run({ status: 'running' }) }), original);
  expect((await pending.recover())?.terminal).toBe(false);
});
test('failure key and attention come from the selected execution, with decisions read explicitly', async () => {
  let decisionReads = 0; const source = readers({ variants: [variant({ public_id: 'original', status: 'failed', run_public_id: 'run-original' })], run: run({ status: 'needs_attention', failure_reason: 'needs repair', turn: { status: 'failed', failure_reason_key: 'tool_failed', public_id: 'turn', conversation_public_id: 'conversation', answering_user_public_id: null, model: null } }) });
  source.decisions = async id => { expect(id).toBe('run-original'); decisionReads++; return []; };
  const execution = new InputExecution(source, original), snapshot = await execution.recover();
  expect(snapshot?.failure_reason_key).toBe('tool_failed'); expect(snapshot?.needs_attention).toBe(true); expect(decisionReads).toBe(0);
  await execution.decisions(); expect(decisionReads).toBe(1);
});
test('blocked and compaction hints retain their owners; direct recovery does not invent a feed cursor', async () => {
  const source = readers({ events: [event(4, 'input_materialized', { ...original, input_public_id: 'input' })] });
  const materialization = new InputMaterialization('input', source);
  await materialization.refresh(); expect(materialization.result).toEqual(expect.objectContaining(original)); expect(materialization.position).toEqual({ cursor: null, sequence: 0 });
  const hintSource = readers({ events: [event(1, 'input_blocked', { input_public_id: 'input', blocked_reason: 'context_full' }), event(2, 'turn_status', { turn_kind: 'compaction_summary', turn_public_id: 'compact', variant_public_id: 'compact-variant' })] });
  hintSource.materialization = async () => null;
  const hints = new InputExecution(hintSource, 'input'); await hints.refresh();
  expect(hints.blocked_reason).toBe('context_full'); expect(hints.compaction?.turn_public_id).toBe('compact');
});
test('refresh and recovery share one incremental replay position instead of rereading the initial window', async () => {
  const events = [event(1, 'input_materialized', { ...original, input_public_id: 'input' }), event(2, 'turn_status', { ...original, status: 'failed', failure_reason: 'retained failure' })];
  const source = readers({ events }); const base = source.events, afters: (string | undefined)[] = [];
  source.events = async (after, options) => { afters.push(after); return base(after, options); };
  const execution = new InputExecution(source, 'input'); await execution.refresh();
  expect((await execution.recover())?.failure_reason).toBe('retained failure'); await execution.recover();
  expect(afters).toEqual([undefined, 'cursor-2', 'cursor-2']); expect(execution.position.sequence).toBe(2);
});
