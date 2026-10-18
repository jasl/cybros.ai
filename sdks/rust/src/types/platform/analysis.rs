use super::*;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LatencyPercentiles {
    pub sample_count: u64,
    pub missing_count: u64,
    pub p50: Option<u64>,
    pub p95: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AnalysisCounters {
    #[serde(flatten)]
    pub counters: UsageCounters,
    pub amount_sample_count: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelLatency {
    pub duration_ms: LatencyPercentiles,
    pub time_to_first_token_ms: LatencyPercentiles,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UsageGroup {
    pub value: String,
    pub totals: AnalysisCounters,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UsageBreakdown {
    pub group_by: String,
    pub rank_by: String,
    pub limit: u32,
    pub total_group_count: u64,
    pub groups: Vec<UsageGroup>,
    pub other: AnalysisCounters,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelAnalysis {
    pub totals: AnalysisCounters,
    pub status_counts: BTreeMap<String, u64>,
    pub latency: ModelLatency,
    pub breakdown: UsageBreakdown,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelUsageAnalysis {
    pub from: String,
    pub to: String,
    pub as_of: String,
    pub cost_unit: Option<String>,
    pub model_usage: ModelAnalysis,
}
