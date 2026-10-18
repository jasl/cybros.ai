import type { JsonObject, JsonValue } from "../json.js";

export interface PlatformMcpConnection {
  public_id: string;
  name: string;
  account_label: string | null;
  endpoint_url: string;
  auth_type: string;
  enabled: boolean;
  available: boolean;
  credential_configured: boolean;
  authorization_status: string;
  authorization_expires_at: string | null;
  tools: JsonValue[];
  catalog_refreshed_at: string | null;
  lock_version: number;
}

export interface PlatformMcpAuthorization {
  connection_public_id: string;
  authorization_url: string;
  expires_at: string;
}

export interface PlatformDeploymentImage {
  name: string;
  reference: string;
}

export interface PlatformDeploymentRelease {
  release: string;
  images: PlatformDeploymentImage[];
}

export interface PlatformDeploymentCandidate {
  release: string;
  images: PlatformDeploymentImage[];
  checked_at: string;
  source_revision: string | null;
  source_url: string | null;
}

export interface PlatformDeploymentCheck {
  name: string;
  status: string;
  message: string | null;
  next_step: string | null;
  available_bytes: number | null;
  required_bytes: number | null;
}

export interface PlatformDeploymentPreflight {
  checked_at: string;
  ready: boolean;
  backup: boolean;
  checks: PlatformDeploymentCheck[];
}

export interface PlatformDeploymentBackup {
  created_at: string;
  size_bytes: number;
  available: boolean;
}

export interface PlatformDeploymentError {
  code: string;
  message: string;
  operation_id: string | null;
}

export interface PlatformDeploymentUpgrade {
  id: string;
  idempotency_key: string;
  actor_public_id: string | null;
  target: PlatformDeploymentRelease;
  previous: PlatformDeploymentRelease | null;
  phase: string;
  status: string;
  accepted_at: string;
  updated_at: string;
  completed_at: string | null;
  error: PlatformDeploymentError | null;
  recovery: string | null;
  log_cursor: string | null;
  backup: boolean;
  database_backup: PlatformDeploymentBackup | null;
}

export interface PlatformDeploymentState {
  supported: boolean;
  sources: PlatformDeploymentImage[];
  installed: PlatformDeploymentRelease | null;
  candidate: PlatformDeploymentCandidate | null;
  preflight: PlatformDeploymentPreflight | null;
  active_operation: PlatformDeploymentUpgrade | null;
  last_operation: PlatformDeploymentUpgrade | null;
}

export interface PlatformDeploymentLogEntry {
  cursor: string;
  text: string | null;
}

export interface PlatformDeploymentLog {
  entries: PlatformDeploymentLogEntry[];
  next_cursor: string | null;
  operation: PlatformDeploymentUpgrade;
}

export interface PlatformBudget {
  public_id: string;
  user_public_id: string;
  user_kind: string;
  credited_amount: string;
  debited_amount: string;
  headroom: string;
  cost_unit: string;
  starts_at: string;
  expires_at: string | null;
  revoked_at: string | null;
  revoked_by_public_id: string | null;
  revoke_reason: string | null;
  usable: boolean;
}

export interface PlatformBudgetPage {
  user_public_id: string;
  user_kind: string;
  cost_unit: string | null;
  measured_at: string;
  current_budget: PlatformBudget | null;
  items: PlatformBudget[];
  next_after: string | null;
}
export interface PlatformBudgetSnapshot { budget: PlatformBudget; measured_at: string; }
export interface PlatformBudgetLedgerEntry {
  public_id: string;
  sequence: number;
  kind: string;
  amount: string;
  cost_unit: string;
  actor_public_id: string | null;
  reason: string | null;
  created_at: string;
}

export interface PlatformBudgetEntry {
  sequence: number;
  kind: string;
  amount: string;
  reason: string | null;
  operation_key: string;
  created_at: string;
}

export interface PlatformBudgetAdjustment {
  budget: PlatformBudget;
  entry: PlatformBudgetEntry;
}

export interface PlatformUsageCounters {
  request_count: number;
  input_tokens: number;
  cache_read_tokens: number;
  cache_creation_tokens: number;
  output_tokens: number;
  reasoning_tokens: number;
  total_tokens: number;
  cost_amount: string;
  cost_complete: boolean;
}

