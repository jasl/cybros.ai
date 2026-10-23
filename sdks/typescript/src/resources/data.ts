import { Resource } from './base.js';
import { segment, object } from '../json.js';
import { MalformedResponse } from '../errors.js';
import type { JsonValue } from '../json.js';
import type { MutationOptions, RequestOptions, Transport, DownloadOptions } from '../http.js';
import type { CreateMemoryCollection, UpdateMemoryCollection, OwnedMemoryCollectionList, MemoryCollectionCondition, CreateStoreEntry, EditMemory, GrepMemory, ListOptions, ScheduleList, ExistingMemoryVersion, Version, WriteMemory, CreateSchedule, UpdateSchedule } from '../requests.js';
export class StoreEntries extends Resource {
  list(query: ListOptions = {}, options: RequestOptions = {}) { return this.paged('StoreEntrySummary', 'store_entries', { ...options, query }); }
  fetch(id: string, options: RequestOptions = {}) { return this.one('StoreEntry', `/${segment(id)}`, 'store_entry', options); }
  create(input: CreateStoreEntry, options: MutationOptions) { return this.receipt('StoreEntry', 'store_entry', { ...options, method: 'POST', body: { store_entry: input }, success: [201] }); }
  update(id: string, input: Version & { value: JsonValue }, options: RequestOptions = {}) { return this.one('StoreEntry', `/${segment(id)}`, 'store_entry', { ...options, method: 'PATCH', body: { store_entry: input } }); }
  delete(id: string, query: Version, options: RequestOptions = {}) { return this.empty(`/${segment(id)}`, { ...options, method: 'DELETE', query, success: [204] }); }
}
export interface MemoryMatch { path: string; line_number: number; text: string; }
export interface MemoryMatches { matches: MemoryMatch[]; truncated: boolean; }
export class MemoryDocuments<Condition extends object = object> extends Resource {
  constructor(transport: Transport, path: string, protected readonly speaker?: string) { super(transport, path); }
  private fields<T extends object>(input: T) { return { ...input, ...(this.speaker === undefined ? {} : { speaker_public_id: this.speaker }) }; }
  list(options: RequestOptions = {}) { return this.many('MemoryDocument', 'memory', { ...options, query: { 'memory[speaker_public_id]': this.speaker } }); }
  read(path: string, options: RequestOptions = {}) { return this.one('MemoryDocument', '/show', 'memory', { ...options, method: 'POST', body: { memory: this.fields({ path }) } }); }
  write(input: WriteMemory & Condition, options: RequestOptions = {}) { return this.one('MemoryDocument', '', 'memory', { ...options, method: 'POST', body: { memory: this.fields(input) }, success: [201] }); }
  edit(input: EditMemory & Condition, options: RequestOptions = {}) { return this.one('MemoryDocument', '/edit', 'memory', { ...options, method: 'POST', body: { memory: this.fields(input) } }); }
  delete(path: string, version: ExistingMemoryVersion & Condition, options: RequestOptions = {}) { return this.empty('/delete', { ...options, method: 'POST', body: { memory: this.fields({ path, ...version }) }, success: [204] }); }
  async grep(input: GrepMemory, options: RequestOptions = {}): Promise<MemoryMatches> {
    const body = object((await this.transport.call(this.path + '/grep', { ...options, method: 'POST', body: { memory: this.fields(input) } })).data);
    if (!Array.isArray(body.matches) || typeof body.truncated !== 'boolean') throw new MalformedResponse('Expected memory matches');
    return { matches: body.matches.map(item => { const match = object(item); if (typeof match.path !== 'string' || !Number.isSafeInteger(match.line_number) || typeof match.text !== 'string') throw new MalformedResponse('Expected memory match path, line_number and text'); return { path: match.path, line_number: match.line_number as number, text: match.text }; }), truncated: body.truncated };
  }
}
export class Memory extends MemoryDocuments<MemoryCollectionCondition> {
  bindings(options: RequestOptions = {}) { return this.one('MemoryBindings', '', 'memory_context', { ...options, query: { 'memory[speaker_public_id]': this.speaker } }); }
}
export class MemoryCollections extends Resource {
  list(query: ListOptions = {}, options: RequestOptions = {}) { return this.paged('MemoryCollection', 'memory_collections', { ...options, query }); }
  private collectionPath(id: string) { return `/agent_api/v1/memory_collections/${segment(id)}`; }
  private collection(id: string) { return new MemoryCollectionResource(this.transport, this.collectionPath(id)); }
  fetch(id: string, options: RequestOptions = {}) { return this.collection(id).fetch(options); }
  update(id: string, input: UpdateMemoryCollection, options: RequestOptions = {}) { return this.collection(id).update(input, options); }
  archive(id: string, input: Version, options: RequestOptions = {}) { return this.collection(id).archive(input, options); }
  restore(id: string, input: Version, options: RequestOptions = {}) { return this.collection(id).restore(input, options); }
  delete(id: string, input: Version, options: RequestOptions = {}) { return this.collection(id).delete(input, options); }
  documents(id: string) { return new MemoryDocuments(this.transport, this.collectionPath(id) + '/documents'); }
}
class MemoryCollectionResource extends Resource {
  fetch(options: RequestOptions) { return this.one('MemoryCollection', '', 'memory_collection', options); }
  update(input: UpdateMemoryCollection, options: RequestOptions) { return this.one('MemoryCollection', '', 'memory_collection', { ...options, method: 'PATCH', body: { memory_collection: input } }); }
  archive(input: Version, options: RequestOptions) { return this.one('MemoryCollection', '/archive', 'memory_collection', { ...options, method: 'POST', body: { memory_collection: input } }); }
  restore(input: Version, options: RequestOptions) { return this.one('MemoryCollection', '/restore', 'memory_collection', { ...options, method: 'POST', body: { memory_collection: input } }); }
  delete(input: Version, options: RequestOptions) { return this.empty('', { ...options, method: 'DELETE', body: { memory_collection: input }, success: [204] }); }
}
export class OwnedMemoryCollections extends MemoryCollections {
  override list(query: OwnedMemoryCollectionList = {}, options: RequestOptions = {}) { return this.paged('MemoryCollection', 'memory_collections', { ...options, query }); }
  create(input: CreateMemoryCollection, options: RequestOptions = {}) { return this.one('MemoryCollection', '', 'memory_collection', { ...options, method: 'POST', body: { memory_collection: input }, success: [200, 201] }); }
}
export class PromptDocuments extends Resource {
  list(options: RequestOptions = {}) { return this.many('PromptDocument', 'prompt_documents', options); }
  read(slot: string, options: RequestOptions = {}) { return this.one('PromptDocument', `/${segment(slot)}`, 'prompt_document', options); }
  write(slot: string, input: { content: string; role?: 'system' | 'developer' | 'user' }, options: RequestOptions = {}) { return this.one('PromptDocument', `/${segment(slot)}`, 'prompt_document', { ...options, method: 'PUT', body: { prompt_document: input } }); }
  delete(slot: string, options: RequestOptions = {}) { return this.empty(`/${segment(slot)}`, { ...options, method: 'DELETE', success: [204] }); }
}
export class WorkspaceSchedules extends Resource {
  list(query: ScheduleList = {}, options: RequestOptions = {}) { return this.paged('Schedule', 'schedules', { ...options, query }); }
}
export class Schedules extends WorkspaceSchedules {
  fetch(id: string, options: RequestOptions = {}) { return this.one('Schedule', `/${segment(id)}`, 'schedule', options); }
  create(input: CreateSchedule, options: MutationOptions) { return this.receipt('Schedule', 'schedule', { ...options, method: 'POST', body: { schedule: input }, success: [201] }); }
  update(id: string, input: UpdateSchedule, options: RequestOptions = {}) { return this.one('Schedule', `/${segment(id)}`, 'schedule', { ...options, method: 'PATCH', body: { schedule: input } }); }
  pause(id: string, options: RequestOptions = {}) { return this.command(id, 'pause', options); }
  resume(id: string, options: RequestOptions = {}) { return this.command(id, 'resume', options); }
  cancel(id: string, options: RequestOptions = {}) { return this.command(id, 'cancel', options); }
  run(id: string, options: RequestOptions = {}) { return this.command(id, 'run', options); }
  executions(id: string, query: ListOptions = {}, options: RequestOptions = {}) { return this.one('ScheduleExecutionPage', `/${segment(id)}/executions`, undefined, { ...options, query }); }
  private command(id: string, verb: string, options: RequestOptions) { return this.one('Schedule', `/${segment(id)}/${verb}`, 'schedule', { ...options, method: 'POST' }); }
}
export class UploadStaging extends Resource {
  create(file: Blob, filename: string, options: RequestOptions = {}) {
    const form = new FormData();
    form.set('upload[file]', file, filename);
    return this.one('Upload', '', 'upload', { ...options, method: 'POST', body: form, success: [201] });
  }
}
export class Uploads extends UploadStaging {
  fetch(id: string, options: RequestOptions = {}) { return this.one('Upload', `/${segment(id)}`, 'upload', options); }
  bytes(id: string, options: DownloadOptions = {}) { return this.transport.download(`${this.path}/${segment(id)}/bytes`, options); }
  thumbnail(id: string, options: DownloadOptions = {}) { return this.transport.download(`${this.path}/${segment(id)}/thumbnail`, options); }
  preview(id: string, options: DownloadOptions = {}) { return this.transport.download(`${this.path}/${segment(id)}/preview`, options); }
}
