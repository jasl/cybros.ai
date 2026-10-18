use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolAssembly {
    pub tool_definitions: Vec<JsonObject>,
    pub environment: JsonObject,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct KernelTool {
    pub canonical_name: String,
    pub name: String,
    pub effect_profile: JsonObject,
    pub definition: JsonObject,
    pub template: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProviderLane {
    pub id: String,
    pub display_name: Option<String>,
    pub credentials: Option<String>,
    pub enabled: bool,
    pub lock_version: Option<i64>,
    pub configured: bool,
    pub material_kind: Option<String>,
    pub reauthorization_required: bool,
    pub models: i64,
    pub unavailable_until: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelPricing {
    pub state: String,
    pub unit: Option<String>,
    pub input_per_mtok: Option<String>,
    pub output_per_mtok: Option<String>,
    #[serde(flatten)]
    pub extra: JsonObject,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CatalogModel {
    pub r#ref: String,
    pub provider: String,
    pub workload: String,
    pub visible: bool,
    pub available: bool,
    pub unavailable_reason: Option<String>,
    pub model_identity: Option<String>,
    pub capabilities: Value,
    pub pricing: ModelPricing,
    #[serde(flatten)]
    pub extra: JsonObject,
}