export interface PlatformUsagePoint {
  request_count: number;
  input_tokens: number;
  cache_read_tokens: number;
  cache_creation_tokens: number;
  output_tokens: number;
  reasoning_tokens: number;
  total_tokens: number;
  cost_amount: string;
  cost_complete: boolean;
  bucket_start_at: string;
}

export interface PlatformUsageReport {
  unit: string;
  series: PlatformUsagePoint[];
  totals: PlatformUsageCounters;
}

export interface PlatformAgent {
  public_id: string;
  handle: string | null;
  display_name: string;
  status: string;
  agent_identifier: string | null;
  named_agent_scope: string | null;
  description: string | null;
  derived_from_public_id: string | null;
}

export interface PlatformAgentConnection {
  executor_public_id: string;
  owner_agent_public_id: string;
  status: string;
  credential_readiness: string;
  presence: string;
  last_seen_at: string | null;
  connected_at: string | null;
}

export interface PlatformAgentDetail extends PlatformAgent {
  application_connection: PlatformAgentConnection | null;
}

export interface PlatformAgentConfiguration {
  agent: PlatformAgent;
  configuration: AgentConfiguration;
  prompt_documents: import('./conversation.js').PromptDocument[];
  agent_updated_at: string;
  measured_at: string;
}

export interface PlatformRunner {
  public_id: string;
  kind: string;
  display_name: string;
  status: string;
  manager_public_id: string;
  assignment_scope: string;
  assignment_agent_public_id: string | null;
  credential_readiness: string;
  eligible_for_current_user: boolean;
  presence: string;
  last_seen_at: string | null;
  connected_at: string | null;
  registered_at: string;
}

export interface PlatformRunnerDetail extends PlatformRunner {
  served_tools: import('./execution.js').ServedTool[];
  served_documents: import('./execution.js').ServedDocument[];
  environment: JsonObject;
}

export interface PlatformRunnerPage {
  items: PlatformRunner[];
  next_after: string | null;
  measured_at: string;
}

export interface PlatformRunnerSnapshot {
  runner: PlatformRunnerDetail;
  measured_at: string;
}

export interface PlatformPrivateRunner {
  public_id: string;
  display_name: string;
  status: string;
  registration_identifier: string;
  assignment_scope: string;
  assignment_agent_public_id: string;
}

export interface PlatformAPIKey {
  public_id: string;
  name: string;
  note: string | null;
  plane: string;
  created_at: string;
  last_used_at: string | null;
  revoked_at: string | null;
  usable: boolean;
}

export interface PlatformAPIKeyGrant {
  api_key: PlatformAPIKey;
  secret: string;
}

export interface PlatformAuthorizationSession {
  public_id: string;
  kind: string;
  state: string;
  progress: string;
  outcome: string | null;
  expires_at: string | null;
  verification_uri: string | null;
  user_code: string | null;
  owned_by_current_user: boolean;
}

export interface PlatformAuthorization {
  provider_id: string;
  state: string;
  expires_at: string | null;
  session: PlatformAuthorizationSession | null;
}

export interface PlatformModelDefinition {
  model: string;
  definition: JsonObject | null;
  source: string;
  removed: boolean;
}

export interface PlatformModelProviderConfiguration {
  provider: ModelProvider;
  definition: JsonObject | null;
  source: string;
  models: PlatformModelDefinition[];
}

export interface PlatformDiscoveredModel {
  id: string;
  display_name: string | null;
}

export interface PlatformModelTest {
  outcome: string;
  duration_ms: number;
  http_status: number | null;
  availability_update: string;
}

export interface PlatformModelTestResult {
  test: PlatformModelTest;
  provider: ModelProvider;
}

export interface PlatformSession {
  public_id: string;
  kind: string;
  expires_at: string;
}

export interface PlatformSessionGrant {
  session: PlatformSession;
  token: string;
  token_type: "Bearer";
}

export interface PlatformMember {
  public_id: string;
  kind: string;
  role: string;
}

export interface PlatformProfile {
  member: PlatformMember;
  credential_plane: 'platform' | null;
}

export interface PlatformCostUnit {
  cost_unit: string | null;
}

