mod support;
use cybros_agent::{Client, Error, PlatformClient, types::requests::*};
use serde_json::{Value, json};
use support::{Reply, Server};
fn fixture(family: &str, key: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/nexus/v1")
        .join(format!("{family}.json"));
    let value: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    value[key].clone()
}
#[tokio::test]
async fn api_key_grants_require_the_requested_plane_and_session_bearer_is_closed() {
    let mut known_wrong = fixture("platform_agents", "valid_member_key_grant_fixture");
    known_wrong["api_key"]["plane"] = json!("executor_transport");
    let mut unknown = known_wrong.clone();
    unknown["api_key"]["plane"] = json!("future_plane");
    let mut session = fixture("sessions", "valid_create_fixture");
    session["token_type"] = json!("future_scheme");
    let server = Server::script(vec![
        Reply::json(200, known_wrong.to_string()),
        Reply::json(200, unknown.to_string()),
        Reply::json(200, session.to_string()),
    ])
    .await;
    let platform = PlatformClient::new(&server.url, "human").unwrap();
    let keys = platform.agents().agent("agent").unwrap().api_keys();
    assert!(matches!(
        keys.issue(&IssueApiKey {
            name: "key".into(),
            ..Default::default()
        })
        .await,
        Err(Error::Protocol(_))
    ));
    assert!(matches!(
        keys.issue(&Default::default()).await,
        Err(Error::ResponseDecode { .. })
    ));
    assert!(matches!(
        PlatformClient::login(&server.url, &Default::default()).await,
        Err(Error::ResponseDecode { .. })
    ));
}
#[tokio::test]
async fn member_mcp_discovery_keeps_pagination_and_named_agent_selection() {
    let connection = fixture("mcp_connections", "member_fixture");
    let basic = connection
        .get("mcp_connection")
        .unwrap_or(&connection)
        .clone();
    let mut server = Server::script(vec![
        Reply::json(
            200,
            json!({"mcp_connections":[basic.clone()],"pagination":{"next_after":"next"}})
                .to_string(),
        ),
        Reply::json(200, json!({"mcp_connection":basic}).to_string()),
    ])
    .await;
    let mcp = Client::new(&server.url, "member")
        .unwrap()
        .mcp_connections();
    let page = mcp
        .list(&McpConnectionListQuery {
            after: Some("previous".into()),
            agent_public_id: Some("named-agent".into()),
            ..Default::default()
        })
        .await
        .unwrap()
        .body;
    assert_eq!(page.next_after.as_deref(), Some("next"));
    mcp.connection("mcp")
        .unwrap()
        .fetch(&McpConnectionQuery {
            agent_public_id: Some("named-agent".into()),
        })
        .await
        .unwrap();
    let list = server.next().await;
    assert!(list.path.contains("after=previous"));
    assert!(list.path.contains("agent_public_id=named-agent"));
    assert!(
        server
            .next()
            .await
            .path
            .ends_with("?agent_public_id=named-agent")
    );
}

#[tokio::test]
async fn platform_model_listing_sends_available_filter() {
    let mut server = Server::script(vec![Reply::json(200, r#"{"models":[]}"#)]).await;
    let models = PlatformClient::new(&server.url, "human").unwrap().models();
    models
        .list(&PlatformModelListQuery {
            available: Some(true),
            ..Default::default()
        })
        .await
        .unwrap();
    assert!(
        server
            .next()
            .await
            .path
            .ends_with("/api/v1/admin/models?available=true")
    );
}
