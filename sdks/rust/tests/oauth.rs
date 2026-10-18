mod support;
use cybros_agent::{
    ClientOptions, Error, credentials::SecretString, error::CredentialFailure, oauth::*,
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, time::Duration};
use support::{Reply, Server};
fn fixture(family: &str, key: &str) -> Value {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/nexus/v1")
        .join(format!("{family}.json"));
    let v: Value = serde_json::from_slice(&std::fs::read(p).unwrap()).unwrap();
    v[key].clone()
}
fn claims() -> ConnectionClaims {
    ConnectionClaims::Agent(AgentClaims {
        agent_identifier: "agent".into(),
        agent_display_name: "Agent".into(),
        executor_display_name: "Executor".into(),
        registration_identifier: None,
        runner_display_name: None,
    })
}
fn form(body: &[u8]) -> BTreeMap<String, String> {
    url::form_urlencoded::parse(body).into_owned().collect()
}
#[test]
fn grant_planes_and_discriminators_keep_independent_lineages() {
    for key in [
        "valid_agent_token_fixture",
        "valid_runner_token_fixture",
        "valid_combined_token_fixture",
    ] {
        TokenGrant::decode(fixture("oauth", key), false).unwrap();
    }
    for key in ["unknown_plane_fixture", "unknown_token_type_fixture"] {
        assert!(TokenGrant::decode(fixture("oauth", key), false).is_err());
    }
    for key in [
        "unknown_plane_fixture",
        "unknown_token_type_fixture",
        "unknown_scope_fixture",
        "unknown_child_plane_fixture",
    ] {
        assert!(
            TokenGrant::decode(fixture("application_oauth", key), true).is_err(),
            "{key}"
        );
    }
    let mut wire = fixture("application_oauth", "valid_runtime_fixture");
    wire["agent"]["refresh_token"] = json!("agent-lineage");
    wire["runner"]["refresh_token"] = json!("runner-lineage");
    let runtime = TokenGrant::decode(wire, true).unwrap();
    assert!(runtime.platform_access_token.is_some());
    assert!(runtime.access_token.is_none());
    let agent = runtime.agent.unwrap();
    let runner = runtime.runner.unwrap();
    assert!(agent.access_token.is_some());
    assert!(runner.access_token.is_none());
    assert!(runner.executor_access_token.is_some());
    assert_ne!(agent.refresh_token.expose(), runner.refresh_token.expose());
    let unknown =
        TokenGrant::decode(fixture("application_oauth", "unknown_role_fixture"), true).unwrap();
    assert_eq!(unknown.user.unwrap().role, "zz_unknown_value");
}
#[tokio::test]
async fn device_poll_recognizes_pending_slow_down_throttling_and_uses_forms() {
    let mut throttle = Reply::json(429, "{}");
    throttle.headers.push(("Retry-After".into(), "7".into()));
    let mut server = Server::script(vec![
        Reply::json(
            200,
            fixture("oauth", "valid_device_authorization_fixture").to_string(),
        ),
        Reply::json(400, r#"{"error":"authorization_pending"}"#),
        Reply::json(400, r#"{"error":"slow_down"}"#),
        throttle,
        Reply::json(
            200,
            fixture("oauth", "valid_agent_token_fixture").to_string(),
        ),
        Reply::json(409, r#"{"error":"too_late"}"#),
        Reply::json(200, ""),
    ])
    .await;
    let oauth = OAuthClient::device(&server.url).unwrap();
    let authorization = oauth
        .request_authorization(Some(&claims()), ConnectionMode::Connect)
        .await
        .unwrap();
    assert!(matches!(
        oauth.poll(&authorization).await.unwrap(),
        Poll::Pending
    ));
    assert!(matches!(
        oauth.poll(&authorization).await.unwrap(),
        Poll::SlowDown
    ));
    assert!(
        matches!(oauth.poll(&authorization).await.unwrap(),Poll::Throttled{retry_after} if retry_after==Duration::from_secs(7))
    );
    assert!(matches!(
        oauth.poll(&authorization).await.unwrap(),
        Poll::Authorized(_)
    ));
    assert_eq!(
        oauth.cancel_authorization(&authorization).await.unwrap(),
        Cancellation::Consumed
    );
    oauth.revoke(&SecretString::new("token")).await.unwrap();
    let request = server.next().await;
    let fields = form(&request.body);
    assert_eq!(request.path, "/oauth/device_authorization");
    assert_eq!(fields["client_id"], "cybros-first-party-connector");
    assert_eq!(fields["agent_identifier"], "agent");
    assert!(!request.headers.contains_key("authorization"));
    let request = server.next().await;
    assert_eq!(form(&request.body)["device_code"], "fixture-device-code");
    assert!(!request.path.contains("fixture-device-code"));
}
#[tokio::test]
async fn application_authorization_pkce_and_single_attempt_exchange() {
    let mut server = Server::script(vec![
        Reply::json(
            200,
            fixture("application_oauth", "valid_login_only_fixture").to_string(),
        ),
        Reply::json(503, "upstream unavailable"),
    ])
    .await;
    let oauth = OAuthClient::application(&server.url, "https://public.example/nexus/").unwrap();
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    let challenge = OAuthClient::pkce_challenge(verifier).unwrap();
    assert_eq!(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    let auth = oauth
        .authorization_url(
            "http://127.0.0.1/callback",
            "state",
            &challenge,
            None,
            ConnectionMode::Login,
        )
        .unwrap();
    let fields: BTreeMap<_, _> = auth.query_pairs().into_owned().collect();
    assert_eq!(auth.path(), "/nexus/oauth/authorize");
    assert_eq!(fields["scope"], "application");
    assert_eq!(fields["connection_mode"], "login");
    let grant = oauth
        .exchange_code(
            &SecretString::new("code"),
            "http://127.0.0.1/callback",
            &SecretString::new(verifier),
        )
        .await
        .unwrap();
    assert!(grant.platform_access_token.is_some());
    assert!(matches!(
        oauth.rotate(&SecretString::new("single-use")).await,
        Err(Error::Credential {
            kind: CredentialFailure::AuthorityLost
        })
    ));
    assert_eq!(form(&server.next().await.body)["code_verifier"], verifier);
    assert_eq!(
        form(&server.next().await.body)["refresh_token"],
        "single-use"
    );
    assert!(server.try_next().is_none());
}
#[tokio::test]
async fn token_poll_body_has_a_finite_budget() {
    let mut slow = Reply::json(
        200,
        fixture("oauth", "valid_agent_token_fixture").to_string(),
    );
    slow.body_delay = Duration::from_secs(1);
    let server = Server::script(vec![
        Reply::json(
            200,
            fixture("oauth", "valid_device_authorization_fixture").to_string(),
        ),
        slow,
    ])
    .await;
    let oauth = OAuthClient::new(
        &server.url,
        &server.url,
        false,
        ClientOptions {
            request_timeout: Duration::from_millis(40),
            ..Default::default()
        },
    )
    .unwrap();
    let auth = oauth
        .request_authorization(Some(&claims()), ConnectionMode::Connect)
        .await
        .unwrap();
    let start = tokio::time::Instant::now();
    assert!(matches!(
        oauth.poll(&auth).await,
        Err(Error::Transport { timeout: true, .. })
    ));
    assert!(start.elapsed() < Duration::from_millis(500));
}
