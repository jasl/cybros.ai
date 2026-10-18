import { DurableFeed } from './feeds.js';
import { RetentionGap } from './errors.js';
import { object } from './json.js';
import type { RequestOptions } from './http.js';
import type { EventPosition } from './feeds.js';
import type { Event, EventPage, InputMaterialization as Materialization, Run, Variant, VariantDeck } from './models.js';
export interface ExecutionIdentity { turn_public_id: string; variant_public_id: string | null; run_public_id: string | null; }
export interface ExecutionReaders {
  materialization(id: string, options: RequestOptions): Promise<Materialization | null>;
  events(after: string | undefined, options: RequestOptions): Promise<EventPage>;
  variants(turnId: string, options: RequestOptions): Promise<VariantDeck>;
  run(runId: string, options: RequestOptions): Promise<Run>;
  decisions?(runId: string, options: RequestOptions): Promise<ExecutionDecision[]>;
}
export interface ExecutionDecision { kind: 'ask' | 'approval'; detail: import('./models.js').TaskDetail; task: import('./resources/runs.js').TaskScope; }
export interface ExecutionSnapshot {
  execution: ExecutionIdentity; variant: Variant | null; status: string | null; run_status: string | null;
  attention: Run['attention']; failure_reason: string | null; failure_reason_key: string | null;
  needs_attention: boolean; content: string | null; terminal: boolean;
}
class ExecutionReplay {
  #position: EventPosition;
  constructor(private readonly events: ExecutionReaders['events'], position: EventPosition, private readonly apply: (event: Event) => void) { this.#position = { ...position }; }
  get position() { return { ...this.#position }; }
  async refresh(options: RequestOptions) {
    const feed = new DurableFeed({ position: this.#position, ...(options.signal ? { signal: options.signal } : {}), replay: (after, request) => this.events(after, { ...options, ...request }) });
    try { await feed.consume(this.apply); }
    catch (error) { if (!(error instanceof RetentionGap)) throw error; }
    finally { this.#position = feed.position; }
  }
}
export class InputMaterialization {
  result: ExecutionIdentity | null = null;
  blocked_reason: string | null = null;
  compaction: ExecutionIdentity | null = null;
  readonly #replay: ExecutionReplay;
  constructor(readonly input_public_id: string, private readonly readers: Pick<ExecutionReaders, 'materialization' | 'events'>, position: EventPosition = { cursor: null, sequence: 0 }, observe?: (event: Event) => void) {
    this.#replay = new ExecutionReplay(readers.events, position, event => { this.apply(event); observe?.(event); });
  }
  get position() { return this.#replay.position; }
  async refresh(options: RequestOptions = {}): Promise<this> {
    await this.#replay.refresh(options);
    if (!this.result) {
      const recovered = await this.readers.materialization(this.input_public_id, options);
      if (recovered) { this.result = recovered; this.blocked_reason = null; }
    }
    return this;
  }
  private apply(event: Event) {
    if (!['input_blocked', 'input_materialized', 'turn_status'].includes(event.type)) return;
    const payload = object(event.payload, 'event payload');
    if (event.type === 'turn_status' && payload.turn_kind === 'compaction_summary' && typeof payload.turn_public_id === 'string') this.compaction = identity(payload);
    if (payload.input_public_id !== this.input_public_id) return;
    if (event.type === 'input_blocked' && typeof payload.blocked_reason === 'string' && payload.blocked_reason !== 'run_held') this.blocked_reason = payload.blocked_reason;
    if (event.type === 'input_materialized' && !this.result && typeof payload.turn_public_id === 'string' && typeof payload.variant_public_id === 'string') { this.result = identity(payload); this.blocked_reason = null; }
  }
}
/** One replay owner observes an accepted Input or explicit execution and its automatic fallbacks. */
export class InputExecution {
  readonly materialization: InputMaterialization | null;
  readonly #original: ExecutionIdentity | null;
  readonly #replay: ExecutionReplay | null;
  readonly #lifecycle = new Map<string, { sequence: number; value: Record<string, unknown> }>();
  snapshot: ExecutionSnapshot | null = null;
  constructor(private readonly readers: ExecutionReaders, input: string | ExecutionIdentity, position: EventPosition = { cursor: null, sequence: 0 }) {
    if (typeof input !== 'string' && (!input.turn_public_id || !input.variant_public_id && !input.run_public_id)) throw new TypeError('execution requires a turn and its variant or run');
    this.#original = typeof input === 'string' ? null : { ...input };
    this.materialization = typeof input === 'string' ? new InputMaterialization(input, readers, position, event => this.apply(event)) : null;
    this.#replay = this.materialization ? null : new ExecutionReplay(readers.events, position, event => this.apply(event));
  }
  get result() { return this.materialization?.result ?? this.#original; }
  get position() { return this.materialization?.position ?? this.#replay!.position; }
  get blocked_reason() { return this.materialization?.blocked_reason ?? null; }
  get compaction() { return this.materialization?.compaction ?? null; }
  async refresh(options: RequestOptions = {}): Promise<this> {
    if (this.materialization) await this.materialization.refresh(options); else await this.#replay!.refresh(options);
    if (this.result) for (const [key, state] of this.#lifecycle) if (state.value.turn_public_id !== this.result.turn_public_id) this.#lifecycle.delete(key);
    return this;
  }
  async recover(options: RequestOptions = {}): Promise<ExecutionSnapshot | null> {
    await this.refresh(options);
    const original = this.result;
    if (!original) return null;
    const deck = await this.readers.variants(original.turn_public_id, options);
    let variant = deck.items.find(item => original.variant_public_id ? item.public_id === original.variant_public_id : item.run_public_id === original.run_public_id) ?? null;
    let candidateId = original.variant_public_id ?? variant?.public_id;
    const seen = new Set<string>(candidateId ? [candidateId] : []);
    while (candidateId) {
      const next = deck.items.find(item => item.source === 'fallback' && item.origin_variant_public_id === candidateId);
      if (!next || seen.has(next.public_id)) break;
      variant = next; candidateId = next.public_id; seen.add(candidateId);
    }
    let execution = variant ? { turn_public_id: original.turn_public_id, variant_public_id: variant.public_id, run_public_id: variant.run_public_id } : original;
    const state = this.recoveryState(execution);
    if (!execution.variant_public_id && typeof state.variant_public_id === 'string') execution = { ...execution, variant_public_id: state.variant_public_id };
    const run = execution.run_public_id ? await this.readers.run(execution.run_public_id, options) : null;
    const status = variant?.status ?? nullableText(state.status);
    const failed = status === 'failed';
    const terminal = status !== null && ['completed', 'failed', 'canceled', 'timed_out'].includes(status) && (!failed || run === null || ['completed', 'canceled'].includes(run.status));
    this.snapshot = { execution, variant, status, run_status: run?.status ?? null, attention: run?.attention ?? null, failure_reason: failed ? run?.failure_reason ?? nullableText(state.failure_reason) : null, failure_reason_key: failed ? (run?.turn?.status === 'failed' ? run.turn.failure_reason_key : null) ?? nullableText(state.failure_reason_key) : null, needs_attention: run?.status === 'needs_attention', content: variant?.content ?? null, terminal };
    return this.snapshot;
  }
  async decisions(options: RequestOptions = {}): Promise<ExecutionDecision[]> {
    if (!this.result) await this.refresh(options);
    const execution = this.snapshot?.execution ?? this.result;
    if (!execution?.run_public_id) return [];
    if (!this.readers.decisions) throw new TypeError('A decisions reader is required');
    return this.readers.decisions(execution.run_public_id, options);
  }
  private apply(event: Event) {
    if (!['turn_status', 'turn_created'].includes(event.type)) return;
    const payload = object(event.payload);
    if (typeof payload.turn_public_id !== 'string' || this.result && payload.turn_public_id !== this.result.turn_public_id) return;
    const key = JSON.stringify([payload.turn_public_id, payload.variant_public_id ?? null, payload.run_public_id ?? null]);
    const state = { ...this.#lifecycle.get(key)?.value, ...payload };
    const status = payload.variant_status ?? payload.status;
    if (typeof status === 'string') { state.status = status; if (status !== 'failed') { delete state.failure_reason; delete state.failure_reason_key; } }
    this.#lifecycle.set(key, { sequence: event.sequence, value: state });
  }
  private recoveryState(execution: ExecutionIdentity): Record<string, unknown> {
    let latest: { sequence: number; value: Record<string, unknown> } | undefined;
    for (const state of this.#lifecycle.values()) {
      const payload = state.value;
      if (payload.turn_public_id !== execution.turn_public_id || execution.run_public_id && payload.run_public_id !== execution.run_public_id || execution.variant_public_id && payload.variant_public_id !== execution.variant_public_id) continue;
      if (!latest || state.sequence > latest.sequence) latest = state;
    }
    return latest?.value ?? {};
  }
}
function nullableText(value: unknown): string | null { return typeof value === 'string' ? value : null; }
function identity(payload: Record<string, unknown>): ExecutionIdentity { return { turn_public_id: payload.turn_public_id as string, variant_public_id: nullableText(payload.variant_public_id), run_public_id: nullableText(payload.run_public_id) }; }
