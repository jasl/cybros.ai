//! Observation of one accepted Conversation input. Standalone Runs use their own
//! state/events/tasks and never enter Conversation materialization recovery.
use crate::{
    Error, Result,
    authoring::{Step, ToolStep},
    events::{KernelFeed, Position},
    resources::{Client, ConversationContext, RunContext, WorkspaceContext},
    types::{
        member::{Event, RunAttention, TaskDetail, Variant},
        requests::{ApprovalMode, CreateRun, MaterializationQuery, PromptMechanism},
    },
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeMap, sync::Arc, time::Duration};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Execution {
    pub turn_public_id: String,
    pub variant_public_id: Option<String>,
    pub run_public_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    pub execution: Execution,
    pub variant: Option<Variant>,
    pub status: Option<String>,
    pub run_status: Option<String>,
    pub attention: Option<RunAttention>,
    pub failure_reason: Option<String>,
    pub failure_reason_key: Option<String>,
    pub content: Option<String>,
}
impl Snapshot {
    pub fn terminal(&self) -> bool {
        matches!(
            self.status.as_deref(),
            Some("completed" | "failed" | "canceled" | "timed_out")
        ) && (self.status.as_deref() != Some("failed")
            || self.execution.run_public_id.is_none()
            || matches!(self.run_status.as_deref(), Some("completed" | "canceled")))
    }
    pub fn needs_attention(&self) -> bool {
        self.run_status.as_deref() == Some("needs_attention")
    }
}
#[derive(Clone, Debug, Default)]
pub struct MaterializationState {
    pub original: Option<Execution>,
    pub blocked_reason: Option<String>,
    pub compaction: Option<Execution>,
}
impl MaterializationState {
    pub fn apply(&mut self, input_public_id: &str, event: &Event) {
        let p = &event.payload;
        let text = |key: &str| p.get(key).and_then(Value::as_str).map(str::to_owned);
        let execution = || {
            text("turn_public_id").map(|turn_public_id| Execution {
                turn_public_id,
                variant_public_id: text("variant_public_id"),
                run_public_id: text("run_public_id"),
            })
        };
        match event.r#type.as_str() {
            "input_blocked"
                if text("input_public_id").as_deref() == Some(input_public_id)
                    && text("blocked_reason").as_deref() != Some("run_held") =>
            {
                self.blocked_reason = text("blocked_reason")
            }
            "input_materialized" if text("input_public_id").as_deref() == Some(input_public_id) => {
                if self.original.is_none() {
                    self.original = execution();
                }
                self.blocked_reason = None;
            }
            "turn_status" if text("turn_kind").as_deref() == Some("compaction_summary") => {
                self.compaction = execution()
            }
            _ => {}
        }
    }
}
pub struct InputExecution {
    conversation: ConversationContext,
    workspace: WorkspaceContext,
    input_public_id: Option<String>,
    feed: KernelFeed,
    pub materialization: MaterializationState,
    pub snapshot: Option<Snapshot>,
    lifecycle: BTreeMap<(String, Option<String>, Option<String>), Value>,
}
impl InputExecution {
    pub fn new(
        client: &Client,
        workspace_public_id: &str,
        conversation_public_id: &str,
        input_public_id: &str,
        position: Position,
    ) -> Result<Self> {
        let workspace = client.workspace(workspace_public_id)?;
        let conversation = workspace.conversation(conversation_public_id)?;
        Ok(Self {
            feed: KernelFeed::new(Arc::new(conversation.clone()), position)?,
            conversation,
            workspace,
            input_public_id: Some(input_public_id.into()),
            materialization: MaterializationState::default(),
            snapshot: None,
            lifecycle: BTreeMap::new(),
        })
    }
    pub fn for_execution(
        client: &Client,
        workspace_public_id: &str,
        conversation_public_id: &str,
        execution: Execution,
        position: Position,
    ) -> Result<Self> {
        if execution.turn_public_id.is_empty()
            || (execution.variant_public_id.is_none() && execution.run_public_id.is_none())
        {
            return Err(Error::Configuration(
                "known execution requires turn and variant or run",
            ));
        }
        let mut result = Self::new(
            client,
            workspace_public_id,
            conversation_public_id,
            "",
            position,
        )?;
        result.input_public_id = None;
        result.materialization.original = Some(execution);
        Ok(result)
    }
    pub fn original(&self) -> Option<&Execution> {
        self.materialization.original.as_ref()
    }
    pub fn position(&self) -> &Position {
        self.feed.position()
    }
    /// Replay only. Does not fetch the Variant deck, Run, or decisions.
    pub async fn refresh(&mut self) -> Result<()> {
        while let Some(event) = self.feed.next_replayed().await? {
            if let Some(input) = &self.input_public_id {
                self.materialization.apply(input, &event);
            }
            if matches!(event.r#type.as_str(), "turn_status" | "turn_created") {
                let p = &event.payload;
                let text = |key: &str| p.get(key).and_then(Value::as_str).map(str::to_owned);
                if let Some(turn) = text("turn_public_id") {
                    let key = (turn, text("variant_public_id"), text("run_public_id"));
                    let state = self
                        .lifecycle
                        .entry(key)
                        .or_insert_with(|| serde_json::json!({}));
                    if let (Some(old), Some(new)) = (state.as_object_mut(), p.as_object()) {
                        old.extend(new.clone());
                        if let Some(status) =
                            new.get("variant_status").or_else(|| new.get("status"))
                        {
                            old.insert("status".into(), status.clone());
                            if status.as_str() != Some("failed") {
                                old.remove("failure_reason");
                                old.remove("failure_reason_key");
                            }
                        }
                    }
                }
            }
            self.feed.ack(&event)?;
        }
        let report = self.feed.finish_pass();
        if self.materialization.original.is_none()
            && (report.retention_gap || self.position().sequence > 0)
            && let Some(input) = &self.input_public_id
        {
            match self
                .conversation
                .inputs()
                .input(input)?
                .materialization(&MaterializationQuery {
                    include_hidden: Some(true),
                })
                .await
            {
                Ok(v) => {
                    let m = v.body;
                    self.materialization.original = Some(Execution {
                        turn_public_id: m.turn_public_id,
                        variant_public_id: Some(m.variant_public_id),
                        run_public_id: m.run_public_id,
                    });
                    self.materialization.blocked_reason = None;
                }
                Err(e) if e.status() == Some(404) => {}
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
    pub async fn recover(&mut self) -> Result<Option<&Snapshot>> {
        self.refresh().await?;
        let Some(original) = self.original().cloned() else {
            return Ok(None);
        };
        let deck = self
            .conversation
            .turns()
            .turn(&original.turn_public_id)?
            .variants()
            .await?
            .body
            .items;
        let candidate = select_candidate(&deck, &original)?;
        let mut execution = match &candidate {
            Some(v) => Execution {
                turn_public_id: original.turn_public_id.clone(),
                variant_public_id: Some(v.public_id.clone()),
                run_public_id: v.run_public_id.clone(),
            },
            None => original,
        };
        let state = self
            .lifecycle
            .iter()
            .filter(|((turn, variant, run), _)| {
                turn == &execution.turn_public_id
                    && execution
                        .run_public_id
                        .as_ref()
                        .is_none_or(|r| run.as_ref() == Some(r))
                    && execution
                        .variant_public_id
                        .as_ref()
                        .is_none_or(|v| variant.as_ref() == Some(v))
            })
            .map(|(_, v)| v)
            .next_back();
        if execution.variant_public_id.is_none() {
            execution.variant_public_id = state
                .and_then(|v| v.get("variant_public_id"))
                .and_then(Value::as_str)
                .map(str::to_owned);
        }
        let run = match &execution.run_public_id {
            Some(id) => Some(self.workspace.run(id)?.fetch().await?.body),
            None => None,
        };
        let status = candidate
            .as_ref()
            .map(|v| v.status.as_str().to_owned())
            .or_else(|| {
                state
                    .and_then(|v| v.get("status"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            });
        let failed = status.as_deref() == Some("failed");
        let failure_reason = if failed {
            run.as_ref()
                .and_then(|r| r.failure_reason.clone())
                .or_else(|| {
                    state
                        .and_then(|v| v.get("failure_reason"))
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                })
        } else {
            None
        };
        let failure_reason_key = if failed {
            run.as_ref()
                .and_then(|r| r.turn.as_ref())
                .filter(|t| t.status.as_str() == "failed")
                .and_then(|t| t.failure_reason_key.clone())
                .or_else(|| {
                    state
                        .and_then(|v| v.get("failure_reason_key"))
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                })
        } else {
            None
        };
        self.snapshot = Some(Snapshot {
            execution,
            status,
            run_status: run.as_ref().map(|r| r.status.as_str().into()),
            attention: run.and_then(|r| r.attention),
            failure_reason,
            failure_reason_key,
            content: candidate.as_ref().and_then(|v| v.content.clone()),
            variant: candidate,
        });
        Ok(self.snapshot.as_ref())
    }
    /// Questions/approvals are an explicit read, never an implicit poll side effect.
    pub async fn decisions(&mut self) -> Result<Vec<TaskDetail>> {
        self.refresh().await?;
        let execution = self
            .snapshot
            .as_ref()
            .map(|s| &s.execution)
            .or_else(|| self.original());
        let Some(run) = execution.and_then(|e| e.run_public_id.as_deref()) else {
            return Ok(vec![]);
        };
        let run = self.workspace.run(run)?;
        let pending = run
            .fetch()
            .await?
            .body
            .tasks
            .into_iter()
            .filter(|t| matches!(t.status.as_str(), "awaiting_input" | "needs_approval"));
        let mut decisions = vec![];
        for task in pending {
            decisions.push(run.task(&task.key)?.fetch().await?.body);
        }
        Ok(decisions)
    }
    /// Optional bounded convenience observation. Timeout/drop never cancels Nexus work.
    pub async fn wait(&mut self, timeout: Duration, poll_interval: Duration) -> Result<Snapshot> {
        if timeout.is_zero() || poll_interval.is_zero() {
            return Err(Error::Configuration("observation budgets must be positive"));
        }
        tokio::time::timeout(timeout, async {
            loop {
                if let Some(snapshot) = self.recover().await?
                    && snapshot.terminal()
                {
                    return Ok(snapshot.clone());
                }
                tokio::time::sleep(poll_interval).await;
            }
        })
        .await
        .map_err(|_| Error::ObservationTimeout { elapsed: timeout })?
    }
}
/// Follow only the original candidate's automatic fallback lineage. Active manual
/// regenerations and unrelated variants cannot replace an accepted input's result.
pub fn select_candidate(deck: &[Variant], original: &Execution) -> Result<Option<Variant>> {
    let mut candidate = deck.iter().find(|v| {
        if let Some(id) = &original.variant_public_id {
            &v.public_id == id
        } else {
            v.run_public_id == original.run_public_id
        }
    });
    let mut id = original
        .variant_public_id
        .as_deref()
        .or_else(|| candidate.map(|v| v.public_id.as_str()));
    let mut visited = std::collections::BTreeSet::new();
    while let Some(current) = id {
        if !visited.insert(current) {
            return Err(Error::Protocol("cyclic fallback lineage"));
        }
        if let Some(fallback) = deck.iter().find(|v| {
            v.source.as_str() == "fallback"
                && v.origin_variant_public_id.as_deref() == Some(current)
        }) {
            candidate = Some(fallback);
            id = Some(&fallback.public_id);
        } else {
            break;
        }
    }
    Ok(candidate.cloned())
}
impl WorkspaceContext {
    pub async fn start_tool_call(
        &self,
        mut tool: ToolStep,
        approval_mode: ApprovalMode,
        idempotency_key: &str,
    ) -> Result<RunContext> {
        if tool.key.is_none() {
            tool.key = Some("call_tool".into());
        }
        let run = self
            .runs()
            .create(
                &CreateRun {
                    steps: vec![Step::Tool { tool }],
                    approval_mode,
                    prompt_mechanism: PromptMechanism::Raw.into(),
                    ..Default::default()
                },
                idempotency_key,
            )
            .await?
            .body
            .run;
        let context = self.run(&run.public_id)?;
        match context.start().await {
            Ok(_) => {}
            Err(e) if e.status() == Some(409) && e.code() == Some("not_startable") => {}
            Err(e) => return Err(e),
        }
        Ok(context)
    }
}
impl RunContext {
    pub async fn wait_for_tool_result(
        &self,
        task_key: &str,
        timeout: Duration,
        poll_interval: Duration,
    ) -> Result<crate::types::member::TaskDetail> {
        if timeout.is_zero() || poll_interval.is_zero() {
            return Err(Error::Configuration("observation budgets must be positive"));
        }
        tokio::time::timeout(timeout, async {
            loop {
                let task = self.task(task_key)?.fetch().await?.body;
                if matches!(
                    task.task.status.as_str(),
                    "completed" | "failed" | "canceled" | "timed_out" | "uncertain" | "skipped"
                ) {
                    return Ok(task);
                }
                tokio::time::sleep(poll_interval).await;
            }
        })
        .await
        .map_err(|_| Error::ObservationTimeout { elapsed: timeout })?
    }
}
