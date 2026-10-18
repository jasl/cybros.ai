mod support;
use cybros_agent::{
    PlatformClient,
    types::{names, requests::*},
};
use serde_json::{Value, json};
use support::{Reply, Server};

fn fixture(family: &str, key: &str) -> Value {
    let source = match family {
        "platform_agents" => include_str!("../../../contracts/nexus/v1/platform_agents.json"),
        "platform_runners" => include_str!("../../../contracts/nexus/v1/platform_runners.json"),
        "tools" => include_str!("../../../contracts/nexus/v1/tools.json"),
        _ => panic!("unknown fixture family"),
    };
    serde_json::from_str::<Value>(source).unwrap()[key].clone()
}

#[tokio::test]
async fn agent_detail_and_configuration_keep_their_distinct_snapshots() {
    let detail = fixture("platform_agents", "valid_agent_detail_fixture");
    let configuration = fixture("platform_agents", "valid_agent_configuration_fixture");
    let mut server = Server::script(vec![
        Reply::json(200, detail.to_string()),
        Reply::json(200, configuration.to_string()),
    ])
    .await;
    let client = PlatformClient::new(&server.url, "platform").unwrap();
    let agent = client.agents().agent("agent-id").unwrap();
    let snapshot = agent.fetch().await.unwrap().body;
    assert_eq!(snapshot.agent.public_id, detail["agent"]["public_id"]);
    let connection = snapshot.application_connection.unwrap();
    assert_eq!(connection.owner_agent_public_id, snapshot.agent.public_id);
    assert_eq!(connection.credential_readiness, "ready");
    assert_eq!(connection.presence, "offline");
    assert_eq!(server.next().await.path, "/api/v1/agents/agent-id");

    let snapshot = agent.configuration().await.unwrap().body;
    assert_eq!(snapshot.agent_updated_at, configuration["agent_updated_at"]);
    assert_eq!(snapshot.measured_at, configuration["measured_at"]);
    assert_eq!(
        snapshot.configuration.default_model,
        configuration["configuration"]["default_model"]
            .as_str()
            .map(str::to_owned)
    );
    assert_eq!(
        snapshot.prompt_documents[0].content.as_deref(),
        configuration["prompt_documents"][0]["content"].as_str()
    );
    assert_eq!(
        server.next().await.path,
        "/api/v1/agents/agent-id/configuration"
    );
}

#[tokio::test]
async fn runner_management_preserves_filters_pagination_and_observation_time() {
    let mut listing = fixture("platform_runners", "valid_runners_fixture");
    listing["pagination"]["next_after"] = "cursor-next".into();
    let detail = fixture("platform_runners", "valid_runner_fixture");
    let mut server = Server::script(vec![
        Reply::json(200, listing.to_string()),
        Reply::json(200, detail.to_string()),
    ])
    .await;
    let client = PlatformClient::new(&server.url, "platform").unwrap();
    let page = client
        .runners()
        .list(&RunnerListQuery {
            kind: Some(MachineKind::ToolProvider),
            status: Some(RunnerStatus::Revoked),
            after: Some("cursor".into()),
            limit: Some(10),
            order: Some(Order::Desc),
        })
        .await
        .unwrap()
        .body;
    assert_eq!(page.measured_at, listing["measured_at"]);
    assert_eq!(page.next_after.as_deref(), Some("cursor-next"));
    assert_eq!(
        page.items[0].manager_public_id,
        listing["runners"][0]["manager_public_id"]
    );
    assert_eq!(
        page.items[0].assignment_scope,
        names::AssignmentScope::AgentPrivate
    );
    assert!(!page.items[0].eligible_for_current_user);
    let request = server.next().await;
    let url = url::Url::parse(&format!("{}{}", server.url, request.path)).unwrap();
    assert_eq!(url.path(), "/api/v1/runners");
    let query: std::collections::BTreeMap<_, _> = url.query_pairs().into_owned().collect();
    assert_eq!(query["kind"], "tool_provider");
    assert_eq!(query["status"], "revoked");
    assert_eq!(query["after"], "cursor");
    assert_eq!(query["limit"], "10");
    assert_eq!(query["order"], "desc");

    let snapshot = client
        .runners()
        .runner("runner-id")
        .unwrap()
        .fetch()
        .await
        .unwrap()
        .body;
    assert_eq!(snapshot.measured_at, detail["measured_at"]);
    assert_eq!(
        snapshot.runner.runner.public_id,
        detail["runner"]["public_id"]
    );
    assert_eq!(snapshot.runner.served_tools[0].name, "read");
    assert_eq!(snapshot.runner.served_documents[0].name, "project");
    assert_eq!(snapshot.runner.environment["root"], "/srv/work");
    assert_eq!(server.next().await.path, "/api/v1/runners/runner-id");
}

#[tokio::test]
async fn runner_responses_require_observation_facts_and_keep_unknown_vocabularies() {
    let mut missing_time = fixture("platform_runners", "valid_runners_fixture");
    missing_time.as_object_mut().unwrap().remove("measured_at");
    let mut missing_eligibility = fixture("platform_runners", "valid_runner_fixture");
    missing_eligibility["runner"]
        .as_object_mut()
        .unwrap()
        .remove("eligible_for_current_user");
    let mut unknown = fixture("platform_runners", "valid_runner_fixture");
    unknown["runner"]["kind"] = "new_kind".into();
    unknown["runner"]["status"] = "new_status".into();
    unknown["runner"]["assignment_scope"] = "new_scope".into();
    let server = Server::script(vec![
        Reply::json(200, missing_time.to_string()),
        Reply::json(200, missing_eligibility.to_string()),
        Reply::json(200, unknown.to_string()),
    ])
    .await;
    let client = PlatformClient::new(&server.url, "platform").unwrap();
    assert!(matches!(
        client.runners().list(&Default::default()).await,
        Err(cybros_agent::Error::ResponseDecode { .. })
    ));
    let runner = client.runners().runner("runner-id").unwrap();
    assert!(matches!(
        runner.fetch().await,
        Err(cybros_agent::Error::ResponseDecode { .. })
    ));
    let snapshot = runner.fetch().await.unwrap().body;
    assert_eq!(
        snapshot.runner.runner.kind,
        names::ExecutorKind::Unknown("new_kind".into())
    );
    assert_eq!(
        snapshot.runner.runner.status,
        names::ExecutorStatus::Unknown("new_status".into())
    );
    assert_eq!(
        snapshot.runner.runner.assignment_scope,
        names::AssignmentScope::Unknown("new_scope".into())
    );
    assert!(serde_json::from_value::<RunnerListQuery>(json!({"status":"new_status"})).is_err());
}
