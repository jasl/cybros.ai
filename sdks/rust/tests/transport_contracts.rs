mod support;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cybros_agent::credentials::{CredentialProvider, Plane, SecretString, StaticCredential};
use cybros_agent::error::{DecodeFailure, SendOutcome};
use cybros_agent::transport::{ClientOptions, UploadBody};
use cybros_agent::types::requests::{
    CreateWorkspace, ObserveOperation, SubmitOperation, SubmittedOperation,
};
use cybros_agent::{Client, Error, ExecutorClient, PlatformClient, Result};
use futures_util::StreamExt;
use serde_json::{Value, json};
use support::{Reply, Server};

fn fixture(family: &str, pointer: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/nexus/v1")
        .join(format!("{family}.json"));
    let pack: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    pack.pointer(pointer).unwrap().clone()
}

fn response(status: u16, value: Value) -> Reply {
    Reply::json(status, serde_json::to_vec(&value).unwrap())
}

fn timed_client(base: &str) -> Client {
    Client::with_credentials(
        base,
        StaticCredential::new(Plane::Member, "member-fixture"),
        ClientOptions {
            request_timeout: Duration::from_millis(100),
            ..Default::default()
        },
    )
    .unwrap()
}

#[tokio::test]
async fn redirects_are_observable_and_never_forward_credentials() {
    let mut destination = Server::repeating(200, "{}").await;
    let mut reply = Reply::json(307, "{}");
    reply
        .headers
        .push(("Location".into(), destination.url.clone()));
    let mut server = Server::script(vec![reply]).await;
    let client = Client::new(&server.url, "member-fixture").unwrap();

    let error = client.profile().fetch().await.unwrap_err();
    assert_eq!(error.status(), Some(307));
    assert_eq!(
        server.next().await.headers["authorization"],
        "Bearer member-fixture"
    );
    assert!(destination.try_next().is_none());
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn rate_limit_and_unknown_api_errors_keep_metadata_without_retry() {
    let mut reply = response(
        429,
        json!({"error": {
            "code": "future_limit", "message": "Try later", "details": {"remaining": 0}
        }}),
    );
    reply.headers.extend([
        ("Retry-After".into(), "9".into()),
        ("X-Request-ID".into(), "request-fixture".into()),
    ]);
    let mut server = Server::script(vec![reply]).await;
    let client = Client::new(&server.url, "member-fixture").unwrap();
    let error = client
        .workspaces()
        .create(
            &CreateWorkspace {
                name: "Example".into(),
                ..Default::default()
            },
            "same-operation",
        )
        .await
        .unwrap_err();
    match error {
        Error::Api {
            status,
            code,
            message,
            details,
            retry_after,
            request_id,
        } => {
            assert_eq!(status, 429);
            assert_eq!(code.as_deref(), Some("future_limit"));
            assert_eq!(message.as_deref(), Some("Try later"));
            assert_eq!(details.as_deref(), Some(&json!({"remaining": 0})));
            assert_eq!(retry_after.as_deref(), Some("9"));
            assert_eq!(request_id.as_deref(), Some("request-fixture"));
        }
        error => panic!("wrong error: {error}"),
    }
    let request = server.next().await;
    assert_eq!(request.headers["idempotency-key"], "same-operation");
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn non_json_server_errors_keep_status_and_bounded_diagnostics() {
    let body = format!("upstream unavailable: {}", "x".repeat(8192));
    let mut server = Server::script(vec![Reply::json(503, body)]).await;
    let client = Client::new(&server.url, "member-fixture").unwrap();
    let error = client.profile().fetch().await.unwrap_err();
    match error {
        Error::Api {
            status, message, ..
        } => {
            assert_eq!(status, 503);
            let diagnostic = message.expect("proxy failure should remain diagnosable");
            assert!(diagnostic.starts_with("upstream unavailable"));
            assert!(diagnostic.len() <= 4096);
        }
        error => panic!("wrong error: {error}"),
    }
    server.next().await;
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn download_errors_preserve_bounded_unicode_diagnostics_and_redact_tokens() {
    let body = format!(
        "proxy refused sk-cybros-api-v1-fixture: {}",
        "错误".repeat(4096)
    );
    let mut reply = Reply::json(502, body);
    reply
        .headers
        .push(("X-Request-ID".into(), "download-error".into()));
    let mut server = Server::script(vec![reply]).await;
    let client = Client::new(&server.url, "member-fixture").unwrap();
    let error = client
        .uploads()
        .upload("file")
        .unwrap()
        .bytes(None, None)
        .await
        .unwrap_err();
    match error {
        Error::Api {
            status,
            message: Some(message),
            request_id,
            ..
        } => {
            assert_eq!(status, 502);
            assert_eq!(request_id.as_deref(), Some("download-error"));
            assert!(message.starts_with("proxy refused [REDACTED]: 错误"));
            assert!(!message.contains("sk-cybros"));
            assert!(message.len() <= 4096);
        }
        error => panic!("wrong error: {error}"),
    }
    server.next().await;
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn download_error_body_timeout_remains_a_transport_failure() {
    let mut reply = response(503, json!({"error":{"code":"temporarily_unavailable"}}));
    reply.body_delay = Duration::from_secs(1);
    let mut server = Server::script(vec![reply]).await;
    let error = timed_client(&server.url)
        .uploads()
        .upload("file")
        .unwrap()
        .bytes(None, None)
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        Error::Transport {
            timeout: true,
            outcome: SendOutcome::Unknown,
            ..
        }
    ));
    server.next().await;
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn malformed_success_is_separate_from_an_api_refusal() {
    let mut reply = Reply::json(200, "not json");
    reply
        .headers
        .push(("X-Request-ID".into(), "request-malformed".into()));
    let server = Server::script(vec![reply]).await;
    let client = Client::new(&server.url, "member-fixture").unwrap();
    assert!(
        matches!(client.profile().fetch().await, Err(Error::ResponseDecode {
        status: 200, request_id: Some(id), reason: DecodeFailure::MalformedJson
    }) if id == "request-malformed")
    );
}

#[tokio::test]
async fn timeout_covers_json_body_after_headers_arrive() {
    let mut reply = response(200, fixture("profiles", "/agent_api"));
    reply.body_delay = Duration::from_secs(1);
    let mut server = Server::script(vec![reply]).await;
    let error = timed_client(&server.url)
        .profile()
        .fetch()
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        Error::Transport {
            timeout: true,
            outcome: SendOutcome::Unknown,
            ..
        }
    ));
    server.next().await;
    assert!(server.try_next().is_none());
}

struct HangingCredential;

#[async_trait]
impl CredentialProvider for HangingCredential {
    async fn token(&self, _: Plane) -> Result<Option<SecretString>> {
        std::future::pending().await
    }
}

#[tokio::test]
async fn timeout_includes_credential_resolution_before_any_request() {
    let mut server = Server::repeating(200, "{}").await;
    let client = Client::with_credentials(
        &server.url,
        Arc::new(HangingCredential),
        ClientOptions {
            request_timeout: Duration::from_millis(50),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(matches!(
        client.profile().fetch().await,
        Err(Error::Transport {
            timeout: true,
            outcome: SendOutcome::NotSent,
            ..
        })
    ));
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn download_preserves_ranges_etags_and_timeout_through_body() {
    let mut partial = Reply::json(206, "abc");
    partial.headers.extend([
        ("ETag".into(), "\"fixture\"".into()),
        ("Content-Range".into(), "bytes 2-4/6".into()),
    ]);
    let unchanged = Reply::json(304, "");
    let mut delayed = Reply::json(200, "late");
    delayed.body_delay = Duration::from_secs(1);
    let mut server = Server::script(vec![partial, unchanged, delayed]).await;
    let client = timed_client(&server.url);
    let upload = client.uploads().upload("file").unwrap();
    let mut download = upload
        .bytes(Some("bytes=2-4"), Some("\"old\""))
        .await
        .unwrap();
    assert_eq!(download.status, 206);
    assert_eq!(download.etag(), Some("\"fixture\""));
    assert_eq!(download.headers["content-range"], "bytes 2-4/6");
    assert_eq!(
        download.bytes.next().await.unwrap().unwrap(),
        Bytes::from_static(b"abc")
    );
    assert!(download.bytes.next().await.is_none());
    let request = server.next().await;
    assert_eq!(request.headers["range"], "bytes=2-4");
    assert_eq!(request.headers["if-none-match"], "\"old\"");
    let mut cached = upload.bytes(None, Some("\"fixture\"")).await.unwrap();
    assert!(cached.unchanged());
    assert!(cached.bytes.next().await.is_none());
    let mut delayed = upload.bytes(None, None).await.unwrap();
    assert!(matches!(
        delayed.bytes.next().await,
        Some(Err(Error::Transport { timeout: true, .. }))
    ));
}

#[tokio::test]
async fn mutation_receipts_preserve_status_replay_and_explicit_key() {
    let mut reply = response(201, fixture("workspaces", "/valid_full_fixture"));
    reply.headers.extend([
        ("Idempotency-Replayed".into(), "true".into()),
        ("X-Request-ID".into(), "request-replay".into()),
    ]);
    let mut server = Server::script(vec![reply]).await;
    let client = Client::new(&server.url, "member-fixture").unwrap();
    let answer = client
        .workspaces()
        .create(
            &CreateWorkspace {
                name: "Exact input".into(),
                ..Default::default()
            },
            "original-key",
        )
        .await
        .unwrap();
    assert_eq!(answer.status, 201);
    assert!(answer.replayed);
    assert_eq!(answer.headers["x-request-id"], "request-replay");
    let request = server.next().await;
    assert_eq!(request.headers["idempotency-key"], "original-key");
    assert_eq!(
        serde_json::from_slice::<Value>(&request.body).unwrap(),
        json!({"workspace":{"name":"Exact input"}})
    );
}

#[tokio::test]
async fn resource_segments_queries_and_claim_proofs_keep_their_boundaries() {
    let mut server = Server::script(vec![
        response(200, fixture("executor_operations", "/pages/initial")),
        response(201, fixture("executor_operations", "/accepted_operation")),
        response(
            200,
            fixture("executor_operations", "/outcomes/false/observation"),
        ),
    ])
    .await;
    let executor = ExecutorClient::new(&server.url, "executor-fixture").unwrap();
    let task = executor.inbox_task("run/a?b", "task %x").unwrap();
    let trace = task
        .operations("claim-fixture", &Default::default())
        .await
        .unwrap();
    assert_eq!(trace.body.position, 0);
    let request = server.next().await;
    assert_eq!(
        request.path,
        "/agent_api/v1/executor/inbox/run%2Fa%3Fb/task%20%25x/operations"
    );
    assert_eq!(request.headers["claim-token"], "claim-fixture");
    assert!(!request.path.contains("claim-fixture"));
    let payload = json!({"kind":"tool", "name":"read_file", "input":{"path":"one"}});
    task.submit(&SubmitOperation {
        claim_token: SecretString::new("claim-fixture"),
        operation: SubmittedOperation {
            key: "read".into(),
            request: payload.as_object().unwrap().clone(),
        },
    })
    .await
    .unwrap();
    let request = server.next().await;
    assert_eq!(
        serde_json::from_slice::<Value>(&request.body).unwrap(),
        json!({
            "claim_token":"claim-fixture", "operation":{"key":"read", "request":payload}
        })
    );
    let result = task
        .observe(&ObserveOperation {
            claim_token: SecretString::new("claim-fixture"),
            after: 1,
        })
        .await
        .unwrap();
    let outcome = result.body.observation.unwrap().outcome.unwrap();
    assert_eq!(outcome.structured_content, json!(false));
    assert_eq!(outcome.structured_content_present, Some(true));
}

#[derive(Default)]
struct PlaneRecorder(Mutex<Vec<Plane>>);

#[async_trait]
impl CredentialProvider for PlaneRecorder {
    async fn token(&self, plane: Plane) -> Result<Option<SecretString>> {
        self.0.lock().unwrap().push(plane);
        Ok(Some(SecretString::new(match plane {
            Plane::Member => "member-fixture",
            Plane::Executor => "executor-fixture",
            Plane::Platform => "platform-fixture",
        })))
    }
}

#[tokio::test]
async fn each_client_resolves_its_own_plane_once_and_handles_are_lazy() {
    let mut server = Server::repeating(418, r#"{"error":{"code":"probe"}}"#).await;
    let provider = Arc::new(PlaneRecorder::default());
    let member =
        Client::with_credentials(&server.url, provider.clone(), Default::default()).unwrap();
    let executor =
        ExecutorClient::with_credentials(&server.url, provider.clone(), Default::default())
            .unwrap();
    let platform =
        PlatformClient::with_credentials(&server.url, provider.clone(), Default::default())
            .unwrap();
    let profile = member.profile();
    assert!(provider.0.lock().unwrap().is_empty());
    assert!(server.try_next().is_none());
    assert_eq!(profile.fetch().await.unwrap_err().status(), Some(418));
    assert_eq!(executor.executor().await.unwrap_err().status(), Some(418));
    assert_eq!(
        platform.profile().fetch().await.unwrap_err().status(),
        Some(418)
    );
    assert_eq!(
        *provider.0.lock().unwrap(),
        [Plane::Member, Plane::Executor, Plane::Platform]
    );
    for token in ["member-fixture", "executor-fixture", "platform-fixture"] {
        assert_eq!(
            server.next().await.headers["authorization"],
            format!("Bearer {token}")
        );
    }
}

#[tokio::test]
async fn binary_upload_sends_one_nested_file_on_member_and_executor_planes() {
    let bytes = Bytes::from_static(b"\0\xffbinary\r\n");
    for plane in ["member", "executor"] {
        let descriptor = fixture("uploads", "/valid_fixture");
        let mut server = Server::script(vec![response(201, descriptor.clone())]).await;
        let mut body = UploadBody::bytes("capture fixture.bin", bytes.clone());
        body.content_type = "application/x-nexus-capture".into();
        let uploaded = match plane {
            "member" => {
                Client::new(&server.url, "member-fixture")
                    .unwrap()
                    .uploads()
                    .create(body)
                    .await
            }
            _ => {
                ExecutorClient::new(&server.url, "executor-fixture")
                    .unwrap()
                    .upload(body)
                    .await
            }
        }
        .unwrap();
        assert_eq!(uploaded.status, 201);
        assert_eq!(uploaded.body.public_id, descriptor["upload"]["public_id"]);
        let request = server.next().await;
        assert_eq!(request.method, "POST");
        assert_eq!(
            request.path,
            fixture("uploads", &format!("/ingest_paths/{plane}"))
        );
        assert_eq!(
            request.headers["authorization"],
            format!("Bearer {plane}-fixture")
        );
        assert_upload_part(&request, &bytes);
        assert!(server.try_next().is_none());
    }
}

fn assert_upload_part(request: &support::Request, bytes: &[u8]) {
    let boundary = request.headers["content-type"]
        .strip_prefix("multipart/form-data; boundary=")
        .unwrap();
    let part = request
        .body
        .strip_prefix(format!("--{boundary}\r\n").as_bytes())
        .unwrap()
        .strip_suffix(format!("\r\n--{boundary}--\r\n").as_bytes())
        .unwrap();
    let header_end = part
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .unwrap();
    let headers: std::collections::BTreeMap<_, _> = std::str::from_utf8(&part[..header_end])
        .unwrap()
        .split("\r\n")
        .map(|line| {
            let (name, value) = line.split_once(':').unwrap();
            (name.to_ascii_lowercase(), value.trim())
        })
        .collect();
    assert_eq!(
        headers["content-disposition"],
        format!(
            "form-data; name=\"{}\"; filename=\"capture fixture.bin\"",
            fixture("uploads", "/ingest_part").as_str().unwrap()
        )
    );
    assert_eq!(headers["content-type"], "application/x-nexus-capture");
    assert_eq!(&part[header_end + 4..], bytes);
    assert!(!request.headers.contains_key("idempotency-key"));
}

#[tokio::test]
async fn rejected_upload_is_an_api_error_without_retry_on_both_planes() {
    for plane in ["member", "executor"] {
        let mut server = Server::script(vec![response(
            413,
            json!({"error": {
                "code": "content_too_large", "message": "The upload exceeds its size bound"
            }}),
        )])
        .await;
        let body = UploadBody::bytes("capture.txt", "capture");
        let result = match plane {
            "member" => {
                Client::new(&server.url, "member-fixture")
                    .unwrap()
                    .uploads()
                    .create(body)
                    .await
            }
            _ => {
                ExecutorClient::new(&server.url, "executor-fixture")
                    .unwrap()
                    .upload(body)
                    .await
            }
        };
        match result.unwrap_err() {
            Error::Api { status, code, .. } => {
                assert_eq!(status, 413);
                assert_eq!(code.as_deref(), Some("content_too_large"));
            }
            error => panic!("wrong upload error: {error}"),
        }
        server.next().await;
        assert!(server.try_next().is_none());
    }
}
