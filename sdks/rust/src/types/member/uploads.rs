use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Upload {
    pub public_id: String,
    pub filename: String,
    pub content_type: String,
    pub byte_size: i64,
    pub created_at: String,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UploadRef {
    pub public_id: String,
    pub filename: String,
    pub content_type: String,
    pub byte_size: i64,
    #[serde(flatten)]
    pub extra: JsonObject,
}
