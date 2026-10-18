use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TranscriptItem {
    pub r#type: crate::types::names::TranscriptItemType,
    pub turn_public_id: Option<String>,
    pub variant_public_id: Option<String>,
    pub run_public_id: Option<String>,
    pub task_key: Option<String>,
    pub turn: Option<Turn>,
    pub text: Option<String>,
    pub tool_call_id: Option<String>,
    pub name: Option<String>,
    pub arguments_delta: Option<String>,
    pub reason: Option<String>,
    pub round: Option<ThreadRow>,
    pub call: Option<ThreadCall>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationHistoryEvidence {
    pub selected: i64,
    pub skipped: i64,
    pub skipped_reason: Option<String>,
    pub compacted: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InputEstimate {
    pub input_tokens: i64,
    pub tokenizer_exact: bool,
    pub catalog_input_token_limit: Option<i64>,
    pub advisory_input_token_limit: Option<i64>,
    pub message_count: i64,
    pub history: ConversationHistoryEvidence,
    pub rendered: Option<RenderedEstimate>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RenderedEstimate {
    pub mechanism: String,
    pub entries: Vec<Value>,
    pub storage: EstimateStorage,
    pub blocks: Vec<ContextBlockEvidence>,
    pub memory: MemoryEvidence,
    pub slots: JsonObject,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EstimateStorage {
    pub bytes: i64,
    pub bound: i64,
    pub within_bound: bool,
    pub refusal: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContextBlockEvidence {
    pub block: String,
    pub index: i64,
    pub r#type: String,
    pub role: Option<String>,
    pub state: String,
    pub tokens: i64,
    pub allocated_tokens: Option<i64>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MemoryEvidence {
    pub included: i64,
    pub omitted: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MemoryDocument {
    pub public_id: String,
    pub lock_version: i64,
    pub path: String,
    pub bytesize: i64,
    pub description: Option<String>,
    pub content: Option<String>,
    pub written_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PromptDocument {
    pub slot: String,
    pub role: String,
    pub bytesize: i64,
    pub version: i64,
    pub content: Option<String>,
    pub written_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SealedRequest {
    pub entries: Vec<Value>,
    pub request_options: JsonObject,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MemoryMatch {
    pub path: String,
    pub line_number: i64,
    pub text: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MemoryMatches {
    pub matches: Vec<MemoryMatch>,
    pub truncated: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ForkedConversation {
    pub conversation: Conversation,
    pub runner_effects: RunnerEffects,
}
