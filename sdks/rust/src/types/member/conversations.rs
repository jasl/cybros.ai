use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationModel {
    pub provider_id: Option<String>,
    pub model_ref: Option<String>,
    pub reasoning_effort: Option<String>,
    pub reasoning_enabled: Option<bool>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationReasoning {
    pub task_key: Option<String>,
    pub model: ConversationModel,
    pub available: bool,
    pub text: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationReasoningPage {
    pub items: Vec<ConversationReasoning>,
    pub pagination: TranscriptPagination,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationContextReport {
    pub used_tokens: Option<i64>,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub window_tokens: Option<i64>,
    pub used_percent: Option<f64>,
    pub as_of_model: Option<ConversationModel>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationUsageSummary {
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
    pub cost_unit: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InputQueue {
    pub limit: i64,
    pub held: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationParent {
    pub public_id: String,
    pub spawn_node_key: Option<String>,
    pub label: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationSummary {
    pub public_id: String,
    pub workspace_public_id: String,
    pub title: Option<String>,
    pub lock_version: i64,
    pub answering_user_public_id: String,
    pub archived_at: Option<String>,
    pub billing_subject: Option<String>,
    pub parent: Option<ConversationParent>,
    pub source_conversation_public_id: Option<String>,
    pub forked_from_turn_public_id: Option<String>,
    pub forked_from_variant_public_id: Option<String>,
    pub side: bool,
    pub active_turn_public_id: Option<String>,
    pub context_revision: i64,
    pub last_activity_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationAccessEntry {
    pub user_public_id: String,
    pub handle: String,
    pub kind: String,
    pub display_name: Option<String>,
    pub level: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationAccess {
    pub default: String,
    pub entries: Vec<ConversationAccessEntry>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Conversation {
    pub public_id: String,
    pub workspace_public_id: String,
    pub title: Option<String>,
    pub lock_version: i64,
    pub answering_user_public_id: String,
    pub archived_at: Option<String>,
    pub billing_subject: Option<String>,
    pub parent: Option<ConversationParent>,
    pub source_conversation_public_id: Option<String>,
    pub forked_from_turn_public_id: Option<String>,
    pub forked_from_variant_public_id: Option<String>,
    pub side: bool,
    pub active_turn_public_id: Option<String>,
    pub context_revision: i64,
    pub last_activity_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub metadata: JsonObject,
    pub input_queue: InputQueue,
    pub latest_event_cursor: Option<String>,
    pub context: Option<ConversationContextReport>,
    pub usage_summary: ConversationUsageSummary,
    pub default_runner: Option<DefaultRunner>,
    pub access: ConversationAccess,
    pub memory_context: Option<JsonObject>,
    pub effective_memory_context: JsonObject,
    pub agent_configuration_present: bool,
    pub cost_limit: Option<String>,
    pub cost_limit_reached: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CallbackResult {
    pub conversation_public_id: String,
    pub input_public_id: String,
    pub turn_public_id: String,
    pub variant_public_id: String,
    pub requester_speaker_public_id: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CallbackSource {
    pub input_public_id: String,
    pub origin: String,
    pub sender_conversation_public_id: Option<String>,
    pub sender_run_public_id: Option<String>,
    pub sender_task_key: Option<String>,
    pub result: CallbackResult,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Input {
    pub public_id: String,
    pub queue_position: i64,
    pub state: crate::types::names::InputState,
    pub kind: crate::types::names::TurnKind,
    pub role: String,
    pub delivery_mode: String,
    pub expected_steering_run_public_id: Option<String>,
    pub context_mode: Option<String>,
    #[serde(default)]
    pub context_options: Value,
    pub tool_names: Option<Vec<String>>,
    pub approval_mode: Option<String>,
    pub instructions: Option<String>,
    pub blocked_reason: Option<String>,
    pub text: Option<String>,
    pub attachments: Option<Vec<UploadRef>>,
    pub steps: Option<Vec<Value>>,
    pub lock_version: i64,
    pub created_at: String,
    pub origin: String,
    pub sender_conversation_public_id: Option<String>,
    pub answering_user_public_id: String,
    pub speaker: Speaker,
    pub deliver_at: Option<String>,
    pub callback_result: Option<CallbackResult>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationIngressSpeaker {
    pub speaker_public_id: String,
    pub kind: String,
    pub display_name: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationSpeaker {
    pub user_public_id: String,
    pub handle: String,
    pub kind: String,
    pub display_name: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InputList {
    #[serde(rename = "inputs")]
    pub items: Vec<Input>,
    pub input_queue: InputQueue,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunnerEffects {
    pub status: String,
    pub runners: Vec<RunnerEffect>,
    pub reason: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunnerEffect {
    pub runner_executor_public_id: String,
    pub run_public_id: String,
    pub task_key: String,
    pub checkpoint: Option<Checkpoint>,
    #[serde(default)]
    pub checkpoint_present: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(try_from = "Value")]
pub struct Checkpoint {
    pub hash: Option<String>,
    pub store: Option<String>,
    #[serde(default)]
    pub skipped: Value,
    #[serde(default)]
    pub outside: Vec<String>,
    #[serde(default)]
    pub ignored: Vec<String>,
    #[serde(default)]
    pub raw: Value,
    #[serde(flatten)]
    pub extra: JsonObject,
}
impl TryFrom<Value> for Checkpoint {
    type Error = String;
    fn try_from(raw: Value) -> std::result::Result<Self, Self::Error> {
        #[derive(Deserialize)]
        struct Fields {
            hash: Option<String>,
            store: Option<String>,
            #[serde(default)]
            skipped: Value,
            #[serde(default)]
            outside: Vec<String>,
            #[serde(default)]
            ignored: Vec<String>,
            #[serde(flatten)]
            extra: JsonObject,
        }
        let fields = match &raw {
            Value::String(hash) => Fields {
                hash: Some(hash.clone()),
                store: None,
                skipped: Value::Null,
                outside: vec![],
                ignored: vec![],
                extra: JsonObject::new(),
            },
            Value::Object(_) => {
                serde_json::from_value::<Fields>(raw.clone()).map_err(|e| e.to_string())?
            }
            _ => return Err("checkpoint must be a hash string or object".into()),
        };
        Ok(Self {
            hash: fields.hash,
            store: fields.store,
            skipped: fields.skipped,
            outside: fields.outside,
            ignored: fields.ignored,
            raw,
            extra: fields.extra,
        })
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Variant {
    pub model_selection: Option<JsonObject>,
    pub fallback_models: Option<Vec<String>>,
    pub public_id: String,
    pub origin_variant_public_id: Option<String>,
    pub source: crate::types::names::VariantSource,
    pub status: crate::types::names::TurnStatus,
    pub model: Option<ConversationModel>,
    pub content_preview: Option<String>,
    pub content: Option<String>,
    pub prompt_text: Option<String>,
    #[serde(default)]
    pub active: bool,
    pub run_public_id: Option<String>,
    pub rounds: Option<Vec<Value>>,
    pub attachments: Option<Vec<UploadRef>>,
    pub runner_effects: Option<RunnerEffects>,
    pub details_pruned_at: Option<String>,
    pub memory_context: Option<JsonObject>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InputMaterialization {
    pub input_public_id: String,
    pub turn_public_id: String,
    pub variant_public_id: String,
    pub run_public_id: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Turn {
    pub input_public_id: Option<String>,
    pub callback_sources: Vec<CallbackSource>,
    pub sender_run_public_id: Option<String>,
    pub sender_task_key: Option<String>,
    pub public_id: String,
    pub position: i64,
    pub kind: crate::types::names::TurnKind,
    pub role: String,
    pub status: crate::types::names::TurnStatus,
    pub visibility: String,
    pub inherited: bool,
    #[serde(default)]
    pub reference: bool,
    pub origin: Option<String>,
    pub sender_conversation_public_id: Option<String>,
    pub active_variant: Option<Variant>,
    pub running_variant: Option<Variant>,
    pub created_at: String,
    pub answering_user_public_id: String,
    pub speaker: Option<Value>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TurnPage {
    #[serde(rename = "turns")]
    pub items: Vec<Turn>,
    pub pagination: TurnPagination,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct VariantDeck {
    #[serde(rename = "variants")]
    pub items: Vec<Variant>,
    pub turn: TurnReference,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct VariantRead {
    pub variant: Variant,
    pub turn: TurnReference,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationRegeneration {
    pub turn: RegeneratedTurn,
    pub variant: Variant,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConversationCompaction {
    pub turn_public_id: String,
    pub position: i64,
    pub kind: String,
    pub turn_status: String,
    pub task_key: Option<String>,
    pub summary_task_key: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Event {
    pub public_id: String,
    pub sequence: i64,
    pub cursor: String,
    pub r#type: crate::types::names::EventType,
    pub resource: EventResource,
    pub occurred_at: String,
    pub payload: Value,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EventPage {
    #[serde(rename = "events")]
    pub items: Vec<Event>,
    pub pagination: EventPagination,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TurnReference {
    pub public_id: String,
    pub inherited: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EventResource {
    pub r#type: String,
    pub public_id: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EventPagination {
    pub next_after: Option<String>,
    pub watermark: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TurnPagination {
    pub before_position: Option<i64>,
    pub after_position: Option<i64>,
    pub has_older: Option<bool>,
    pub has_newer: Option<bool>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TranscriptPagination {
    pub next_before: Option<String>,
    pub has_older: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RegeneratedTurn {
    pub public_id: String,
    pub status: crate::types::names::TurnStatus,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Speaker {
    Member(ConversationSpeaker),
    Ingress(ConversationIngressSpeaker),
}
