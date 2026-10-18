use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct McpConnection {
    pub public_id: String,
    pub name: String,
    pub account_label: Option<String>,
    pub endpoint_url: String,
    pub auth_type: String,
    pub enabled: bool,
    pub available: bool,
    pub credential_configured: bool,
    pub authorization_status: String,
    pub authorization_expires_at: Option<String>,
    pub tools: Vec<JsonObject>,
    pub catalog_refreshed_at: Option<String>,
    pub lock_version: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct McpAuthorization {
    pub connection_public_id: String,
    pub authorization_url: String,
    pub expires_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}
