mod support;
use cybros_agent::{
    Client, PlatformClient,
    types::{member::*, platform::*, requests::*},
};
use serde_json::Value;
use support::{Reply, Server};

fn fixture(family: &str, key: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/nexus/v1")
        .join(format!("{family}.json"));
    let pack: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    pack[key].clone()
}

#[tokio::test]
async fn analysis_preserves_exact_cost_samples_null_latency_and_query_scope() {
    let mut server = Server::script(vec![
        Reply::json(200, fixture("analyses", "valid_member_fixture").to_string()),
        Reply::json(200, fixture("analyses", "valid_admin_fixture").to_string()),
    ])
    .await;
    let client = Client::new(&server.url, "member").unwrap();
    let analysis = client
        .work()
        .analysis(&WorkAnalysisQuery {
            workspace_public_id: Some("workspace".into()),
            agent_public_id: Some("agent".into()),
            from: Some("2026-10-15T00:00:00.123456Z".into()),
            to: Some("2026-10-16T00:00:00.123456Z".into()),
            provider_id: Some("dev".into()),
            catalog_model_ref: Some("dev/mock-text".into()),
            workload: Some(Workload::TextGeneration),
            status: Some("succeeded".into()),
            group_by: Some(AnalysisGroup::CatalogModelRef),
            rank_by: Some(AnalysisRank::CostAmount),
            limit: Some(3),
        })
        .await
        .unwrap()
        .body;
    assert_eq!(
        analysis.model_usage.totals.counters.cost_amount,
        "0.040500000000000001"
    );
    assert_eq!(analysis.model_usage.totals.amount_sample_count, 2);
    assert_eq!(analysis.model_usage.latency.duration_ms.p50, Some(0));
    assert_eq!(
        analysis.model_usage.latency.time_to_first_token_ms.p50,
        None
    );
    assert_eq!(
        analysis
            .model_usage
            .latency
            .time_to_first_token_ms
            .missing_count,
        3
    );
    assert_eq!(analysis.execution.tools.groups[0].error_result_count, 1);
    let request = server.next().await;
    let url = url::Url::parse(&format!("{}{}", server.url, request.path)).unwrap();
    let query: std::collections::BTreeMap<_, _> = url.query_pairs().into_owned().collect();
    assert_eq!(query["from"], "2026-10-15T00:00:00.123456Z");
    assert_eq!(query["group_by"], "catalog_model_ref");
    assert_eq!(query["rank_by"], "cost_amount");
    assert_eq!(query["workspace_public_id"], "workspace");
    assert_eq!(query["agent_public_id"], "agent");
    assert_eq!(query["catalog_model_ref"], "dev/mock-text");
    assert_eq!(query["limit"], "3");
    assert!(!query.contains_key("unit"));

    let platform = PlatformClient::new(&server.url, "platform").unwrap();
    let admin = platform
        .model_usage_analysis(&ModelUsageAnalysisQuery {
            group_by: Some(AnalysisGroup::Status),
            rank_by: Some(AnalysisRank::TotalTokens),
            ..Default::default()
        })
        .await
        .unwrap()
        .body;
    assert_eq!(admin.model_usage.breakdown.total_group_count, 2);
    let request = server.next().await;
    assert!(
        request
            .path
            .starts_with("/api/v1/admin/model_usage/analysis?")
    );
    assert!(request.path.contains("group_by=status"));
}

#[test]
fn analysis_keeps_new_response_vocabulary_and_requires_evidence_fields() {
    let group: WorkAnalysis =
        serde_json::from_value(fixture("analyses", "unknown_group_fixture")["analysis"].clone())
            .unwrap();
    assert_eq!(group.model_usage.breakdown.group_by, "zz_unknown_value");
    let rank: ModelUsageAnalysis =
        serde_json::from_value(fixture("analyses", "unknown_rank_fixture")["analysis"].clone())
            .unwrap();
    assert_eq!(rank.model_usage.breakdown.rank_by, "zz_unknown_value");
    let statuses: WorkAnalysis =
        serde_json::from_value(fixture("analyses", "unknown_status_fixture")["analysis"].clone())
            .unwrap();
    assert_eq!(statuses.model_usage.status_counts["zz_unknown_value"], 1);
    assert_eq!(
        statuses.execution.tools.status_counts["zz_unknown_value"],
        1
    );
    let mut missing = fixture("analyses", "valid_member_fixture")["analysis"].clone();
    missing["model_usage"]["totals"]
        .as_object_mut()
        .unwrap()
        .remove("amount_sample_count");
    assert!(serde_json::from_value::<WorkAnalysis>(missing).is_err());
}

