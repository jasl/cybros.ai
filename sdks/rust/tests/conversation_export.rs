mod support;

use base64::Engine;
use cybros_agent::credentials::{Plane, StaticCredential};
use cybros_agent::transport::ClientOptions;
use cybros_agent::{Client, Error};
use futures_util::StreamExt;
use std::time::Duration;
use support::{Reply, Server};

#[tokio::test]
async fn export_retains_gzip_bytes_and_member_error_semantics() {
    // A gzip member containing two UTF-8 JSON Lines. No SDK JSON decoder runs here.
    let bytes = base64::engine::general_purpose::STANDARD
        .decode("H4sIAAAAAAAAA6tWKqksSFWyUkqtKMgvKlGq5aqGi+SlALkA6JiHCCEAAAA=")
        .unwrap();
    let mut gzip = Reply::json(200, bytes.clone());
    gzip.headers = vec![("Content-Type".into(), "application/gzip".into())];
    let refused = Reply::json(
        404,
        r#"{"error":{"code":"not_found","message":"Not found"}}"#,
    );
    let mut server = Server::script(vec![gzip, refused]).await;
    let chat = Client::new(&server.url, "member-fixture")
        .unwrap()
        .workspace("workspace")
        .unwrap()
        .conversation("conversation")
        .unwrap();
    let mut download = chat.export().await.unwrap();
    assert_eq!(download.status, 200);
    assert_eq!(download.headers["content-type"], "application/gzip");
    assert!(download.etag().is_none());
    let mut received = vec![];
    while let Some(chunk) = download.bytes.next().await {
        received.extend_from_slice(&chunk.unwrap());
    }
    assert_eq!(received, bytes);
    let request = server.next().await;
    assert_eq!(request.method, "GET");
    assert_eq!(
        request.path,
        "/agent_api/v1/workspaces/workspace/conversations/conversation/export"
    );
    assert_eq!(request.headers["authorization"], "Bearer member-fixture");
    assert!(!request.headers.contains_key("range"));
    assert!(!request.headers.contains_key("if-none-match"));
    assert!(
        matches!(chat.export().await, Err(Error::Api { status: 404, code: Some(code), .. }) if code == "not_found")
    );
    server.next().await;
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn export_deadline_covers_the_caller_owned_body() {
    let mut reply = Reply::json(200, b"gzip body".to_vec());
    reply.body_delay = Duration::from_secs(1);
    let server = Server::script(vec![reply]).await;
    let client = Client::with_credentials(
        &server.url,
        StaticCredential::new(Plane::Member, "member-fixture"),
        ClientOptions {
            request_timeout: Duration::from_millis(100),
            ..Default::default()
        },
    )
    .unwrap();
    let mut download = client
        .workspace("workspace")
        .unwrap()
        .conversation("conversation")
        .unwrap()
        .export()
        .await
        .unwrap();
    assert!(matches!(
        download.bytes.next().await,
        Some(Err(Error::Transport { timeout: true, .. }))
    ));
}
