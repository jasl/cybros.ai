import { Resource } from './base.js';
import { shape } from '../decode.js';
import { nonempty, segment, object } from '../json.js';
import type { JsonObject } from '../json.js';
import type { MutationOptions, RequestOptions } from '../http.js';
import type { ConversationFieldOptions, InputConfiguration, TurnList } from '../requests.js';
export class Turns extends Resource {
  list(query: TurnList = {}, options: RequestOptions = {}) {
    if (query.after_position !== undefined && query.before_position !== undefined) throw new TypeError('Choose one turn window boundary');
    return this.one('TurnPage', '', undefined, { ...options, query });
  }
  fetch(id: string, query: { include_hidden?: boolean } = {}, options: RequestOptions = {}) { return this.one('Turn', `/${segment(id)}`, 'turn', { ...options, query }); }
  async setViewState(id: string, input: { visibility?: string; concealed?: boolean }, options: RequestOptions = {}): Promise<{ public_id: string; inherited: boolean }> {
    const body = object(object((await this.transport.call(`${this.path}/${segment(id)}`, { ...options, method: 'PATCH', body: { turn: input } })).data).turn);
    if (typeof body.public_id !== 'string') throw new TypeError('Expected turn public_id');
    return { public_id: body.public_id, inherited: body.inherited === true };
  }
  delete(id: string, options: RequestOptions = {}) { return this.empty(`/${segment(id)}`, { ...options, method: 'DELETE', success: [204] }); }
  edit(id: string, input: { text: string; entries?: never } | { text?: never; entries: JsonObject[] }, options: RequestOptions = {}) { return this.one('Variant', `/${segment(id)}/edit`, 'variant', { ...options, method: 'POST', body: { edit: input } }); }
  async regenerate(id: string, input: Pick<InputConfiguration, 'model' | 'configuration' | 'agent_configuration' | 'model_selection' | 'fallback_models'>, options: MutationOptions) {
    nonempty(options?.idempotencyKey ?? '', 'idempotencyKey');
    const result = await this.transport.call(`${this.path}/${segment(id)}/regeneration`, { ...options, method: 'POST', body: { regeneration: input }, success: [202] });
    return { ...shape('ConversationRegeneration', result.data), status: result.status, replayed: result.replayed, requestId: result.requestId };
  }
  regenerationReceipt(idempotencyKey: string, options: RequestOptions = {}) { return this.one('ConversationRegeneration', '/../regeneration_receipt', undefined, { ...options, query: { idempotency_key: idempotencyKey } }); }
  variants(id: string, options: RequestOptions = {}) { return this.one('VariantDeck', `/${segment(id)}/variants`, undefined, options); }
  variant(id: string, variantId: string, options: RequestOptions = {}) { return this.one('VariantRead', `/${segment(id)}/variants/${segment(variantId)}`, undefined, options); }
  field(id: string, variantId: string, field: 'prompt' | 'content' | 'steers', query: ConversationFieldOptions = {}, options: RequestOptions = {}) { return this.one('ConversationFieldPage', `/${segment(id)}/variants/${segment(variantId)}/fields/${field}`, undefined, { ...options, query }); }
  request(id: string, variantId: string, options: RequestOptions = {}) { return this.one('SealedRequest', `/${segment(id)}/variants/${segment(variantId)}/request`, 'request', options); }
  reasoning(id: string, variantId: string, query: { before?: string; limit?: number } = {}, options: RequestOptions = {}) { return this.one('ConversationReasoningPage', `/${segment(id)}/variants/${segment(variantId)}/reasoning`, undefined, { ...options, query }); }
  activate(id: string, variantId: string, options: RequestOptions = {}) { return this.one('Variant', `/${segment(id)}/variants/${segment(variantId)}/activation`, 'variant', { ...options, method: 'POST' }); }
  setVariantViewState(id: string, variantId: string, input: { concealed: boolean }, options: RequestOptions = {}) { return this.one('Variant', `/${segment(id)}/variants/${segment(variantId)}`, 'variant', { ...options, method: 'PATCH', body: { variant: input } }); }
}
