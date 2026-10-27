use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestModel {
    pub provider_id: String,
    pub model_ref: String,
    pub reasoning_effort: Option<String>,
    pub reasoning_enabled: Option<bool>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestInputEstimate {
    pub input_tokens: i64,
    pub tokenizer_exact: bool,
    pub catalog_input_token_limit: Option<i64>,
    pub advisory_input_token_limit: Option<i64>,
    pub model: InferenceRequestModel,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestUsage {
    pub usage_record_public_id: String,
    pub input_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub uncached_input_tokens: Option<i64>,
    pub cache_creation_tokens: Option<i64>,
    pub cache_hit_rate: Option<f64>,
    pub output_tokens: Option<i64>,
    pub reasoning_tokens: Option<i64>,
    pub total_tokens: Option<i64>,
    pub cost_amount: Option<String>,
    pub cost_unit: Option<String>,
    pub cost_complete: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestUsageSummary {
    pub request_count: i64,
    pub input_tokens: i64,
    pub cache_read_tokens: i64,
    pub uncached_input_tokens: i64,
    pub cache_creation_tokens: i64,
    pub cache_hit_rate: Option<f64>,
    pub output_tokens: i64,
    pub reasoning_tokens: i64,
    pub total_tokens: i64,
    pub cost_amount: String,
    pub cost_complete: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestFile {
    pub index: i64,
    pub filename: String,
    pub content_type: String,
    pub byte_size: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestTiming {
    pub duration_ms: Option<i64>,
    pub time_to_first_token_ms: Option<i64>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestError {
    pub code: String,
    #[serde(default)]
    pub attempt_budget_spent: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestReasoning {
    pub available: bool,
    pub text: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestEmbedding {
    pub index: i64,
    pub vector: Vec<f64>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestModelChange {
    pub from: String,
    pub to: String,
    pub reason: String,
    pub category: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum DecisionChoice {
    Text(String),
    Boolean(bool),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum DecisionProbabilityValue {
    Choice(DecisionChoice),
    Level(i64),
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DecisionProbability {
    pub value: DecisionProbabilityValue,
    pub probability: f64,
    pub label: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DecisionAnswer {
    pub name: String,
    pub r#type: String,
    pub probability: Option<f64>,
    pub choice: Option<DecisionChoice>,
    pub score: Option<f64>,
    pub confidence: Option<f64>,
    pub probabilities: Option<Vec<DecisionProbability>>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestResult {
    pub status: crate::types::names::InferenceStatus,
    pub finish_quality: Option<String>,
    pub output_text: Option<String>,
    pub usage: Option<InferenceRequestUsage>,
    pub timing: Option<InferenceRequestTiming>,
    pub error: Option<InferenceRequestError>,
    pub reasoning: Option<InferenceRequestReasoning>,
    pub output_files: Option<Vec<InferenceRequestFile>>,
    pub embeddings: Option<Vec<InferenceRequestEmbedding>>,
    pub answers: Option<Vec<DecisionAnswer>>,
    pub refusal_category: Option<String>,
    pub model_change: Option<InferenceRequestModelChange>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestSummary {
    pub public_id: String,
    pub workload: String,
    pub status: crate::types::names::InferenceStatus,
    pub model: InferenceRequestModel,
    pub billing_subject: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequest {
    pub model_selection: Option<JsonObject>,
    pub fallback_models: Option<Vec<String>>,
    pub public_id: String,
    pub workload: String,
    pub status: crate::types::names::InferenceStatus,
    pub model: InferenceRequestModel,
    pub billing_subject: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub usage_summary: InferenceRequestUsageSummary,
    pub result: Option<InferenceRequestResult>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestEventPage {
    #[serde(rename = "events")]
    pub items: Vec<InferenceRequestEvent>,
    pub pagination: EventPagination,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InferenceRequestEvent {
    pub public_id: String,
    pub sequence: i64,
    pub cursor: String,
    pub r#type: crate::types::names::InferenceEventType,
    pub resource: EventResource,
    pub occurred_at: String,
    pub payload: Value,
    #[serde(flatten)]
    pub extra: JsonObject,
}