#[tokio::test]
async fn self_budget_reads_keep_current_window_ledger_and_signed_exact_money() {
    let mut list = fixture("platform_budgets", "valid_list_fixture");
    list["current_budget"]["headroom"] = "-0.000000000000000001".into();
    let mut server = Server::script(vec![
        Reply::json(200, list.to_string()),
        Reply::json(
            200,
            fixture("platform_budgets", "valid_show_fixture").to_string(),
        ),
        Reply::json(
            200,
            fixture("platform_budgets", "valid_entries_fixture").to_string(),
        ),
        Reply::json(
            200,
            fixture("platform_budgets", "valid_uncapped_fixture").to_string(),
        ),
    ])
    .await;
    let client = Client::new(&server.url, "member").unwrap();
    let page = client
        .profile()
        .budgets()
        .list(&PageQuery {
            after: Some("opaque".into()),
            limit: Some(1),
            order: Some(Order::Desc),
        })
        .await
        .unwrap()
        .body;
    assert_eq!(
        page.current_budget.unwrap().headroom,
        "-0.000000000000000001"
    );
    assert_eq!(page.budgets[0].credited_amount, "10.000000000000000001");
    let request = server.next().await;
    assert!(request.path.starts_with("/agent_api/v1/profile/budgets?"));
    assert!(request.path.contains("order=desc"));
    assert!(request.path.contains("after=opaque"));
    let read = client
        .profile()
        .budgets()
        .budget("budget")
        .unwrap()
        .fetch()
        .await
        .unwrap()
        .body;
    assert!(!read.measured_at.is_empty());
    let entries = client
        .profile()
        .budgets()
        .budget("budget")
        .unwrap()
        .entries(&Default::default())
        .await
        .unwrap()
        .body;
    assert_eq!(entries.items[0].amount, "0.000000000000000001");
    assert!(
        !serde_json::to_value(&entries.items[0])
            .unwrap()
            .as_object()
            .unwrap()
            .contains_key("operation_key")
    );
    let platform = PlatformClient::new(&server.url, "platform").unwrap();
    let empty = platform
        .profile()
        .budgets()
        .list(&Default::default())
        .await
        .unwrap()
        .body;
    assert!(empty.current_budget.is_none());
    assert!(empty.budgets.is_empty());
}

#[tokio::test]
async fn schedules_have_workspace_and_exact_candidate_routes() {
    let mut server = Server::script(vec![
        Reply::json(200, fixture("schedules", "valid_list_fixture").to_string()),
        Reply::json(
            200,
            fixture("conversations", "valid_variant_read_fixture").to_string(),
        ),
    ])
    .await;
    let client = Client::new(&server.url, "member").unwrap();
    let page = client
        .schedules()
        .list(&GlobalScheduleQuery {
            workspace_public_id: Some("workspace".into()),
            status: Some("paused".into()),
            ..Default::default()
        })
        .await
        .unwrap()
        .body;
    assert!(!page.items[0].workspace_public_id.is_empty());
    assert!(
        page.items[0]
            .last_execution
            .as_ref()
            .unwrap()
            .variant_public_id
            .is_some()
    );
    let request = server.next().await;
    assert!(request.path.contains("workspace_public_id=workspace"));
    assert!(request.path.contains("status=paused"));
    let read = client
        .workspace("workspace")
        .unwrap()
        .conversation("conversation")
        .unwrap()
        .turns()
        .turn("turn")
        .unwrap()
        .variant("variant")
        .unwrap()
        .fetch()
        .await
        .unwrap()
        .body;
    assert!(!read.variant.public_id.is_empty());
    let request = server.next().await;
    assert_eq!(
        request.path,
        "/agent_api/v1/workspaces/workspace/conversations/conversation/turns/turn/variants/variant"
    );
}
