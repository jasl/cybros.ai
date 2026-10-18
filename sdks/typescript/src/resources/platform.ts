import { Resource } from './base.js';
import { BudgetReads } from './budgets.js';
import { object, segment } from '../json.js';
import { MalformedResponse } from '../errors.js';
import type { RequestOptions, MutationOptions, Transport } from '../http.js';
import type { ListOptions, PlatformRunnerList, Version, ModelUsageAnalysisQuery } from '../requests.js';
export class PlatformProfile extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('PlatformProfile', '', undefined, options); }
  get budgets() { return new BudgetReads(this.transport, this.path + '/budgets'); }
}
export class Session extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('PlatformSession', '', 'session', options); }
  async revoke(options: RequestOptions = {}) { const data = object((await this.transport.call(this.path, { ...options, method: 'DELETE' })).data); if (data.revoked !== true) throw new MalformedResponse('Expected revoked session'); }
}
export class Persona extends Resource {
  read(options: RequestOptions = {}) { return this.one('PromptDocument', '', 'prompt_document', options); }
  write(input: { content: string; role?: 'system' | 'developer' | 'user' }, options: RequestOptions = {}) { return this.one('PromptDocument', '', 'prompt_document', { ...options, method: 'PUT', body: { prompt_document: input } }); }
  delete(options: RequestOptions = {}) { return this.empty('', { ...options, method: 'DELETE', success: [204] }); }
}
export class CostUnit extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('PlatformCostUnit', '', 'account', options); }
  configure(cost_unit: string, options: RequestOptions = {}) { return this.one('PlatformCostUnit', '', 'account', { ...options, method: 'PUT', body: { account: { cost_unit } } }); }
}
export class Retention extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('PlatformRetention', '', 'account', options); }
  update(execution_details_retention_days: number | null, options: RequestOptions = {}) { return this.one('PlatformRetention', '', 'account', { ...options, method: 'PATCH', body: { account: { execution_details_retention_days } } }); }
}
export class PlatformAgents extends Resource {
  list(query: ListOptions = {}, options: RequestOptions = {}) { return this.paged('PlatformAgent', 'agents', { ...options, query }); }
  create(display_name: string, options: RequestOptions = {}) { return this.one('PlatformAgent', '', 'agent', { ...options, method: 'POST', body: { agent: { display_name } }, success: [201] }); }
  agent(id: string) { return new PlatformAgentScope(this.transport, `${this.path}/${segment(id)}`); }
}
export class PlatformAgentScope extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('PlatformAgentDetail', '', 'agent', options); }
  configuration(options: RequestOptions = {}) { return this.one('PlatformAgentConfiguration', '/configuration', undefined, options); }
  revokeConnection(options: RequestOptions = {}) { return this.transition('connection_revocation', options); }
  remove(options: RequestOptions = {}) { return this.transition('removal', options); }
  restore(options: RequestOptions = {}) { return this.transition('restoration', options); }
  get apiKeys() { return new APIKeys(this.transport, this.path + '/api_keys', 'member'); }
  get executorApiKeys() { return new APIKeys(this.transport, this.path + '/executor/api_keys', 'executor_transport'); }
  get privateRunners() { return new PrivateRunners(this.transport, this.path + '/private_runners'); }
  get budgets() { return new Budgets(this.transport, this.path + '/budgets'); }
  private transition(verb: string, options: RequestOptions) { return this.one('PlatformAgent', `/${verb}`, 'agent', { ...options, method: 'POST' }); }
}
export class PlatformRunners extends Resource {
  list(query: PlatformRunnerList = {}, options: RequestOptions = {}) { return this.one('PlatformRunnerPage', '', undefined, { ...options, query }); }
  fetch(id: string, options: RequestOptions = {}) { return this.one('PlatformRunnerSnapshot', `/${segment(id)}`, undefined, options); }
}
export class PrivateRunners extends Resource {
  list(query: ListOptions = {}, options: RequestOptions = {}) { return this.paged('PlatformPrivateRunner', 'private_runners', { ...options, query }); }
  create(display_name: string, options: RequestOptions = {}) { return this.one('PlatformPrivateRunner', '', 'private_runner', { ...options, method: 'POST', body: { private_runner: { display_name } }, success: [201] }); }
  runner(id: string) { return new PrivateRunnerScope(this.transport, `${this.path}/${segment(id)}`); }
}
export class PrivateRunnerScope extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('PlatformPrivateRunner', '', 'private_runner', options); }
  get apiKeys() { return new APIKeys(this.transport, this.path + '/api_keys', 'executor_transport'); }
}
export class APIKeys extends Resource {
  constructor(transport: Transport, path: string, readonly plane: 'member' | 'executor_transport') { super(transport, path); }
  async list(query: ListOptions = {}, options: RequestOptions = {}) { const result = await this.paged('PlatformAPIKey', 'api_keys', { ...options, query }); result.items.forEach(key => this.validatePlane(key.plane)); return result; }
  async create(input: { name: string; note?: string | null }, options: RequestOptions = {}) { const result = await this.one('PlatformAPIKeyGrant', '', undefined, { ...options, method: 'POST', body: { api_key: input }, success: [201] }); this.validatePlane(result.api_key.plane); return result; }
  revoke(id: string, options: RequestOptions = {}) { return this.empty(`/${segment(id)}/revocation`, { ...options, method: 'POST', success: [204] }); }
  private validatePlane(value: string) { if (value !== this.plane) throw new MalformedResponse('Unexpected API key plane'); }
}
export interface OpenBudget { amount: string; starts_at: string; expires_at?: string | null; reason?: string; }
export class Budgets extends BudgetReads {
  open(input: OpenBudget, options: MutationOptions) { return this.receipt('PlatformBudget', 'budget', { ...options, method: 'POST', body: { budget: input }, success: [201] }); }
  adjust(id: string, input: { kind: 'credit' | 'debit'; amount: string; reason?: string }, options: MutationOptions) { return this.one('PlatformBudgetAdjustment', `/${segment(id)}`, undefined, { ...options, method: 'PATCH', body: { budget: input } }); }
  revoke(id: string, input: { reason?: string }, options: MutationOptions) { return this.one('PlatformBudget', `/${segment(id)}/revocation`, 'budget', { ...options, method: 'POST', body: { revocation: input } }); }
}
export interface UsageQuery { from: string; to: string; unit?: 'hour' | 'day' | 'month'; provider_id?: string; catalog_model_ref?: string; workload?: string; status?: string; }
export class ModelUsage extends Resource {
  report(query: UsageQuery, options: RequestOptions = {}) { return this.one('PlatformUsageReport', '/report', 'report', { ...options, query }); }
  analysis(query: ModelUsageAnalysisQuery = {}, options: RequestOptions = {}) { return this.one('PlatformUsageAnalysis', '/analysis', 'analysis', { ...options, query }); }
}
export interface CreateMcpConnection { name: string; endpoint_url: string; auth_type: 'none' | 'bearer' | 'oauth'; account_label?: string | null; bearer_token?: string; enabled?: boolean; }
export class PlatformMcpConnections extends Resource {
  list(query: ListOptions = {}, options: RequestOptions = {}) { return this.paged('PlatformMcpConnection', 'mcp_connections', { ...options, query }); }
  fetch(id: string, options: RequestOptions = {}) { return this.one('PlatformMcpConnection', `/${segment(id)}`, 'mcp_connection', options); }
  create(input: CreateMcpConnection, options: RequestOptions = {}) { return this.one('PlatformMcpConnection', '', 'mcp_connection', { ...options, method: 'POST', body: { mcp_connection: input }, success: [201] }); }
  update(id: string, input: Version & { name?: string; account_label?: string | null; enabled?: boolean }, options: RequestOptions = {}) { return this.one('PlatformMcpConnection', `/${segment(id)}`, 'mcp_connection', { ...options, method: 'PATCH', body: { mcp_connection: input } }); }
  refreshCatalog(id: string, input: Version, options: RequestOptions = {}) { return this.one('PlatformMcpConnection', `/${segment(id)}/catalog_refresh`, 'mcp_connection', { ...options, method: 'POST', body: { command: input } }); }
  startAuthorization(id: string, input: Version, options: RequestOptions = {}) { return this.one('PlatformMcpAuthorization', `/${segment(id)}/authorization`, 'authorization', { ...options, method: 'POST', body: { command: input } }); }
  rotateCredential(id: string, input: Version & { bearer_token: string }, options: RequestOptions = {}) { return this.one('PlatformMcpConnection', `/${segment(id)}/credential`, 'mcp_connection', { ...options, method: 'PUT', body: { credential: input } }); }
  clearCredential(id: string, input: Version, options: RequestOptions = {}) { return this.one('PlatformMcpConnection', `/${segment(id)}/credential`, 'mcp_connection', { ...options, method: 'DELETE', body: { command: input } }); }
}
export class PlatformModels extends Resource { list(query: { workload?: string; available?: boolean } = {}, options: RequestOptions = {}) { return this.many('Model', 'models', { ...options, query }); } }
