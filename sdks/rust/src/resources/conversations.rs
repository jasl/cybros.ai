use super::*;
use types::member::*;
handle!(Conversations);
impl Conversations {
    list!(
        list,
        "",
        ConversationListQuery,
        ConversationSummary,
        "conversations"
    );
    list!(
        archived,
        "archived",
        ConversationArchiveQuery,
        ConversationSummary,
        "conversations"
    );
    create!(
        create,
        "",
        CreateConversation,
        Some("conversation"),
        Conversation,
        Some("conversation")
    );
    pub fn conversation(&self, id: &str) -> Result<ConversationContext> {
        Ok(ConversationContext(self.0.id(id)?))
    }
}
handle!(ConversationContext);
impl ConversationContext {
    get!(fetch, "", Conversation, Some("conversation"));
    /// Download gzip bytes. The caller owns the stream and discards partial output on failure.
    pub async fn export(&self) -> Result<Download> {
        self.0
            .transport
            .download(
                &format!("{}/export", self.0.path),
                None::<&()>,
                Headers::default(),
            )
            .await
    }
    write!(
        update,
        PATCH,
        "",
        UpdateConversation,
        Some("conversation"),
        Conversation,
        Some("conversation")
    );
    command!(archive, POST, "archive", Conversation, Some("conversation"));
    command!(
        unarchive,
        POST,
        "unarchive",
        Conversation,
        Some("conversation")
    );
    command!(delete, DELETE, "", Empty, None);
    command!(cancel, POST, "cancellation", Empty, None);
    list!(
        children,
        "children",
        ConversationChildrenQuery,
        ConversationSummary,
        "conversations"
    );
    child!(inputs, "inputs", ConversationInputs);
    child!(schedules, "schedules", Schedules);
    child!(memory, "memory", Memory);
    child!(store_entries, "store_entries", StoreEntries);
    child!(turns, "turns", Turns);
    query_get!(
        history,
        "history",
        HistoryQuery,
        ConversationHistoryPage,
        None
    );
    query_get!(
        regeneration_receipt,
        "regeneration_receipt",
        ReceiptQuery,
        ConversationRegeneration,
        None
    );
    write!(
        set_memory_context,
        POST,
        "memory_context",
        SetMemoryContext,
        None,
        Conversation,
        Some("conversation")
    );
    write!(
        set_default_runner,
        PUT,
        "default_runner",
        SetDefaultRunner,
        Some("default_runner"),
        Conversation,
        Some("conversation")
    );
    write!(
        set_access,
        PUT,
        "access",
        SetAccess,
        Some("access"),
        Conversation,
        Some("conversation")
    );
    create!(
        fork,
        "forks",
        ForkConversation,
        Some("fork"),
        ForkedConversation,
        None
    );
    write!(
        estimate_input,
        POST,
        "context_estimate",
        ContextEstimate,
        Some("context_estimate"),
        InputEstimate,
        Some("context_estimate")
    );
    write!(
        compact,
        POST,
        "compaction",
        ModelRequest,
        Some("compaction"),
        ConversationCompaction,
        None
    );
    query_get!(events, "events", EventQuery, EventPage, None);
}
handle!(Inputs);
impl Inputs {
    get!(list, "", InputList, None);
    create!(
        create,
        "",
        CreateRunInput,
        Some("input"),
        Input,
        Some("input")
    );
    write!(
        reorder,
        POST,
        "reorder",
        ReorderInputs,
        None,
        Vec<Input>,
        Some("inputs")
    );
    pub fn input(&self, id: &str) -> Result<InputContext> {
        Ok(InputContext(self.0.id(id)?))
    }
}
handle!(InputContext);
impl InputContext {
    write!(
        update,
        PATCH,
        "",
        UpdateRunInput,
        Some("input"),
        Input,
        Some("input")
    );
    command!(delete, DELETE, "", Empty, None);
}
handle!(ConversationInputs);
impl ConversationInputs {
    get!(list, "", InputList, None);
    create!(create, "", CreateInput, Some("input"), Input, Some("input"));
    write!(
        reorder,
        POST,
        "reorder",
        ReorderInputs,
        None,
        Vec<Input>,
        Some("inputs")
    );
    pub fn input(&self, id: &str) -> Result<ConversationInputContext> {
        Ok(ConversationInputContext(self.0.id(id)?))
    }
}
handle!(ConversationInputContext);
impl ConversationInputContext {
    write!(
        update,
        PATCH,
        "",
        UpdateInput,
        Some("input"),
        Input,
        Some("input")
    );
    command!(delete, DELETE, "", Empty, None);
    query_get!(
        materialization,
        "materialization",
        MaterializationQuery,
        InputMaterialization,
        Some("materialization")
    );
}
handle!(Turns);
impl Turns {
    query_get!(list, "", TurnsQuery, TurnPage, None);
    pub fn turn(&self, id: &str) -> Result<TurnContext> {
        Ok(TurnContext(self.0.id(id)?))
    }
}
handle!(TurnContext);
impl TurnContext {
    query_get!(fetch, "", MaterializationQuery, Turn, Some("turn"));
    write!(
        set_view_state,
        PATCH,
        "",
        ViewState,
        Some("turn"),
        TurnReference,
        Some("turn")
    );
    command!(delete, DELETE, "", Empty, None);
    write!(
        edit,
        POST,
        "edit",
        EditTurn,
        Some("edit"),
        Variant,
        Some("variant")
    );
    create!(
        regenerate,
        "regeneration",
        RegenerateTurn,
        Some("regeneration"),
        ConversationRegeneration,
        None
    );
    get!(variants, "variants", VariantDeck, None);
    child_id!(variant, "variants", VariantContext);
}
handle!(VariantContext);
impl VariantContext {
    get!(fetch, "", VariantRead, None);
    pub async fn field(
        &self,
        field: &str,
        query: &ConversationFieldQuery,
    ) -> Result<Response<ConversationFieldPage>> {
        self.0
            .call(
                Method::GET,
                &format!("fields/{}", segment(field)?),
                Some(query),
                None::<&()>,
                None,
                Headers::default(),
                None,
            )
            .await
    }
    get!(request, "request", SealedRequest, Some("request"));
    query_get!(
        reasoning,
        "reasoning",
        TranscriptQuery,
        ConversationReasoningPage,
        None
    );
    command!(activate, POST, "activation", Variant, Some("variant"));
    write!(
        set_view_state,
        PATCH,
        "",
        VariantViewState,
        Some("variant"),
        Variant,
        Some("variant")
    );
}
handle!(Schedules);
impl Schedules {
    list!(list, "", ScheduleListQuery, Schedule, "schedules");
    create!(
        create,
        "",
        CreateSchedule,
        Some("schedule"),
        Schedule,
        Some("schedule")
    );
    pub fn schedule(&self, id: &str) -> Result<ScheduleContext> {
        Ok(ScheduleContext(self.0.id(id)?))
    }
}
handle!(ScheduleContext);
impl ScheduleContext {
    get!(fetch, "", Schedule, Some("schedule"));
    write!(
        update,
        PATCH,
        "",
        UpdateSchedule,
        Some("schedule"),
        Schedule,
        Some("schedule")
    );
    command!(pause, POST, "pause", Schedule, Some("schedule"));
    command!(resume, POST, "resume", Schedule, Some("schedule"));
    command!(cancel, POST, "cancel", Schedule, Some("schedule"));
    command!(run, POST, "run", Schedule, Some("schedule"));
    query_get!(
        executions,
        "executions",
        PageQuery,
        ScheduleExecutionPage,
        None
    );
}
