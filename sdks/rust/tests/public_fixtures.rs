//! Shared wire fixtures pass through real public clients and native HTTP decoding.
mod support;
use cybros_agent::{Client, ExecutorClient, PlatformClient};
use support::{Reply, Server};
fn fixture(family: &str, key: &str) -> serde_json::Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/nexus/v1")
        .join(format!("{family}.json"));
    let value: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    value
        .get(key)
        .unwrap_or_else(|| panic!("{family}.{key}"))
        .clone()
}
#[tokio::test]
async fn shared_families_use_public_response_envelopes() {
    let mut errors = vec![];
    include!("public_fixture_cases/conversations.rs");
    include!("public_fixture_cases/execution.rs");
    include!("public_fixture_cases/executor.rs");
    include!("public_fixture_cases/inference.rs");
    include!("public_fixture_cases/member_resources.rs");
    include!("public_fixture_cases/platform.rs");
    assert!(errors.is_empty(), "{}", errors.join("\n"));
}

#[tokio::test]
async fn run_listing_preserves_workspace_public_id() {
    let server =
        Server::script(vec![Reply::json(200, serde_json::json!({
        "runs": [{"public_id":"run", "workspace_public_id":"workspace", "status":"running"}],
        "pagination": {"next_after":null}
    }).to_string())])
        .await;
    let member = Client::new(&server.url, "member").unwrap();
    let page = member
        .workspace("workspace")
        .unwrap()
        .runs()
        .list(&Default::default())
        .await
        .unwrap();
    assert_eq!(
        page.body.items[0].workspace_public_id.as_deref(),
        Some("workspace")
    );
}
