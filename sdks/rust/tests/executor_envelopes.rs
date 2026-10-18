mod support;
use cybros_agent::{ExecutorClient, types::requests::CommitTask};
use serde_json::json;
use support::{Reply, Server};

#[tokio::test]
async fn claim_read_and_commit_decode_the_kernel_envelopes() {
    let mut server = Server::script(vec![
        Reply::json(200, r#"{"claim":{"active":true}}"#),
        Reply::json(200, json!({"task":{"key":"tool","kind":"tool","status":"completed","lifetime":"turn","wake":"auto","result":{"is_error":true}}}).to_string()),
    ]).await;
    let task = ExecutorClient::new(&server.url, "fixture")
        .unwrap()
        .inbox_task("run", "tool")
        .unwrap();
    assert!(task.claim_status("claim-proof").await.unwrap().body.active);
    let claim = server.next().await;
    assert_eq!(claim.headers["claim-token"], "claim-proof");
    assert!(!claim.path.contains("claim-proof"));
    let settled = task
        .commit(&CommitTask {
            claim_token: cybros_agent::credentials::SecretString::new("claim-proof"),
            is_error: true.into(),
            ..Default::default()
        })
        .await
        .unwrap()
        .body;
    assert_eq!(settled.status.as_str(), "completed");
    assert_eq!(settled.result.unwrap()["is_error"], true);
    let body: serde_json::Value = serde_json::from_slice(&server.next().await.body).unwrap();
    assert_eq!(body["claim_token"], "claim-proof");
    assert_eq!(body["is_error"], true);
}
