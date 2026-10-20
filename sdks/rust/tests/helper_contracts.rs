mod support;
use cybros_agent::{
    Client, PlatformClient,
    authoring::*,
    checkpoints::*,
    thread::ThreadAccumulator,
    types::{member::*, requests::*},
};
use futures_util::StreamExt;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use support::{Reply, Server};
fn fixture(family: &str, key: &str) -> Value {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/nexus/v1")
        .join(format!("{family}.json"));
    let v: Value = serde_json::from_slice(&std::fs::read(p).unwrap()).unwrap();
    v[key].clone()
}
#[test]
fn authoring_serializes_all_model_default_fields_and_only_public_grammar() {
    let model = ModelDefaults {
        executor_contexts: None,
        model: Some(AuthoringModel::Reference("dev/text".into())),
        workload: Some(Workload::TextGeneration),
        tools: Some(vec![]),
        configuration: Some(json!({"temperature":0}).as_object().unwrap().clone()),
        instructions: Some("inspect".into()),
        compaction: Some(Default::default()),
        on_failure: Some(OnFailure::Halt),
        fan_on_failure: Some(FanOnFailure::Absorb),
        kernel_tools: Some(vec!["nexus.tools.call".into()]),
        runner_executor_public_ids: Some(vec!["runner".into()]),
        runner_tool_names: Some(vec!["read".into()]),
        mcp_tools: Some(vec![]),
        model_selection: Some(Default::default()),
        fallback_models: Some(vec!["dev/backup".into()]),
    };
    let step = Step::Tool {
        tool: ToolStep {
            name: "delegate".into(),
            input: Default::default(),
            model_defaults: Some(Box::new(model)),
            ..Default::default()
        },
    };
    let value = serde_json::to_value(step).unwrap();
    let defaults = value["tool"]["model_defaults"].as_object().unwrap();
    let expected:BTreeMap<&str,()>="model workload configuration tools instructions compaction on_failure fan_on_failure kernel_tools runner_executor_public_ids runner_tool_names mcp_tools model_selection fallback_models".split_whitespace().map(|k|(k,())).collect();
    assert_eq!(
        defaults.keys().map(String::as_str).collect::<Vec<_>>(),
        expected.keys().copied().collect::<Vec<_>>()
    );
    assert!(!value.to_string().contains("environment"));
    let parallel = Step::Parallel(ParallelStep {
        parallel: vec![
            Step::ask("choose"),
            Step::Sequence(vec![Step::wait("prior"), Step::model("continue")]),
        ],
        until: Some(Until::Quorum(1)),
        losers: Some(Losers::RunOut),
        ..Default::default()
    });
    let v = serde_json::to_value(parallel).unwrap();
    assert_eq!(v["until"], 1);
    assert_eq!(v["losers"], "run_out");
    assert!(v["parallel"][1].is_array());
    let a = json!({"name":"read","description":"Read.","inputSchema":{},"future":true})
        .as_object()
        .unwrap()
        .clone();
    let lowered = serde_json::to_value(ToolLowering::function_entry(&a).unwrap()).unwrap();
    assert_eq!(
        lowered,
        json!({"type":"function","function":{"name":"read","description":"Read.","parameters":{"type":"object","properties":{}}}})
    );
}
#[tokio::test]
async fn context_estimate_sends_the_actual_preview_intent() {
    let mut server = Server::script(vec![Reply::json(
        200,
        fixture("conversations", "valid_rendered_estimate_fixture").to_string(),
    )])
    .await;
    let c = Client::new(&server.url, "fixture")
        .unwrap()
        .workspace("workspace")
        .unwrap()
        .conversation("conversation")
        .unwrap();
    c.estimate_input(&ContextEstimate {
        prompt: "actual prompt".to_owned().into(),
        render: true.into(),
        answering_user_public_id: "answerer".to_owned().into(),
        speaker_public_id: "speaker".to_owned().into(),
        template: json!({"version":1}).as_object().unwrap().clone().into(),
        fallback_models: vec!["dev/backup".into()].into(),
        ..Default::default()
    })
    .await
    .unwrap();
    let body: Value = serde_json::from_slice(&server.next().await.body).unwrap();
    assert_eq!(
        body,
        json!({"context_estimate":{"prompt":"actual prompt","render":true,"answering_user_public_id":"answerer","speaker_public_id":"speaker","template":{"version":1},"fallback_models":["dev/backup"]}})
    );
}
#[test]
fn thread_completion_replaces_live_marks_and_branches_retract_guesses() {
    let mut thread = ThreadAccumulator::new(2);
    let progress = |key: &str, mainline: bool| {
        serde_json::from_value::<ProgressFrame>(json!({"type":"round_started","task_key":key,"at":"now","payload":{"mainline":mainline,"attempt":1}})).unwrap()
    };
    let call:ProgressFrame=serde_json::from_value(json!({"type":"step_started","task_key":"r2t0","tool_name":"read","at":"now","payload":{"status":"dispatched"}})).unwrap();
    thread.step_started(&call);
    assert_eq!(thread.rows()[0].task_key, "r2");
    thread.round_started(&progress("r2", false));
    assert!(thread.rows().is_empty());
    thread.step_started(&call);
    assert!(thread.rows().is_empty());
    thread.round_started(&progress("r1", true));
    assert_eq!(thread.live(), &["r1"]);
    let row = fixture("runs", "valid_thread_page_fixture")["rounds"][0].clone();
    let settled: TranscriptItem =
        serde_json::from_value(json!({"type":"round","round":row})).unwrap();
    thread.settle_round(&settled);
    assert!(thread.live().is_empty());
    assert_eq!(thread.rows()[0].status.as_str(), "completed");
    assert!(!thread.rows()[0].extra.contains_key("attempt"));
    thread.round_started(&progress("r3", true));
    thread.round_started(&progress("r4", true));
    assert_eq!(thread.rows().len(), 2);
    assert_eq!(thread.rows()[0].task_key, "r3");
}
#[tokio::test]
async fn checkpoint_skips_and_compact_strings_match_shared_wire_contract() {
    let fixtures = fixture("conversations", "runner_effects_fixtures");
    for value in fixtures.as_object().unwrap().values() {
        serde_json::from_value::<RunnerEffects>(value.clone()).unwrap();
    }
    let effects: RunnerEffects = serde_json::from_value(fixtures["skipped"].clone()).unwrap();
    let server = Server::repeating(500, "{}").await;
    let w = Client::new(&server.url, "fixture")
        .unwrap()
        .workspace("workspace")
        .unwrap();
    let keys = BTreeMap::from([(
        effects.runners[0].runner_executor_public_id.clone(),
        RestoreKeys {
            read: "read-key".into(),
            restore: "restore-key".into(),
        },
    )]);
    let result = restore_checkpoints(&w, &effects, &keys, &RestoreOptions::default(), |_, _| None)
        .await
        .unwrap();
    assert_eq!(result.status, RestoreStatus::Unavailable);
    assert!(result.runners[0].read_run_public_id.is_none());
    let compact: RunnerEffects = serde_json::from_value(fixtures["placeholder"].clone()).unwrap();
    assert_eq!(
        compact.runners[0]
            .checkpoint
            .as_ref()
            .unwrap()
            .hash
            .as_deref(),
        Some("c1")
    );
}
#[tokio::test]
async fn deployment_sse_preserves_cursor_and_unknown_events_without_reconnecting() {
    let log = fixture("platform_deployment", "valid_log_fixture")["log"].clone();
    let body = format!(
        "event: deployment.progress.v1\nid: next\ndata: {log}\n\nevent: future.v2\nid: later\ndata: {{\"future\":true}}\n\n"
    );
    let mut reply = Reply::json(200, body);
    reply.headers = vec![("Content-Type".into(), "text/event-stream".into())];
    let mut server = Server::script(vec![reply]).await;
    let p = PlatformClient::new(&server.url, "fixture").unwrap();
    let mut stream = p
        .deployment()
        .operation("operation")
        .unwrap()
        .stream(
            &CursorQuery {
                cursor: Some("saved".into()),
            },
            Some("fallback"),
        )
        .await
        .unwrap();
    assert!(
        matches!(stream.next().await.unwrap().unwrap(),cybros_agent::types::platform::DeploymentEvent::Progress{id,..} if id=="next")
    );
    assert!(
        matches!(stream.next().await.unwrap().unwrap(),cybros_agent::types::platform::DeploymentEvent::Unknown{event,id,data} if event=="future.v2"&&id=="later"&&data["future"]==true)
    );
    assert!(stream.next().await.is_none());
    let request = server.next().await;
    assert!(request.path.ends_with("?cursor=saved"));
    assert_eq!(request.headers["last-event-id"], "fallback");
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn append_resolutions_process_progress_and_side_filter_use_exact_wire_fields() {
    let mut server = Server::repeating(418, r#"{"error":{"code":"probe"}}"#).await;
    let m = Client::new(&server.url, "fixture").unwrap();
    m.workspace("w")
        .unwrap()
        .conversations()
        .list(&ConversationListQuery {
            side: Some(true),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert!(server.next().await.path.ends_with("?side=1"));
    m.workspace("w")
        .unwrap()
        .run("run")
        .unwrap()
        .append(
            &AppendTasks {
                steps: vec![],
                resolve: vec![
                    TaskResolution::Key("await-one".into()),
                    TaskResolution::Entry {
                        task: "await-two".into(),
                        content: json!("answer").into(),
                    },
                ]
                .into(),
                ..Default::default()
            },
            "operation-key",
        )
        .await
        .unwrap_err();
    let request = server.next().await;
    let body: Value = serde_json::from_slice(&request.body).unwrap();
    assert_eq!(
        body["resolve"],
        json!(["await-one",{"task":"await-two","content":"answer"}])
    );
    assert_eq!(request.headers["idempotency-key"], "operation-key");
    let e = cybros_agent::ExecutorClient::new(&server.url, "fixture").unwrap();
    e.report_progress(&ProgressRequest {
        frame: ProgressFrameRequest::Process(ProcessProgress {
            process_id: "p1".into(),
            source: ProcessClaimSource {
                run_public_id: "run".into(),
                task_key: "task".into(),
                claim_token: cybros_agent::credentials::SecretString::new("claim-proof"),
            },
            lines: vec!["ready".into()],
            ..Default::default()
        }),
    })
    .await
    .unwrap_err();
    let body: Value = serde_json::from_slice(&server.next().await.body).unwrap();
    assert_eq!(
        body["frame"]["source"],
        json!({"run_public_id":"run","task_key":"task","claim_token":"claim-proof"})
    );
}

#[tokio::test]
async fn checkpoint_restore_uses_original_runner_key_and_compact_undo() {
    let effects: RunnerEffects = serde_json::from_value(
        fixture("conversations", "runner_effects_fixtures")["placeholder"].clone(),
    )
    .unwrap();
    let runner = effects.runners[0].runner_executor_public_id.clone();
    let run = fixture("runs", "valid_request_run_fixture");
    let mut task = fixture("runs", "valid_tool_task_detail_fixture");
    task["task"]["status"] = json!("completed");
    task["task"]["result"] = json!({"is_error":false});
    task["task"]["metadata"] = json!({"checkpoint":"undo-hash"});
    let mut server = Server::script(vec![
        Reply::json(200, run.to_string()),
        Reply::json(409, r#"{"error":{"code":"not_startable"}}"#),
        Reply::json(200, task.to_string()),
    ])
    .await;
    let w = Client::new(&server.url, "fixture")
        .unwrap()
        .workspace("workspace")
        .unwrap();
    let result = restore_checkpoints(
        &w,
        &effects,
        &BTreeMap::from([(
            runner.clone(),
            RestoreKeys {
                read: "read-key".into(),
                restore: "restore-key".into(),
            },
        )]),
        &RestoreOptions::default(),
        |_, _| None,
    )
    .await
    .unwrap();
    assert_eq!(result.status, RestoreStatus::Restored);
    assert_eq!(result.runners[0].undo.as_deref(), Some("undo-hash"));
    let create = server.next().await;
    let body: Value = serde_json::from_slice(&create.body).unwrap();
    assert_eq!(create.headers["idempotency-key"], "restore-key");
    assert_eq!(body["run"]["steps"][0]["tool"]["input"]["checkpoint"], "c1");
    assert_eq!(
        body["run"]["steps"][0]["tool"]["route"]["runner_executor_public_id"],
        runner
    );
    assert_eq!(server.next().await.method, "POST");
    assert_eq!(server.next().await.method, "GET");
    assert!(server.try_next().is_none());
}
