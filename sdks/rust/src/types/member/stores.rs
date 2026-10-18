use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StoreEntrySummary {
    pub public_id: String,
    pub namespace: String,
    pub key: String,
    pub lock_version: i64,
    pub created_at: String,
    pub updated_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StoreEntry {
    pub public_id: String,
    pub namespace: String,
    pub key: String,
    pub lock_version: i64,
    pub created_at: String,
    pub updated_at: String,
    pub value: Value,
    #[serde(flatten)]
    pub extra: JsonObject,
}
