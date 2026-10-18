use super::*;
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct DeploymentImage {
    pub name: String,
    pub reference: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct DeploymentRelease {
    pub release: String,
    pub images: Vec<DeploymentImage>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentCandidate {
    pub release: String,
    pub images: Vec<DeploymentImage>,
    pub checked_at: String,
    pub source_revision: Option<String>,
    pub source_url: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentCheck {
    pub name: String,
    pub status: crate::types::names::CheckStatus,
    pub message: Option<String>,
    pub next_step: Option<String>,
    pub available_bytes: Option<u64>,
    pub required_bytes: Option<u64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentPreflight {
    pub checked_at: String,
    pub ready: bool,
    pub backup: bool,
    pub checks: Vec<DeploymentCheck>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentBackup {
    pub created_at: String,
    pub size_bytes: u64,
    pub available: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentError {
    pub code: String,
    pub message: String,
    pub operation_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentUpgrade {
    pub id: String,
    pub idempotency_key: String,
    pub actor_public_id: Option<String>,
    pub target: DeploymentRelease,
    pub previous: Option<DeploymentRelease>,
    pub phase: crate::types::names::DeploymentPhase,
    pub status: crate::types::names::DeploymentStatus,
    pub accepted_at: String,
    pub updated_at: String,
    pub completed_at: Option<String>,
    pub error: Option<DeploymentError>,
    pub recovery: Option<String>,
    pub log_cursor: Option<String>,
    pub backup: bool,
    pub database_backup: Option<DeploymentBackup>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentState {
    pub supported: bool,
    pub sources: Vec<DeploymentImage>,
    pub installed: Option<DeploymentRelease>,
    pub candidate: Option<DeploymentCandidate>,
    pub preflight: Option<DeploymentPreflight>,
    pub active_operation: Option<DeploymentUpgrade>,
    pub last_operation: Option<DeploymentUpgrade>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentLogEntry {
    pub cursor: String,
    pub text: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentLog {
    pub entries: Vec<DeploymentLogEntry>,
    pub next_cursor: Option<String>,
    pub operation: DeploymentUpgrade,
}
#[derive(Clone, Debug)]
pub enum DeploymentEvent {
    Progress {
        id: String,
        log: Box<DeploymentLog>,
    },
    Error {
        id: String,
        error: DeploymentError,
    },
    Unknown {
        event: String,
        id: String,
        data: Value,
    },
}
