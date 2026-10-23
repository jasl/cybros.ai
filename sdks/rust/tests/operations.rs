//! Each shared operation is exercised through its real public resource method.
mod support;
use cybros_agent::{Client, ExecutorClient, PlatformClient, transport::UploadBody};
use support::Server;
#[tokio::test]
async fn every_supported_operation_reaches_its_public_route() {
    let manifest: serde_json::Value =
        serde_json::from_str(include_str!("../../../contracts/nexus/v1/operations.json")).unwrap();
    let expected: std::collections::BTreeSet<String> = manifest["operations"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|o| o["sdk_supported"] == true)
        .map(|o| o["id"].as_str().unwrap().to_owned())
        .collect();
    let mut covered = std::collections::BTreeSet::<String>::new();
    let mut server = Server::repeating(418, r#"{"error":{"code":"route_probe"}}"#).await;
    let base = server.url.clone();
    let member = Client::new(&base, "member-fixture").unwrap();
    let executor = ExecutorClient::new(&base, "executor-fixture").unwrap();
    let platform = PlatformClient::new(&base, "platform-fixture").unwrap();
    macro_rules! operation {
        ($id:literal,$method:literal,$path:literal,$call:expr) => {{
            let error = $call.await.err().expect("probe must refuse the operation");
            assert_eq!(error.status(), Some(418), "{}: {error}", $id);
            let request = server.next().await;
            assert_eq!(request.method, $method, "{}", $id);
            assert_eq!(request.path.split('?').next().unwrap(), $path, "{}", $id);
            assert!(covered.insert($id.into()));
        }};
    }
    include!("operation_bindings/conversations.rs");
    include!("operation_bindings/executor.rs");
    include!("operation_bindings/inference.rs");
    include!("operation_bindings/member_resources.rs");
    include!("operation_bindings/memory_collections.rs");
    include!("operation_bindings/platform.rs");
    include!("operation_bindings/runs.rs");
    include!("operation_bindings/turns.rs");
    include!("operation_bindings/work.rs");
    include!("operation_bindings/analysis_and_budgets.rs");
    assert_eq!(covered, expected);
}
