import { Resource } from './base.js';
import { Memory, PromptDocuments, StoreEntries } from './data.js';
import { BudgetReads } from './budgets.js';
import { segment } from '../json.js';
import type { RequestOptions } from '../http.js';
import type { DeclareAgent, DeclareConfiguration, RegisterIngressSpeaker, ListOptions, AgentConfigurationInput } from '../requests.js';
export class Profile extends Resource {
  fetch(options: RequestOptions = {}) { return this.one('Profile', '', undefined, options); }
  declareConfiguration(input: DeclareConfiguration, options: RequestOptions = {}) { return this.one('Profile', '/configuration', undefined, { ...options, method: 'PUT', body: input }); }
  registerIngressSpeaker(input: RegisterIngressSpeaker, options: RequestOptions = {}) { return this.one('IngressSpeaker', '/ingress_speakers', 'ingress_speaker', { ...options, method: 'POST', body: { ingress_speaker: input }, success: [200, 201] }); }
  get memory() { return new Memory(this.transport, this.path + '/memory'); }
  get promptDocuments() { return new PromptDocuments(this.transport, this.path + '/prompt_documents'); }
  get storeEntries() { return new StoreEntries(this.transport, this.path + '/store_entries'); }
  get agents() { return new NamedAgents(this.transport, this.path + '/agents'); }
  get budgets() { return new BudgetReads(this.transport, this.path + '/budgets'); }
}
export class NamedAgents extends Resource {
  list(options: RequestOptions = {}) { return this.many('NamedAgent', 'agents', options); }
  declare(name: string, input: DeclareAgent, options: RequestOptions = {}) { return this.one('NamedAgent', `/${segment(name)}`, 'agent', { ...options, method: 'PUT', body: input, success: [200, 201] }); }
  remove(name: string, options: RequestOptions = {}) { return this.empty(`/${segment(name)}`, { ...options, method: 'DELETE', success: [204] }); }
  memory(name: string) { return new Memory(this.transport, `${this.path}/${segment(name)}/memory`); }
}
export class Models extends Resource { list(query: { workload?: string } = {}, options: RequestOptions = {}) { return this.many('Model', 'models', { ...options, query }); } }
export class Tools extends Resource {
  list(options: RequestOptions = {}) { return this.many('ToolEntry', 'tools', options); }
  assemble(input: { default_runner_executor_public_id?: string | null; configuration?: AgentConfigurationInput; conversation_public_id?: string; agent_public_id?: string } = {}, options: RequestOptions = {}) { return this.one('ToolAssembly', '/assembly', undefined, { ...options, method: 'POST', body: input }); }
}
export class ModelProviders extends Resource { list(options: RequestOptions = {}) { return this.many('ModelProvider', 'model_providers', options); } }
export class Executors extends Resource {
  list(query: { kind?: 'runner' | 'tool_provider' } = {}, options: RequestOptions = {}) { return this.many('DiscoveredExecutor', 'executors', { ...options, query }); }
  fetch(id: string, options: RequestOptions = {}) { return this.one('DiscoveredExecutor', `/${segment(id)}`, 'executor', options); }
}
export class McpConnections extends Resource {
  list(query: ListOptions & { agent_public_id?: string } = {}, options: RequestOptions = {}) { return this.paged('McpConnection', 'mcp_connections', { ...options, query }); }
  fetch(id: string, query: { agent_public_id?: string } = {}, options: RequestOptions = {}) { return this.one('McpConnection', `/${segment(id)}`, 'mcp_connection', { ...options, query }); }
}
