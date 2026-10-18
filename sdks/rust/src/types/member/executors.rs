use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AddressedTo {
    pub role: String,
    pub executor_public_id: Option<String>,
    pub presence: Option<String>,
    pub last_seen_at: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskTarget {
    pub executor_public_id: Option<String>,
    pub display_name: Option<String>,
    pub kind: Option<String>,
    pub connection_public_id: Option<String>,
    pub account_label: Option<String>,
    pub tool_name: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ClaimedBy {
    pub executor_public_id: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InboxTask {
    pub kind: crate::types::names::InboxKind,
    pub run_public_id: String,
    pub workspace_public_id: String,
    pub conversation_public_id: Option<String>,
    pub parent_public_id: Option<String>,
    pub task_key: String,
    pub prompt: Option<String>,
    pub options: Option<Vec<String>>,
    pub multi: Option<bool>,
    pub tool_name: Option<String>,
    pub tool_alias: Option<String>,
    #[serde(default)]
    pub tool_input: JsonObject,
    pub scope: Option<JsonObject>,
    pub tool_call_id: Option<String>,
    pub started_at: Option<String>,
    pub deadline_at: Option<String>,
    pub timeout_ms: Option<i64>,
    pub target: Option<TaskTarget>,
    pub claimed: bool,
    pub addressed_to: Option<AddressedTo>,
    pub effect_profile: Option<JsonObject>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ClaimedTask {
    pub task: InboxTask,
    pub claim: Claim,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ClaimStatus {
    pub active: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExecutorAddress {
    pub public_id: String,
    pub kind: crate::types::names::ExecutorKind,
    pub status: crate::types::names::ExecutorStatus,
    pub display_name: Option<String>,
    pub credential_epoch: i64,
    pub presence: String,
    pub last_seen_at: Option<String>,
    pub connected_at: Option<String>,
    pub agent_public_id: Option<String>,
    pub registration_identifier: Option<String>,
    pub assignment_scope: Option<String>,
    pub assignment_agent_public_id: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExecutorDescription {
    pub executor: ExecutorAddress,
    pub measured_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DefaultRunner {
    pub executor_public_id: String,
    pub display_name: Option<String>,
    pub presence: String,
    pub last_seen_at: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ServedTool {
    pub name: String,
    pub effect_profile: JsonObject,
    pub timeout_ms: Option<i64>,
    pub description: Option<String>,
    pub input_schema: Option<JsonObject>,
    pub mcp: Option<JsonObject>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ServedDocument {
    pub name: String,
    pub description: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DiscoveredExecutor {
    pub public_id: String,
    pub kind: crate::types::names::ExecutorKind,
    pub display_name: Option<String>,
    pub status: crate::types::names::ExecutorStatus,
    pub assignment_scope: String,
    pub assignment_agent_public_id: Option<String>,
    pub served_tools: Vec<ServedTool>,
    pub environment: JsonObject,
    pub served_documents: Vec<ServedDocument>,
    pub presence: String,
    pub last_seen_at: Option<String>,
    pub connected_at: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Claim {
    pub claim_token: crate::credentials::SecretString,
    pub deadline_at: Option<String>,
}
