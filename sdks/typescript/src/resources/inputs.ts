import { Resource } from './base.js';
import { segment } from '../json.js';
import type { MutationOptions, RequestOptions } from '../http.js';
import type { CreateInput, RunInput, UpdateInput, UpdateRunInput } from '../requests.js';
import { NotFound } from '../errors.js';
export class Inputs<I extends CreateInput | RunInput = RunInput, U extends UpdateInput | UpdateRunInput = UpdateRunInput> extends Resource {
  list(options: RequestOptions = {}) { return this.one('InputList', '', undefined, options); }
  create(input: I, options: MutationOptions) {
    validateContent(input);
    return this.receipt('Input', 'input', { ...options, method: 'POST', body: { input }, success: [202] });
  }
  update(id: string, input: U, options: RequestOptions = {}) {
    validateContent(input);
    return this.one('Input', `/${segment(id)}`, 'input', { ...options, method: 'PATCH', body: { input } });
  }
  delete(id: string, options: RequestOptions = {}) { return this.empty(`/${segment(id)}`, { ...options, method: 'DELETE', success: [204] }); }
  reorder(orderedPublicIds: string[], options: RequestOptions = {}) { return this.many('Input', 'inputs', { ...options, method: 'POST', body: { inputs: orderedPublicIds } }, '/reorder'); }
}
export class ConversationInputs extends Inputs<CreateInput, UpdateInput> {
  async materialization(id: string, query: { include_hidden?: boolean } = {}, options: RequestOptions = {}) {
    try { return await this.one('InputMaterialization', `/${segment(id)}/materialization`, 'materialization', { ...options, query }); }
    catch (error) { if (error instanceof NotFound) return null; throw error; }
  }
}
function validateContent(input: { text?: string; entries?: unknown; attachments?: string[] }) {
  if (input.entries !== undefined && (input.text !== undefined || input.attachments !== undefined)) throw new TypeError('entries cannot be combined with text or attachments');
}
