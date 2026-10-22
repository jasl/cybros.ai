use super::*;
request!(ModelRequest {} {model:String,reasoning_effort:String,reasoning_enabled:bool});
vocabulary!(InlinePosition { Lead, Tail });
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum InlineDocument {
    Slot {
        slot: String,
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        role: Option<InputRole>,
    },
    Positioned {
        role: InlineEntryRole,
        position: InlinePosition,
        text: String,
    },
}
vocabulary!(InlineEntryRole { Developer, User });
vocabulary!(ReasoningReplayMode {
    None,
    LastTurn,
    All
});
request!(ReasoningReplay {mode:ReasoningReplayMode} {});
request!(CreateInput {} {
    executor_contexts:JsonObject,
    text:String,entries:Vec<Value>,kind:InputKind,role:InputRole,model:ModelRequest,
    configuration:JsonObject,agent_configuration:AgentConfigurationRequest,model_selection:ModelSelection,
    fallback_models:Vec<String>,delivery_mode:DeliveryMode,context_mode:ContextMode,history:JsonObject,
    reasoning_replay:ReasoningReplay,inline:Vec<InlineDocument>,visible_in_context:bool,expected_context_revision:i64,
    expected_tail_turn_public_id:String,expected_steering_run_public_id:String,tool_names:Vec<String>,
    approval_mode:ApprovalMode,instructions:String,answering_user_public_id:String,attachments:Vec<String>,
    variables:JsonObject,steps:Vec<Step>,deliver_at:String,deliver_in:String,speaker_public_id:String
});
request!(UpdateInput {} {
    executor_contexts:JsonObject,
    expected_lock_version:i64,text:String,entries:Vec<Value>,model:ModelRequest,
    configuration:JsonObject,agent_configuration:AgentConfigurationRequest,model_selection:ModelSelection,
    fallback_models:Vec<String>,delivery_mode:DeliveryMode,context_mode:ContextMode,history:JsonObject,
    reasoning_replay:ReasoningReplay,inline:Vec<InlineDocument>,visible_in_context:bool,tool_names:Vec<String>,
    approval_mode:ApprovalMode,instructions:String,attachments:Vec<String>,variables:JsonObject,
    steps:Vec<Step>,deliver_at:String,deliver_in:String
});
vocabulary!(RunInputKind { Message });
vocabulary!(RunInputRole { User });
request!(CreateRunInput {} {text:String,entries:Vec<Value>,kind:RunInputKind,role:RunInputRole,attachments:Vec<String>,delivery_mode:DeliveryMode,speaker_public_id:String});
request!(UpdateRunInput {} {text:String,entries:Vec<Value>,attachments:Vec<String>,delivery_mode:DeliveryMode,expected_lock_version:i64});
request!(ReorderInputs {inputs:Vec<String>} {});
request!(ContextEstimate {} {prompt:String,render:bool,answering_user_public_id:String,speaker_public_id:String,model:ModelRequest,history:JsonObject,reasoning_replay:ReasoningReplay,inline:Vec<InlineDocument>,variables:JsonObject,template:JsonObject,configuration:JsonObject,agent_configuration:AgentConfigurationRequest,model_selection:ModelSelection,fallback_models:Vec<String>});
request!(ViewState {} {visibility:String,concealed:bool});
request!(EditTurn {} {text:String,entries:Vec<Value>});
request!(RegenerateTurn {} {model:ModelRequest,configuration:JsonObject,agent_configuration:AgentConfigurationRequest,model_selection:ModelSelection,fallback_models:Vec<String>});
request!(CreateRun {steps:Vec<Step>,approval_mode:ApprovalMode} {billing_subject:String,prompt_mechanism:PromptMechanism,approval_rules:Vec<ApprovalRule>,default_runner_executor_public_id:String,speaker_public_id:String,model_selection:ModelSelection,fallback_models:Vec<String>});
request!(AppendTasks {steps:Vec<Step>} {expected_revision:i64,resolve:Vec<TaskResolution>});
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum TaskResolution {
    Key(String),
    Entry {
        task: String,
        #[serde(default, skip_serializing_if = "Field::is_unset")]
        content: Field<Value>,
    },
}
request!(ResolveTask {} {answer:JsonObject,resolution_token:SecretString,content:Value,structured_content:Value,result_type:String,outcome:Outcome});
request!(DenyTask {} {reason:String});
request!(AbandonTask {} {resolution:FailureResolution});
request!(CreateInferenceRequest {model:ModelRequest,workload:Workload,input:Value} {configuration:JsonObject,billing_subject:String,model_selection:ModelSelection,fallback_models:Vec<String>,upload_public_ids:Vec<String>});
request!(InferenceEstimate {model:ModelRequest,workload:Workload,input:Value} {configuration:JsonObject,upload_public_ids:Vec<String>,model_selection:ModelSelection,fallback_models:Vec<String>});
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ScheduleRuleRequest {
    Once {
        run_at: String,
    },
    Interval {
        every_seconds: u64,
        starts_at: String,
    },
    Daily {
        local_time: String,
        time_zone: String,
    },
}
impl Default for ScheduleRuleRequest {
    fn default() -> Self {
        Self::Once {
            run_at: String::new(),
        }
    }
}
request!(CreateSchedule {prompt:String,rule:ScheduleRuleRequest} {executor_contexts:JsonObject,name:String,model:ModelRequest,configuration:JsonObject,tool_names:Vec<String>,approval_mode:ApprovalMode,answering_user_public_id:String,speaker_public_id:String,model_selection:ModelSelection,fallback_models:Vec<String>,source_run_public_id:String,source_task_key:String});
request!(UpdateSchedule {expected_lock_version:i64} {executor_contexts:JsonObject,name:String,prompt:String,rule:ScheduleRuleRequest,model:ModelRequest,configuration:JsonObject,tool_names:Vec<String>,approval_mode:ApprovalMode,answering_user_public_id:String,speaker_public_id:String,model_selection:ModelSelection,fallback_models:Vec<String>});
request!(AnnouncedTool {name:String,effect_profile:EffectProfile} {timeout_ms:u64,description:String,input_schema:JsonObject,mcp:JsonObject});
request!(AnnouncedDocument {name:String,description:String} {});
request!(ServiceAnnouncement {tools:Vec<AnnouncedTool>} {environment:JsonObject,documents:Vec<AnnouncedDocument>});
request!(ServiceAnnouncements {} {agent:ServiceAnnouncement,runner:ServiceAnnouncement,tool_provider:ServiceAnnouncement});
request!(Announcement {services:ServiceAnnouncements} {});
request!(ExtendClaim {claim_token:SecretString,timeout_ms:u64} {});
request!(CommitTask {claim_token:SecretString} {content:Value,structured_content:Value,result_type:String,is_error:bool,outcome:Outcome,title:String,metadata:JsonObject});
request!(SubmittedOperation {key:String,request:OperationRequest} {});
request!(SubmitOperation {claim_token:SecretString,operation:SubmittedOperation} {});
request!(ObserveOperation {claim_token:SecretString,after:u64} {});
/// Explicitly opaque protocol request. Complete JSON participates in the stable
/// operation identity, including fields the kernel records as business refusals.
pub type OperationRequest = JsonObject;
request!(ProgressRequest {frame:ProgressFrameRequest} {});
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ProgressFrameRequest {
    Task(TaskProgress),
    Process(ProcessProgress),
}
impl Default for ProgressFrameRequest {
    fn default() -> Self {
        Self::Task(TaskProgress::default())
    }
}
request!(TaskProgress {run_public_id:String,task_key:String,claim_token:SecretString} {text_tail:String,structured:Value});
request!(ProcessProgress {process_id:String,source:ProcessClaimSource,lines:Vec<String>} {conversation_public_id:String,run_public_id:String,exit:i64});
request!(ProcessClaimSource {run_public_id:String,task_key:String,claim_token:SecretString} {});
query!(TurnsQuery {
    after_position: i64,
    before_position: i64,
    limit: u32,
    include_hidden: bool
});
query!(TranscriptQuery {
    before: String,
    limit: u32,
    prefix: String
});
request!(VariantViewState {concealed:bool} {});
request!(RunControl {force:bool} {});
request!(RetryTask {} {model:ModelRequest});

/// A complete gathered SDP for the current UUIDv7 connection.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RealtimeSignal {
    pub connection_id: String,
    pub sdp: String,
}

/// Replace only the peer named by `previous_connection_id`; an old retry
/// cannot overwrite a newer handshake. Omit it for the first offer.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RealtimeOffer {
    pub connection_id: String,
    pub sdp: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_connection_id: Option<String>,
}

query!(RunCandidateQuery {
    agent_public_id: String,
    after: String
});
