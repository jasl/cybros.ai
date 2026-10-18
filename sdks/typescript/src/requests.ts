import type { JsonObject, JsonValue } from './json.js';
import type { Step } from './steps.js';
export interface ListOptions { after?: string; limit?: number; order?: 'asc' | 'desc'; }
export interface ScheduleList extends ListOptions { workspace_public_id?: string; status?: 'active' | 'paused' | 'canceled' | 'completed'; }
export interface ModelUsageAnalysisQuery {
  from?: string;
  to?: string;
  provider_id?: string;
  catalog_model_ref?: string;
  workload?: string;
  status?: 'succeeded' | 'failed' | 'discarded' | 'abandoned';
  group_by?: 'provider_id' | 'catalog_model_ref' | 'workload' | 'status';
  rank_by?: 'request_count' | 'total_tokens' | 'cost_amount';
  limit?: number;
}
export interface WorkAnalysisQuery extends ModelUsageAnalysisQuery { workspace_public_id?: string; agent_public_id?: string; }
export interface EventOptions { after?: string; limit?: number; }
export interface Version { lock_version: number; }
export interface ModelSelection { model?: string; reasoning_effort?: string | null; reasoning_enabled?: boolean | null; }
export interface ToolMetadata { defer_loading?: boolean; route?: { kind: 'runner'; runner_executor_public_id: string; tool_name: string } | { kind: 'mcp'; connection_public_id: string; tool_name: string }; effect_profile?: JsonObject; output_schema?: JsonObject; }
export interface NestedFunctionTool extends ToolMetadata { type: 'function'; function: { name: string; description?: string; parameters?: JsonObject; strict?: boolean }; }
export interface FlatFunctionTool extends ToolMetadata { type: 'function'; name: string; description?: string; parameters?: JsonObject; strict?: boolean; }
export interface ToolAlias { type: 'function'; function: { name: string }; canonical: string; params?: Record<string, { maps_to: string; invert?: boolean; description?: string }>; omit?: string[]; description?: string; defer_loading?: boolean; }
/** Provider-native, non-function declarations retain the provider's own JSON grammar. */
export type ProviderNativeTool = JsonObject & { type: string };
export type ToolDefinition = NestedFunctionTool | FlatFunctionTool | ToolAlias | ProviderNativeTool;
export type InlineBlock = { slot: 'system_prompt' | 'character' | 'persona'; text: string; role?: 'system' | 'developer' | 'user' | 'assistant'; position?: never } | { slot?: never; text: string; role: 'developer' | 'user'; position?: 'lead' | 'tail' };
export interface McpToolImport { connection_public_id: string; tool_name: string; name: string; }
export interface AgentConfigurationInput {
  tool_definitions?: ToolDefinition[] | null; approval_mode?: 'bypass' | 'ask' | 'rules' | null;
  approval_rules?: ApprovalRule[] | null; prompt_mechanism?: 'default' | 'raw' | 'assembly' | null; compaction_policy?: JsonValue;
  prompt_template?: JsonValue; default_model?: string | null; image_model?: string | null; lifecycle_hooks?: JsonValue;
  fallback_models?: string[]; kernel_tools?: string[] | null; runner_executor_public_ids?: string[] | null;
  runner_tool_names?: string[] | null; mcp_tools?: McpToolImport[] | null; memory_context_limit?: JsonObject | null;
  conversation_reach?: string | null; delegation_catalog?: JsonValue[] | null;
}
export interface DeclareConfiguration { configuration: AgentConfigurationInput; prompt_documents?: Partial<Record<'system_prompt' | 'summarizer', { content: string; role?: 'system' | 'developer' | 'user' } | null>> | null; }
export interface DeclareAgent {
  scope: 'instance' | 'steward'; description: string; configuration: AgentConfigurationInput;
  display_name?: string | null; system_prompt?: string | null; summarizer?: string | null; create_only?: boolean;
}
export interface RegisterIngressSpeaker { channel_key: string; external_id: string; display_name: string; }
export interface CreateWorkspace { name: string; access_mode?: 'account_wide' | 'private'; metadata?: JsonObject; }
export interface UpdateWorkspace extends Version { name?: string; metadata?: JsonObject; }
export interface WorkspaceList extends ListOptions { state?: string; dedicated_to_current_agent?: boolean; }
export type AccessEntry = ({ user_public_id: string; handle?: never } | { user_public_id?: never; handle: string }) & { level: 'full' | 'read' | 'none' };
export interface ConversationAccessInput { default: 'full' | 'read' | 'none'; entries?: AccessEntry[]; }
export interface CreateConversation {
  title?: string | null; metadata?: JsonObject; billing_subject?: string | null; cost_limit?: string | null;
  default_runner_executor_public_id?: string | null; answering_user_public_id?: string;
  access?: ConversationAccessInput; memory_context?: JsonObject | null;
}
export interface ConversationList extends ListOptions { order_by?: 'public_id' | 'last_activity_at'; answering_user_public_id?: string; }
export interface WorkspaceConversationList extends ConversationList { side?: boolean; }
export interface AllConversationList extends ConversationList { archived?: boolean; metadata_key?: string; metadata_value?: string; }
export type ConversationChildrenList = Omit<ConversationList, 'answering_user_public_id'>;
export interface ConversationSearch { query: string; archived?: 'exclude' | 'include' | 'only'; include_auxiliary?: boolean; answering_user_public_id?: string; limit?: number; after?: string; }
export type ConversationFieldOptions = { location?: string; after?: never } | { location?: never; after?: string };
export interface UpdateConversation extends Version { title?: string | null; metadata?: JsonObject; cost_limit?: string | null; }
export interface ForkConversation { turn_public_id?: string; variant_public_id?: string; title?: string | null; side?: boolean; }
export interface InputConfiguration {
  model?: ModelSelection; configuration?: JsonObject | null; agent_configuration?: JsonObject | null;
  model_selection?: ModelSelectionIntent | null; fallback_models?: string[] | null; history?: { max_entries?: number; token_budget_share?: number } | null;
  reasoning_replay?: { mode: 'none' | 'last_turn' | 'all' } | null; context_mode?: 'assembled' | 'raw'; inline?: InlineBlock[] | null;
  instructions?: string; variables?: JsonObject;
  tool_names?: string[] | null; approval_mode?: 'bypass' | 'ask' | 'rules';
}
export interface CreateInput extends InputConfiguration {
  kind: 'message' | 'direct_reply'; text?: string; entries?: JsonObject[]; attachments?: string[];
  role?: 'user' | 'assistant' | 'system' | 'tool'; delivery_mode?: 'queue' | 'steer' | 'steer_now'; speaker_public_id?: string;
  answering_user_public_id?: string; deliver_at?: string; deliver_in?: string; visible_in_context?: boolean; steps?: Step[];
  expected_context_revision?: number; expected_tail_turn_public_id?: string | null; expected_steering_run_public_id?: string;
}
export interface RunInput { kind: 'message'; text?: string; entries?: JsonObject[]; attachments?: string[]; role?: 'user'; delivery_mode?: 'queue' | 'steer' | 'steer_now'; speaker_public_id?: string; }
export type UpdateRunInput = Partial<Pick<RunInput, 'text' | 'entries' | 'attachments' | 'delivery_mode'>> & { expected_lock_version?: number };
export type UpdateInput = Partial<Omit<CreateInput, 'kind' | 'role' | 'speaker_public_id' | 'answering_user_public_id' | 'expected_context_revision' | 'expected_tail_turn_public_id' | 'expected_steering_run_public_id'>> & { expected_lock_version?: number };
export interface TurnList { after_position?: number; before_position?: number; limit?: number; include_hidden?: boolean; }
export interface HistoryOptions { after_position?: number; before_position?: number; limit?: number; around_turn_public_id?: string; include_execution?: boolean; execution_before?: string; execution_prefix?: string; }
export interface EstimateInput extends Pick<InputConfiguration, 'model' | 'configuration' | 'agent_configuration' | 'model_selection' | 'fallback_models' | 'history' | 'reasoning_replay' | 'inline' | 'variables'> { prompt?: string; render?: boolean; answering_user_public_id?: string; speaker_public_id?: string; template?: JsonObject; }
export interface CreateRun {
  steps: Step[]; approval_mode: 'bypass' | 'ask' | 'rules'; billing_subject?: string | null;
  prompt_mechanism?: 'default' | 'raw' | 'assembly'; approval_rules?: ApprovalRule[]; default_runner_executor_public_id?: string | null;
  speaker_public_id?: string; model_selection?: ModelSelectionIntent | null; fallback_models?: string[] | null;
}
export interface RunList extends ListOptions { status?: string | string[]; attention?: string; from?: string; to?: string; answering_user_public_id?: string; agent_public_id?: string; executor_public_id?: string; kind?: 'all' | 'standalone' | 'conversation'; }
export interface AllRunList extends RunList { workspace_public_id?: string; }
export interface AttentionList extends ListOptions { workspace_public_id?: string; view?: 'actionable' | 'following'; }
export interface WorkReportQuery { workspace_public_id?: string; agent_public_id?: string; from?: string; to?: string; unit?: 'hour' | 'day'; }
export type AppendResolution = string | { task: string; content?: JsonValue; outcome?: 'completed' };
export interface AppendTasks { steps: Step[]; resolve?: AppendResolution[]; expected_revision?: number; }
export interface ResolveTask { resolution_token?: string; content?: JsonValue; structured_content?: JsonValue; result_type?: string; outcome?: 'completed' | 'failed'; }
export interface ToolCall { runner_executor_public_id: string; tool: string; input?: JsonObject; timeout_ms?: number; approval_rules?: ApprovalRule[]; }
export interface CreateStoreEntry { namespace: string; key: string; value: JsonValue; }
export interface MemoryVersion { expected_public_id: string | null; expected_lock_version: number | null; }
export interface ExistingMemoryVersion { expected_public_id: string; expected_lock_version: number; }
export interface WriteMemory extends MemoryVersion { path: string; content: string; description?: string | null; }
export interface EditMemory extends ExistingMemoryVersion { path: string; old_text: string; new_text: string; }
export interface GrepMemory { pattern: string; path?: string; ignore_case?: boolean; limit?: number; }
export type ScheduleRuleInput = { kind: 'once'; run_at: string } | { kind: 'interval'; every_seconds: number; starts_at: string } | { kind: 'daily'; local_time: string; time_zone: string };
export interface CreateSchedule extends Pick<InputConfiguration, 'model' | 'configuration' | 'model_selection' | 'fallback_models' | 'tool_names' | 'approval_mode'> {
  prompt: string; rule: ScheduleRuleInput; name?: string; answering_user_public_id?: string; speaker_public_id?: string;
  source_run_public_id?: string; source_task_key?: string;
}
export interface UpdateSchedule extends Partial<Omit<CreateSchedule, 'source_run_public_id' | 'source_task_key'>> { expected_lock_version: number; }
export type Workload = 'text_generation' | 'embedding' | 'image_generation' | 'speech_generation' | 'transcription';
export interface CreateInferenceRequest {
  workload: Workload; model: ModelSelection; input: JsonValue;
  configuration?: JsonObject; upload_public_ids?: string[]; billing_subject?: string | null;
  model_selection?: ModelSelectionIntent | null; fallback_models?: string[] | null;
}
export type EstimateInferenceRequest = Omit<CreateInferenceRequest, 'billing_subject'>;
export interface EffectProfile { kind: 'pure' | 'read_only' | 'write'; destructive: boolean; effect_scope: 'closed' | 'open'; idempotency: 'intrinsic' | 'keyed' | 'none'; reconciliation: 'none' | 'lookup'; }
export interface AnnouncedTool { name: string; effect_profile: EffectProfile; timeout_ms?: number; description?: string; input_schema?: JsonObject & { type: 'object' }; mcp?: { server_key: string; tool_name: string }; }
export interface ExecutorAnnouncement { tools: AnnouncedTool[]; documents?: { name: string; description: string }[] | null; environment?: JsonObject | null; }
export interface TaskProgress { run_public_id: string; task_key: string; claim_token: string; text_tail?: string; structured?: JsonValue; process_id?: never; }
export type ProcessProgress = ({ conversation_public_id: string; run_public_id?: never } | { conversation_public_id?: never; run_public_id: string }) & { process_id: string; source: { run_public_id: string; task_key: string; claim_token: string }; lines?: string[]; exit?: number | null; task_key?: never };
export type ProgressFrameInput = TaskProgress | ProcessProgress;
export interface CommitTask extends Omit<ResolveTask, 'resolution_token'> { claim_token: string; is_error?: boolean; title?: string; metadata?: JsonObject; }
export type OperationRequest = JsonObject;

export interface ApprovalRule { tool: string; verdict: 'allow' | 'ask' | 'deny'; path?: string; match?: string; reason?: string; origin?: 'model' | 'author' | 'kernel'; }
export interface ModelSelectionIntent { source: 'default' | 'inherited' | 'explicit'; model: string; constraint: 'any' | 'model' | 'provider' | 'route'; alternatives?: string[]; }
export interface PlatformRunnerList extends ListOptions {
  kind?: 'runner' | 'tool_provider';
  status?: 'active' | 'revoked';
}
