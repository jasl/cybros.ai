use super::*;
request!(Login {email:String,password:SecretString} {});
request!(SetCostUnit {cost_unit:String} {});
request!(SetRetention {execution_details_retention_days:Option<i64>} {});
request!(CreateAgent {display_name:String} {});
vocabulary!(RunnerStatus { Active, Revoked });
query!(RunnerListQuery {
    kind: MachineKind,
    status: RunnerStatus,
    after: String,
    limit: u32,
    order: Order
});
request!(IssueApiKey {name:String} {note:String});
request!(CreatePrivateRunner {display_name:String} {});
request!(ProviderVersion {expected_lock_version:Option<i64>} {});
request!(ProviderDefinition {definition:JsonObject,expected_lock_version:Option<i64>} {});
request!(ModelDefinitionRequest {model:String,definition:JsonObject,expected_lock_version:Option<i64>} {});
request!(ModelVersion {model:String,expected_lock_version:Option<i64>} {});
request!(ProviderLaneRequest {enabled:bool,expected_lock_version:Option<i64>} {});
request!(ModelVisibility {model:String,visible:bool,expected_lock_version:Option<i64>} {});
request!(ModelAvailability {model:String,available:bool,expected_lock_version:Option<i64>} {});
request!(ProviderApiKey {api_key:SecretString} {});
request!(StartAuthorization {} {restart:bool});
request!(CreateMcpConnection {name:String,endpoint_url:String,auth_type:AuthType} {account_label:String,bearer_token:SecretString,enabled:bool});
request!(UpdateMcpConnection {lock_version:i64} {name:String,account_label:String,enabled:bool});
request!(McpCredential {lock_version:i64,bearer_token:SecretString} {});
request!(McpVersion {lock_version:i64} {});
request!(UpgradeDeployment {candidate:crate::types::platform::DeploymentRelease} {backup:bool});
request!(CheckRelease {} {tag:String,backup:bool});
request!(CreateBudget {amount:String,starts_at:String} {reason:String,expires_at:String});
vocabulary!(BudgetAdjustmentKind { Credit, Debit });
request!(UpdateBudget {kind:BudgetAdjustmentKind,amount:String} {reason:String});
request!(RevokeBudget {} {reason:String});
vocabulary!(UsageUnitRequest { Hour, Day, Month });
query!(UsageReportQuery {
    from: String,
    to: String,
    unit: UsageUnitRequest,
    provider_id: String,
    catalog_model_ref: String,
    workload: String,
    status: String
});
