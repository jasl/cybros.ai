import { DurableFeed } from '../feeds.js';
import type { FeedOptions } from '../feeds.js';
import type { InferenceRequestEvent } from '../models.js';
import { Resource } from './base.js';
import { segment } from '../json.js';
import type { DownloadOptions, MutationOptions, RequestOptions } from '../http.js';
import type { CreateInferenceRequest, EstimateInferenceRequest, EventOptions, ListOptions } from '../requests.js';
export class InferenceRequests extends Resource {
  list(query: ListOptions & { workload?: string } = {}, options: RequestOptions = {}) { return this.paged('InferenceRequestSummary', 'inference_requests', { ...options, query }); }
  fetch(id: string, options: RequestOptions = {}) { return this.one('InferenceRequest', `/${segment(id)}`, 'inference_request', options); }
  create(input: CreateInferenceRequest, options: MutationOptions) { return this.receipt('InferenceRequest', 'inference_request', { ...options, method: 'POST', body: { inference_request: input }, success: [200, 202] }); }
  estimateInput(input: EstimateInferenceRequest, options: RequestOptions = {}) { return this.one('InferenceRequestInputEstimate', '/input_estimate', 'input_estimate', { ...options, method: 'POST', body: { input_estimate: input } }); }
  events(id: string, query: EventOptions = {}, options: RequestOptions = {}) { return this.one('InferenceRequestEventPage', `/${segment(id)}/events`, undefined, { ...options, query }); }
  feed(id: string, options: FeedOptions<InferenceRequestEvent> = {}) { return new DurableFeed({ ...options, replay: (after, request) => this.events(id, after === undefined ? {} : { after }, request) }); }
  cancel(id: string, options: RequestOptions = {}) { return this.one('InferenceRequest', `/${segment(id)}/cancellation`, 'inference_request', { ...options, method: 'POST' }); }
  delete(id: string, options: RequestOptions = {}) { return this.empty(`/${segment(id)}`, { ...options, method: 'DELETE', success: [204] }); }
  download(id: string, index: number, options: DownloadOptions = {}) {
    if (!Number.isSafeInteger(index) || index < 0) throw new TypeError('file index must be a nonnegative integer');
    return this.transport.download(`${this.path}/${segment(id)}/files/${index}`, options);
  }
}
