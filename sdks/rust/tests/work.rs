mod support;
use cybros_agent::{Client, types::requests::*};
use support::{Reply, Server};

fn fixture(key: &str) -> serde_json::Value {
    let pack: serde_json::Value =
        serde_json::from_str(include_str!("../../../contracts/nexus/v1/work.json")).unwrap();
    pack[key].clone()
}

#[tokio::test]
async fn work_queries_decode_canonical_documents_and_keep_filters() {
    let runs = fixture("valid_runs_fixture");
    let attention = fixture("valid_attention_fixture");
    let mut report = fixture("valid_report_fixture");
    report["report"]["agent_public_id"] = "agent".into();
    let mut server = Server::script(vec![
        Reply::json(200, runs.to_string()),
        Reply::json(200, attention.to_string()),
        Reply::json(200, report.to_string()),
    ])
    .await;
    let client = Client::new(&server.url, "member").unwrap();
    let page = client
        .work()
        .runs(&CrossWorkspaceRunQuery {
            workspace_public_id: Some("workspace".into()),
            from: Some("2026-10-14T00:00:00Z".into()),
            to: Some("2026-10-15T00:00:00Z".into()),
            answering_user_public_id: Some("answerer".into()),
            agent_public_id: Some("agent".into()),
            executor_public_id: Some("runner".into()),
            kind: Some(RunKind::Conversation),
            status: Some("running,paused".into()),
            attention: Some("any".into()),
            order: Some(Order::Desc),
            after: Some("cursor".into()),
            limit: Some(5),
        })
        .await
        .unwrap()
        .body;
    assert_eq!(
        page.items[0].workspace_public_id.as_deref(),
        runs["runs"][0]["workspace_public_id"].as_str()
    );
    let request = server.next().await;
    let url = url::Url::parse(&format!("{}{}", server.url, request.path)).unwrap();
    assert_eq!(url.path(), "/agent_api/v1/runs");
    let query: std::collections::BTreeMap<_, _> = url.query_pairs().into_owned().collect();
    assert_eq!(query["workspace_public_id"], "workspace");
    assert_eq!(query["from"], "2026-10-14T00:00:00Z");
    assert_eq!(query["to"], "2026-10-15T00:00:00Z");
    assert_eq!(query["answering_user_public_id"], "answerer");
    assert_eq!(query["agent_public_id"], "agent");
    assert_eq!(query["executor_public_id"], "runner");
    assert_eq!(query["kind"], "conversation");
    assert_eq!(query["status"], "running,paused");
    assert_eq!(query["attention"], "any");
    assert_eq!(query["order"], "desc");
    assert_eq!(query["after"], "cursor");
    assert_eq!(query["limit"], "5");

    let page = client
        .work()
        .attention(&AttentionQuery {
            workspace_public_id: Some("workspace".into()),
            view: Some(AttentionView::Following),
            ..Default::default()
        })
        .await
        .unwrap()
        .body;
    assert_eq!(
        page.items[0].task.key,
        attention["items"][0]["task"]["key"].as_str().unwrap()
    );
    assert_eq!(
        page.items[0].run_public_id,
        attention["items"][0]["run_public_id"].as_str().unwrap()
    );
    assert!(page.items[0].conversation_public_id.is_none());
    let request = server.next().await;
    assert!(request.path.starts_with("/agent_api/v1/attention?"));
    assert!(request.path.contains("view=following"));

    let read = client
        .work()
        .report(&WorkReportQuery {
            workspace_public_id: Some("workspace".into()),
            agent_public_id: Some("agent".into()),
            from: Some("2026-10-14T00:00:00Z".into()),
            to: Some("2026-10-15T00:00:00Z".into()),
            unit: Some(WorkReportUnit::Day),
        })
        .await
        .unwrap()
        .body;
    assert_eq!(
        read.current.run_counts.canceling,
        report["report"]["current"]["run_counts"]["canceling"]
            .as_i64()
            .unwrap()
    );
    assert_eq!(
        read.totals.conversation_usage.cost_amount,
        report["report"]["totals"]["conversation_usage"]["cost_amount"]
            .as_str()
            .unwrap()
    );
    assert!(!read.totals.conversation_usage.cost_complete);
    assert_eq!(read.agent_public_id.as_deref(), Some("agent"));
    assert_eq!(
        read.series[0].bucket_start_at,
        report["report"]["series"][0]["bucket_start_at"]
            .as_str()
            .unwrap()
    );
    assert_eq!(
        read.previous.totals.created_runs,
        report["report"]["previous"]["totals"]["created_runs"]
            .as_i64()
            .unwrap()
    );
    let request = server.next().await;
    assert!(request.path.starts_with("/agent_api/v1/work_report?"));
    assert!(request.path.contains("unit=day"));
    assert!(request.path.contains("agent_public_id=agent"));
}

#[tokio::test]
async fn report_requires_cost_evidence_and_keeps_unknown_response_units() {
    let mut malformed = fixture("valid_report_fixture");
    malformed["report"]["totals"]["conversation_usage"]
        .as_object_mut()
        .unwrap()
        .remove("cost_complete");
    let unknown = fixture("unknown_unit_fixture");
    let server = Server::script(vec![
        Reply::json(200, malformed.to_string()),
        Reply::json(200, unknown.to_string()),
    ])
    .await;
    let client = Client::new(&server.url, "member").unwrap();
    assert!(matches!(
        client.work().report(&Default::default()).await,
        Err(cybros_agent::Error::ResponseDecode { .. })
    ));
    let report = client
        .work()
        .report(&Default::default())
        .await
        .unwrap()
        .body;
    assert_eq!(report.unit, unknown["report"]["unit"].as_str().unwrap());
}
