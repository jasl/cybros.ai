use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Session {
    pub public_id: String,
    pub kind: String,
    pub expires_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum SessionTokenType {
    Bearer,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionGrant {
    pub session: Session,
    pub token: crate::credentials::SecretString,
    pub token_type: SessionTokenType,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Member {
    pub public_id: String,
    pub kind: String,
    pub role: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Profile {
    pub member: Member,
    pub credential_plane: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CostUnit {
    pub cost_unit: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Retention {
    pub execution_details_retention_days: Option<i64>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelDefinition {
    pub model: String,
    pub definition: Option<JsonObject>,
    pub source: String,
    pub removed: bool,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelProviderConfiguration {
    pub model_provider: ProviderLane,
    pub configuration: ProviderConfiguration,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DiscoveredModel {
    pub id: String,
    pub display_name: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelTest {
    pub outcome: String,
    pub duration_ms: i64,
    pub http_status: Option<i64>,
    pub availability_update: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelTestResult {
    #[serde(rename = "model_test")]
    pub test: ModelTest,
    #[serde(rename = "model_provider")]
    pub provider: ProviderLane,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProviderConfiguration {
    pub definition: Option<JsonObject>,
    pub source: String,
    pub models: Vec<ModelDefinition>,
}
