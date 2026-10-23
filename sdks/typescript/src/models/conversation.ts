import type { InputState, TurnStatus } from '../models.js';
import type { JsonObject, JsonValue } from "../json.js";
import type { RunnerEffects } from "../models.js";

export interface ToolAssembly {
  tool_definitions: JsonValue[];
  environment: JsonObject;
}

export interface Upload {
  public_id: string;
  filename: string;
  content_type: string;
  byte_size: number;
  created_at: string;
}

export interface ScheduleRule {
  kind: string;
  run_at: string | null;
  every_seconds: number | null;
  starts_at: string | null;
  local_time: string | null;
  time_zone: string | null;
}

export interface ScheduleModel {
  model: string;
  reasoning_effort: string | null;
  reasoning_enabled: boolean | null;
}

export interface ScheduleExecution {
  child_conversation_public_id: string;
  input_public_id: string | null;
  turn_public_id: string | null;
  variant_public_id: string | null;
  run_public_id: string | null;
  scheduled_for: string;
  status: string;
  created_at: string;
}

export interface Schedule {
  public_id: string;
  workspace_public_id: string;
  name: string | null;
  prompt: string;
  rule: ScheduleRule;
  model: ScheduleModel | null;
  configuration: JsonObject | null;
  agent_configuration: JsonObject | null;
  model_selection: JsonObject | null;
  fallback_models: string[] | null;
  tool_names: string[] | null;
  approval_mode: string | null;
  answering_user_public_id: string | null;
  speaker_public_id: string | null;
  status: string;
  lock_version: number;
  next_run_at: string | null;
  last_enqueued_at: string | null;
  last_input_public_id: string | null;
  last_error_code: string | null;
  last_execution: ScheduleExecution | null;
  source_run_public_id: string | null;
  source_task_key: string | null;
  conversation_public_id: string | null;
  conversation_title: string | null;
  creating_user_public_id: string | null;
  created_at: string | null;
  updated_at: string | null;
}

export interface ScheduleExecutionPage {
  items: ScheduleExecution[];
  next_after: string | null;
  last_cursor: string | null;
}

export interface ConversationSearchMatch {
  conversation_public_id: string;
  title: string | null;
  turn_public_id: string | null;
  variant_public_id: string | null;
  position: number | null;
  field: string;
  inherited: boolean;
  excerpt: string | null;
  truncated: boolean;
  location: string | null;
}

export interface ConversationFieldPage {
  conversation_public_id: string;
  turn_public_id: string;
  variant_public_id: string;
  field: string;
  inherited: boolean;
  text: string;
  next_after: string | null;
}

export interface ConversationSearchPage {
  matches: ConversationSearchMatch[];
  next_after: string | null;
}

export interface ConversationHistoryTitle {
  public_id: string;
  title: string | null;
}

export interface ConversationHistoryTurn {
  public_id: string;
  position: number;
  kind: string;
  role: string;
  status: string;
  created_at: string;
  prompt: string | null;
  content: string | null;
  steers: string | null;
  truncated: boolean;
}

export interface ConversationHistoryExecution {
  turn_public_id: string;
  variant_public_id: string;
  active: boolean;
  status: string;
  run_public_id: string;
  run_status: string;
  rounds: ThreadRow[];
  next_before: string | null;
  has_older: boolean;
  truncated: boolean;
  details_pruned_at: string | null;
  attention_reason: string | null;
  failure_reason: string | null;
}

export interface ConversationHistoryPage {
  conversation: ConversationHistoryTitle;
  turns: ConversationHistoryTurn[];
  before_position: number | null;
  after_position: number | null;
  has_older: boolean;
  has_newer: boolean;
  truncated: boolean;
  execution: ConversationHistoryExecution | null;
  execution_included: boolean;
}

export interface AddressedTo {
  role: string;
  executor_public_id: string | null;
  presence: string | null;
  last_seen_at: string | null;
}

export interface ThreadRow {
  task_key: string;
  mainline: boolean;
  status: string;
  visibility: string;
  text_preview: string | null;
  text_bytes: number | null;
  usage: JsonObject | null;
  error: JsonObject | null;
  compacted_before: string | null;
  pruned_before: string | null;
  started_at: string | null;
  completed_at: string | null;
  calls: ThreadCalls;
  branches: string[];
}

export interface ThreadCalls {
  count: number;
  items: ThreadCall[];
}

