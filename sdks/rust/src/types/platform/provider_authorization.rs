use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Authorization {
    pub provider_id: String,
    pub state: String,
    pub expires_at: Option<String>,
    pub session: Option<AuthorizationSession>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuthorizationSession {
    pub public_id: String,
    pub kind: String,
    pub state: String,
    pub progress: String,
    pub outcome: Option<String>,
    pub expires_at: Option<String>,
    pub verification_uri: Option<String>,
    pub user_code: Option<String>,
    pub owned_by_current_user: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}
