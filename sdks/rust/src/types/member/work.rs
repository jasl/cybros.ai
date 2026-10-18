use super::*;
use crate::types::platform::UsageCounters;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AttentionItem {
    pub workspace_public_id: String,
    pub run_public_id: String,
    pub conversation_public_id: Option<String>,
    pub task: Task,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkRunCounts {
    pub pending: i64,
    pub running: i64,
    pub paused: i64,
    pub needs_attention: i64,
    pub canceling: i64,
    pub completed: i64,
    pub canceled: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkCurrent {
    pub run_counts: WorkRunCounts,
    pub attention_count: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkTotals {
    pub created_runs: i64,
    pub active_answering_agents: i64,
    pub conversation_usage: UsageCounters,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkPoint {
    pub bucket_start_at: String,
    pub created_runs: i64,
    pub active_answering_agents: i64,
    pub conversation_usage: UsageCounters,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkPrevious {
    pub from: String,
    pub to: String,
    pub totals: WorkTotals,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkReport {
    pub from: String,
    pub to: String,
    pub unit: String,
    pub as_of: String,
    pub workspace_public_id: Option<String>,
    pub agent_public_id: Option<String>,
    pub current: WorkCurrent,
    pub totals: WorkTotals,
    pub series: Vec<WorkPoint>,
    pub previous: WorkPrevious,
    #[serde(flatten)]
    pub extra: JsonObject,
}
