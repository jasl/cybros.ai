import { Resource } from './base.js';
import { Memory, PromptDocuments, StoreEntries, WorkspaceSchedules } from './data.js';
import { Conversations, ConversationScope } from './conversations.js';
import { Runs, RunScope, TaskScope } from './runs.js';
import { InferenceRequests } from './inference.js';
import { segment } from '../json.js';
import type { MutationOptions, RequestOptions } from '../http.js';
import type { CreateWorkspace, UpdateWorkspace, WorkspaceList, Version } from '../requests.js';
import type { AgentMessaging } from '../models.js';
export class Workspaces extends Resource {
  list(query: WorkspaceList = {}, options: RequestOptions = {}) { return this.paged('WorkspaceSummary', 'workspaces', { ...options, query }); }
  fetch(id: string, options: RequestOptions = {}) { return this.one('Workspace', `/${segment(id)}`, 'workspace', options); }
  create(input: CreateWorkspace, options: MutationOptions) { return this.receipt('Workspace', 'workspace', { ...options, method: 'POST', body: { workspace: input }, success: [201] }); }
}
export class WorkspaceScope extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('Workspace', '', 'workspace', options); }
  update(input: UpdateWorkspace, options: RequestOptions = {}) { return this.one('Workspace', '', 'workspace', { ...options, method: 'PATCH', body: { workspace: input } }); }
  updateAccessMode(input: Version & { access_mode: 'account_wide' | 'private' }, options: RequestOptions = {}) { return this.one('Workspace', '/access_mode', 'workspace', { ...options, method: 'PUT', body: { access_mode: input } }); }
  messaging(options: RequestOptions = {}) { return this.one('WorkspaceMessaging', '/messaging', 'messaging', options); }
  setMessaging(input: Version & { agents: AgentMessaging[] }, options: RequestOptions = {}) { return this.one('WorkspaceMessaging', '/messaging', 'messaging', { ...options, method: 'PUT', body: { messaging: input } }); }
  setToolProviderOverrides(input: Version & { overrides: Record<string, string> }, options: RequestOptions = {}) { return this.one('Workspace', '/tool_provider_overrides', 'workspace', { ...options, method: 'PUT', body: { tool_provider_overrides: input } }); }
  transferOwnership(input: Version & { target_user_public_id: string }, options: RequestOptions = {}) { return this.one('Workspace', '/ownership_transfer', 'workspace', { ...options, method: 'POST', body: { ownership_transfer: input } }); }
  archive(input: Version, options: RequestOptions = {}) { return this.one('Workspace', '/archival', 'workspace', { ...options, method: 'POST', body: { command: input } }); }
  restore(input: Version, options: RequestOptions = {}) { return this.one('Workspace', '/restoration', 'workspace', { ...options, method: 'POST', body: { command: input } }); }
  delete(query: Version, options: RequestOptions = {}) { return this.one('Workspace', '', 'workspace', { ...options, method: 'DELETE', query }); }
  principals(options: RequestOptions = {}) { return this.many('Principal', 'principals', options, '/principals'); }
  get memory() { return new Memory(this.transport, this.path + '/memory'); }
  get storeEntries() { return new StoreEntries(this.transport, this.path + '/store_entries'); }
  get promptDocuments() { return new PromptDocuments(this.transport, this.path + '/prompt_documents'); }
  get conversations() { return new Conversations(this.transport, this.path + '/conversations'); }
  conversation(id: string) { return new ConversationScope(this.transport, `${this.path}/conversations/${segment(id)}`); }
  get runs() { return new Runs(this.transport, this.path + '/runs'); }
  run(id: string) { return new RunScope(this.transport, `${this.path}/runs/${segment(id)}`); }
  task(runId: string, taskKey: string) { return new TaskScope(this.transport, `${this.path}/runs/${segment(runId)}/tasks/${segment(taskKey)}`); }
  get schedules() { return new WorkspaceSchedules(this.transport, this.path + '/schedules'); }
  get inferenceRequests() { return new InferenceRequests(this.transport, this.path + '/inference_requests'); }
}
