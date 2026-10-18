use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationSearchMatch {
    pub conversation_public_id: String,
    pub title: Option<String>,
    pub turn_public_id: Option<String>,
    pub variant_public_id: Option<String>,
    pub position: Option<i64>,
    pub field: String,
    pub inherited: bool,
    pub excerpt: Option<String>,
    pub truncated: bool,
    pub location: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationFieldPage {
    pub conversation_public_id: String,
    pub turn_public_id: String,
    pub variant_public_id: String,
    pub field: String,
    pub inherited: bool,
    pub text: String,
    pub pagination: SchedulePagination,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationSearchPage {
    pub matches: Vec<ConversationSearchMatch>,
    pub pagination: SchedulePagination,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationHistoryTitle {
    pub public_id: String,
    pub title: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationHistoryTurn {
    pub public_id: String,
    pub position: i64,
    pub kind: String,
    pub role: String,
    pub status: String,
    pub created_at: String,
    pub prompt: Option<String>,
    pub content: Option<String>,
    pub steers: Option<String>,
    pub truncated: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationHistoryExecution {
    pub turn_public_id: String,
    pub variant_public_id: String,
    pub active: bool,
    pub status: String,
    pub run_public_id: String,
    pub run_status: String,
    pub rounds: Vec<ThreadRow>,
    pub pagination: TranscriptPagination,
    pub truncated: bool,
    pub details_pruned_at: Option<String>,
    pub attention_reason: Option<String>,
    pub failure_reason: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationHistoryPage {
    pub conversation: ConversationHistoryTitle,
    pub turns: Vec<ConversationHistoryTurn>,
    pub pagination: TurnPagination,
    pub truncated: bool,
    pub execution: Option<ConversationHistoryExecution>,
}
