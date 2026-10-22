//! Named request documents. Optional nullable fields use [`Field`] to preserve omission.
use super::{Field, JsonObject};
use crate::{authoring::Step, credentials::SecretString};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
macro_rules! request {
    ($name:ident { $($field:ident : $ty:ty),* $(,)? } { $($optional:ident : $oty:ty),* $(,)? }) => {
        #[derive(Clone, Debug, Default, Serialize, Deserialize)]
        pub struct $name {
            $(pub $field: $ty,)*
            $(#[serde(default, skip_serializing_if="Field::is_unset")] pub $optional: Field<$oty>,)*
        }
    };
}
macro_rules! query {
    ($name:ident { $($(#[$attr:meta])* $field:ident : $ty:ty),* $(,)? }) => {
        #[derive(Clone, Debug, Default, Serialize, Deserialize)]
        pub struct $name { $($(#[$attr])* #[serde(skip_serializing_if="Option::is_none")] pub $field: Option<$ty>,)* }
    };
}
macro_rules! vocabulary {
    ($name:ident { $first:ident $(,$variant:ident)* $(,)? }) => {
        #[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
        #[serde(rename_all="snake_case")]
        pub enum $name { #[default] $first, $($variant),* }
    };
}
vocabulary!(Workload {
    TextGeneration,
    Embedding,
    ImageGeneration,
    SpeechGeneration,
    Transcription
});
vocabulary!(AccessMode {
    AccountWide,
    Private
});
vocabulary!(AccessLevel { Full, Read, None });
vocabulary!(ApprovalMode { Bypass, Ask, Rules });
vocabulary!(DeliveryMode {
    Queue,
    Steer,
    SteerNow
});
vocabulary!(InputKind {
    Message,
    DirectReply
});
vocabulary!(InputRole {
    User,
    Assistant,
    System,
    Tool
});
vocabulary!(PromptRole {
    System,
    Developer,
    User
});
vocabulary!(ContextMode { Assembled, Raw });
vocabulary!(PromptMechanism {
    Default,
    Assembly,
    Raw
});
vocabulary!(Order { Asc, Desc });
vocabulary!(RunKind {
    All,
    Standalone,
    Conversation
});
vocabulary!(AttentionView {
    Actionable,
    Following
});
vocabulary!(WorkReportUnit { Hour, Day });
vocabulary!(Outcome { Completed, Failed });
vocabulary!(FailureResolution { Cascade, Continue });
vocabulary!(AuthType {
    None,
    Bearer,
    Oauth
});
vocabulary!(MessageVisibility { Public, Private });
vocabulary!(WorkspaceListState { Live, Archived });
vocabulary!(ConversationOrder {
    PublicId,
    LastActivityAt
});
vocabulary!(MachineKind {
    Runner,
    ToolProvider
});
vocabulary!(MemoryScope {
    Conversation,
    Workspace,
    User,
    Agent,
    Speaker
});
vocabulary!(MemoryAccess { Read, ReadWrite });
vocabulary!(SelectionSource {
    Default,
    Inherited,
    Explicit
});
vocabulary!(SelectionConstraint {
    Any,
    Model,
    Provider,
    Route
});
vocabulary!(ApprovalVerdict { Allow, Ask, Deny });
vocabulary!(RuleOrigin {
    Model,
    Author,
    Kernel
});
vocabulary!(NamedAgentScope { Instance, Steward });
vocabulary!(ConversationReach { Workspace, Subtree });
query!(PageQuery {
    after: String,
    limit: u32,
    order: Order
});
query!(WorkspaceListQuery {
    after: String,
    limit: u32,
    order: Order,
    state: WorkspaceListState,
    dedicated_to_current_agent: bool
});
query!(ConversationListQuery {
    after: String,
    limit: u32,
    order: Order,
    order_by: ConversationOrder,
    #[serde(serialize_with = "serialize_numeric_bool")]
    side: bool,
    answering_user_public_id: String
});
query!(ConversationArchiveQuery {
    after: String,
    limit: u32,
    order: Order,
    order_by: ConversationOrder,
    answering_user_public_id: String
});
query!(ConversationChildrenQuery {
    after: String,
    limit: u32,
    order: Order,
    order_by: ConversationOrder
});
query!(CrossWorkspaceConversationQuery {
    after: String,
    limit: u32,
    order: Order,
    order_by: ConversationOrder,
    answering_user_public_id: String,
    archived: bool,
    metadata_key: String,
    metadata_value: String
});
vocabulary!(ConversationArchiveFilter {
    Exclude,
    Include,
    Only
});
query!(ConversationSearchQuery {
    query: String,
    archived: ConversationArchiveFilter,
    include_auxiliary: bool,
    answering_user_public_id: String,
    limit: u32,
    after: String
});
query!(ConversationFieldQuery {
    location: String,
    after: String
});
query!(RunListQuery {
    after: String,
    limit: u32,
    order: Order,
    status: String,
    attention: String,
    from: String,
    to: String,
    answering_user_public_id: String,
    agent_public_id: String,
    executor_public_id: String,
    kind: RunKind
});
query!(CrossWorkspaceRunQuery {
    workspace_public_id: String,
    after: String,
    limit: u32,
    order: Order,
    status: String,
    attention: String,
    from: String,
    to: String,
    answering_user_public_id: String,
    agent_public_id: String,
    executor_public_id: String,
    kind: RunKind
});
query!(AttentionQuery {
    workspace_public_id: String,
    view: AttentionView,
    after: String,
    limit: u32,
    order: Order
});
query!(WorkReportQuery {
    workspace_public_id: String,
    agent_public_id: String,
    from: String,
    to: String,
    unit: WorkReportUnit
});
query!(EventQuery {
    after: String,
    limit: u32
});
query!(HistoryQuery {
    around_turn_public_id: String,
    after_position: i64,
    before_position: i64,
    limit: u32,
    include_execution: bool,
    execution_before: String,
    execution_prefix: String
});
query!(ModelListQuery { workload: Workload });
query!(ExecutorListQuery {
    kind: crate::types::names::ExecutorKind,
    role: crate::types::names::ExecutorKind
});
query!(MaterializationQuery {
    include_hidden: bool
});
query!(OperationQuery {
    after: u64,
    limit: u32
});
query!(ScheduleListQuery {
    after: String,
    limit: u32,
    order: Order,
    status: String
});
query!(GlobalScheduleQuery {
    workspace_public_id: String,
    after: String,
    limit: u32,
    order: Order,
    status: String
});
vocabulary!(AnalysisGroup {
    ProviderId,
    CatalogModelRef,
    Workload,
    Status
});
vocabulary!(AnalysisRank {
    RequestCount,
    TotalTokens,
    CostAmount
});
query!(ModelUsageAnalysisQuery {
    from: String,
    to: String,
    provider_id: String,
    catalog_model_ref: String,
    workload: Workload,
    status: String,
    group_by: AnalysisGroup,
    rank_by: AnalysisRank,
    limit: u32
});
query!(WorkAnalysisQuery {
    workspace_public_id: String,
    agent_public_id: String,
    from: String,
    to: String,
    provider_id: String,
    catalog_model_ref: String,
    workload: Workload,
    status: String,
    group_by: AnalysisGroup,
    rank_by: AnalysisRank,
    limit: u32
});
query!(InferenceListQuery {
    after: String,
    limit: u32,
    order: Order,
    workload: Workload
});
query!(CursorQuery { cursor: String });
query!(ReceiptQuery {
    idempotency_key: String
});

mod execution;
mod platform;
mod workspace;
pub use execution::*;
pub use platform::*;
pub use workspace::*;

fn serialize_numeric_bool<S: serde::Serializer>(
    value: &Option<bool>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    match value {
        Some(value) => serializer.serialize_u8(u8::from(*value)),
        None => serializer.serialize_none(),
    }
}

query!(McpConnectionListQuery {
    after: String,
    limit: u32,
    order: Order,
    agent_public_id: String
});
query!(McpConnectionQuery {
    agent_public_id: String
});

query!(PlatformModelListQuery {
    workload: Workload,
    available: bool
});
