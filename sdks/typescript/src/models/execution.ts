import type { RunStatus, TaskStatus, TurnStatus } from '../models.js';
import type { JsonObject, JsonValue } from "../json.js";
import type { AddressedTo, Checkpoint, DefaultRunner, InputQueue, ThreadRow } from "../models.js";

export interface ExecutorDescription {
  executor: ExecutorAddress;
  measured_at: string;
}

export interface ExecutorAddress {
  public_id: string;
  kind: string;
  status: string;
  display_name: string | null;
  credential_epoch: number;
  presence: string;
  last_seen_at: string | null;
  connected_at: string | null;
  agent_public_id: string | null;
  registration_identifier: string | null;
  assignment_scope: string | null;
  assignment_agent_public_id: string | null;
}

export interface DiscoveredExecutor {
  public_id: string;
  kind: string;
  display_name: string | null;
  status: string;
  assignment_scope: string;
  assignment_agent_public_id: string | null;
  served_tools: ServedTool[];
  environment: JsonObject;
  served_documents: ServedDocument[];
  presence: string;
  last_seen_at: string | null;
  connected_at: string | null;
}

export interface ServedTool {
  name: string;
  effect_profile: JsonObject;
  timeout_ms: number | null;
  description: string | null;
  input_schema: JsonObject | null;
  mcp: JsonObject | null;
}

export interface ServedDocument {
  name: string;
  description: string;
}

export interface OperationContext {
  tools: JsonValue[];
  model_defaults: JsonObject;
  environment: JsonObject | null;
}

export interface OperationRefusal {
  code: string;
  message: string;
}

export interface OperationEvent {
  type: string;
  position: number;
  key: string;
  request: JsonObject | null;
  receipt: JsonObject | null;
  outcome: JsonValue;
  refusal: OperationRefusal | null;
}

export interface TaskOperations {
  context: OperationContext;
  trace: OperationEvent[];
  position: number;
  next_after: number | null;
}

export interface OperationRead {
  observation: OperationEvent | null;
  position: number;
}

export interface InboxTask {
  kind: string;
  run_public_id: string;
  workspace_public_id: string;
  conversation_public_id: string | null;
  parent_public_id: string | null;
  task_key: string;
  prompt: string | null;
  options: string[] | null;
  multi: boolean | null;
  fields: JsonValue[] | null;
  tool_name: string | null;
  tool_alias: string | null;
  tool_input: JsonObject;
  scope: JsonObject | null;
  tool_call_id: string | null;
  started_at: string | null;
  deadline_at: string | null;
  timeout_ms: number | null;
  claimed: boolean;
  addressed_to: AddressedTo | null;
  target: TaskTarget | null;
  effect_profile: JsonObject | null;
}

export interface ClaimedBy {
  executor_public_id: string;
}

export interface TaskTarget {
  executor_public_id: string | null;
  display_name: string | null;
  kind: string | null;
  connection_public_id: string | null;
  account_label: string | null;
  tool_name: string | null;
}

export interface Run {
  model_selection: JsonObject | null;
  fallback_models: string[] | null;
  requester_speaker_public_id: string | null;
  public_id: string;
  workspace_public_id: string | null;
  status: RunStatus;
  failure_reason: string | null;
  deliverable_task_key: string | null;
  tasks: Task[];
  task_progress: RunProgress;
  attention: RunAttention | null;
  turn: RunTurn | null;
  input_queue: InputQueue | null;
  started_at: string | null;
  paused_at: string | null;
  completed_at: string | null;
  details_pruned_at: string | null;
  created_at: string | null;
  updated_at: string | null;
  default_runner: DefaultRunner | null;
  prompt_mechanism: string | null;
  approval_mode: string | null;
  runner_effects: RunnerEffects | null;
}

