use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Member {
    pub public_id: String,
    pub handle: String,
    pub kind: crate::types::names::MemberKind,
    pub role: String,
    pub display_name: Option<String>,
    pub agent_identifier: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Credential {
    pub plane: String,
    pub expires_at: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentConfiguration {
    pub tool_definitions: Vec<JsonObject>,
    pub kernel_tools: Vec<String>,
    pub runner_executor_public_ids: Vec<String>,
    pub runner_tool_names: Option<Vec<String>>,
    pub mcp_tools: Vec<JsonObject>,
    pub approval_mode: Option<String>,
    pub approval_rules: Option<Vec<JsonObject>>,
    pub prompt_mechanism: Option<String>,
    pub prompt_template: Option<JsonObject>,
    pub compaction_policy: Option<JsonObject>,
    pub lifecycle_hooks: Option<JsonObject>,
    pub default_model: Option<String>,
    pub image_model: Option<String>,
    pub fallback_models: Vec<String>,
    pub memory_context_limit: Option<JsonObject>,
    pub conversation_reach: Option<String>,
    pub delegation_catalog: Option<Vec<JsonObject>>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Profile {
    pub member: Member,
    pub credential: Credential,
    pub configuration: Option<AgentConfiguration>,
    pub measured_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NamedAgent {
    pub scope: String,
    pub name: String,
    pub public_id: String,
    pub handle: String,
    pub display_name: Option<String>,
    pub description: String,
    pub agent_identifier: String,
    pub steward_public_id: String,
    pub kind: String,
    pub derived_from_public_id: String,
    pub system_prompt: Option<String>,
    pub summarizer: Option<String>,
    pub configuration: AgentConfiguration,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct IngressSpeaker {
    pub public_id: String,
    pub kind: String,
    pub channel_key: String,
    pub external_id: String,
    pub display_name: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}
