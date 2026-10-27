use super::*;
request!(CreateWorkspace {name:String} {access_mode:AccessMode,metadata:JsonObject});
request!(UpdateWorkspace {lock_version:i64} {name:String,metadata:JsonObject});
request!(UpdateAccessMode {lock_version:i64,access_mode:AccessMode} {});
request!(TransferOwnership {lock_version:i64,target_user_public_id:String} {});
request!(SetToolProviderOverrides {lock_version:i64,overrides:BTreeMap<String,String>} {});
request!(MessagingAgent {agent_public_id:String,mode:MessageVisibility,allowed_sender_public_ids:Vec<String>} {});
request!(SetMessaging {lock_version:i64,agents:Vec<MessagingAgent>} {});
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AccessEntry {
    User {
        user_public_id: String,
        level: AccessLevel,
    },
    Handle {
        handle: String,
        level: AccessLevel,
    },
}
request!(SetAccess {default:AccessLevel,entries:Vec<AccessEntry>} {});
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum MemorySource {
    Collection {
        collection_public_id: String,
    },
    Scope {
        scope: MemoryScope,
        #[serde(skip_serializing_if = "Option::is_none")]
        conversation_public_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        speaker_public_id: Option<String>,
    },
}
impl Default for MemorySource {
    fn default() -> Self {
        Self::Scope {
            scope: MemoryScope::Conversation,
            conversation_public_id: None,
            speaker_public_id: None,
        }
    }
}
request!(MemoryBinding {name:String,source:MemorySource,access:MemoryAccess} {});
request!(MemoryRootSource {scope:MemoryScope} {});
request!(MemoryRootLimit {name:MemoryScope,source:MemoryRootSource,access:MemoryAccess} {});
request!(MemoryContextLimit {bindings:Vec<MemoryRootLimit>} {});
query!(OwnedMemoryCollectionQuery {
    after: String,
    limit: u32,
    default: bool,
    speaker_public_id: String
});
request!(CreateMemoryCollection {} {name:String,description:String,speaker_public_id:String,default:bool});
request!(UpdateMemoryCollection {lock_version:i64} {name:String,description:String});
request!(MemoryCollectionVersion {lock_version:i64} {});
request!(MemoryContext {bindings:Vec<MemoryBinding>} {});
request!(CreateConversation {} {title:String,metadata:JsonObject,billing_subject:String,cost_limit:String,default_runner_executor_public_id:String,answering_user_public_id:String,access:SetAccess,memory_context:MemoryContext});
request!(UpdateConversation {lock_version:i64} {title:String,metadata:JsonObject,cost_limit:String});
request!(SetMemoryContext {memory_context:Option<MemoryContext>} {});
request!(SetDefaultRunner {executor_public_id:Option<String>} {});
request!(ForkConversation {} {turn_public_id:String,variant_public_id:String,title:String,side:bool});
request!(MemoryRead {path:String} {speaker_public_id:String});
request!(CollectionMemoryWrite {path:String,content:String,expected_public_id:Option<String>,expected_lock_version:Option<i64>} {description:String});
request!(MemoryWrite {expected_collection_public_id:String,path:String,content:String,expected_public_id:Option<String>,expected_lock_version:Option<i64>} {description:String,speaker_public_id:String});
request!(CollectionMemoryEdit {path:String,old_text:String,new_text:String,expected_public_id:String,expected_lock_version:i64} {});
request!(MemoryEdit {expected_collection_public_id:String,path:String,old_text:String,new_text:String,expected_public_id:String,expected_lock_version:i64} {speaker_public_id:String});
request!(CollectionMemoryDelete {path:String,expected_public_id:String,expected_lock_version:i64} {});
request!(MemoryDelete {expected_collection_public_id:String,path:String,expected_public_id:String,expected_lock_version:i64} {speaker_public_id:String});
request!(MemoryGrep {pattern:String} {path:String,ignore_case:bool,limit:u32,speaker_public_id:String});
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MemoryListQuery {
    #[serde(
        rename = "memory[speaker_public_id]",
        skip_serializing_if = "Option::is_none"
    )]
    pub speaker_public_id: Option<String>,
}
request!(WritePromptDocument {content:String} {role:PromptRole});
request!(CreateStoreEntry {namespace:String,key:String,value:Value} {});
request!(UpdateStoreEntry {lock_version:i64,value:Value} {});
request!(IngressSpeakerRequest {channel_key:String,external_id:String,display_name:String} {});
request!(ModelSelection {source:SelectionSource,model:String,constraint:SelectionConstraint} {alternatives:Vec<String>});
request!(ApprovalRule {tool:String,verdict:ApprovalVerdict} {path:String,r#match:String,reason:String,origin:RuleOrigin});
request!(McpToolImport {connection_public_id:String,tool_name:String,name:String} {});
request!(AgentConfigurationRequest {} {
    tool_definitions:Vec<ToolDeclaration>,kernel_tools:Vec<String>,runner_executor_public_ids:Vec<String>,
    runner_tool_names:Vec<String>,mcp_tools:Vec<McpToolImport>,
    approval_mode:ApprovalMode,approval_rules:Vec<ApprovalRule>,prompt_mechanism:PromptMechanism,
    prompt_template:JsonObject,compaction_policy:JsonObject,lifecycle_hooks:JsonObject,
    default_model:String,image_model:String,fallback_models:Vec<String>,memory_context_limit:MemoryContextLimit,
    conversation_reach:ConversationReach,delegation_catalog:Vec<JsonObject>
});
request!(PromptDocumentsRequest {} {system_prompt:WritePromptDocument,summarizer:WritePromptDocument});
request!(DeclareConfiguration {configuration:AgentConfigurationRequest} {prompt_documents:PromptDocumentsRequest});
request!(NamedAgentRequest {scope:NamedAgentScope,description:String,configuration:AgentConfigurationRequest} {display_name:String,system_prompt:String,summarizer:String,create_only:bool});

/// Known declaration shapes are typed; provider-native tools retain their own JSON grammar.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ToolDeclaration {
    Function(FunctionDeclaration),
    FlatFunction(FlatFunctionDeclaration),
    Alias(ToolAlias),
    Provider(JsonObject),
}
vocabulary!(FunctionType { Function });
request!(FunctionDefinition {name:String} {description:String,parameters:JsonObject,strict:bool});
request!(FunctionDeclaration {r#type:FunctionType,function:FunctionDefinition} {defer_loading:bool,route:DeclarationRoute,output_schema:JsonObject,effect_profile:EffectProfile});
request!(FlatFunctionDeclaration {r#type:FunctionType,name:String} {description:String,parameters:JsonObject,strict:bool,defer_loading:bool,route:DeclarationRoute,output_schema:JsonObject,effect_profile:EffectProfile});
request!(AliasParameter {maps_to:String} {invert:bool,description:String});
request!(ToolAlias {name:String,canonical:String} {params:BTreeMap<String,AliasParameter>,omit:Vec<String>,description:String,defer_loading:bool});
vocabulary!(EffectKind {
    ReadOnly,
    Pure,
    Write
});
vocabulary!(EffectScope { Closed, Open });
vocabulary!(Idempotency {
    Intrinsic,
    Keyed,
    None
});
vocabulary!(Reconciliation { None, Lookup });
request!(EffectProfile {kind:EffectKind,destructive:bool,effect_scope:EffectScope,idempotency:Idempotency,reconciliation:Reconciliation} {});
/// A member-authored Runner step may use its host's default Runner.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ToolRoute {
    Runner {
        #[serde(skip_serializing_if = "Option::is_none")]
        runner_executor_public_id: Option<String>,
    },
    Mcp {
        connection_public_id: String,
    },
}
/// A model-callable route always freezes an explicit target and served name.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DeclarationRoute {
    Runner {
        runner_executor_public_id: String,
        tool_name: String,
    },
    Mcp {
        connection_public_id: String,
        tool_name: String,
    },
}
request!(AssembleTools {} {default_runner_executor_public_id:String,configuration:AgentConfigurationRequest,conversation_public_id:String,agent_public_id:String});

vocabulary!(ConversationLinkState {
    Active,
    Closed,
    All
});
query!(ConversationLinkQuery {
    state: ConversationLinkState,
    after: String,
    limit: u32
});
request!(CreateConversationLink { agent_public_id: String, peer_conversation_public_id: String, peer_agent_public_id: String } {});
