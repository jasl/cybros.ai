use super::*;
use eventsource_stream::Eventsource;
use futures_util::{Stream, StreamExt};
use std::{pin::Pin, time::Duration};
use types::{
    member::{CatalogModel, PromptDocument, ProviderLane},
    platform::*,
};
impl PlatformClient {
    query_get!(
        model_usage_analysis,
        "admin/model_usage/analysis",
        ModelUsageAnalysisQuery,
        ModelUsageAnalysis,
        Some("analysis")
    );
    child!(session, "session", PlatformSession);
    child!(profile, "profile", PlatformProfile);
    child!(persona, "persona", Persona);
    child!(cost_unit, "admin/account/cost_unit", CostUnitContext);
    child!(retention, "admin/account/retention", RetentionContext);
    child!(models, "admin/models", PlatformModels);
    child!(
        model_providers,
        "admin/model_providers",
        PlatformModelProviders
    );
    child!(mcp_connections, "mcp_connections", PlatformMcpConnections);
    child!(agents, "agents", Agents);
    child!(runners, "runners", Runners);
    child!(deployment, "admin/deployment", Deployment);
    query_get!(
        model_usage,
        "admin/model_usage/report",
        UsageReportQuery,
        UsageReport,
        Some("report")
    );
    pub fn budgets(&self, user_public_id: &str) -> Result<Budgets> {
        Ok(Budgets(
            self.0
                .child("admin/users")
                .id(user_public_id)?
                .child("budgets"),
        ))
    }
    /// Human session login is the unauthenticated bootstrap door.
    pub async fn login(base_url: &str, request: &Login) -> Result<Response<SessionGrant>> {
        let transport = Arc::new(Transport::new(
            base_url,
            Arc::new(crate::credentials::Anonymous),
            Plane::Platform,
            ClientOptions::default(),
        )?);
        Resource {
            transport,
            path: "/api/v1/session".into(),
        }
        .call(
            Method::POST,
            "",
            None::<&()>,
            Some(request),
            None,
            Headers::default(),
            None,
        )
        .await
    }
}
handle!(PlatformSession);
impl PlatformSession {
    get!(fetch, "", Session, Some("session"));
    command!(revoke, DELETE, "", Empty, None);
}
handle!(PlatformProfile);
impl PlatformProfile {
    child!(budgets, "budgets", BudgetReads);
    get!(fetch, "", Profile, None);
}
handle!(Persona);
impl Persona {
    get!(read, "", PromptDocument, Some("prompt_document"));
    write!(
        write,
        PUT,
        "",
        WritePromptDocument,
        Some("prompt_document"),
        PromptDocument,
        Some("prompt_document")
    );
    command!(delete, DELETE, "", Empty, None);
}
handle!(CostUnitContext);
impl CostUnitContext {
    get!(fetch, "", CostUnit, Some("account"));
    write!(
        configure,
        PUT,
        "",
        SetCostUnit,
        Some("account"),
        CostUnit,
        Some("account")
    );
}
handle!(RetentionContext);
impl RetentionContext {
    get!(fetch, "", Retention, Some("account"));
    write!(
        update,
        PATCH,
        "",
        SetRetention,
        Some("account"),
        Retention,
        Some("account")
    );
}
handle!(PlatformModels);
impl PlatformModels {
    query_get!(
        list,
        "",
        PlatformModelListQuery,
        Vec<CatalogModel>,
        Some("models")
    );
}
handle!(PlatformModelProviders);
impl PlatformModelProviders {
    get!(list, "", Vec<ProviderLane>, Some("model_providers"));
    pub fn provider(&self, id: &str) -> Result<ModelProviderContext> {
        Ok(ModelProviderContext(self.0.id(id)?))
    }
}
handle!(ModelProviderContext);
impl ModelProviderContext {
    get!(fetch, "", ModelProviderConfiguration, None);
    write!(
        set_definition,
        PUT,
        "definition",
        ProviderDefinition,
        Some("command"),
        ModelProviderConfiguration,
        None
    );
    write!(
        reset_definition,
        DELETE,
        "definition",
        ProviderVersion,
        Some("command"),
        ModelProviderConfiguration,
        None
    );
    write!(
        set_model_definition,
        PUT,
        "model_definition",
        ModelDefinitionRequest,
        Some("command"),
        ModelProviderConfiguration,
        None
    );
    write!(
        remove_model_definition,
        DELETE,
        "model_definition",
        ModelVersion,
        Some("command"),
        ModelProviderConfiguration,
        None
    );
    write!(
        reset_model_definition,
        POST,
        "model_definition/reset",
        ModelVersion,
        Some("command"),
        ModelProviderConfiguration,
        None
    );
    write!(
        discover_models,
        POST,
        "model_discovery",
        ProviderVersion,
        Some("command"),
        Vec<DiscoveredModel>,
        Some("models")
    );
    write!(
        set_lane,
        PUT,
        "lane",
        ProviderLaneRequest,
        Some("command"),
        ProviderLane,
        Some("model_provider")
    );
    write!(
        set_model_visibility,
        PUT,
        "model_visibility",
        ModelVisibility,
        Some("command"),
        ProviderLane,
        Some("model_provider")
    );
    write!(
        set_model_availability,
        PUT,
        "model_availability",
        ModelAvailability,
        Some("command"),
        ProviderLane,
        Some("model_provider")
    );
    write!(
        test_model,
        POST,
        "model_test",
        ModelVersion,
        Some("command"),
        ModelTestResult,
        None
    );
    write!(
        install_api_key,
        PUT,
        "api_key",
        ProviderApiKey,
        Some("command"),
        ProviderLane,
        Some("model_provider")
    );
    command!(
        remove_api_key,
        DELETE,
        "api_key",
        ProviderLane,
        Some("model_provider")
    );
    child!(authorization, "authorization", ProviderAuthorization);
}
handle!(ProviderAuthorization);
impl ProviderAuthorization {
    get!(fetch, "", Authorization, Some("authorization"));
    write!(
        start,
        POST,
        "",
        StartAuthorization,
        Some("command"),
        AuthorizationSession,
        Some("authorization_session")
    );
    command!(clear, DELETE, "", Authorization, Some("authorization"));
    child_id!(session, "sessions", ProviderAuthorizationSession);
}
handle!(ProviderAuthorizationSession);
impl ProviderAuthorizationSession {
    get!(
        fetch,
        "",
        AuthorizationSession,
        Some("authorization_session")
    );
}
handle!(PlatformMcpConnections);
impl PlatformMcpConnections {
    list!(list, "", PageQuery, McpConnection, "mcp_connections");
    write!(
        create,
        POST,
        "",
        CreateMcpConnection,
        Some("mcp_connection"),
        McpConnection,
        Some("mcp_connection")
    );
    pub fn connection(&self, id: &str) -> Result<PlatformMcpConnection> {
        Ok(PlatformMcpConnection(self.0.id(id)?))
    }
}
handle!(PlatformMcpConnection);
impl PlatformMcpConnection {
    get!(fetch, "", McpConnection, Some("mcp_connection"));
    write!(
        update,
        PATCH,
        "",
        UpdateMcpConnection,
        Some("mcp_connection"),
        McpConnection,
        Some("mcp_connection")
    );
    write!(
        refresh_catalog,
        POST,
        "catalog_refresh",
        McpVersion,
        Some("command"),
        McpConnection,
        Some("mcp_connection")
    );
    write!(
        start_authorization,
        POST,
        "authorization",
        McpVersion,
        Some("command"),
        McpAuthorization,
        Some("authorization")
    );
    write!(
        rotate_credential,
        PUT,
        "credential",
        McpCredential,
        Some("credential"),
        McpConnection,
        Some("mcp_connection")
    );
    write!(
        clear_credential,
        DELETE,
        "credential",
        McpVersion,
        Some("command"),
        McpConnection,
        Some("mcp_connection")
    );
}
handle!(Agents);
impl Agents {
    list!(list, "", PageQuery, Agent, "agents");
    write!(
        create,
        POST,
        "",
        CreateAgent,
        Some("agent"),
        Agent,
        Some("agent")
    );
    pub fn agent(&self, id: &str) -> Result<AgentContext> {
        Ok(AgentContext(self.0.id(id)?))
    }
}
handle!(AgentContext);
impl AgentContext {
    child!(budgets, "budgets", Budgets);
    get!(fetch, "", AgentDetail, Some("agent"));
    get!(
        configuration,
        "configuration",
        AgentConfigurationSnapshot,
        None
    );
    command!(
        revoke_connection,
        POST,
        "connection_revocation",
        Agent,
        Some("agent")
    );
    command!(remove, POST, "removal", Agent, Some("agent"));
    command!(restore, POST, "restoration", Agent, Some("agent"));
    pub fn api_keys(&self) -> ApiKeys {
        ApiKeys(self.0.child("api_keys"), ApiKeyPlane::Member)
    }
    pub fn executor_api_keys(&self) -> ApiKeys {
        ApiKeys(
            self.0.child("executor/api_keys"),
            ApiKeyPlane::ExecutorTransport,
        )
    }
    child!(private_runners, "private_runners", PrivateRunners);
}
handle!(Runners);
impl Runners {
    pub async fn list(&self, query: &RunnerListQuery) -> Result<Response<RunnerPage>> {
        #[derive(serde::Deserialize)]
        struct Pagination {
            next_after: Option<String>,
        }
        #[derive(serde::Deserialize)]
        struct RunnerList {
            runners: Vec<Runner>,
            pagination: Pagination,
            measured_at: String,
        }
        let response: Response<RunnerList> = self
            .0
            .call(
                Method::GET,
                "",
                Some(query),
                None::<&()>,
                None,
                Headers::default(),
                None,
            )
            .await?;
        Ok(response.map(|body| RunnerPage {
            items: body.runners,
            next_after: body.pagination.next_after,
            measured_at: body.measured_at,
        }))
    }
    pub fn runner(&self, id: &str) -> Result<RunnerContext> {
        Ok(RunnerContext(self.0.id(id)?))
    }
}
handle!(RunnerContext);
impl RunnerContext {
    get!(fetch, "", RunnerSnapshot, None);
}
#[derive(Clone)]
pub struct ApiKeys(Resource, ApiKeyPlane);
impl ApiKeys {
    pub async fn list(&self, query: &PageQuery) -> Result<Response<Page<ApiKey>>> {
        let response = self.0.page::<ApiKey, _>("", query, "api_keys").await?;
        if response.body.items.iter().any(|key| key.plane != self.1) {
            return Err(Error::Protocol("API key response has the wrong plane"));
        }
        Ok(response)
    }
    pub async fn issue(&self, request: &IssueApiKey) -> Result<Response<ApiKeyGrant>> {
        let response: Response<ApiKeyGrant> = self
            .0
            .call(
                Method::POST,
                "",
                None::<&()>,
                Some(request),
                Some("api_key"),
                Headers::default(),
                None,
            )
            .await?;
        if response.body.api_key.plane != self.1 {
            return Err(Error::Protocol("API key grant has the wrong plane"));
        }
        Ok(response)
    }
    pub fn key(&self, id: &str) -> Result<ApiKeyContext> {
        Ok(ApiKeyContext(self.0.id(id)?))
    }
}
handle!(ApiKeyContext);
impl ApiKeyContext {
    command!(revoke, POST, "revocation", Empty, None);
}
handle!(PrivateRunners);
impl PrivateRunners {
    list!(list, "", PageQuery, PrivateRunner, "private_runners");
    write!(
        create,
        POST,
        "",
        CreatePrivateRunner,
        Some("private_runner"),
        PrivateRunner,
        Some("private_runner")
    );
    pub fn runner(&self, id: &str) -> Result<PrivateRunnerContext> {
        Ok(PrivateRunnerContext(self.0.id(id)?))
    }
}
handle!(PrivateRunnerContext);
impl PrivateRunnerContext {
    get!(fetch, "", PrivateRunner, Some("private_runner"));
    pub fn api_keys(&self) -> ApiKeys {
        ApiKeys(self.0.child("api_keys"), ApiKeyPlane::ExecutorTransport)
    }
}
handle!(Budgets);
impl Budgets {
    query_get!(list, "", PageQuery, BudgetList, None);
    create!(
        open,
        "",
        CreateBudget,
        Some("budget"),
        Budget,
        Some("budget")
    );
    pub fn budget(&self, id: &str) -> Result<BudgetContext> {
        Ok(BudgetContext(self.0.id(id)?))
    }
}
handle!(BudgetContext);
impl BudgetContext {
    get!(fetch, "", BudgetRead, None);
    list!(entries, "entries", PageQuery, BudgetLedgerEntry, "entries");
    pub async fn adjust(
        &self,
        request: &UpdateBudget,
        idempotency_key: &str,
    ) -> Result<Response<BudgetAdjustment>> {
        self.0
            .call(
                Method::PATCH,
                "",
                None::<&()>,
                Some(request),
                Some("budget"),
                Headers {
                    idempotency_key: Some(idempotency_key),
                    ..Default::default()
                },
                None,
            )
            .await
    }
    create!(
        revoke,
        "revocation",
        RevokeBudget,
        Some("revocation"),
        Budget,
        Some("budget")
    );
}
handle!(BudgetReads);
impl BudgetReads {
    query_get!(list, "", PageQuery, BudgetList, None);
    pub fn budget(&self, id: &str) -> Result<BudgetReadContext> {
        Ok(BudgetReadContext(self.0.id(id)?))
    }
}
handle!(BudgetReadContext);
impl BudgetReadContext {
    get!(fetch, "", BudgetRead, None);
    list!(entries, "entries", PageQuery, BudgetLedgerEntry, "entries");
}
handle!(Deployment);
impl Deployment {
    get!(fetch, "", DeploymentState, Some("deployment"));
    pub async fn check_release(&self, request: &CheckRelease) -> Result<Response<DeploymentState>> {
        self.0
            .transport
            .json(
                Method::POST,
                &format!("{}/release_check", self.0.path),
                None::<&()>,
                Some(&json!({"release_check":request})),
                Headers::default(),
                Some("deployment"),
                Some(Duration::from_secs(130)),
            )
            .await
    }
    create!(
        upgrade,
        "upgrades",
        UpgradeDeployment,
        None,
        DeploymentUpgrade,
        Some("upgrade")
    );
    child_id!(operation, "upgrades", DeploymentOperation);
}
handle!(DeploymentOperation);
impl DeploymentOperation {
    get!(fetch, "", DeploymentUpgrade, Some("upgrade"));
    query_get!(log, "log", CursorQuery, DeploymentLog, Some("log"));
    /// One finite observation window. Dropping it never mutates the operation.
    pub async fn stream(
        &self,
        query: &CursorQuery,
        last_event_id: Option<&str>,
    ) -> Result<Pin<Box<dyn Stream<Item = Result<DeploymentEvent>> + Send>>> {
        let mut request = self
            .0
            .transport
            .request(
                Method::GET,
                &format!("{}/stream", self.0.path),
                Some(query),
                Headers::default(),
                None,
            )
            .await?
            .header("Accept", "text/event-stream");
        if let Some(id) = last_event_id {
            request = request.header("Last-Event-ID", id);
        }
        let response = request.send().await.map_err(Error::transport)?;
        if !response.status().is_success() {
            return Transport::decode::<Empty>(response, None)
                .await
                .map(|_| unreachable!());
        }
        Ok(Box::pin(response.bytes_stream().eventsource().map(
            |event| {
                let event =
                    event.map_err(|_| Error::Protocol("invalid deployment event stream"))?;
                let data: Value = serde_json::from_str(&event.data)
                    .map_err(|_| Error::Protocol("invalid deployment event JSON"))?;
                match event.event.as_str() {
                    "deployment.progress.v1" => Ok(DeploymentEvent::Progress {
                        id: event.id,
                        log: serde_json::from_value(data)
                            .map_err(|_| Error::Protocol("invalid deployment progress"))?,
                    }),
                    "deployment.error.v1" => Ok(DeploymentEvent::Error {
                        id: event.id,
                        error: serde_json::from_value(data)
                            .map_err(|_| Error::Protocol("invalid deployment error"))?,
                    }),
                    _ => Ok(DeploymentEvent::Unknown {
                        event: event.event,
                        id: event.id,
                        data,
                    }),
                }
            },
        )))
    }
}
