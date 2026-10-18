use super::*;
use crate::types::member::{AgentConfiguration, PromptDocument};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentDetail {
    #[serde(flatten)]
    pub agent: Agent,
    pub application_connection: Option<AgentApplicationConnection>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentApplicationConnection {
    pub executor_public_id: String,
    pub owner_agent_public_id: String,
    pub status: crate::types::names::ExecutorStatus,
    pub credential_readiness: String,
    pub presence: String,
    pub last_seen_at: Option<String>,
    pub connected_at: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentConfigurationSnapshot {
    pub agent: Agent,
    pub configuration: AgentConfiguration,
    pub prompt_documents: Vec<PromptDocument>,
    pub agent_updated_at: String,
    pub measured_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}
