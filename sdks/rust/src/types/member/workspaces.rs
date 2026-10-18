use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkspaceOwnerSummary {
    pub public_id: String,
    pub display_name: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolProviderOverride {
    pub provider_public_id: String,
    pub display_name: Option<String>,
    pub assignment_scope: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkspaceCreatorSummary {
    pub public_id: String,
    pub display_name: Option<String>,
    pub kind: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentMessaging {
    pub agent_public_id: String,
    pub mode: String,
    pub allowed_sender_public_ids: Vec<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkspaceMessaging {
    pub agents: Vec<AgentMessaging>,
    pub lock_version: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkspaceSummary {
    pub public_id: String,
    pub name: String,
    pub access_mode: crate::types::names::AccessMode,
    pub state: crate::types::names::WorkspaceState,
    pub dedicated: bool,
    pub lock_version: i64,
    pub archived_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Workspace {
    pub public_id: String,
    pub name: String,
    pub access_mode: crate::types::names::AccessMode,
    pub state: crate::types::names::WorkspaceState,
    pub dedicated: bool,
    pub lock_version: i64,
    pub archived_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub metadata: JsonObject,
    pub tool_provider_overrides: JsonObject,
    pub owner: WorkspaceOwnerSummary,
    pub creator: WorkspaceCreatorSummary,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Principal {
    pub public_id: String,
    pub handle: String,
    pub kind: String,
    pub display_name: Option<String>,
    pub agent_identifier: Option<String>,
    pub steward_public_id: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}
