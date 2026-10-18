#![cfg(feature = "realtime")]
use async_trait::async_trait;
use cybros_agent::{
    Error, Result,
    credentials::{CredentialProvider, Plane, SecretString, StaticCredential},
    error::RealtimeFailure,
    realtime::*,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};
use tokio::{net::TcpListener, sync::mpsc};
use tokio_tungstenite::{
    accept_hdr_async,
    tungstenite::{
        Message,
        handshake::server::{Request, Response},
    },
};
#[allow(clippy::result_large_err)] // tungstenite fixes the callback error type to its HTTP response.
async fn server(
    messages: Vec<Value>,
    subprotocol: bool,
) -> (
    String,
    mpsc::UnboundedReceiver<Value>,
    tokio::task::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = mpsc::unbounded_channel();
    let actor = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket =
            accept_hdr_async(stream, move |request: &Request, mut response: Response| {
                assert_eq!(request.uri().path(), "/agent_api/v1/cable");
                assert!(request.headers().contains_key("authorization"));
                if subprotocol {
                    response.headers_mut().insert(
                        "Sec-WebSocket-Protocol",
                        "actioncable-v1-json".parse().unwrap(),
                    );
                }
                Ok(response)
            })
            .await
            .unwrap();
        let Some(Ok(Message::Text(text))) = socket.next().await else {
            return;
        };
        let subscribe: Value = serde_json::from_str(&text).unwrap();
        let id = subscribe["identifier"].clone();
        let _ = tx.send(subscribe);
        socket
            .send(Message::Text(
                json!({"type":"confirm_subscription","identifier":"stale-attempt"})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        socket
            .send(Message::Text(json!({"type":"welcome"}).to_string().into()))
            .await
            .unwrap();
        socket
            .send(Message::Text(
                json!({"type":"confirm_subscription","identifier":id})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        socket
            .send(Message::Text("malformed frame".into()))
            .await
            .unwrap();
        for message in messages {
            let packet = if message.get("type") == Some(&json!("ping")) {
                message
            } else {
                json!({"identifier":id,"message":message})
            };
            socket
                .send(Message::Text(packet.to_string().into()))
                .await
                .unwrap();
        }
        while let Some(Ok(message)) = socket.next().await {
            if let Message::Text(text) = message {
                let value: Value = serde_json::from_str(&text).unwrap();
                let done = value["command"] == "unsubscribe";
                let _ = tx.send(value);
                if done {
                    break;
                }
            }
        }
    });
    (url, rx, actor)
}
fn conversation(items: Items) -> Channel {
    Channel::Conversation {
        workspace_id: "workspace".into(),
        conversation_id: "conversation".into(),
        items,
    }
}
fn event() -> Value {
    json!({"public_id":"event","sequence":1,"cursor":"cursor","type":"future_event","resource":{"type":"conversation","public_id":"conversation"},"occurred_at":"now","payload":{"extra":true}})
}
#[tokio::test]
async fn native_socket_confirms_exact_attempt_decodes_unknown_events_and_unsubscribes() {
    let (url, mut requests, actor) = server(
        vec![json!({"event":event()}), json!({"future_envelope":true})],
        true,
    )
    .await;
    let mut subscription = CableClient::member(&url, "fixture")
        .unwrap()
        .subscribe(conversation(Items::Events))
        .await
        .unwrap();
    let subscribe = requests.recv().await.unwrap();
    let identifier: Value =
        serde_json::from_str(subscribe["identifier"].as_str().unwrap()).unwrap();
    assert_eq!(identifier["items"], "events");
    assert!(identifier["_cybros_sdk_subscription_id"].is_string());
    let Some(Frame::Event(event)) = subscription.next().await.unwrap() else {
        panic!("event expected")
    };
    assert_eq!(event.r#type.as_str(), "future_event");
    assert_eq!(event.payload["extra"], true);
    assert!(
        matches!(subscription.next().await.unwrap(),Some(Frame::Other(v)) if v["future_envelope"]==true)
    );
    subscription.close();
    assert_eq!(requests.recv().await.unwrap()["command"], "unsubscribe");
    actor.await.unwrap();
}
#[tokio::test]
async fn transcript_and_progress_decode_their_wire_envelopes() {
    let (url, _, actor) = server(
        vec![json!({"event":{"type":"text_delta","text":"hello","task_key":"r1"}})],
        true,
    )
    .await;
    let mut subscription = CableClient::member(&url, "fixture")
        .unwrap()
        .subscribe(conversation(Items::Transcript))
        .await
        .unwrap();
    assert!(
        matches!(subscription.next().await.unwrap(),Some(Frame::Transcript(v)) if v.text.as_deref()==Some("hello"))
    );
    subscription.close();
    actor.await.unwrap();
    let(url,_,actor)=server(vec![json!({"frame":{"type":"round_started","at":"now","task_key":"r1","payload":{"mainline":true}}})],true).await;
    let mut subscription = CableClient::member(&url, "fixture")
        .unwrap()
        .subscribe(conversation(Items::Progress))
        .await
        .unwrap();
    assert!(
        matches!(subscription.next().await.unwrap(),Some(Frame::Progress(v)) if v.payload["mainline"]==true)
    );
    subscription.close();
    actor.await.unwrap();
}
#[tokio::test]
async fn executor_ping_sends_pong_and_overflow_reports_recovery_requirement() {
    let (url, mut requests, actor) = server(vec![json!({"type":"ping","message":1})], true).await;
    let mut subscription = CableClient::executor(&url, "fixture")
        .unwrap()
        .subscribe(Channel::ExecutorInbox)
        .await
        .unwrap();
    requests.recv().await.unwrap();
    let pong = requests.recv().await.unwrap();
    let data: Value = serde_json::from_str(pong["data"].as_str().unwrap()).unwrap();
    assert_eq!(data["action"], "pong");
    subscription.close();
    actor.await.unwrap();
    let (url, _, actor) = server((0..20).map(|_| json!({"event":event()})).collect(), true).await;
    let options = CableOptions {
        buffer_capacity: 1,
        ..Default::default()
    };
    let mut sub = CableClient::new(
        &url,
        StaticCredential::new(Plane::Member, "fixture"),
        Plane::Member,
        options,
    )
    .unwrap()
    .subscribe(conversation(Items::Events))
    .await
    .unwrap();
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(matches!(sub.next().await, Err(Error::Realtime { .. })));
    drop(sub);
    let _ = actor.await;
}
struct Hung;
#[async_trait]
impl CredentialProvider for Hung {
    async fn token(&self, _: Plane) -> Result<Option<SecretString>> {
        std::future::pending().await
    }
}
#[tokio::test]
async fn handshake_budget_includes_credentials_and_protocol_is_strict() {
    let client = CableClient::new(
        "http://127.0.0.1:1",
        Arc::new(Hung),
        Plane::Member,
        CableOptions {
            handshake_timeout: Duration::from_millis(20),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(matches!(
        client.subscribe(conversation(Items::Events)).await,
        Err(Error::Realtime {
            kind: RealtimeFailure::Timeout
        })
    ));
    let (url, _, actor) = server(vec![], false).await;
    assert!(matches!(
        CableClient::member(&url, "fixture")
            .unwrap()
            .subscribe(conversation(Items::Events))
            .await,
        Err(Error::Realtime {
            kind: RealtimeFailure::UnsupportedProtocol
        })
    ));
    actor.await.unwrap();
}

struct ReplayPages(
    tokio::sync::Mutex<
        std::collections::VecDeque<cybros_agent::Result<cybros_agent::types::member::EventPage>>,
    >,
);
#[async_trait]
impl cybros_agent::events::ReplaySource for ReplayPages {
    async fn replay(
        &self,
        _: &cybros_agent::events::Position,
    ) -> Result<cybros_agent::types::member::EventPage> {
        self.0.lock().await.pop_front().expect("unexpected replay")
    }
}
fn replay_page(sequence: i64, has_event: bool) -> cybros_agent::types::member::EventPage {
    let mut e = event();
    e["sequence"] = json!(sequence);
    e["cursor"] = json!(format!("c{sequence}"));
    e["public_id"] = json!(format!("e{sequence}"));
    serde_json::from_value(json!({"events":if has_event{vec![e]}else{vec![]},"pagination":{"next_after":null,"watermark":sequence}})).unwrap()
}
#[tokio::test]
async fn follower_retries_replay_then_confirms_and_replays_the_gap_before_live_frames() {
    use cybros_agent::events::{FeedControl, FollowOptions, KernelFeed, Position};
    let source = Arc::new(ReplayPages(tokio::sync::Mutex::new(
        vec![
            Err(Error::Api {
                status: 503,
                code: None,
                message: None,
                details: None,
                retry_after: None,
                request_id: None,
            }),
            Ok(replay_page(1, true)),
            Ok(replay_page(2, true)),
        ]
        .into(),
    )));
    let (url, _, actor) = server(vec![], true).await;
    let mut feed = KernelFeed::new(source, Position::default()).unwrap();
    let mut confirmed = 0;
    let mut seen = vec![];
    feed.follow(
        &CableClient::member(&url, "fixture").unwrap(),
        conversation(Items::Events),
        FollowOptions {
            max_reconnects: 2,
            retry_backoff: Duration::from_millis(1),
        },
        |event, _| {
            seen.push(event.sequence);
            async move {
                Ok(if event.sequence == 2 {
                    FeedControl::Stop
                } else {
                    FeedControl::Continue
                })
            }
        },
        |report| async move {
            assert!(!report.retention_gap);
            Ok(FeedControl::Continue)
        },
        || {
            confirmed += 1;
            Ok(())
        },
    )
    .await
    .unwrap();
    assert_eq!(confirmed, 1);
    assert_eq!(seen, vec![1, 2]);
    assert_eq!(feed.position().sequence, 2);
    actor.await.unwrap();
}
#[tokio::test]
#[allow(clippy::result_large_err)] // Native server handshake callback uses tungstenite's fixed error type.
async fn follower_reconnects_with_a_new_confirmation_and_an_http_gap_barrier() {
    use cybros_agent::events::{FeedControl, FollowOptions, KernelFeed, Position};
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let actor = tokio::spawn(async move {
        let mut ids = vec![];
        for attempt in 0..2 {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = accept_hdr_async(stream, |_: &Request, mut response: Response| {
                response.headers_mut().insert(
                    "Sec-WebSocket-Protocol",
                    "actioncable-v1-json".parse().unwrap(),
                );
                Ok(response)
            })
            .await
            .unwrap();
            let Some(Ok(Message::Text(text))) = socket.next().await else {
                panic!("subscription expected")
            };
            let sub: Value = serde_json::from_str(&text).unwrap();
            let id = sub["identifier"].clone();
            ids.push(id.clone());
            socket
                .send(Message::Text(
                    json!({"type":"confirm_subscription","identifier":id})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
            if attempt == 0 {
                socket.close(None).await.unwrap();
            } else {
                while let Some(Ok(Message::Text(text))) = socket.next().await {
                    let value: Value = serde_json::from_str(&text).unwrap();
                    if value["command"] == "unsubscribe" {
                        break;
                    }
                }
            }
        }
        assert_ne!(ids[0], ids[1]);
    });
    let source = Arc::new(ReplayPages(tokio::sync::Mutex::new(
        vec![
            Ok(replay_page(1, true)),
            Ok(replay_page(1, false)),
            Ok(replay_page(1, false)),
            Ok(replay_page(2, true)),
        ]
        .into(),
    )));
    let mut feed = KernelFeed::new(source, Position::default()).unwrap();
    let mut confirmed = 0;
    feed.follow(
        &CableClient::member(&url, "fixture").unwrap(),
        conversation(Items::Events),
        FollowOptions {
            max_reconnects: 2,
            retry_backoff: Duration::from_millis(1),
        },
        |event, _| async move {
            Ok(if event.sequence == 2 {
                FeedControl::Stop
            } else {
                FeedControl::Continue
            })
        },
        |report| async move {
            assert!(!report.retention_gap);
            Ok(FeedControl::Continue)
        },
        || {
            confirmed += 1;
            Ok(())
        },
    )
    .await
    .unwrap();
    assert_eq!(confirmed, 2);
    actor.await.unwrap();
}
