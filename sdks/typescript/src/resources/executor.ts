import { Resource } from './base.js';
import { segment } from '../json.js';
import type { DownloadOptions, RequestOptions } from '../http.js';
import type { CommitTask, EventOptions, OperationRequest } from '../requests.js';
export class ExecutorInbox extends Resource {
  list(query: EventOptions = {}, options: RequestOptions = {}) { return this.paged('InboxTask', 'tasks', { ...options, query }); }
}
export class ExecutorTask extends Resource {
  claim(options: RequestOptions = {}) { return this.one('ClaimedTask', '/claim', undefined, { ...options, method: 'POST' }); }
  claimStatus(claimToken: string, options: RequestOptions = {}) { return this.one('ClaimStatus', '/claim', undefined, { ...options, headers: { 'Claim-Token': claimToken } }); }
  attachment(id: string, claimToken: string, options: RequestOptions = {}) { return this.one('Upload', `/attachments/${segment(id)}`, 'upload', { ...options, headers: { 'Claim-Token': claimToken } }); }
  attachmentBytes(id: string, claimToken: string, options: DownloadOptions = {}) { return this.transport.download(`${this.path}/attachments/${segment(id)}/bytes`, { ...options, headers: { 'Claim-Token': claimToken } }); }
  extend(input: { claim_token: string; timeout_ms: number }, options: RequestOptions = {}) { return this.one('ClaimedTask', '/extend', undefined, { ...options, method: 'POST', body: input }); }
  commit(input: CommitTask, options: RequestOptions = {}) { return this.one('Task', '/commit', 'task', { ...options, method: 'POST', body: input }); }
  operations(claimToken: string, query: { after?: number; limit?: number } = {}, options: RequestOptions = {}) { return this.one('TaskOperations', '/operations', 'operations', { ...options, headers: { 'Claim-Token': claimToken }, query }); }
  submit(input: { claim_token: string; operation: { key: string; request: OperationRequest } }, options: RequestOptions = {}) { return this.one('OperationEvent', '/operations', 'operation', { ...options, method: 'POST', body: input, success: [200, 201] }); }
  observe(input: { claim_token: string; after: number }, options: RequestOptions = {}) { return this.one('OperationRead', '/observation', undefined, { ...options, method: 'POST', body: input }); }
}