export interface Task {
  key: string;
  kind: string;
  status: TaskStatus;
  lifetime: string;
  wake: string;
  after: string[];
  waiting_on: string[];
  on_failure: string | null;
  failure_resolution: string | null;
  tool_name: string | null;
  tool_alias: string | null;
  result: JsonObject | null;
  error: JsonObject | null;
  visibility: string | null;
  created_at: string | null;
  started_at: string | null;
  completed_at: string | null;
  model: JsonObject | null;
  workload: string | null;
  result_delivered_at: string | null;
  addressed_to: AddressedTo | null;
  target: TaskTarget | null;
  claimed_by: ClaimedBy | null;
  approval: JsonValue;
}

export interface RunProgress {
  total: number;
  waiting: number;
  needs_approval: number;
  running: number;
  dispatched: number;
  awaiting_input: number;
  completed: number;
  failed: number;
  canceled: number;
  timed_out: number;
  uncertain: number;
  skipped: number;
}

export interface RunAttention {
  reason: string;
  blocked_task_keys: string[];
  blocked_task_overflow: JsonValue;
}

export interface TaskDetail {
  model_selection: JsonObject | null;
  fallback_models: string[] | null;
  task: Task;
  declaring_task_key: string | null;
  output: string | null;
  output_preview: string | null;
  content: JsonValue;
  structured_content: JsonValue;
  prompt: string | null;
  options: string[] | null;
  multi: boolean | null;
  fields: JsonValue[] | null;
  tool_input: JsonObject | null;
  effect_profile: JsonObject | null;
  request_bytes: number | null;
  instructions: string | null;
  tool_definitions: JsonValue[] | null;
  title: string | null;
  metadata: JsonObject | null;
  wait: JsonObject | null;
}

export interface CompactedRound {
  task: Task;
  summary_task_key: string;
}

export interface AppendedTasks {
  accepted_task_keys: string[];
  steps: JsonValue[];
  deliverable_task_key: string | null;
  revision: JsonValue;
  resolution_tokens: JsonObject;
  replayed: boolean;
}

export interface RunTurn {
  status: TurnStatus;
  failure_reason_key: string | null;
  public_id: string | null;
  conversation_public_id: string | null;
  answering_user_public_id: string | null;
  model: JsonObject | null;
}

export interface RunTranscript {
  rounds: ThreadRow[];
  next_before: JsonValue;
  has_older: boolean;
}

export interface RunGraph {
  nodes: GraphNode[];
  edges: GraphEdge[];
  mermaid: string;
}

export interface GraphNode {
  key: string;
  kind: string;
  status: string;
  visibility: string;
  deliverable: boolean;
  lifetime: string;
  wake: string;
  input_from: string[];
  result_from: string[];
  mainline: boolean | null;
  error_key: string | null;
  join: JsonObject | null;
  expansion_parent: string | null;
}

export interface GraphEdge {
  from: string;
  to: string;
  structural: boolean;
}

export interface RunPhases {
  phases: RunPhase[];
  current: JsonValue;
  background: BackgroundTask[];
  spend: JsonObject;
}

export interface RunPhase {
  label: string;
  keys: string[];
  done: number;
  total: number;
  status: string;
}

export interface BackgroundTask {
  key: string;
  status: string;
  result_delivered_at: string | null;
}

export interface ClaimedTask {
  task: InboxTask;
  claim_token: string;
  deadline_at: string | null;
}

export interface ClaimStatus {
  active: boolean;
}

export interface RunnerEffects {
  status: string;
  reason: string | null;
  runners: RunnerEffect[];
}

export interface RunnerEffect {
  runner_executor_public_id: string;
  run_public_id: string;
  task_key: string;
  checkpoint: Checkpoint | null;
  checkpoint_present: boolean;
}

/** Permission for this task's live data, bounded from the HTTP request start. */
export interface TaskRealtime {
  status: string;
  reason: string | null;
  connection_id: string | null;
  offer_sdp: string | null;
  answer_sdp: string | null;
  max_age_ms: number;
}
