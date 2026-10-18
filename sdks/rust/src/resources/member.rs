use super::*;
use types::member::*;
impl Client {
    child!(schedules, "schedules", GlobalSchedules);
    child!(profile, "profile", ProfileContext);
    child!(workspaces, "workspaces", Workspaces);
    child_id!(workspace, "workspaces", WorkspaceContext);
    child!(uploads, "uploads", Uploads);
    child!(tools, "tools", ToolCatalog);
    child!(models, "models", Models);
    child!(model_providers, "model_providers", ModelProviders);
    child!(mcp_connections, "mcp_connections", McpConnections);
    child!(executors, "executors", Executors);
    list!(
        conversations,
        "conversations",
        CrossWorkspaceConversationQuery,
        ConversationSummary,
        "conversations"
    );
}
handle!(ProfileContext);
impl ProfileContext {
    child!(budgets, "budgets", BudgetReads);
    get!(fetch, "", Profile, None);
    write!(
        configure,
        PUT,
        "configuration", DeclareConfiguration, None, Profile, None
    );
    child!(agents, "agents", NamedAgents);
    child!(memory, "memory", Memory);
    child!(store_entries, "store_entries", StoreEntries);
    child!(prompt_documents, "prompt_documents", PromptDocuments);
    write!(
        resolve_ingress_speaker,
        POST,
        "ingress_speakers",
        IngressSpeakerRequest,
        Some("ingress_speaker"),
        IngressSpeaker,
        Some("ingress_speaker")
    );
}
handle!(NamedAgents);
impl NamedAgents {
    get!(list, "", Vec<NamedAgent>, Some("agents"));
    pub fn agent(&self, name: &str) -> Result<NamedAgentContext> {
        Ok(NamedAgentContext(self.0.id(name)?))
    }
}
handle!(NamedAgentContext);
impl NamedAgentContext {
    write!(
        declare,
        PUT,
        "",
        NamedAgentRequest,
        None,
        NamedAgent,
        Some("agent")
    );
    command!(delete, DELETE, "", Empty, None);
    child!(memory, "memory", Memory);
}
handle!(Workspaces);
impl Workspaces {
    list!(list, "", WorkspaceListQuery, WorkspaceSummary, "workspaces");
    create!(
        create,
        "",
        CreateWorkspace,
        Some("workspace"),
        Workspace,
        Some("workspace")
    );
    pub fn workspace(&self, id: &str) -> Result<WorkspaceContext> {
        Ok(WorkspaceContext(self.0.id(id)?))
    }
}
handle!(WorkspaceContext);
impl WorkspaceContext {
    get!(fetch, "", Workspace, Some("workspace"));
    write!(
        update,
        PATCH,
        "",
        UpdateWorkspace,
        Some("workspace"),
        Workspace,
        Some("workspace")
    );
    write!(
        update_access_mode,
        PUT,
        "access_mode",
        UpdateAccessMode,
        Some("access_mode"),
        Workspace,
        Some("workspace")
    );
    write!(
        transfer_ownership,
        POST,
        "ownership_transfer",
        TransferOwnership,
        Some("ownership_transfer"),
        Workspace,
        Some("workspace")
    );
    write!(
        set_messaging,
        PUT,
        "messaging",
        SetMessaging,
        Some("messaging"),
        WorkspaceMessaging,
        Some("messaging")
    );
    write!(
        set_tool_provider_overrides,
        PUT,
        "tool_provider_overrides",
        SetToolProviderOverrides,
        Some("tool_provider_overrides"),
        Workspace,
        Some("workspace")
    );
    get!(
        messaging,
        "messaging",
        WorkspaceMessaging,
        Some("messaging")
    );
    get!(principals, "principals", Vec<Principal>, Some("principals"));
    pub async fn archive(&self, lock_version: i64) -> Result<Response<Workspace>> {
        self.lifecycle("archival", lock_version).await
    }
    pub async fn restore(&self, lock_version: i64) -> Result<Response<Workspace>> {
        self.lifecycle("restoration", lock_version).await
    }
    async fn lifecycle(&self, path: &str, lock_version: i64) -> Result<Response<Workspace>> {
        self.0
            .call(
                Method::POST,
                path,
                None::<&()>,
                Some(&json!({"lock_version":lock_version})),
                Some("command"),
                Headers::default(),
                Some("workspace"),
            )
            .await
    }
    pub async fn delete(&self, lock_version: i64) -> Result<Response<Workspace>> {
        self.0
            .call(
                Method::DELETE,
                "",
                Some(&[("lock_version", lock_version)]),
                None::<&()>,
                None,
                Headers::default(),
                Some("workspace"),
            )
            .await
    }
    child!(store_entries, "store_entries", StoreEntries);
    child!(memory, "memory", Memory);
    child!(prompt_documents, "prompt_documents", PromptDocuments);
    child!(conversations, "conversations", Conversations);
    child_id!(conversation, "conversations", ConversationContext);
    child!(runs, "runs", Runs);
    child_id!(run, "runs", RunContext);
    child!(inference_requests, "inference_requests", InferenceRequests);
    list!(
        schedules,
        "schedules",
        ScheduleListQuery,
        Schedule,
        "schedules"
    );
    query_get!(
        search_conversations,
        "conversation_search",
        ConversationSearchQuery,
        ConversationSearchPage,
        None
    );
}
handle!(ToolCatalog);
impl ToolCatalog {
    get!(list, "", Vec<KernelTool>, Some("tools"));
    write!(
        assemble,
        POST,
        "assembly", AssembleTools, None, ToolAssembly, None
    );
}
handle!(Models);
impl Models {
    query_get!(list, "", ModelListQuery, Vec<CatalogModel>, Some("models"));
}
handle!(ModelProviders);
impl ModelProviders {
    get!(list, "", Vec<ProviderLane>, Some("model_providers"));
}
handle!(McpConnections);
impl McpConnections {
    list!(
        list,
        "",
        McpConnectionListQuery,
        McpConnection,
        "mcp_connections"
    );
    pub fn connection(&self, id: &str) -> Result<McpConnectionContext> {
        Ok(McpConnectionContext(self.0.id(id)?))
    }
}
handle!(McpConnectionContext);
impl McpConnectionContext {
    query_get!(
        fetch,
        "",
        McpConnectionQuery,
        McpConnection,
        Some("mcp_connection")
    );
}
handle!(Executors);
impl Executors {
    query_get!(
        list,
        "",
        ExecutorListQuery,
        Vec<DiscoveredExecutor>,
        Some("executors")
    );
    pub fn executor(&self, id: &str) -> Result<DiscoveredExecutorContext> {
        Ok(DiscoveredExecutorContext(self.0.id(id)?))
    }
}
handle!(DiscoveredExecutorContext);
impl DiscoveredExecutorContext {
    get!(fetch, "", DiscoveredExecutor, Some("executor"));
}
