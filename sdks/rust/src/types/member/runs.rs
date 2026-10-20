use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Task {
    pub workload: Option<String>,
    pub tool_alias: Option<String>,
    pub lifetime: String,
    pub wake: String,
    pub key: String,
    pub kind: crate::types::names::TaskKind,
    pub status: crate::types::names::TaskStatus,
    #[serde(default)]
    pub after: Vec<String>,
    #[serde(default)]
    pub waiting_on: Vec<String>,
    pub on_failure: Option<String>,
    pub failure_resolution: Option<String>,
    pub tool_name: Option<String>,
    pub result: Option<JsonObject>,
    pub error: Option<JsonObject>,
    pub visibility: Option<String>,
    pub created_at: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub model: Option<JsonObject>,
    pub result_delivered_at: Option<String>,
    pub target: Option<TaskTarget>,
    pub addressed_to: Option<AddressedTo>,
    pub claimed_by: Option<ClaimedBy>,
    pub approval: Option<JsonObject>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunTurn {
    pub status: crate::types::names::TurnStatus,
    pub failure_reason_key: Option<String>,
    pub public_id: Option<String>,
    pub conversation_public_id: Option<String>,
    pub answering_user_public_id: Option<String>,
    pub model: Option<JsonObject>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskDetail {
    pub executor_context: Option<JsonObject>,
    pub effect_profile: Option<JsonObject>,
    pub model_selection: Option<JsonObject>,
    pub fallback_models: Option<Vec<String>>,
    pub declaring_task_key: Option<String>,
    pub wait: Option<JsonObject>,
    pub prompt: Option<String>,
    pub options: Option<Vec<String>>,
    pub multi: Option<bool>,
    pub fields: Option<Vec<JsonObject>>,
    pub tool_input: Option<JsonObject>,
    pub request_bytes: Option<i64>,
    pub instructions: Option<String>,
    pub tool_definitions: Option<Vec<JsonObject>>,
    pub title: Option<String>,
    pub metadata: Option<JsonObject>,
    #[serde(flatten)]
    pub task: Task,
    pub output: Option<String>,
    pub output_preview: Option<String>,
    #[serde(default)]
    pub content: Value,
    #[serde(default)]
    pub structured_content: Value,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct RunProgress {
    pub total: i64,
    pub waiting: i64,
    pub needs_approval: i64,
    pub running: i64,
    pub dispatched: i64,
    pub awaiting_input: i64,
    pub completed: i64,
    pub failed: i64,
    pub canceled: i64,
    pub timed_out: i64,
    pub uncertain: i64,
    pub skipped: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunAttention {
    pub reason: String,
    #[serde(default)]
    pub blocked_task_keys: Vec<String>,
    #[serde(default)]
    pub blocked_task_overflow: Value,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Run {
    pub model_selection: Option<JsonObject>,
    pub fallback_models: Option<Vec<String>>,
    pub requester_speaker_public_id: Option<String>,
    pub runner_effects: Option<RunnerEffects>,
    pub approval_mode: Option<String>,
    pub public_id: String,
    pub workspace_public_id: Option<String>,
    pub status: crate::types::names::RunStatus,
    pub failure_reason: Option<String>,
    pub deliverable_task_key: Option<String>,
    #[serde(default)]
    pub tasks: Vec<Task>,
    #[serde(default)]
    pub task_progress: RunProgress,
    pub attention: Option<RunAttention>,
    pub turn: Option<RunTurn>,
    pub input_queue: Option<InputQueue>,
    pub started_at: Option<String>,
    pub paused_at: Option<String>,
    pub completed_at: Option<String>,
    pub details_pruned_at: Option<String>,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
    pub default_runner: Option<DefaultRunner>,
    pub prompt_mechanism: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CompactedRound {
    pub task: Task,
    pub summary_task_key: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CreatedRun {
    pub run: Run,
    pub receipt: Option<AppendReceipt>,
    #[serde(default)]
    pub replayed: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AppendedTasks {
    pub accepted_task_keys: Vec<String>,
    pub steps: Vec<Value>,
    pub deliverable_task_key: Option<String>,
    pub revision: Option<i64>,
    pub resolution_tokens: std::collections::BTreeMap<String, crate::credentials::SecretString>,
    #[serde(default)]
    pub replayed: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunPhase {
    pub label: String,
    pub keys: Vec<String>,
    pub done: i64,
    pub total: i64,
    pub status: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackgroundTask {
    pub key: String,
    pub status: crate::types::names::TaskStatus,
    pub result_delivered_at: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunPhases {
    pub phases: Vec<RunPhase>,
    pub current: Option<i64>,
    pub background: Vec<BackgroundTask>,
    pub spend: JsonObject,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProgressFrame {
    pub r#type: crate::types::names::ProgressType,
    pub run_public_id: Option<String>,
    pub conversation_public_id: Option<String>,
    pub task_key: Option<String>,
    pub tool_name: Option<String>,
    pub process_id: Option<String>,
    pub executor_public_id: Option<String>,
    pub at: String,
    pub payload: JsonObject,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunTranscript {
    pub rounds: Vec<ThreadRow>,
    pub pagination: TranscriptPagination,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ThreadCall {
    pub task_key: String,
    pub tool_call_id: Option<String>,
    pub name: String,
    pub tool: Option<String>,
    pub status: crate::types::names::TaskStatus,
    pub is_error: Option<bool>,
    pub title: Option<String>,
    pub metadata: Option<JsonObject>,
    pub output_preview: Option<String>,
    pub output_bytes: Option<i64>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ThreadCalls {
    pub count: i64,
    pub items: Vec<ThreadCall>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ThreadRow {
    pub task_key: String,
    pub mainline: bool,
    pub status: crate::types::names::TaskStatus,
    pub visibility: String,
    pub text_preview: Option<String>,
    pub text_bytes: Option<i64>,
    pub usage: Option<JsonObject>,
    pub error: Option<JsonObject>,
    pub compacted_before: Option<String>,
    pub pruned_before: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub calls: ThreadCalls,
    pub branches: Vec<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GraphNode {
    pub lifetime: String,
    pub wake: String,
    pub key: String,
    pub kind: crate::types::names::TaskKind,
    pub status: crate::types::names::TaskStatus,
    pub visibility: String,
    pub deliverable: bool,
    pub input_from: Vec<String>,
    pub result_from: Vec<String>,
    pub mainline: Option<bool>,
    pub error_key: Option<String>,
    pub join: Option<JsonObject>,
    pub expansion_parent: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GraphEdge {
    pub from: String,
    pub to: String,
    pub structural: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunGraph {
    pub nodes: Vec<GraphNode>,
    pub edges: Vec<GraphEdge>,
    pub mermaid: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AppendReceipt {
    pub accepted_task_keys: Vec<String>,
    pub steps: Vec<Value>,
    pub deliverable_task_key: Option<String>,
    pub revision: Option<i64>,
    #[serde(default)]
    pub resolution_tokens: std::collections::BTreeMap<String, crate::credentials::SecretString>,
    #[serde(default)]
    pub replayed: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunCandidate {
    pub public_id: String,
    pub workspace_public_id: String,
    pub conversation_public_id: String,
    pub turn_public_id: String,
    pub status: String,
}
