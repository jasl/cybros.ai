//! Open response vocabularies preserve unknown values from newer deployments.
use serde::{Deserialize, Serialize};
macro_rules! open_enum {
 ($name:ident {$($variant:ident => $wire:literal),* $(,)?}) => {
  #[derive(Clone,Debug,PartialEq,Eq)] pub enum $name {$($variant,)* Unknown(String)}
  impl $name {pub fn as_str(&self)->&str {match self {$ (Self::$variant => $wire,)* Self::Unknown(s)=>s}}}
  impl From<&str> for $name {fn from(s:&str)->Self {Self::from(s.to_owned())}}
  impl From<String> for $name {fn from(s:String)->Self {match s.as_str() {$($wire=>Self::$variant,)* _=>Self::Unknown(s)}}}
  impl Serialize for $name {fn serialize<S:serde::Serializer>(&self,s:S)->Result<S::Ok,S::Error>{s.serialize_str(self.as_str())}}
  impl<'de> Deserialize<'de> for $name {fn deserialize<D:serde::Deserializer<'de>>(d:D)->Result<Self,D::Error>{String::deserialize(d).map(Self::from)}}
 };
}
open_enum!(AssignmentScope {UserPrivate => "user_private", AccountWide => "account_wide"});
open_enum!(BudgetEntryKind {
    InitialGrant => "initial_grant", CreditAdjustment => "credit_adjustment",
    DebitAdjustment => "debit_adjustment", Charge => "charge",
    AllowanceConsumption => "allowance_consumption"
});
open_enum!(UsageUnit {Hour => "hour", Day => "day", Month => "month"});
open_enum!(CheckStatus {Ready => "ready", Blocked => "blocked", Unavailable => "unavailable"});
open_enum!(DeploymentPhase {Accepted => "accepted", Preparing => "preparing", Draining => "draining", Stopping => "stopping", BackingUp => "backing_up", Migrating => "migrating", Activating => "activating", Resuming => "resuming", Verifying => "verifying", Completed => "completed"});
open_enum!(DeploymentStatus {Running => "running", Succeeded => "succeeded", Failed => "failed", Interrupted => "interrupted"});
open_enum!(AgentStatus {Active => "active", Removed => "removed", Suspended => "suspended"});
open_enum!(ExecutorStatus {Active => "active", Revoked => "revoked"});
open_enum!(ExecutorKind {Agent => "agent", Runner => "runner", ToolProvider => "tool_provider"});
open_enum!(RunStatus {Pending => "pending", Running => "running", Paused => "paused", NeedsAttention => "needs_attention", Canceling => "canceling", Completed => "completed", Canceled => "canceled"});
open_enum!(TaskStatus {AwaitingInput => "awaiting_input", Canceled => "canceled", Completed => "completed", Dispatched => "dispatched", Failed => "failed", NeedsApproval => "needs_approval", Running => "running", Skipped => "skipped", TimedOut => "timed_out", Uncertain => "uncertain", Waiting => "waiting"});
open_enum!(TaskKind {AwaitTask => "await_task", ModelTask => "model_task", ToolTask => "tool_task", JoinTask => "join_task", DelegationTask => "delegation_task"});
open_enum!(TurnStatus {Canceled => "canceled", Completed => "completed", Failed => "failed", Pending => "pending", Running => "running", TimedOut => "timed_out"});
open_enum!(TurnKind {CompactionSummary => "compaction_summary", DirectReply => "direct_reply", Message => "message"});
open_enum!(VariantSource {Edit => "edit", Fallback => "fallback", Fork => "fork", Import => "import", Inference => "inference", Manual => "manual", Run => "run"});
open_enum!(InputState {Blocked => "blocked", Pending => "pending", Steering => "steering"});
open_enum!(Visibility {ExcludedFromContext => "excluded_from_context", Hidden => "hidden", Visible => "visible"});
open_enum!(EventType {AccessChanged => "access_changed", AttentionRequired => "attention_required", ContextCompacted => "context_compacted", ContextTrimmed => "context_trimmed", ConversationEnded => "conversation_ended", ConversationTakenOver => "conversation_taken_over", DefaultRunnerChanged => "default_runner_changed", ForkCreated => "fork_created", HandleChanged => "handle_changed", InputAccepted => "input_accepted", InputBlocked => "input_blocked", InputDeleted => "input_deleted", InputEdited => "input_edited", InputMaterialized => "input_materialized", ReasoningReplayDowngraded => "reasoning_replay_downgraded", RoundResult => "round_result", SoftDelete => "soft_delete", TaskDeadlineExtended => "task_deadline_extended", TaskReaddressed => "task_readdressed", TaskStatus => "task_status", TurnCreated => "turn_created", TurnDeleted => "turn_deleted", TurnStatus => "turn_status", TurnVariant => "turn_variant", Usage => "usage", Visibility => "visibility"});
open_enum!(InferenceStatus {Canceled => "canceled", Completed => "completed", Failed => "failed", Queued => "queued", Running => "running", TimedOut => "timed_out"});
open_enum!(InferenceEventType {ProviderOutputItemCompleted => "provider_output_item_completed", ProviderOutputItemDelta => "provider_output_item_delta", ProviderOutputItemStarted => "provider_output_item_started", ReasoningDelta => "reasoning_delta", Result => "result", Rollback => "rollback", RunStatus => "run_status", TextDelta => "text_delta", Usage => "usage"});
open_enum!(Workload {Decision => "decision", Embedding => "embedding", ImageGeneration => "image_generation", SpeechGeneration => "speech_generation", TextGeneration => "text_generation", Transcription => "transcription"});
open_enum!(ScheduleStatus {Active => "active", Paused => "paused", Canceled => "canceled", Completed => "completed"});
open_enum!(ScheduleRuleKind {Once => "once", Interval => "interval", Daily => "daily"});
open_enum!(WorkspaceState {Active => "active", Archived => "archived", Archiving => "archiving", Deleted => "deleted", Deleting => "deleting", Restoring => "restoring"});
open_enum!(AccessMode {AccountWide => "account_wide", Private => "private"});
open_enum!(InboxKind {ToolCall => "tool_call", Ask => "ask", Approval => "approval"});
open_enum!(SessionKind {Api => "api", Browser => "browser"});
open_enum!(MemberKind {Agent => "agent", Human => "human"});
open_enum!(MemberRole {Admin => "admin", Member => "member", Owner => "owner"});
open_enum!(TranscriptItemType {TextDelta => "text_delta", ReasoningDelta => "reasoning_delta", ToolCallStarted => "tool_call_started", ToolCallArgumentsDelta => "tool_call_arguments_delta", StreamReset => "stream_reset", Turn => "turn", Round => "round", Call => "call"});
open_enum!(ProgressType {ExecutorProgress => "executor_progress", ProcessOutput => "process_output", RoundStarted => "round_started", StepStarted => "step_started", StepClaimed => "step_claimed"});
