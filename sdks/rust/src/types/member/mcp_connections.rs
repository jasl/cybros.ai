use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct McpConnection {
    pub public_id: String,
    pub name: String,
    pub account_label: Option<String>,
    pub enabled: bool,
    pub available: bool,
    pub tools: Vec<JsonObject>,
    #[serde(flatten)]
    pub extra: JsonObject,
}
