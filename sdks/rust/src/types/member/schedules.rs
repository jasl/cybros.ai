use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ScheduleRule {
    pub kind: crate::types::names::ScheduleRuleKind,
    pub run_at: Option<String>,
    pub every_seconds: Option<i64>,
    pub starts_at: Option<String>,
    pub local_time: Option<String>,
    pub time_zone: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ScheduleModel {
    pub model: String,
    pub reasoning_effort: Option<String>,
    pub reasoning_enabled: Option<bool>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ScheduleExecution {
    pub child_conversation_public_id: String,
    pub input_public_id: Option<String>,
    pub turn_public_id: Option<String>,
    pub variant_public_id: Option<String>,
    pub run_public_id: Option<String>,
    pub scheduled_for: String,
    pub status: crate::types::names::TurnStatus,
    pub created_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Schedule {
    pub public_id: String,
    pub workspace_public_id: String,
    pub name: Option<String>,
    pub prompt: String,
    pub rule: ScheduleRule,
    pub model: Option<ScheduleModel>,
    pub model_selection: Option<JsonObject>,
    pub fallback_models: Option<Vec<String>>,
    pub configuration: Option<JsonObject>,
    pub agent_configuration: Option<JsonObject>,
    pub tool_names: Option<Vec<String>>,
    pub approval_mode: Option<String>,
    pub answering_user_public_id: Option<String>,
    pub speaker_public_id: Option<String>,
    pub status: crate::types::names::ScheduleStatus,
    pub lock_version: i64,
    pub next_run_at: Option<String>,
    pub last_enqueued_at: Option<String>,
    pub last_input_public_id: Option<String>,
    pub last_error_code: Option<String>,
    pub last_execution: Option<ScheduleExecution>,
    pub source_run_public_id: Option<String>,
    pub source_task_key: Option<String>,
    pub conversation_public_id: Option<String>,
    pub conversation_title: Option<String>,
    pub creating_user_public_id: Option<String>,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ScheduleExecutionPage {
    #[serde(rename = "executions")]
    pub items: Vec<ScheduleExecution>,
    pub pagination: SchedulePagination,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SchedulePagination {
    pub next_after: Option<String>,
    pub last_cursor: Option<String>,
}
