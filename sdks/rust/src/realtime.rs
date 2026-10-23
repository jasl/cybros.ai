//! Optional native ActionCable transport. Each returned subscription owns one
//! finite handshake and a bounded queue; close/drop only ends observation.
use crate::{
    Error, Result,
    credentials::{CredentialProvider, Plane, StaticCredential},
    error::RealtimeFailure,
    types::{
        JsonObject,
        member::{Event, ProgressFrame, TranscriptItem},
    },
};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};
static GENERATION: AtomicU64 = AtomicU64::new(1);
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Items {
    Events,
    Lifecycle,
    Transcript,
    Progress,
}
#[derive(Clone, Debug)]
pub enum Channel {
    Conversation {
        workspace_id: String,
        conversation_id: String,
        items: Items,
    },
    Run {
        workspace_id: String,
        run_id: String,
        items: Items,
    },
    InferenceRequest {
        workspace_id: String,
        inference_request_id: String,
        items: Option<Items>,
    },
    ExecutorInbox,
}
impl Channel {
    pub fn identifier(&self) -> String {
        let mut value = match self {
            Self::Conversation {
                workspace_id,
                conversation_id,
                items,
            } => {
                json!({"channel":"AgentAPI::V1::ConversationEventsChannel","workspace_id":workspace_id,"conversation_id":conversation_id,"items":items})
            }
            Self::Run {
                workspace_id,
                run_id,
                items,
            } => {
                json!({"channel":"AgentAPI::V1::RunEventsChannel","workspace_id":workspace_id,"run_id":run_id,"items":items})
            }
            Self::InferenceRequest {
                workspace_id,
                inference_request_id,
                items,
            } => {
                let mut v = json!({"channel":"AgentAPI::V1::InferenceRequestEventsChannel","workspace_id":workspace_id,"inference_request_id":inference_request_id});
                if let Some(i) = items {
                    v["items"] = json!(i);
                }
                v
            }
            Self::ExecutorInbox => json!({"channel":"AgentAPI::V1::ExecutorInboxChannel"}),
        };
        value["_cybros_sdk_subscription_id"] =
            json!(GENERATION.fetch_add(1, Ordering::Relaxed).to_string());
        value.to_string()
    }
}
#[derive(Clone, Debug)]
pub enum Frame {
    Event(Event),
    Transcript(Box<TranscriptItem>),
    Progress(ProgressFrame),
    Other(JsonObject),
}
#[derive(Clone, Debug)]
pub struct CableOptions {
    pub handshake_timeout: Duration,
    pub heartbeat_timeout: Duration,
    pub buffer_capacity: usize,
    pub max_message_bytes: usize,
}
impl Default for CableOptions {
    fn default() -> Self {
        Self {
            handshake_timeout: Duration::from_secs(10),
            heartbeat_timeout: Duration::from_secs(30),
            buffer_capacity: 256,
            max_message_bytes: 1024 * 1024,
        }
    }
}
#[derive(Clone)]
pub struct CableClient {
    base: url::Url,
    credentials: Arc<dyn CredentialProvider>,
    plane: Plane,
    options: CableOptions,
}
impl CableClient {
    pub fn member(base_url: &str, token: impl Into<String>) -> Result<Self> {
        Self::new(
            base_url,
            StaticCredential::new(Plane::Member, token),
            Plane::Member,
            CableOptions::default(),
        )
    }
    pub fn executor(base_url: &str, token: impl Into<String>) -> Result<Self> {
        Self::new(
            base_url,
            StaticCredential::new(Plane::Executor, token),
            Plane::Executor,
            CableOptions::default(),
        )
    }
    pub fn new(
        base_url: &str,
        credentials: Arc<dyn CredentialProvider>,
        plane: Plane,
        options: CableOptions,
    ) -> Result<Self> {
        let base = url::Url::parse(base_url)
            .map_err(|_| Error::Configuration("invalid Cable base URL"))?;
        if !matches!(base.scheme(), "http" | "https")
            || base.host_str().is_none()
            || !base.username().is_empty()
            || base.password().is_some()
            || base.query().is_some()
            || base.fragment().is_some()
            || plane == Plane::Platform
            || options.buffer_capacity == 0
            || options.handshake_timeout.is_zero()
            || options.heartbeat_timeout.is_zero()
        {
            return Err(Error::Configuration("invalid Cable configuration"));
        }
        Ok(Self {
            base,
            credentials,
            plane,
            options,
        })
    }
    /// Returns only after the server confirms this exact subscription attempt.
    pub async fn subscribe(&self, channel: Channel) -> Result<Subscription> {
        tokio::time::timeout(
            self.options.handshake_timeout,
            self.subscribe_inner(channel),
        )
        .await
        .map_err(|_| Error::Realtime {
            kind: RealtimeFailure::Timeout,
        })?
    }
    async fn subscribe_inner(&self, channel: Channel) -> Result<Subscription> {
        let token = self
            .credentials
            .token(self.plane)
            .await?
            .ok_or(Error::Credential {
                kind: crate::error::CredentialFailure::MissingPlane,
            })?;
        let mut endpoint = self
            .base
            .join("/agent_api/v1/cable")
            .map_err(|_| Error::Configuration("invalid Cable URL"))?;
        endpoint
            .set_scheme(if self.base.scheme() == "https" {
                "wss"
            } else {
                "ws"
            })
            .map_err(|_| Error::Configuration("invalid Cable scheme"))?;
        let mut request = endpoint
            .as_str()
            .into_client_request()
            .map_err(|_| Error::Configuration("invalid Cable request"))?;
        let headers = request.headers_mut();
        let mut bearer = tokio_tungstenite::tungstenite::http::HeaderValue::from_str(&format!(
            "Bearer {}",
            token.expose()
        ))
        .map_err(|_| Error::Configuration("invalid Cable credential"))?;
        bearer.set_sensitive(true);
        headers.insert("Authorization", bearer);
        headers.insert(
            "Origin",
            self.base
                .origin()
                .ascii_serialization()
                .parse()
                .map_err(|_| Error::Configuration("invalid Cable origin"))?,
        );
        headers.insert(
            "Sec-WebSocket-Protocol",
            "actioncable-v1-json, actioncable-unsupported"
                .parse()
                .expect("literal"),
        );
        let identifier = channel.identifier();
        let deadline = tokio::time::Instant::now() + self.options.handshake_timeout;
        let mut config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default();
        config.max_message_size = Some(self.options.max_message_bytes);
        config.max_frame_size = Some(self.options.max_message_bytes);
        let (mut socket, response) = tokio::time::timeout_at(
            deadline,
            tokio_tungstenite::connect_async_with_config(request, Some(config), false),
        )
        .await
        .map_err(|_| Error::Realtime {
            kind: RealtimeFailure::Timeout,
        })?
        .map_err(handshake_error)?;
        if response
            .headers()
            .get("Sec-WebSocket-Protocol")
            .and_then(|v| v.to_str().ok())
            != Some("actioncable-v1-json")
        {
            return Err(Error::Realtime {
                kind: RealtimeFailure::UnsupportedProtocol,
            });
        }
        socket
            .send(Message::Text(
                json!({"command":"subscribe","identifier":identifier})
                    .to_string()
                    .into(),
            ))
            .await
            .map_err(|_| Error::Realtime {
                kind: RealtimeFailure::Disconnected,
            })?;
        loop {
            let frame = tokio::time::timeout_at(deadline, socket.next())
                .await
                .map_err(|_| Error::Realtime {
                    kind: RealtimeFailure::Timeout,
                })?
                .ok_or(Error::Realtime {
                    kind: RealtimeFailure::Disconnected,
                })?
                .map_err(|_| Error::Realtime {
                    kind: RealtimeFailure::Disconnected,
                })?;
            if let Message::Text(text) = frame
                && let Ok(v) = serde_json::from_str::<Value>(&text)
            {
                if v.get("identifier").and_then(Value::as_str) == Some(&identifier) {
                    match v.get("type").and_then(Value::as_str) {
                        Some("confirm_subscription") => break,
                        Some("reject_subscription") => {
                            return Err(Error::Realtime {
                                kind: RealtimeFailure::Rejected,
                            });
                        }
                        _ => {}
                    }
                }
                if v.get("type").and_then(Value::as_str) == Some("disconnect") {
                    return Err(Error::Realtime {
                        kind: RealtimeFailure::Disconnected,
                    });
                }
            }
        }
        let (sender, receiver) = tokio::sync::mpsc::channel(self.options.buffer_capacity);
        let (close, mut closing) = tokio::sync::oneshot::channel();
        let lost = Arc::new(AtomicBool::new(false));
        let actor_lost = lost.clone();
        let heartbeat = self.options.heartbeat_timeout;
        tokio::spawn(async move {
            loop {
                tokio::select! {
                 _=&mut closing=>{let _=tokio::time::timeout(Duration::from_secs(2),async{let _=socket.send(Message::Text(json!({"command":"unsubscribe","identifier":identifier}).to_string().into())).await;let _=socket.close(None).await;}).await;break;},
                 incoming=tokio::time::timeout(heartbeat,socket.next())=>{
                  let message=match incoming{Ok(Some(Ok(m)))=>m,_=>{actor_lost.store(true,Ordering::Release);break;}};
                  match message{
                   Message::Text(text)=>{let Ok(v)=serde_json::from_str::<Value>(&text)else{continue;};match v.get("type").and_then(Value::as_str){Some("disconnect")=>{actor_lost.store(true,Ordering::Release);break;},Some("ping")=>{if matches!(channel,Channel::ExecutorInbox){let pong=json!({"command":"message","identifier":identifier,"data":json!({"action":"pong"}).to_string()});if !matches!(tokio::time::timeout(heartbeat,socket.send(Message::Text(pong.to_string().into()))).await,Ok(Ok(()))){actor_lost.store(true,Ordering::Release);break;}}},_=>{}}
                    if v.get("identifier").and_then(Value::as_str)!=Some(&identifier){continue;}
                    if let Some(message)=v.get("message")&& let Some(frame)=decode_frame(&channel,message.clone())&& sender.try_send(frame).is_err(){actor_lost.store(true,Ordering::Release);break;}
                   },Message::Close(_)=>{actor_lost.store(true,Ordering::Release);break;},Message::Ping(bytes)=>{if !matches!(tokio::time::timeout(heartbeat,socket.send(Message::Pong(bytes))).await,Ok(Ok(()))){actor_lost.store(true,Ordering::Release);break;}},_=>{}
                  }
                 }
                }
            }
        });
        Ok(Subscription {
            receiver,
            close: Some(close),
            lost,
        })
    }
}
fn decode_frame(channel: &Channel, v: Value) -> Option<Frame> {
    if let Some(e) = v.get("event") {
        if matches!(
            channel,
            Channel::Conversation {
                items: Items::Transcript,
                ..
            } | Channel::Run {
                items: Items::Transcript,
                ..
            }
        ) {
            return serde_json::from_value(e.clone())
                .ok()
                .map(Frame::Transcript);
        }
        return serde_json::from_value(e.clone()).ok().map(Frame::Event);
    }
    if let Some(e) = v.get("frame") {
        return serde_json::from_value(e.clone()).ok().map(Frame::Progress);
    }
    v.as_object().cloned().map(Frame::Other)
}
pub struct Subscription {
    receiver: tokio::sync::mpsc::Receiver<Frame>,
    close: Option<tokio::sync::oneshot::Sender<()>>,
    lost: Arc<AtomicBool>,
}
impl Subscription {
    pub async fn next(&mut self) -> Result<Option<Frame>> {
        if self.lost.load(Ordering::Acquire) {
            return Err(Error::Realtime {
                kind: RealtimeFailure::Disconnected,
            });
        }
        let frame = self.receiver.recv().await;
        if self.lost.load(Ordering::Acquire) {
            return Err(Error::Realtime {
                kind: RealtimeFailure::Disconnected,
            });
        }
        Ok(frame)
    }
    pub fn close(&mut self) {
        if let Some(close) = self.close.take() {
            let _ = close.send(());
        }
        self.receiver.close();
    }
}
impl Drop for Subscription {
    fn drop(&mut self) {
        self.close();
    }
}

fn handshake_error(error: tokio_tungstenite::tungstenite::Error) -> Error {
    match error {
        tokio_tungstenite::tungstenite::Error::Protocol(
            tokio_tungstenite::tungstenite::error::ProtocolError::SecWebSocketSubProtocolError(_),
        ) => Error::Realtime {
            kind: RealtimeFailure::UnsupportedProtocol,
        },
        tokio_tungstenite::tungstenite::Error::Http(response) => Error::Api {
            status: response.status().as_u16(),
            code: None,
            message: None,
            details: None,
            retry_after: response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned),
            request_id: response
                .headers()
                .get("x-request-id")
                .and_then(|v| v.to_str().ok())
                .map(crate::error::redact),
        },
        _ => Error::Realtime {
            kind: RealtimeFailure::Disconnected,
        },
    }
}
