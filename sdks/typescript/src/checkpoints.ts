import { APIError, CancelledError, TimeoutError, TransportError } from './errors.js';
import { shape } from './decode.js';
import { nonempty, object } from './json.js';
import type { JsonValue } from './json.js';
import type { MutationOptions } from './http.js';
import type { Checkpoint, RunnerEffect, RunnerEffects, TaskDetail } from './models.js';
import type { ApprovalRule } from './requests.js';
import type { Runs, ToolResultWaitOptions } from './resources/runs.js';
export interface CheckpointRestoreOptions extends MutationOptions, ToolResultWaitOptions {
  approvalRules?: ApprovalRule[];
  restoreGuard?: (runnerPublicId: string, checkpoint: Checkpoint) => string | null | Promise<string | null>;
}
export interface RunnerRestoration {
  runner_executor_public_id: string; status: 'restored' | 'failed' | 'unavailable';
  checkpoint?: string; undo?: string; reason?: string; skipped?: JsonValue; outside?: string[]; ignored?: string[];
}
export interface CheckpointRestoration { status: 'untouched' | 'kept' | 'restored' | 'partial' | 'failed' | 'unavailable'; runners: RunnerRestoration[]; reason?: string; }
/** Restores each retained checkpoint on its original Runner; each result remains independent. */
export async function restoreCheckpoints(runs: Runs, effects: RunnerEffects, options: CheckpointRestoreOptions): Promise<CheckpointRestoration> {
  nonempty(options.idempotencyKey, 'idempotencyKey');
  if (effects.status === 'untouched') return { status: 'untouched', runners: [] };
  const outcomes: RunnerRestoration[] = [];
  for (const effect of effects.runners) {
    try { outcomes.push({ runner_executor_public_id: effect.runner_executor_public_id, ...await restoreOne(runs, effect, options) }); }
    catch (error) {
      if (error instanceof CancelledError || error instanceof TimeoutError) throw error;
      if (!(error instanceof APIError) && !(error instanceof TransportError)) throw error;
      outcomes.push({ runner_executor_public_id: effect.runner_executor_public_id, status: error instanceof APIError ? 'failed' : 'unavailable', reason: error instanceof APIError ? error.code ?? 'request_failed' : 'transport_error' });
    }
  }
  const statuses = outcomes.map(value => value.status);
  const status = statuses.length === 0 ? 'unavailable' : statuses.every(value => value === 'restored') && effects.status !== 'unavailable' ? 'restored' : statuses.includes('restored') ? 'partial' : statuses.includes('failed') ? 'failed' : 'unavailable';
  return { status, runners: outcomes, ...(effects.reason === null ? {} : { reason: effects.reason }) };
}
async function restoreOne(runs: Runs, effect: RunnerEffect, options: CheckpointRestoreOptions): Promise<Omit<RunnerRestoration, 'runner_executor_public_id'>> {
  let checkpoint = effect.checkpoint;
  if (!checkpoint?.hash && checkpoint?.skipped == null) {
    const detail = await call(runs, effect, 'checkpoints', { run_public_id: effect.run_public_id }, options);
    if (completed(detail) && detail.structured_content !== null && typeof detail.structured_content === 'object' && !Array.isArray(detail.structured_content)) {
      const records = detail.structured_content.records;
      if (Array.isArray(records)) {
        const record = records.find(item => item !== null && typeof item === 'object' && !Array.isArray(item) && item.present === true && typeof item.hash === 'string');
        if (record) checkpoint = shape('Checkpoint', record);
      }
    }
  }
  if (!checkpoint?.hash) return { status: 'unavailable', reason: 'no_checkpoint', ...(checkpoint?.skipped == null ? {} : { skipped: checkpoint.skipped }) };
  const refusal = await options.restoreGuard?.(effect.runner_executor_public_id, checkpoint);
  if (refusal) return { status: 'failed', reason: refusal };
  const detail = await call(runs, effect, 'checkpoint_restore', { checkpoint: checkpoint.hash, ...(checkpoint.store === null ? {} : { store: checkpoint.store }) }, options);
  const rawUndo = detail.metadata?.checkpoint;
  const undo = rawUndo == null ? null : shape('Checkpoint', rawUndo).hash;
  if (completed(detail)) return { status: 'restored', checkpoint: checkpoint.hash, ...(undo ? { undo } : {}), ...(checkpoint.outside.length ? { outside: checkpoint.outside } : {}), ...(checkpoint.ignored.length ? { ignored: checkpoint.ignored } : {}) };
  const reason = detail.task.status === 'completed' ? /^[a-z_]+/.exec(detail.output ?? '')?.[0] : detail.task.error?.key;
  return { status: 'failed', ...(typeof reason === 'string' ? { reason } : {}), ...(undo ? { undo } : {}) };
}
async function call(runs: Runs, effect: RunnerEffect, tool: string, input: import('./json.js').JsonObject, options: CheckpointRestoreOptions) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify([options.idempotencyKey, effect.runner_executor_public_id, effect.run_public_id, tool]))));
  const idempotencyKey = Array.from(digest, byte => byte.toString(16).padStart(2, '0')).join('');
  const run = await runs.startToolCall({ runner_executor_public_id: effect.runner_executor_public_id, tool, input, ...(options.approvalRules === undefined ? {} : { approval_rules: options.approvalRules }) }, { ...options, idempotencyKey });
  return run.waitForToolResult(options);
}
function completed(detail: TaskDetail) { return detail.task.status === 'completed' && detail.task.result?.is_error !== true; }
