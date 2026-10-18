import { restoreCheckpoints } from '../checkpoints.js';
import type { CheckpointRestoreOptions } from '../checkpoints.js';
import type { RunnerEffects } from '../models.js';
import { Resource } from './base.js';
import { ConversationInputs } from './inputs.js';
import { Memory, Schedules, StoreEntries } from './data.js';
import { RunScope, Runs } from './runs.js';
import { Turns } from './turns.js';
import { InputExecution } from '../input-execution.js';
import { DurableFeed } from '../feeds.js';
import { shape } from '../decode.js';
import { nonempty, segment } from '../json.js';
import type { JsonObject } from '../json.js';
import type { Download, MutationOptions, RequestOptions } from '../http.js';
import type { AllConversationList, ConversationAccessInput, ConversationChildrenList, ConversationList, WorkspaceConversationList, ConversationSearch, CreateConversation, EstimateInput, EventOptions, ForkConversation, HistoryOptions, ModelSelection, UpdateConversation } from '../requests.js';
import type { FeedOptions } from '../feeds.js';
export class AllConversations extends Resource {
  list(query: AllConversationList = {}, options: RequestOptions = {}) { return this.paged('ConversationSummary', 'conversations', { ...options, query }); }
}
export class Conversations extends Resource {
  list(query: WorkspaceConversationList = {}, options: RequestOptions = {}) { return this.paged('ConversationSummary', 'conversations', { ...options, query: { ...query, ...(query.side === undefined ? {} : { side: query.side ? '1' : '0' }) } }); }
  archived(query: ConversationList = {}, options: RequestOptions = {}) { return this.paged('ConversationSummary', 'conversations', { ...options, query }, '/archived'); }
  async search(query: ConversationSearch, options: RequestOptions = {}) { return shape('ConversationSearchPage', (await this.transport.call(this.path.replace(/\/conversations$/, '/conversation_search'), { ...options, query })).data); }
  create(input: CreateConversation, options: MutationOptions) { return this.receipt('Conversation', 'conversation', { ...options, method: 'POST', body: { conversation: input }, success: [201] }); }
  fetch(id: string, options: RequestOptions = {}) { return this.one('Conversation', `/${segment(id)}`, 'conversation', options); }
}
export class ConversationScope extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('Conversation', '', 'conversation', options); }
  /** Consume or cancel the caller-owned gzip stream; discard partial bytes after failure. */
  export(options: RequestOptions = {}): Promise<Download> { return this.transport.download(this.path + '/export', options); }
  update(input: UpdateConversation, options: RequestOptions = {}) { return this.one('Conversation', '', 'conversation', { ...options, method: 'PATCH', body: { conversation: input } }); }
  archive(options: RequestOptions = {}) { return this.one('Conversation', '/archive', 'conversation', { ...options, method: 'POST' }); }
  unarchive(options: RequestOptions = {}) { return this.one('Conversation', '/unarchive', 'conversation', { ...options, method: 'POST' }); }
  delete(options: RequestOptions = {}) { return this.empty('', { ...options, method: 'DELETE', success: [204] }); }
  cancel(options: RequestOptions = {}) { return this.empty('/cancellation', { ...options, method: 'POST', success: [202] }); }
  children(query: ConversationChildrenList = {}, options: RequestOptions = {}) { return this.paged('ConversationSummary', 'conversations', { ...options, query }, '/children'); }
  get inputs() { return new ConversationInputs(this.transport, this.path + '/inputs'); }
  get schedules() { return new Schedules(this.transport, this.path + '/schedules'); }
  memory(speakerPublicId?: string) { return new Memory(this.transport, this.path + '/memory', speakerPublicId); }
  get storeEntries() { return new StoreEntries(this.transport, this.path + '/store_entries'); }
  get turns() { return new Turns(this.transport, this.path + '/turns'); }
  history(query: HistoryOptions = {}, options: RequestOptions = {}) { return this.one('ConversationHistoryPage', '/history', undefined, { ...options, query }); }
  setMemoryContext(memory_context: JsonObject | null, options: RequestOptions = {}) { return this.one('Conversation', '/memory_context', 'conversation', { ...options, method: 'POST', body: { memory_context } }); }
  setDefaultRunner(executor_public_id: string | null, options: RequestOptions = {}) { return this.one('Conversation', '/default_runner', 'conversation', { ...options, method: 'PUT', body: { default_runner: { executor_public_id } } }); }
  setAccess(access: ConversationAccessInput, options: RequestOptions = {}) { return this.one('Conversation', '/access', 'conversation', { ...options, method: 'PUT', body: { access } }); }
  async fork(input: ForkConversation, options: MutationOptions) {
    nonempty(options?.idempotencyKey ?? '', 'idempotencyKey');
    if (input.turn_public_id === undefined && input.side !== true) throw new TypeError('fork requires turn_public_id or side: true');
    const response = await this.transport.call(this.path + '/forks', { ...options, method: 'POST', body: { fork: input }, success: [201] });
    return { conversation: shape('Conversation', response.data, 'conversation'), runner_effects: shape('RunnerEffects', response.data, 'runner_effects'), status: response.status, replayed: response.replayed, requestId: response.requestId };
  }
  async rewind(input: ForkConversation & { turn_public_id: string }, options: CheckpointRestoreOptions & { restoreCheckpoints?: boolean }) {
    const forked = await this.fork(input, options);
    const restoration = options.restoreCheckpoints === false ? { status: forked.runner_effects.status === 'untouched' ? 'untouched' as const : 'kept' as const, runners: [] } : await this.restoreCheckpoints(forked.runner_effects, options);
    return { ...forked, fork_point: forked.runner_effects, restoration };
  }
  restoreCheckpoints(effects: RunnerEffects, options: CheckpointRestoreOptions) { return restoreCheckpoints(new Runs(this.transport, this.path.replace(/\/conversations\/[^/]+$/, '') + '/runs'), effects, options); }
  estimateInput(input: EstimateInput, options: RequestOptions = {}) { return this.one('InputEstimate', '/context_estimate', 'context_estimate', { ...options, method: 'POST', body: { context_estimate: input } }); }
  compact(input: ModelSelection = {}, options: RequestOptions = {}) { return this.one('ConversationCompaction', '/compaction', undefined, { ...options, method: 'POST', body: { compaction: input }, success: [202] }); }
  events(query: EventOptions = {}, options: RequestOptions = {}) { return this.one('EventPage', '/events', undefined, { ...options, query }); }
  feed(options: FeedOptions = {}) { return new DurableFeed({ ...options, replay: (after, request) => this.events(after === undefined ? {} : { after }, request) }); }
  inputExecution(inputId: string, position?: import('../feeds.js').EventPosition) { return new InputExecution(this.executionReaders(), inputId, position); }
  execution(identity: import('../input-execution.js').ExecutionIdentity, position?: import('../feeds.js').EventPosition) { return new InputExecution(this.executionReaders(), identity, position); }
  private executionReaders() {
    return { materialization: (id: string, options: RequestOptions) => this.inputs.materialization(id, { include_hidden: true }, options),
      events: (after: string | undefined, options: RequestOptions) => this.events(after === undefined ? {} : { after }, options),
      variants: (id: string, options: RequestOptions) => this.turns.variants(id, options),
      decisions: (id: string, options: RequestOptions) => new RunScope(this.transport, this.path.replace(/\/conversations\/[^/]+$/, '') + '/runs/' + segment(id)).decisions(options),
      run: (id: string, options: RequestOptions) => new RunScope(this.transport, this.path.replace(/\/conversations\/[^/]+$/, '') + '/runs/' + segment(id)).fetch(options) };
  }
}
