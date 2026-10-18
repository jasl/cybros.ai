use serde_json::Value;
use std::{fmt, time::Duration};
pub type Result<T> = std::result::Result<T, Error>;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SendOutcome {
    NotSent,
    Unknown,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransportCategory {
    Build,
    Connect,
    Timeout,
    Body,
    Decode,
    Request,
    Other,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RealtimeFailure {
    Disconnected,
    BufferOverflow,
    Rejected,
    Timeout,
    UnsupportedProtocol,
    InvalidFrame,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecodeFailure {
    MalformedJson,
    MissingEnvelope,
    InvalidDocument,
}
#[derive(Clone, Debug)]
pub enum Error {
    Configuration(&'static str),
    Protocol(&'static str),
    Realtime {
        kind: RealtimeFailure,
    },
    Transport {
        outcome: SendOutcome,
        timeout: bool,
        category: TransportCategory,
    },
    Api {
        status: u16,
        code: Option<String>,
        message: Option<String>,
        details: Option<Box<Value>>,
        retry_after: Option<String>,
        request_id: Option<String>,
    },
    ResponseDecode {
        status: u16,
        request_id: Option<String>,
        reason: DecodeFailure,
    },
    Credential {
        kind: CredentialFailure,
    },
    ObservationTimeout {
        elapsed: Duration,
    },
    RetentionGap {
        recovery: Value,
    },
    Consumer(String),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CredentialFailure {
    MissingPlane,
    AuthorityLost,
    NotDurable,
    Published,
    Store,
    Superseded,
}
impl Error {
    pub fn status(&self) -> Option<u16> {
        match self {
            Self::Api { status, .. } | Self::ResponseDecode { status, .. } => Some(*status),
            _ => None,
        }
    }
    pub fn code(&self) -> Option<&str> {
        if let Self::Api { code, .. } = self {
            code.as_deref()
        } else {
            None
        }
    }
    pub(crate) fn transport(error: reqwest::Error) -> Self {
        let category = if error.is_builder() {
            TransportCategory::Build
        } else if error.is_connect() {
            TransportCategory::Connect
        } else if error.is_timeout() {
            TransportCategory::Timeout
        } else if error.is_body() {
            TransportCategory::Body
        } else if error.is_decode() {
            TransportCategory::Decode
        } else if error.is_request() {
            TransportCategory::Request
        } else {
            TransportCategory::Other
        };
        Self::Transport {
            outcome: if error.is_builder() || error.is_connect() {
                SendOutcome::NotSent
            } else {
                SendOutcome::Unknown
            },
            timeout: error.is_timeout(),
            category,
        }
    }
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Configuration(s) | Self::Protocol(s) => f.write_str(s),
            Self::Realtime { kind } => write!(f, "Cable failure: {kind:?}"),
            Self::Transport {
                outcome,
                timeout,
                category,
            } => write!(
                f,
                "request failed ({category:?}; send outcome: {outcome:?}; timeout: {timeout})"
            ),
            Self::Api {
                status,
                code,
                message,
                ..
            } => write!(
                f,
                "Nexus HTTP {status} ({}): {}",
                code.as_deref().unwrap_or("unstructured_error"),
                message.as_deref().unwrap_or("request refused")
            ),
            Self::ResponseDecode { status, reason, .. } => {
                write!(f, "invalid Nexus HTTP {status} response ({reason:?})")
            }
            Self::Credential { kind } => write!(f, "credential operation failed: {kind:?}"),
            Self::ObservationTimeout { .. } => {
                f.write_str("observation deadline elapsed; server execution is unchanged")
            }
            Self::RetentionGap { .. } => {
                f.write_str("event history was pruned; explicit recovery is required")
            }
            Self::Consumer(_) => f.write_str("event consumer failed"),
        }
    }
}
impl std::error::Error for Error {}
/// Redact recognized token families while retaining task keys and useful prose.
pub(crate) fn redact(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < bytes.len() {
        let boundary = i == 0 || !bytes[i - 1].is_ascii_alphanumeric();
        let prefix = i + 3 <= bytes.len()
            && matches!(
                &bytes[i..i + 3],
                b"sk-" | b"rt-" | b"dc-" | b"rc-" | b"SK-" | b"RT-" | b"DC-" | b"RC-"
            );
        if boundary && prefix && bytes.get(i + 3).is_some_and(u8::is_ascii_alphanumeric) {
            let mut end = i + 4;
            while end < bytes.len()
                && (bytes[end].is_ascii_alphanumeric() || b"._-".contains(&bytes[end]))
            {
                end += 1;
            }
            out.push_str("[REDACTED]");
            i = end;
        } else {
            let ch = text[i..].chars().next().expect("in bounds");
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}
pub(crate) fn redact_value(value: Value) -> Value {
    match value {
        Value::String(s) => Value::String(redact(&s)),
        Value::Array(v) => Value::Array(v.into_iter().map(redact_value).collect()),
        Value::Object(v) => Value::Object(
            v.into_iter()
                .map(|(k, v)| {
                    let name = k.to_ascii_lowercase();
                    let secret = name == "key"
                        || [
                            "token",
                            "secret",
                            "bearer",
                            "password",
                            "credential",
                            "passphrase",
                            "authorization",
                            "cookie",
                            "api_key",
                            "apikey",
                        ]
                        .iter()
                        .any(|word| name.contains(word));
                    (
                        k,
                        if secret {
                            Value::String("[REDACTED]".into())
                        } else {
                            redact_value(v)
                        },
                    )
                })
                .collect(),
        ),
        v => v,
    }
}
