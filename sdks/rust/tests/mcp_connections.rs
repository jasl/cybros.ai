mod support;
use cybros_agent::{PlatformClient, types::requests::*};
use serde_json::{Value, json};
use support::{Reply, Server};

fn fixture(key: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/nexus/v1/mcp_connections.json");
    let pack: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    pack.get(key).unwrap().clone()
}

#[tokio::test]
async fn oauth_creation_and_authorization_use_typed_owner_commands() {
    let oauth = fixture("oauth_owner_fixture");
    let authorization = fixture("authorization_fixture");
    let mut server = Server::script(vec![
        Reply::json(201, oauth.to_string()),
        Reply::json(200, authorization.to_string()),
    ])
    .await;
    let connections = PlatformClient::new(&server.url, "human")
        .unwrap()
        .mcp_connections();
    let connection = connections
        .create(&CreateMcpConnection {
            name: "Work".into(),
            endpoint_url: "https://tools.example/mcp".into(),
            auth_type: AuthType::Oauth,
            ..Default::default()
        })
        .await
        .unwrap()
        .body;
    assert_eq!(connection.auth_type, "oauth");
    assert_eq!(connection.authorization_status, "authorized");
    assert_eq!(
        connection.authorization_expires_at.as_deref(),
        oauth["mcp_connection"]["authorization_expires_at"].as_str()
    );
    let started = connections
        .connection(&connection.public_id)
        .unwrap()
        .start_authorization(&McpVersion { lock_version: 3 })
        .await
        .unwrap();
    assert_eq!(started.status, 200);
    assert_eq!(
        serde_json::to_value(started.body).unwrap(),
        authorization["authorization"]
    );
    let create = server.next().await;
    assert_eq!(create.method, "POST");
    assert_eq!(create.path, "/api/v1/mcp_connections");
    assert_eq!(
        serde_json::from_slice::<Value>(&create.body).unwrap(),
        json!({"mcp_connection":{"name":"Work","endpoint_url":"https://tools.example/mcp","auth_type":"oauth"}})
    );
    let start = server.next().await;
    assert_eq!(start.method, "POST");
    assert_eq!(
        start.path,
        format!(
            "/api/v1/mcp_connections/{}/authorization",
            connection.public_id
        )
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&start.body).unwrap(),
        json!({"command":{"lock_version":3}})
    );
}

#[tokio::test]
async fn owner_reads_preserve_future_status_and_clear_nullable_oauth_state() {
    let mut cleared = fixture("oauth_owner_fixture");
    cleared["mcp_connection"]["authorization_status"] = json!("not_authorized");
    cleared["mcp_connection"]["authorization_expires_at"] = Value::Null;
    cleared["mcp_connection"]["credential_configured"] = json!(false);
    cleared["mcp_connection"]["available"] = json!(false);
    cleared["mcp_connection"]["lock_version"] = json!(4);
    let mut server = Server::script(vec![
        Reply::json(
            200,
            fixture("unknown_authorization_status_fixture").to_string(),
        ),
        Reply::json(200, cleared.to_string()),
    ])
    .await;
    let connection = PlatformClient::new(&server.url, "human")
        .unwrap()
        .mcp_connections()
        .connection("connection")
        .unwrap();
    let future = connection.fetch().await.unwrap().body;
    assert_eq!(future.authorization_status, "future_status");
    assert!(!future.extra.contains_key("authorization_status"));
    let result = connection
        .clear_credential(&McpVersion { lock_version: 3 })
        .await
        .unwrap()
        .body;
    assert_eq!(result.authorization_status, "not_authorized");
    assert_eq!(result.authorization_expires_at, None);
    assert!(!result.credential_configured);
    assert_eq!(server.next().await.method, "GET");
    let clear = server.next().await;
    assert_eq!(clear.method, "DELETE");
    assert_eq!(clear.path, "/api/v1/mcp_connections/connection/credential");
    assert_eq!(
        serde_json::from_slice::<Value>(&clear.body).unwrap(),
        json!({"command":{"lock_version":3}})
    );
}

#[tokio::test]
async fn authorization_version_conflict_is_returned_without_retry() {
    let mut server = Server::script(vec![Reply::json(
        409,
        json!({"error":{"code":"stale_object"}}).to_string(),
    )])
    .await;
    let error = PlatformClient::new(&server.url, "human")
        .unwrap()
        .mcp_connections()
        .connection("connection")
        .unwrap()
        .start_authorization(&McpVersion { lock_version: 2 })
        .await
        .unwrap_err();
    assert_eq!(error.status(), Some(409));
    assert_eq!(error.code(), Some("stale_object"));
    assert_eq!(server.next().await.method, "POST");
    assert!(server.try_next().is_none());
}
