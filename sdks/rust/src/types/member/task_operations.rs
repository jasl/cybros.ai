use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OperationContext {
    pub environment: Option<JsonObject>,
    pub tools: Vec<Value>,
    pub model_defaults: JsonObject,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OperationRefusal {
    pub code: String,
    pub message: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OperationEvent {
    pub r#type: String,
    pub position: i64,
    pub key: String,
    pub request: Option<JsonObject>,
    pub receipt: Option<OperationReceipt>,
    pub outcome: Option<OperationOutcome>,
    pub refusal: Option<OperationRefusal>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskOperations {
    pub context: OperationContext,
    pub trace: Vec<OperationEvent>,
    pub position: i64,
    pub next_after: Option<i64>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OperationRead {
    pub observation: Option<OperationEvent>,
    pub position: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OperationReceipt {
    #[serde(default)]
    pub task_keys: Vec<String>,
    #[serde(default)]
    pub result_task_keys: Vec<String>,
    #[serde(default)]
    pub steps: Vec<Value>,
    #[serde(default)]
    pub keys: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub background: bool,
    #[serde(default)]
    pub released_operations: Vec<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OperationOutcome {
    pub status: Option<crate::types::names::TaskStatus>,
    pub is_error: Option<bool>,
    pub output_present: Option<bool>,
    pub output: Option<String>,
    #[serde(default)]
    pub content: Value,
    #[serde(default)]
    pub structured_content: Value,
    pub structured_content_present: Option<bool>,
    pub error: Option<JsonObject>,
    pub run_public_id: Option<String>,
    pub task_key: Option<String>,
    #[serde(default)]
    pub results: Vec<OperationOutcome>,
    #[serde(default)]
    pub selected: Value,
    #[serde(flatten)]
    pub extra: JsonObject,
}
