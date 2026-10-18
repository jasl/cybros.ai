use super::*;
use crate::credentials::SecretString;
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Agent {
    pub public_id: String,
    pub handle: Option<String>,
    pub display_name: Option<String>,
    pub status: crate::types::names::AgentStatus,
    pub agent_identifier: Option<String>,
    pub named_agent_scope: Option<String>,
    pub description: Option<String>,
    pub derived_from_public_id: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PrivateRunner {
    pub public_id: String,
    pub display_name: Option<String>,
    pub status: crate::types::names::ExecutorStatus,
    pub registration_identifier: String,
    pub assignment_scope: crate::types::names::AssignmentScope,
    pub assignment_agent_public_id: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ApiKeyPlane {
    Member,
    ExecutorTransport,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ApiKey {
    pub public_id: String,
    pub name: String,
    pub note: Option<String>,
    pub plane: ApiKeyPlane,
    pub created_at: String,
    pub last_used_at: Option<String>,
    pub revoked_at: Option<String>,
    pub usable: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ApiKeyGrant {
    pub api_key: ApiKey,
    pub secret: SecretString,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Budget {
    pub public_id: String,
    pub user_public_id: String,
    pub user_kind: String,
    pub credited_amount: String,
    pub debited_amount: String,
    pub headroom: String,
    pub cost_unit: Option<String>,
    pub starts_at: String,
    pub expires_at: Option<String>,
    pub revoked_at: Option<String>,
    pub revoked_by_public_id: Option<String>,
    pub revoke_reason: Option<String>,
    pub usable: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BudgetList {
    pub user_public_id: String,
    pub user_kind: String,
    pub cost_unit: Option<String>,
    pub measured_at: String,
    pub current_budget: Option<Budget>,
    pub budgets: Vec<Budget>,
    pub pagination: BudgetPagination,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BudgetPagination {
    pub next_after: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BudgetRead {
    pub budget: Budget,
    pub measured_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BudgetLedgerEntry {
    pub public_id: String,
    pub sequence: u64,
    pub kind: crate::types::names::BudgetEntryKind,
    pub amount: String,
    pub cost_unit: String,
    pub actor_public_id: Option<String>,
    pub reason: Option<String>,
    pub created_at: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BudgetEntry {
    pub sequence: u64,
    pub kind: crate::types::names::BudgetEntryKind,
    pub amount: String,
    pub reason: Option<String>,
    pub operation_key: String,
    pub created_at: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BudgetAdjustment {
    pub budget: Budget,
    pub entry: BudgetEntry,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UsageCounters {
    pub request_count: u64,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_creation_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_tokens: u64,
    pub total_tokens: u64,
    pub cost_amount: String,
    pub cost_complete: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UsagePoint {
    pub bucket_start_at: String,
    #[serde(flatten)]
    pub counters: UsageCounters,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UsageReport {
    pub unit: crate::types::names::UsageUnit,
    pub series: Vec<UsagePoint>,
    pub totals: UsageCounters,
}
