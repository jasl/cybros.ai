//! Explicit composition of Conversation forks and Runner checkpoint tool calls.
//! Each Runner keeps its own outcome; this is never a global rollback.
use crate::{
    Error, Result,
    authoring::{Step, ToolStep},
    resources::{ConversationContext, WorkspaceContext},
    types::{
        member::{Checkpoint, Conversation, RunnerEffect, RunnerEffects, TaskDetail},
        requests::{
            ApprovalMode, ApprovalRule, CreateRun, ForkConversation, PromptMechanism, ToolRoute,
        },
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeMap, time::Duration};
#[derive(Clone, Debug)]
pub struct RestoreKeys {
    pub read: String,
    pub restore: String,
}
#[derive(Clone, Debug)]
pub struct RestoreOptions {
    pub timeout: Duration,
    pub poll_interval: Duration,
    pub approval_rules: Option<Vec<ApprovalRule>>,
}
impl Default for RestoreOptions {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(120),
            poll_interval: Duration::from_secs(1),
            approval_rules: None,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RestoreStatus {
    Untouched,
    Kept,
    Restored,
    Partial,
    Unavailable,
    Failed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunnerRestoration {
    pub runner_executor_public_id: String,
    pub status: RestoreStatus,
    pub reason: Option<String>,
    pub checkpoint: Option<String>,
    pub undo: Option<String>,
    pub read_run_public_id: Option<String>,
    pub restore_run_public_id: Option<String>,
    pub outside: Vec<String>,
    pub ignored: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Restoration {
    pub status: RestoreStatus,
    pub runners: Vec<RunnerRestoration>,
    pub reason: Option<String>,
}
#[derive(Clone, Debug)]
pub struct Rewound {
    pub conversation: Conversation,
    pub replayed: bool,
    pub fork_point: RunnerEffects,
    pub restoration: Restoration,
}
/// Keys are supplied by the caller for both possible mutations on every Runner.
/// Persist these with the fork key; retrying never creates a new operation identity.
#[allow(clippy::too_many_arguments)] // The fork and each Runner retain distinct caller-owned operation identities.
pub async fn rewind<G>(
    conversation: &ConversationContext,
    workspace: &WorkspaceContext,
    request: &ForkConversation,
    fork_key: &str,
    restore: bool,
    keys: &BTreeMap<String, RestoreKeys>,
    options: &RestoreOptions,
    guard: G,
) -> Result<Rewound>
where
    G: Fn(&str, &Checkpoint) -> Option<String>,
{
    let response = conversation.fork(request, fork_key).await?;
    let forked = response.body;
    let restoration = if restore {
        restore_checkpoints(workspace, &forked.runner_effects, keys, options, guard).await?
    } else {
        Restoration {
            status: if forked.runner_effects.status == "untouched" {
                RestoreStatus::Untouched
            } else {
                RestoreStatus::Kept
            },
            runners: vec![],
            reason: None,
        }
    };
    Ok(Rewound {
        conversation: forked.conversation,
        replayed: response.replayed,
        fork_point: forked.runner_effects,
        restoration,
    })
}
pub async fn restore_checkpoints<G>(
    workspace: &WorkspaceContext,
    effects: &RunnerEffects,
    keys: &BTreeMap<String, RestoreKeys>,
    options: &RestoreOptions,
    guard: G,
) -> Result<Restoration>
where
    G: Fn(&str, &Checkpoint) -> Option<String>,
{
    if options.timeout.is_zero() || options.poll_interval.is_zero() {
        return Err(Error::Configuration(
            "restoration observation budgets must be positive",
        ));
    }
    if effects.status == "untouched" {
        return Ok(Restoration {
            status: RestoreStatus::Untouched,
            runners: vec![],
            reason: effects.reason.clone(),
        });
    }
    for effect in &effects.runners {
        let key = keys
            .get(&effect.runner_executor_public_id)
            .ok_or(Error::Configuration(
                "restoration requires caller-owned Runner operation keys",
            ))?;
        if key.read.is_empty() || key.restore.is_empty() || key.read == key.restore {
            return Err(Error::Configuration(
                "checkpoint read and restore need distinct nonempty keys",
            ));
        }
    }
    let mut runners = vec![];
    for effect in &effects.runners {
        let key = keys
            .get(&effect.runner_executor_public_id)
            .expect("validated keys");
        let mut outcome = RunnerRestoration {
            runner_executor_public_id: effect.runner_executor_public_id.clone(),
            status: RestoreStatus::Unavailable,
            reason: None,
            checkpoint: None,
            undo: None,
            read_run_public_id: None,
            restore_run_public_id: None,
            outside: vec![],
            ignored: vec![],
        };
        if let Err(error) = restore_one(workspace, effect, key, options, &guard, &mut outcome).await
        {
            outcome.status = if matches!(
                error,
                Error::Transport { .. } | Error::ObservationTimeout { .. }
            ) {
                RestoreStatus::Unavailable
            } else {
                RestoreStatus::Failed
            };
            outcome.reason = Some(
                error
                    .code()
                    .unwrap_or(match error {
                        Error::ObservationTimeout { .. } => "observation_timeout",
                        Error::Transport { .. } => "transport_error",
                        _ => "restore_failed",
                    })
                    .into(),
            );
        }
        runners.push(outcome);
    }
    let status = if runners.is_empty() {
        RestoreStatus::Unavailable
    } else if effects.status != "unavailable"
        && runners.iter().all(|r| r.status == RestoreStatus::Restored)
    {
        RestoreStatus::Restored
    } else if runners.iter().any(|r| r.status == RestoreStatus::Restored) {
        RestoreStatus::Partial
    } else if runners.iter().any(|r| r.status == RestoreStatus::Failed) {
        RestoreStatus::Failed
    } else {
        RestoreStatus::Unavailable
    };
    Ok(Restoration {
        status,
        runners,
        reason: effects.reason.clone(),
    })
}
async fn restore_one<G>(
    workspace: &WorkspaceContext,
    effect: &RunnerEffect,
    keys: &RestoreKeys,
    options: &RestoreOptions,
    guard: &G,
    outcome: &mut RunnerRestoration,
) -> Result<()>
where
    G: Fn(&str, &Checkpoint) -> Option<String>,
{
    let mut checkpoint = effect
        .checkpoint
        .clone()
        .filter(|c| c.hash.as_ref().is_some_and(|h| !h.is_empty()));
    let skipped = effect
        .checkpoint
        .as_ref()
        .is_some_and(|c| !c.skipped.is_null());
    if checkpoint.is_none() && !skipped {
        let context = start_request(
            workspace,
            &effect.runner_executor_public_id,
            "checkpoints",
            json!({"run_public_id":effect.run_public_id}),
            &keys.read,
            options,
        )
        .await?;
        outcome.read_run_public_id = Some(context.1);
        let detail = context
            .0
            .wait_for_tool_result("call_tool", options.timeout, options.poll_interval)
            .await?;
        if completed(&detail) {
            checkpoint = detail
                .structured_content
                .get("records")
                .and_then(Value::as_array)
                .and_then(|records| {
                    records.iter().find(|r| {
                        r.get("present") == Some(&Value::Bool(true))
                            && r.get("hash").and_then(Value::as_str).is_some()
                    })
                })
                .and_then(|r| serde_json::from_value(r.clone()).ok());
        }
    }
    let Some(captured) = checkpoint else {
        outcome.reason = Some("no_checkpoint".into());
        return Ok(());
    };
    outcome.checkpoint = captured.hash.clone();
    outcome.outside = captured.outside.clone();
    outcome.ignored = captured.ignored.clone();
    if let Some(reason) = guard(&effect.runner_executor_public_id, &captured) {
        outcome.status = RestoreStatus::Failed;
        outcome.reason = Some(reason);
        return Ok(());
    }
    let mut input = json!({"checkpoint":captured.hash});
    if let Some(store) = captured.store {
        input["store"] = json!(store);
    }
    let context = start_request(
        workspace,
        &effect.runner_executor_public_id,
        "checkpoint_restore",
        input,
        &keys.restore,
        options,
    )
    .await?;
    outcome.restore_run_public_id = Some(context.1);
    let detail = context
        .0
        .wait_for_tool_result("call_tool", options.timeout, options.poll_interval)
        .await?;
    outcome.undo = detail
        .metadata
        .as_ref()
        .and_then(|m| m.get("checkpoint"))
        .and_then(|v| serde_json::from_value::<Checkpoint>(v.clone()).ok())
        .and_then(|c| c.hash);
    if completed(&detail) {
        outcome.status = RestoreStatus::Restored;
    } else {
        outcome.status = RestoreStatus::Failed;
        outcome.reason = detail
            .task
            .error
            .as_ref()
            .and_then(|e| e.get("key"))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| {
                detail
                    .output
                    .as_ref()
                    .and_then(|output| output.split_whitespace().next())
                    .map(str::to_owned)
            });
    }
    Ok(())
}
fn completed(detail: &TaskDetail) -> bool {
    detail.task.status.as_str() == "completed"
        && !detail
            .task
            .result
            .as_ref()
            .and_then(|v| v.get("is_error"))
            .and_then(Value::as_bool)
            .unwrap_or(false)
}
async fn start_request(
    workspace: &WorkspaceContext,
    runner: &str,
    tool: &str,
    input: Value,
    key: &str,
    options: &RestoreOptions,
) -> Result<(crate::resources::RunContext, String)> {
    let request = CreateRun {
        steps: vec![Step::Tool {
            tool: ToolStep {
                name: tool.into(),
                input: input.as_object().cloned().expect("constructed object"),
                key: Some("call_tool".into()),
                route: Some(ToolRoute::Runner {
                    runner_executor_public_id: Some(runner.into()),
                }),
                ..Default::default()
            },
        }],
        approval_mode: ApprovalMode::Bypass,
        prompt_mechanism: PromptMechanism::Raw.into(),
        approval_rules: options
            .approval_rules
            .clone()
            .map_or(crate::Field::Unset, crate::Field::Value),
        default_runner_executor_public_id: runner.to_owned().into(),
        ..Default::default()
    };
    let created = workspace.runs().create(&request, key).await?.body;
    let id = created.run.public_id;
    let context = workspace.run(&id)?;
    match context.start().await {
        Ok(_) => {}
        Err(e) if e.status() == Some(409) && e.code() == Some("not_startable") => {}
        Err(e) => return Err(e),
    };
    Ok((context, id))
}
