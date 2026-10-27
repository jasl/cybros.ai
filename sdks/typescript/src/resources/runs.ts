import { Resource } from './base.js';
import { Inputs } from './inputs.js';
import { delay, DurableFeed } from '../feeds.js';
import { shape } from '../decode.js';
import { Conflict, TimeoutError } from '../errors.js';
import { nonempty, object, segment } from '../json.js';
import { Steps } from '../steps.js';
import type { MutationOptions, RequestOptions } from '../http.js';
import type { AppendTasks, CreateRun, EventOptions, ModelSelection, ResolveTask, RunList, ToolCall } from '../requests.js';
import type { FeedOptions } from '../feeds.js';
export class Runs extends Resource {
  list(query: RunList = {}, options: RequestOptions = {}) { return this.paged('Run', 'runs', { ...options, query }); }
  fetch(id: string, options: RequestOptions = {}) { return this.one('Run', `/${segment(id)}`, 'run', options); }
  async create(input: CreateRun, options: MutationOptions) {
    nonempty(options?.idempotencyKey ?? '', 'idempotencyKey');
    const response = await this.transport.call(this.path, { ...options, method: 'POST', body: { run: input }, success: [200, 201] });
    return { run: shape('Run', response.data, 'run'), receipt: shape('AppendedTasks', response.data, 'receipt'), status: response.status, replayed: response.replayed || object(response.data).replayed === true, requestId: response.requestId };
  }
  async startToolCall(input: ToolCall, options: MutationOptions) {
    const { run } = await this.create({ steps: [Steps.tool({ name: input.tool, key: 'call_tool', input: input.input ?? {}, ...(input.timeout_ms === undefined ? {} : { timeout_ms: input.timeout_ms }), route: { kind: 'runner', runner_executor_public_id: input.runner_executor_public_id } })], approval_mode: 'bypass', prompt_mechanism: 'raw', default_runner_executor_public_id: input.runner_executor_public_id, ...(input.approval_rules === undefined ? {} : { approval_rules: input.approval_rules }) }, options);
    const scope = new RunScope(this.transport, `${this.path}/${segment(run.public_id)}`);
    try { await scope.start(options); } catch (error) { if (!(error instanceof Conflict) || error.code !== 'not_startable') throw error; }
    return scope;
  }
}
export interface ToolResultWaitOptions extends RequestOptions { pollMs?: number; patienceMs?: number; }
export class RunScope extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('Run', '', 'run', options); }
  /** Local observation only: expiry or cancellation never stops this Run. */
  async waitForToolResult(options: ToolResultWaitOptions = {}) {
    const pollMs = options.pollMs ?? 500;
    if (!Number.isFinite(pollMs) || pollMs <= 0 || options.patienceMs !== undefined && (!Number.isFinite(options.patienceMs) || options.patienceMs <= 0)) throw new TypeError('Wait intervals must be finite and positive');
    const deadline = options.patienceMs === undefined ? null : performance.now() + options.patienceMs;
    while (true) {
      const remaining = deadline === null ? null : deadline - performance.now();
      if (remaining !== null && remaining <= 0) throw new TimeoutError('Tool result observation deadline exceeded');
      const detail = await this.task('call_tool').fetch({ ...options, ...(remaining === null ? {} : { timeoutMs: Math.min(options.timeoutMs ?? 30_000, remaining) }) });
      if (['completed', 'failed', 'timed_out', 'uncertain', 'canceled', 'skipped'].includes(detail.task.status)) return detail;
      await delay(deadline === null ? pollMs : Math.min(pollMs, Math.max(0, deadline - performance.now())), options.signal);
    }
  }
  task(key: string) { return new TaskScope(this.transport, `${this.path}/tasks/${segment(key)}`); }
  setDefaultRunner(executor_public_id: string | null, options: RequestOptions = {}) { return this.one('Run', '/default_runner', 'run', { ...options, method: 'PUT', body: { default_runner: { executor_public_id } } }); }
  async append(input: AppendTasks, options: MutationOptions) {
    nonempty(options?.idempotencyKey ?? '', 'idempotencyKey');
    const response = await this.transport.call(this.path + '/tasks', { ...options, method: 'POST', body: input, success: [200, 201] });
    return { receipt: shape('AppendedTasks', response.data, 'receipt'), status: response.status, replayed: response.replayed, requestId: response.requestId };
  }
  events(query: EventOptions = {}, options: RequestOptions = {}) { return this.one('EventPage', '/events', undefined, { ...options, query }); }
  transcript(query: { before?: string; limit?: number; prefix?: string } = {}, options: RequestOptions = {}) { return this.one('RunTranscript', '/transcript', undefined, { ...options, query }); }
  graph(options: RequestOptions = {}) { return this.one('RunGraph', '/graph', undefined, options); }
  phases(options: RequestOptions = {}) { return this.one('RunPhases', '/phases', undefined, options); }
  get inputs() { return new Inputs(this.transport, this.path + '/inputs'); }
  start(options: RequestOptions = {}) { return this.one('Run', '/start', 'run', { ...options, method: 'POST' }); }
  pause(force = false, options: RequestOptions = {}) { return this.one('Run', '/pause', 'run', { ...options, method: 'POST', body: { force } }); }
  resume(options: RequestOptions = {}) { return this.one('Run', '/resume', 'run', { ...options, method: 'POST' }); }
  stop(force = true, options: RequestOptions = {}) { return this.one('Run', '/stop', 'run', { ...options, method: 'POST', body: { force } }); }
  delete(options: RequestOptions = {}) { return this.empty('', { ...options, method: 'DELETE', success: [204] }); }
  feed(options: FeedOptions = {}) { return new DurableFeed({ ...options, replay: (after, request) => this.events(after === undefined ? {} : { after }, request) }); }
  async decisions(options: RequestOptions = {}) {
    const run = await this.fetch(options);
    const rows = run.tasks.filter(task => task.status === 'awaiting_input' || task.status === 'needs_approval');
    return Promise.all(rows.map(async task => ({ kind: task.status === 'awaiting_input' ? 'ask' as const : 'approval' as const, detail: await this.task(task.key).fetch(options), task: this.task(task.key) })));
  }
}
export class TaskScope extends Resource {
  realtime(options: RequestOptions = {}) { return this.one('TaskRealtime', '/realtime', 'realtime', options); }
  answerRealtime(input: { connection_id: string; sdp: string }, options: RequestOptions = {}) { return this.one('TaskRealtime', '/realtime', 'realtime', { ...options, method: 'PUT', body: input }); }
  fetch(options: RequestOptions = {}) { return this.one('TaskDetail', '', 'task', options); }
  resolve(input: ResolveTask, options: RequestOptions = {}) { return this.one('Task', '/resolution', 'task', { ...options, method: 'POST', body: input }); }
  retry(model?: ModelSelection, options: RequestOptions = {}) { return this.one('Task', '/retry', 'task', { ...options, method: 'POST', ...(model === undefined ? {} : { body: { model } }) }); }
  abandon(options: RequestOptions = {}) { return this.command('abandon', options); }
  cancel(options: RequestOptions = {}) { return this.command('cancel', options); }
  approve(options: RequestOptions = {}) { return this.command('approve', options); }
  deny(reason?: string, options: RequestOptions = {}) { return this.one('Task', '/deny', 'task', { ...options, method: 'POST', body: { reason } }); }
  compact(options: RequestOptions = {}) { return this.one('CompactedRound', '/compact', undefined, { ...options, method: 'POST', success: [202] }); }
  request(options: RequestOptions = {}) { return this.one('SealedRequest', '/request', 'request', options); }
  private command(verb: string, options: RequestOptions) { return this.one('Task', `/${verb}`, 'task', { ...options, method: 'POST' }); }
}
