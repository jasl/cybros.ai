import { object } from './json.js';
import type { JsonObject } from './json.js';
import type { ProgressFrame, RunTranscript, TranscriptItem } from './models.js';
const encoder = new TextEncoder(), decoder = new TextDecoder();
/** A bounded UTF-8 tail with the total byte count needed to detect replacement. */
export class TranscriptAccumulator {
  #buffer = new Uint8Array(0);
  length = 0;
  key: string | null = null;
  replaced = false;
  constructor(readonly bound = 64 * 1024) { if (!Number.isSafeInteger(bound) || bound < 0) throw new TypeError('bound must be a nonnegative integer'); }
  get text() { return decoder.decode(this.#buffer); }
  get empty() { return this.#buffer.length === 0; }
  accumulate(text: string, key: string | null = null): string | null {
    if (key !== null && key !== this.key) this.reset(key);
    const bytes = encoder.encode(text); if (!bytes.length) return null;
    const joined = new Uint8Array(this.#buffer.length + bytes.length); joined.set(this.#buffer); joined.set(bytes, this.#buffer.length);
    this.#buffer = joined; this.length += bytes.length; this.trim(); return text;
  }
  reset(key: string | null = null): void { this.#buffer = new Uint8Array(0); this.length = 0; this.key = key; this.replaced = false; }
  replaceOnSettle(text: string): string { return this.replaceSnapshot(text); }
  replaceSnapshot(text: string, length = 0): string {
    if (!Number.isSafeInteger(length) || length < 0) throw new TypeError('length must be a nonnegative integer');
    const bytes = encoder.encode(text), total = Math.max(length, bytes.length), growth = total - this.length;
    const overlap = bytes.subarray(0, Math.max(0, bytes.length - growth));
    const continuation = growth >= 0 && growth <= bytes.length && (overlap.length === 0 || endsWith(this.#buffer, overlap) || endsWith(overlap, this.#buffer));
    this.replaced = this.length > 0 && !continuation;
    const count = this.replaced ? bytes.length : Math.min(Math.max(0, growth), bytes.length);
    const remainder = decoder.decode(bytes.subarray(bytes.length - count));
    this.#buffer = bytes; this.length = total; this.trim(); return remainder;
  }
  private trim() { let start = Math.max(0, this.#buffer.length - this.bound); while (start < this.#buffer.length && (this.#buffer[start]! & 0xc0) === 0x80) start++; this.#buffer = this.#buffer.slice(start); }
}
function endsWith(source: Uint8Array, tail: Uint8Array) { if (tail.length > source.length) return false; return tail.every((value, index) => source[source.length - tail.length + index] === value); }
export type ThreadSnapshotRow = JsonObject & { task_key: string; mainline: boolean; status: string };
/** Ephemeral mainline projection: settled snapshots replace live marks; branch rows retract. */
export class ThreadAccumulator {
  #rows = new Map<string, ThreadSnapshotRow>();
  #live = new Set<string>();
  #branches = new Set<string>();
  seed(page: RunTranscript): ThreadSnapshotRow[] {
    this.#rows = new Map(page.rounds.map(row => [row.task_key, structuredClone(row) as unknown as ThreadSnapshotRow]));
    this.#live.clear(); this.#branches.clear(); return this.rows;
  }
  get rows(): ThreadSnapshotRow[] { return structuredClone([...this.#rows.values()]); }
  get live(): string[] { return [...this.#live]; }
  get snapshot() { return { rows: this.rows, live: this.live }; }
  settleRound(item: TranscriptItem): ThreadSnapshotRow | null {
    if (item.payload.round == null) return null;
    const row = object(item.payload.round) as ThreadSnapshotRow, key = requiredKey(row.task_key);
    if (row.mainline !== true) return this.retract(key);
    this.#rows.set(key, structuredClone(row));
    for (const live of this.#live) if (live === key || roundOf(live) === key) this.#live.delete(live);
    return structuredClone(row);
  }
  settleCall(item: TranscriptItem): ThreadSnapshotRow | null {
    if (item.payload.call == null) return null;
    const call = object(item.payload.call) as JsonObject, key = requiredKey(call.task_key), round = roundOf(key);
    if (!round || this.#branches.has(round)) return null;
    const row = this.upsertCall(round, call, true); this.#live.delete(key); return row;
  }
  roundStarted(frame: ProgressFrame): ThreadSnapshotRow | null {
    const key = requiredKey(frame.task_key), payload = object(frame.payload);
    if (payload.mainline !== true) return this.retract(key);
    const row = { ...(this.#rows.get(key) ?? newRow(key)), status: 'running', ...present(payload, ['attempt', 'model', 'request_bytes']) };
    this.#rows.set(key, row); this.#live.add(key); return structuredClone(row);
  }
  stepStarted(frame: ProgressFrame): ThreadSnapshotRow | null { return this.markCall(frame, { ...present(object(frame.payload), ['status']) }); }
  stepClaimed(frame: ProgressFrame): ThreadSnapshotRow | null { return this.markCall(frame, frame.executor_public_id === null ? {} : { executor_public_id: frame.executor_public_id }); }
  private markCall(frame: ProgressFrame, values: JsonObject) {
    const key = requiredKey(frame.task_key), round = roundOf(key); if (!round || this.#branches.has(round)) return null;
    const row = this.upsertCall(round, { task_key: key, ...(frame.tool_name === null ? {} : { name: frame.tool_name }), ...values }, false); this.#live.add(key); return row;
  }
  private upsertCall(key: string, call: JsonObject, replace: boolean): ThreadSnapshotRow {
    const row = this.#rows.get(key) ?? newRow(key), calls = object(row.calls ?? { count: 0, items: [] });
    const items = [...(calls.items as JsonObject[])], index = items.findIndex(item => item.task_key === call.task_key);
    if (index < 0) items.push(call); else items[index] = replace ? call : { ...items[index], ...call };
    const next = { ...row, calls: { ...calls, count: Math.max(typeof calls.count === 'number' ? calls.count : 0, items.length), items } } as ThreadSnapshotRow;
    this.#rows.set(key, structuredClone(next)); return structuredClone(next);
  }
  private retract(key: string): null { this.#rows.delete(key); for (const live of this.#live) if (live === key || roundOf(live) === key) this.#live.delete(live); this.#branches.add(key); return null; }
}
function roundOf(key: string): string | null { const match = /^r(\d+)t\d+$/.exec(key); return match ? `r${match[1]}` : null; }
function requiredKey(value: unknown): string { if (typeof value !== 'string' || !value) throw new TypeError('A transcript task_key is required'); return value; }
function newRow(key: string): ThreadSnapshotRow { return { task_key: key, mainline: true, status: 'waiting', calls: { count: 0, items: [] }, branches: [] }; }
function present(input: Record<string, unknown>, keys: string[]): JsonObject { return Object.fromEntries(keys.filter(key => input[key] !== null && input[key] !== undefined).map(key => [key, input[key]])) as JsonObject; }