export interface ThreadCall {
  task_key: string;
  tool_call_id: string | null;
  name: string;
  tool: string | null;
  status: string;
  is_error: boolean | null;
  title: string | null;
  metadata: JsonObject | null;
  output_preview: string | null;
  output_bytes: number | null;
  started_at: string | null;
  completed_at: string | null;
}

export interface InputMaterialization {
  input_public_id: string;
  turn_public_id: string;
  variant_public_id: string;
  run_public_id: string | null;
}

export interface ConversationReasoning {
  task_key: string | null;
  model: ConversationModel;
  available: boolean;
  text: string | null;
}

export interface ConversationReasoningPage {
  items: ConversationReasoning[];
  next_before: string | null;
  has_older: boolean;
}

export interface ConversationSummary {
  public_id: string;
  workspace_public_id: string;
  title: string | null;
  lock_version: number;
  answering_user_public_id: string;
  archived_at: string | null;
  billing_subject: string | null;
  parent: ConversationParent | null;
  source_conversation_public_id: string | null;
  forked_from_turn_public_id: string | null;
  forked_from_variant_public_id: string | null;
  side: boolean;
  active_turn_public_id: string | null;
  context_revision: number;
  last_activity_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface Conversation {
  public_id: string;
  workspace_public_id: string;
  title: string | null;
  lock_version: number;
  answering_user_public_id: string;
  archived_at: string | null;
  billing_subject: string | null;
  parent: ConversationParent | null;
  source_conversation_public_id: string | null;
  forked_from_turn_public_id: string | null;
  forked_from_variant_public_id: string | null;
  side: boolean;
  active_turn_public_id: string | null;
  context_revision: number;
  last_activity_at: string | null;
  created_at: string;
  updated_at: string;
  metadata: JsonObject;
  input_queue: InputQueue;
  latest_event_cursor: string | null;
  context: ConversationContextReport | null;
  usage_summary: ConversationUsageSummary;
  default_runner: DefaultRunner | null;
  access: ConversationAccess;
  memory_context: JsonObject | null;
  effective_memory_context: JsonObject;
  agent_configuration_present: boolean;
  cost_limit: string | null;
  cost_limit_reached: boolean;
}

export interface ConversationAccess {
  default: string;
  entries: ConversationAccessEntry[];
}

export interface ConversationAccessEntry {
  user_public_id: string;
  handle: string;
  kind: string;
  display_name: string | null;
  level: string;
}

export interface DefaultRunner {
  executor_public_id: string;
  display_name: string | null;
  presence: string;
  last_seen_at: string | null;
}

export interface ConversationParent {
  public_id: string;
  spawn_node_key: string | null;
  label: string | null;
}

export interface InputQueue {
  limit: number;
  held: number;
}

export interface ConversationContextReport {
  used_tokens: number | null;
  input_tokens: number | null;
  output_tokens: number | null;
  cache_read_tokens: number | null;
  window_tokens: number | null;
  used_percent: number | null;
  as_of_model: ConversationModel | null;
}

export interface ConversationUsageSummary {
  request_count: number;
  input_tokens: number;
  cache_read_tokens: number;
  uncached_input_tokens: number;
  cache_creation_tokens: number;
  cache_hit_rate: number | null;
  output_tokens: number;
  reasoning_tokens: number;
  total_tokens: number;
  cost_amount: string;
  cost_complete: boolean;
  cost_unit: string | null;
}

export interface ConversationModel {
  provider_id: string | null;
  model_ref: string | null;
  reasoning_effort: string | null;
  reasoning_enabled: boolean | null;
}

export interface InputList {
  items: Input[];
  input_queue: InputQueue;
}

export interface Input {
  public_id: string;
  queue_position: number;
  state: InputState;
  kind: string;
  role: string;
  delivery_mode: string;
  expected_steering_run_public_id: string | null;
  context_mode: string | null;
  context_options: JsonValue;
  tool_names: string[] | null;
  approval_mode: string | null;
  instructions: string | null;
  blocked_reason: string | null;
  text: string | null;
  attachments: UploadRef[] | null;
  steps: JsonValue[] | null;
  lock_version: number;
  created_at: string;
  origin: string;
  sender_conversation_public_id: string | null;
  callback_result: CallbackResult | null;
  answering_user_public_id: string;
  speaker: ConversationSpeaker | ConversationIngressSpeaker;
  deliver_at: string | null;
}

export interface ConversationSpeaker {
  user_public_id: string;
  handle: string;
  kind: string;
  display_name: string | null;
}

export interface ConversationIngressSpeaker {
  speaker_public_id: string;
  kind: string;
  display_name: string;
}

export interface UploadRef {
  public_id: string;
  filename: string;
  content_type: string;
  byte_size: number;
}

export interface CallbackResult {
  conversation_public_id: string;
  input_public_id: string;
  turn_public_id: string;
  variant_public_id: string;
  requester_speaker_public_id: string | null;
}

export interface CallbackSource {
  input_public_id: string;
  origin: string;
  sender_conversation_public_id: string | null;
  sender_run_public_id: string | null;
  sender_task_key: string | null;
  result: CallbackResult;
}

export interface TurnPage {
  items: Turn[];
  before_position: number | null;
  after_position: number | null;
}

export interface Turn {
  public_id: string;
  input_public_id: string | null;
  callback_sources: CallbackSource[];
  position: number;
  kind: string;
  role: string;
  status: TurnStatus;
  visibility: string;
  inherited: boolean;
  reference: boolean;
  origin: string | null;
  sender_conversation_public_id: string | null;
  sender_run_public_id: string | null;
  sender_task_key: string | null;
  active_variant: Variant | null;
  running_variant: Variant | null;
  created_at: string;
  answering_user_public_id: string;
  speaker: ConversationSpeaker | ConversationIngressSpeaker | null;
}

export interface Variant {
  model_selection: JsonObject | null;
  fallback_models: string[] | null;
  public_id: string;
  origin_variant_public_id: string | null;
  source: string;
  status: TurnStatus;
  model: ConversationModel | null;
  content_preview: string | null;
  content: string | null;
  prompt_text: string | null;
  active: boolean;
  run_public_id: string | null;
  rounds: JsonValue[] | null;
  attachments: UploadRef[] | null;
  runner_effects: RunnerEffects | null;
  details_pruned_at: string | null;
  memory_context: JsonObject | null;
}

export interface Checkpoint {
  raw: JsonValue;
  hash: string | null;
  store: string | null;
  skipped: JsonValue;
  outside: string[];
  ignored: string[];
}

export interface VariantRead {
  variant: Variant;
  turn_public_id: string;
  turn_inherited: boolean;
}

export interface VariantDeck {
  items: Variant[];
  turn_public_id: string;
  turn_inherited: boolean;
}

export interface ConversationCompaction {
  turn_public_id: string;
  position: number;
  kind: string;
  turn_status: string;
  task_key: string | null;
  summary_task_key: string | null;
}

export interface ConversationRegeneration {
  turn_public_id: string;
  turn_status: string;
  variant: Variant;
}

export interface TranscriptItem {
  type: string;
  turn_public_id: string | null;
  variant_public_id: string | null;
  run_public_id: string | null;
  task_key: string | null;
  turn: Turn | null;
  payload: JsonObject;
}

export interface MemoryDocument {
  collection_public_id: string;
  public_id: string;
  lock_version: number;
  path: string;
  bytesize: number;
  description: string | null;
  content: string | null;
  written_at: string;
}

export interface PromptDocument {
  slot: string;
  role: string;
  bytesize: number;
  version: number;
  content: string | null;
  written_at: string;
}

export interface SealedRequest {
  entries: JsonValue[];
  request_options: JsonObject;
}

export interface InputEstimate {
  input_tokens: number;
  tokenizer_exact: boolean;
  catalog_input_token_limit: number | null;
  advisory_input_token_limit: number | null;
  message_count: number;
  history: ConversationHistoryEvidence;
  rendered: RenderedEstimate | null;
}

export interface RenderedEstimate {
  mechanism: string;
  entries: JsonValue[];
  storage: EstimateStorage;
  blocks: ContextBlockEvidence[];
  memory: MemoryEvidence;
  slots: JsonObject;
}

export interface EstimateStorage {
  bytes: number;
  bound: number;
  within_bound: boolean;
  refusal: string | null;
}

export interface ContextBlockEvidence {
  block: string;
  index: number;
  type: string;
  role: string | null;
  state: string;
  tokens: number;
  allocated_tokens: number | null;
}

export interface MemoryEvidence {
  included: number;
  omitted: number;
}

export interface ConversationHistoryEvidence {
  selected: number;
  skipped: number;
  skipped_reason: string | null;
  compacted: number;
}

export interface InferenceRequestInputEstimate {
  input_tokens: number;
  tokenizer_exact: boolean;
  catalog_input_token_limit: number | null;
  advisory_input_token_limit: number | null;
  model: InferenceRequestModel;
}

export interface InferenceRequestSummary {
  public_id: string;
  workload: string;
  status: string;
  model: InferenceRequestModel;
  billing_subject: string | null;
  created_at: string;
  updated_at: string;
}

export interface InferenceRequest {
  public_id: string;
  workload: string;
  status: string;
  model: InferenceRequestModel;
  billing_subject: string | null;
  created_at: string;
  updated_at: string;
  model_selection: JsonObject | null;
  fallback_models: string[] | null;
  usage_summary: InferenceRequestUsageSummary;
  result: InferenceRequestResult | null;
}

export interface InferenceRequestModel {
  provider_id: string;
  model_ref: string;
  reasoning_effort: string | null;
  reasoning_enabled: boolean | null;
}

export interface InferenceRequestResult {
  status: string;
  finish_quality: string | null;
  refusal_category: string | null;
  output_text: string | null;
  usage: InferenceRequestUsage | null;
  timing: InferenceRequestTiming | null;
  error: InferenceRequestError | null;
  reasoning: InferenceRequestReasoning | null;
  output_files: InferenceRequestFile[] | null;
  embeddings: InferenceRequestEmbedding[] | null;
  model_change: InferenceRequestModelChange | null;
}

export interface InferenceRequestEmbedding {
  index: number;
  vector: number[];
}

export interface InferenceRequestModelChange {
  from: string;
  to: string;
  reason: string;
  category: string | null;
}

export interface InferenceRequestFile {
  index: number;
  filename: string;
  content_type: string;
  byte_size: number;
}

export interface InferenceRequestUsage {
  usage_record_public_id: string;
  input_tokens: number | null;
  cache_read_tokens: number | null;
  uncached_input_tokens: number | null;
  cache_creation_tokens: number | null;
  cache_hit_rate: number | null;
  output_tokens: number | null;
  reasoning_tokens: number | null;
  total_tokens: number | null;
  cost_amount: string | null;
  cost_unit: string | null;
  cost_complete: boolean;
}

export interface InferenceRequestUsageSummary {
  request_count: number;
  input_tokens: number;
  cache_read_tokens: number;
  uncached_input_tokens: number;
  cache_creation_tokens: number;
  cache_hit_rate: number | null;
  output_tokens: number;
  reasoning_tokens: number;
  total_tokens: number;
  cost_amount: string;
  cost_complete: boolean;
}

export interface InferenceRequestTiming {
  duration_ms: number | null;
  time_to_first_token_ms: number | null;
}

export interface InferenceRequestError {
  code: string;
  attempt_budget_spent: boolean;
}

export interface InferenceRequestReasoning {
  available: boolean;
  text: string | null;
}

export interface InferenceRequestEventPage {
  items: InferenceRequestEvent[];
  next_after: string | null;
  watermark: number;
}

export interface InferenceRequestEvent {
  public_id: string;
  sequence: number;
  cursor: string;
  type: string;
  resource_type: string;
  resource_public_id: string;
  occurred_at: string;
  payload: JsonValue;
}

export interface EventPage {
  items: Event[];
  next_after: string | null;
  watermark: number;
}

export interface Event {
  public_id: string;
  sequence: number;
  cursor: string;
  type: string;
  resource_type: string;
  resource_public_id: string;
  occurred_at: string;
  payload: JsonValue;
}

export interface ProgressFrame {
  type: string;
  run_public_id: string | null;
  conversation_public_id: string | null;
  task_key: string | null;
  tool_name: string | null;
  process_id: string | null;
  executor_public_id: string | null;
  at: string;
  payload: JsonObject;
}

export interface MemoryCollection {
  public_id: string;
  name: string | null;
  description: string | null;
  scope: string;
  owner_public_id: string;
  speaker_public_id: string | null;
  is_default: boolean;
  archived_at: string | null;
  lock_version: number;
  created_at: string;
  updated_at: string;
  writable: boolean;
  manageable: boolean;
}
export interface ResolvedMemoryBinding {
  name: string;
  source: JsonObject;
  scope: string;
  access: string;
  collection_public_id: string | null;
  owner_public_id: string;
  speaker_public_id: string | null;
  state: string;
}
export interface MemoryBindings { bindings: ResolvedMemoryBinding[]; }