export interface PlatformRetention {
  execution_details_retention_days: number | null;
}

export interface ModelProvider {
  id: string;
  display_name: string | null;
  credentials: string | null;
  enabled: boolean;
  lock_version: number | null;
  configured: boolean;
  material_kind: string | null;
  reauthorization_required: boolean;
  models: number;
  unavailable_until: string | null;
}

export interface Model {
  ref: string;
  provider: string;
  workload: string;
  visible: boolean;
  available: boolean;
  unavailable_reason: JsonValue;
  model_identity: string | null;
  capabilities: JsonObject;
  pricing: ModelPricing;
}

export interface ModelPricing {
  state: JsonValue;
  unit: JsonValue;
  input_per_mtok: JsonValue;
  output_per_mtok: JsonValue;
}

export interface McpConnection {
  public_id: string;
  name: string;
  account_label: string | null;
  enabled: boolean;
  available: boolean;
  tools: JsonValue[];
}

export interface NamedAgent {
  scope: string;
  name: string;
  public_id: string;
  handle: string;
  display_name: string | null;
  description: string;
  agent_identifier: string;
  steward_public_id: string;
  kind: string;
  derived_from_public_id: string;
  system_prompt: string | null;
  summarizer: string | null;
  configuration: AgentConfiguration;
}

export interface AgentConfiguration {
  tool_definitions: JsonValue[];
  kernel_tools: string[];
  runner_executor_public_ids: string[];
  runner_tool_names: string[] | null;
  mcp_tools: JsonValue[];
  approval_mode: string | null;
  approval_rules: JsonValue;
  prompt_mechanism: string | null;
  prompt_template: JsonValue;
  compaction_policy: JsonValue;
  default_model: string | null;
  image_model: string | null;
  lifecycle_hooks: JsonValue;
  fallback_models: string[];
  memory_context_limit: JsonObject | null;
  conversation_reach: string | null;
  delegation_catalog: JsonValue[] | null;
}

export interface IngressSpeaker {
  public_id: string;
  kind: string;
  channel_key: string;
  external_id: string;
  display_name: string;
}

export interface Profile {
  member: Member;
  credential: Credential;
  configuration: AgentConfiguration | null;
  measured_at: string;
}

export interface Member {
  public_id: string;
  handle: string;
  kind: string;
  role: string;
  display_name: string | null;
  agent_identifier: string | null;
}

export interface Credential {
  plane: 'member';
  expires_at: string | null;
}

export interface ToolEntry {
  canonical_name: string;
  name: string;
  effect_profile: JsonObject;
  definition: JsonObject;
  template: string | null;
}

export interface WorkspaceSummary {
  public_id: string;
  name: string;
  access_mode: string;
  state: string;
  dedicated: boolean;
  lock_version: number;
  archived_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface Workspace {
  public_id: string;
  name: string;
  access_mode: string;
  state: string;
  dedicated: boolean;
  lock_version: number;
  archived_at: string | null;
  created_at: string;
  updated_at: string;
  metadata: JsonObject;
  tool_provider_overrides: Record<string, ToolProviderOverride>;
  owner: WorkspaceOwnerSummary;
  creator: WorkspaceCreatorSummary;
}

export interface WorkspaceOwnerSummary {
  public_id: string;
  display_name: string | null;
}

export interface WorkspaceCreatorSummary {
  public_id: string;
  display_name: string | null;
  kind: string;
}

export interface ToolProviderOverride {
  provider_public_id: string;
  display_name: string | null;
  assignment_scope: string | null;
}

export interface WorkspaceMessaging {
  agents: AgentMessaging[];
  lock_version: number;
}

export interface AgentMessaging {
  agent_public_id: string;
  mode: string;
  allowed_sender_public_ids: string[];
}

export interface StoreEntrySummary {
  public_id: string;
  namespace: string;
  key: string;
  lock_version: number;
  created_at: string;
  updated_at: string;
}

export interface StoreEntry {
  public_id: string;
  namespace: string;
  key: string;
  lock_version: number;
  created_at: string;
  updated_at: string;
  value: JsonValue;
}

export interface Principal {
  public_id: string;
  handle: string;
  kind: string;
  display_name: string | null;
  agent_identifier: string | null;
  steward_public_id: string | null;
}
