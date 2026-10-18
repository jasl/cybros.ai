use super::*;
use crate::types::member::{ServedDocument, ServedTool};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Runner {
    pub public_id: String,
    pub kind: crate::types::names::ExecutorKind,
    pub display_name: Option<String>,
    pub status: crate::types::names::ExecutorStatus,
    pub manager_public_id: String,
    pub assignment_scope: crate::types::names::AssignmentScope,
    pub assignment_agent_public_id: Option<String>,
    pub credential_readiness: String,
    pub eligible_for_current_user: bool,
    pub presence: String,
    pub last_seen_at: Option<String>,
    pub connected_at: Option<String>,
    pub registered_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunnerDetail {
    #[serde(flatten)]
    pub runner: Runner,
    pub served_tools: Vec<ServedTool>,
    pub served_documents: Vec<ServedDocument>,
    pub environment: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunnerSnapshot {
    pub runner: RunnerDetail,
    pub measured_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunnerPage {
    pub items: Vec<Runner>,
    pub next_after: Option<String>,
    pub measured_at: String,
}
