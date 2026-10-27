mod support;
use cybros_agent::{
    Client, Error,
    events::Position,
    execution::{Execution, InputExecution},
};
use serde_json::{Value, json};
use std::time::Duration;
use support::{Reply, Server};
fn fixture(family: &str, key: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/nexus/v1")
        .join(format!("{family}.json"));
    let value: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    value[key].clone()
}
fn events(items: Vec<Value>, watermark: i64) -> Value {
    json!({"events":items,"pagination":{"next_after":null,"watermark":watermark}})
}
fn event(sequence: i64, kind: &str, payload: Value) -> Value {
    json!({"public_id":format!("event-{sequence}"),"sequence":sequence,"cursor":format!("cursor-{sequence}"),"type":kind,"resource":{"type":"conversation","public_id":"conversation"},"occurred_at":"now","payload":payload})
}
fn reply(v: Value) -> Reply {
    Reply::json(200, v.to_string())
}
#[tokio::test]
async fn refresh_only_replays_and_recover_holds_failed_original_until_its_run_settles() {
    let materialized = event(
        1,
        "input_materialized",
        json!({"input_public_id":"input","turn_public_id":"turn","variant_public_id":"original","run_public_id":"original-run"}),
    );
    let empty = events(vec![], 1);
    let mut deck = fixture("conversations", "valid_variants_fixture");
    deck["variants"][0]["public_id"] = json!("original");
    deck["variants"][0]["run_public_id"] = json!("original-run");
    deck["variants"][0]["status"] = json!("failed");
    deck["variants"][0]["active"] = json!(false);
    let mut manual = deck["variants"][0].clone();
    manual["public_id"] = json!("manual");
    manual["run_public_id"] = json!("manual-run");
    manual["source"] = json!("regeneration");
    manual["status"] = json!("completed");
    manual["active"] = json!(true);
    deck["variants"].as_array_mut().unwrap().push(manual);
    let mut held = fixture("runs", "valid_request_run_fixture");
    held["run"]["public_id"] = json!("original-run");
    held["run"]["status"] = json!("needs_attention");
    held["run"]["failure_reason"] = json!("provider failed");
    held["run"]["turn"]["status"] = json!("failed");
    held["run"]["turn"]["failure_reason_key"] = json!("provider_error");
    let mut settled = held.clone();
    settled["run"]["status"] = json!("completed");
    let mut server = Server::script(vec![
        reply(events(vec![materialized], 1)),
        reply(empty.clone()),
        reply(deck.clone()),
        reply(held),
        reply(empty),
        reply(deck),
        reply(settled),
    ])
    .await;
    let client = Client::new(&server.url, "fixture").unwrap();
    let mut observer = InputExecution::new(
        &client,
        "workspace",
        "conversation",
        "input",
        Position::default(),
    )
    .unwrap();
    observer.refresh().await.unwrap();
    assert_eq!(
        observer.original().unwrap().variant_public_id.as_deref(),
        Some("original")
    );
    assert_eq!(server.next().await.method, "GET");
    assert!(server.try_next().is_none());
    let snapshot = observer.recover().await.unwrap().unwrap();
    assert!(!snapshot.terminal());
    assert!(snapshot.needs_attention());
    assert_eq!(
        snapshot.execution.run_public_id.as_deref(),
        Some("original-run")
    );
    assert_eq!(
        snapshot.failure_reason_key.as_deref(),
        Some("provider_error")
    );
    let snapshot = observer.recover().await.unwrap().unwrap();
    assert!(snapshot.terminal());
    assert_eq!(
        snapshot.execution.variant_public_id.as_deref(),
        Some("original")
    );
    for _ in 0..6 {
        let request = server.next().await;
        assert_eq!(request.method, "GET");
        assert!(!request.path.contains("manual-run"));
    }
    assert!(server.try_next().is_none());
}
#[tokio::test]
async fn resumed_input_recovers_exact_materialization_and_never_queries_a_standalone_host() {
    let materialized = json!({"materialization":{"input_public_id":"input","turn_public_id":"turn","variant_public_id":"variant","run_public_id":"run"}});
    let mut server = Server::script(vec![reply(events(vec![], 7)), reply(materialized)]).await;
    let client = Client::new(&server.url, "fixture").unwrap();
    let mut observer = InputExecution::new(
        &client,
        "workspace",
        "conversation",
        "input",
        Position {
            cursor: Some("saved".into()),
            sequence: 5,
        },
    )
    .unwrap();
    observer.refresh().await.unwrap();
    assert_eq!(observer.original().unwrap().turn_public_id, "turn");
    assert!(server.next().await.path.ends_with("events?after=saved"));
    let read = server.next().await;
    assert!(
        read.path
            .contains("/conversations/conversation/inputs/input/materialization")
    );
    assert!(read.path.contains("include_hidden=true"));
    assert_eq!(observer.position().sequence, 5);
}
#[tokio::test]
async fn known_execution_retains_lifecycle_when_variant_is_not_yet_in_deck() {
    let lifecycle = event(
        1,
        "turn_status",
        json!({"turn_public_id":"turn","variant_public_id":"variant","run_public_id":"run","variant_status":"failed","failure_reason":"event failure","failure_reason_key":"event_key"}),
    );
    let mut deck = fixture("conversations", "valid_variants_fixture");
    deck["variants"] = json!([]);
    let mut run = fixture("runs", "valid_request_run_fixture");
    run["run"]["public_id"] = json!("run");
    let server = Server::script(vec![
        reply(events(vec![lifecycle], 1)),
        reply(deck),
        reply(run),
    ])
    .await;
    let client = Client::new(&server.url, "fixture").unwrap();
    let mut observer = InputExecution::for_execution(
        &client,
        "workspace",
        "conversation",
        Execution {
            turn_public_id: "turn".into(),
            variant_public_id: None,
            run_public_id: Some("run".into()),
        },
        Position::default(),
    )
    .unwrap();
    let snapshot = observer.recover().await.unwrap().unwrap();
    assert!(snapshot.terminal());
    assert_eq!(
        snapshot.execution.variant_public_id.as_deref(),
        Some("variant")
    );
    assert_eq!(snapshot.failure_reason_key.as_deref(), Some("event_key"));
}
#[tokio::test]
async fn waiting_timeout_does_not_cancel_server_work() {
    let mut reply = reply(events(vec![], 0));
    reply.body_delay = Duration::from_secs(1);
    let mut server = Server::script(vec![reply]).await;
    let client = Client::new(&server.url, "fixture").unwrap();
    let mut observer = InputExecution::new(
        &client,
        "workspace",
        "conversation",
        "input",
        Position::default(),
    )
    .unwrap();
    assert!(matches!(
        observer
            .wait(Duration::from_millis(20), Duration::from_millis(1))
            .await,
        Err(Error::ObservationTimeout { .. })
    ));
    assert_eq!(server.next().await.method, "GET");
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn missing_materialization_remains_unknown_without_a_new_request() {
    let mut server = Server::script(vec![
        reply(events(vec![], 1)),
        Reply::json(404, r#"{"error":{"code":"not_found"}}"#),
    ])
    .await;
    let client = Client::new(&server.url, "fixture").unwrap();
    let mut observer = InputExecution::new(
        &client,
        "workspace",
        "conversation",
        "accepted-input",
        Position {
            sequence: 1,
            cursor: Some("cursor-1".into()),
        },
    )
    .unwrap();
    assert!(observer.recover().await.unwrap().is_none());
    for _ in 0..2 {
        let request = server.next().await;
        assert_eq!(request.method, "GET");
        assert!(
            request.path.contains("/events")
                || request
                    .path
                    .contains("/inputs/accepted-input/materialization")
        );
    }
    assert!(server.try_next().is_none());
}
