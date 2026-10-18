use super::*;
use crate::types::platform::{LatencyPercentiles, ModelAnalysis};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkAnalysis {
    pub from: String,
    pub to: String,
    pub as_of: String,
    pub cost_unit: Option<String>,
    pub workspace_public_id: Option<String>,
    pub agent_public_id: Option<String>,
    pub model_usage: ModelAnalysis,
    pub execution: ExecutionAnalysis,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExecutionLatency {
    pub delivery_ms: LatencyPercentiles,
    pub completion_ms: LatencyPercentiles,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExecutionAnalysis {
    pub run_count: u64,
    pub retained_run_count: u64,
    pub details_pruned_run_count: u64,
    pub status_counts: BTreeMap<String, u64>,
    pub delivered_count: u64,
    pub undelivered_count: u64,
    pub completed_count: u64,
    pub uncompleted_count: u64,
    pub latency: ExecutionLatency,
    pub tools: ToolsAnalysis,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolAnalysisGroup {
    pub tool_name: String,
    pub task_count: u64,
    pub status_counts: BTreeMap<String, u64>,
    pub error_result_count: u64,
    pub latency: LatencyPercentiles,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolsAnalysis {
    pub task_count: u64,
    pub status_counts: BTreeMap<String, u64>,
    pub error_result_count: u64,
    pub latency: LatencyPercentiles,
    pub total_group_count: u64,
    pub groups: Vec<ToolAnalysisGroup>,
    pub other_task_count: u64,
}
