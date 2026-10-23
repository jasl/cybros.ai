import { Transport } from './http.js';
import { Resource } from './resources/base.js';
import { Profile, Models, Tools, ModelProviders, Executors, McpConnections } from './resources/identity.js';
import { Workspaces, WorkspaceScope } from './resources/workspaces.js';
import { AllConversations } from './resources/conversations.js';
import { WorkQueries } from './resources/work.js';
import { MemoryCollections, Uploads, UploadStaging, WorkspaceSchedules } from './resources/data.js';
import { ExecutorInbox, ExecutorTask } from './resources/executor.js';
import { Budgets, CostUnit, ModelUsage, Persona, PlatformAgents, PlatformRunners, PlatformMcpConnections, PlatformModels, PlatformProfile, Retention, Session } from './resources/platform.js';
import { PlatformModelProviders } from './resources/providers.js';
import { Deployment } from './resources/deployment.js';
import { shape } from './decode.js';
import { segment } from './json.js';
import type { ClientOptions, ConnectionOptions, RequestOptions } from './http.js';
import type { ExecutorAnnouncement, ProgressFrameInput } from './requests.js';
export class Client {
  readonly #transport: Transport;
  constructor(options: ClientOptions) { this.#transport = new Transport(options, 'member'); }
  get profile() { return new Profile(this.#transport, '/agent_api/v1/profile'); }
  get workspaces() { return new Workspaces(this.#transport, '/agent_api/v1/workspaces'); }
  workspace(id: string) { return new WorkspaceScope(this.#transport, `/agent_api/v1/workspaces/${segment(id)}`); }
  get memoryCollections() { return new MemoryCollections(this.#transport, '/agent_api/v1/memory_collections'); }
  get conversations() { return new AllConversations(this.#transport, '/agent_api/v1/conversations'); }
  get schedules() { return new WorkspaceSchedules(this.#transport, '/agent_api/v1/schedules'); }
  get work() { return new WorkQueries(this.#transport, '/agent_api/v1'); }
  get uploads() { return new Uploads(this.#transport, '/agent_api/v1/uploads'); }
  get tools() { return new Tools(this.#transport, '/agent_api/v1/tools'); }
  get models() { return new Models(this.#transport, '/agent_api/v1/models'); }
  get modelProviders() { return new ModelProviders(this.#transport, '/agent_api/v1/model_providers'); }
  get executors() { return new Executors(this.#transport, '/agent_api/v1/executors'); }
  get mcpConnections() { return new McpConnections(this.#transport, '/agent_api/v1/mcp_connections'); }
}
export class ExecutorClient {
  readonly #transport: Transport;
  constructor(options: ClientOptions) { this.#transport = new Transport(options, 'executor'); }
  async executor(options: RequestOptions = {}) { return shape('ExecutorDescription', (await this.#transport.call('/agent_api/v1/executor', options)).data); }
  async announce(input: ExecutorAnnouncement, options: RequestOptions = {}) { return shape('ExecutorDescription', (await this.#transport.call('/agent_api/v1/executor/announcement', { ...options, method: 'PUT', body: input })).data); }
  get inbox() { return new ExecutorInbox(this.#transport, '/agent_api/v1/executor/inbox'); }
  inboxTask(runId: string, taskKey: string) { return new ExecutorTask(this.#transport, `/agent_api/v1/executor/inbox/${segment(runId)}/${segment(taskKey)}`); }
  get uploads() { return new UploadStaging(this.#transport, '/agent_api/v1/executor/uploads'); }
  async reportProgress(frame: ProgressFrameInput, options: RequestOptions = {}) { await this.#transport.call('/agent_api/v1/executor/progress', { ...options, method: 'POST', body: { frame }, success: [202], allowEmpty: true }); }
}
export class PlatformClient {
  readonly #transport: Transport;
  constructor(options: ClientOptions) { this.#transport = new Transport(options, 'platform'); }
  get session() { return new Session(this.#transport, '/api/v1/session'); }
  get profile() { return new PlatformProfile(this.#transport, '/api/v1/profile'); }
  get persona() { return new Persona(this.#transport, '/api/v1/persona'); }
  get costUnit() { return new CostUnit(this.#transport, '/api/v1/admin/account/cost_unit'); }
  get retention() { return new Retention(this.#transport, '/api/v1/admin/account/retention'); }
  get agents() { return new PlatformAgents(this.#transport, '/api/v1/agents'); }
  get runners() { return new PlatformRunners(this.#transport, '/api/v1/runners'); }
  budgets(userId: string) { return new Budgets(this.#transport, `/api/v1/admin/users/${segment(userId)}/budgets`); }
  get modelUsage() { return new ModelUsage(this.#transport, '/api/v1/admin/model_usage'); }
  get models() { return new PlatformModels(this.#transport, '/api/v1/admin/models'); }
  get modelProviders() { return new PlatformModelProviders(this.#transport, '/api/v1/admin/model_providers'); }
  get mcpConnections() { return new PlatformMcpConnections(this.#transport, '/api/v1/mcp_connections'); }
  get deployment() { return new Deployment(this.#transport, '/api/v1/admin/deployment'); }
}
export class Sessions {
  readonly #transport: Transport;
  constructor(options: ConnectionOptions) { this.#transport = new Transport(options, 'platform', true); }
  async create(input: { email: string; password: string }, options: RequestOptions = {}) { return shape('PlatformSessionGrant', (await this.#transport.call('/api/v1/session', { ...options, method: 'POST', body: input, success: [201] })).data); }
}
