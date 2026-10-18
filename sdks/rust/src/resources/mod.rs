//! Scoped resource handles. Constructing a handle never makes a request.
use crate::{
    Error, Result,
    credentials::{CredentialProvider, Plane, StaticCredential},
    transport::{ClientOptions, Download, Headers, Response, Transport, UploadBody, segment},
    types::{self, Empty, Page, requests::*},
};
use reqwest::Method;
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Clone)]
struct Resource {
    transport: Arc<Transport>,
    path: String,
}
impl Resource {
    fn child(&self, suffix: &str) -> Self {
        Self {
            transport: self.transport.clone(),
            path: format!("{}/{}", self.path, suffix),
        }
    }
    fn id(&self, id: &str) -> Result<Self> {
        Ok(self.child(&segment(id)?))
    }
    #[allow(clippy::too_many_arguments)] // Private resource dispatch keeps one boundary for explicit wire metadata.
    async fn call<T: DeserializeOwned, Q: Serialize + ?Sized, B: Serialize + ?Sized>(
        &self,
        method: Method,
        suffix: &str,
        query: Option<&Q>,
        body: Option<&B>,
        body_root: Option<&str>,
        headers: Headers<'_>,
        root: Option<&str>,
    ) -> Result<Response<T>> {
        let path = if suffix.is_empty() {
            self.path.clone()
        } else {
            format!("{}/{}", self.path, suffix)
        };
        let body = body
            .map(serde_json::to_value)
            .transpose()
            .map_err(|_| Error::Configuration("request cannot be serialized"))?;
        let body = body.map(|value| match body_root {
            Some(key) => json!({key:value}),
            None => value,
        });
        self.transport
            .json(method, &path, query, body.as_ref(), headers, root, None)
            .await
    }
    async fn page<T: DeserializeOwned, Q: Serialize + ?Sized>(
        &self,
        suffix: &str,
        query: &Q,
        key: &str,
    ) -> Result<Response<Page<T>>> {
        let response: Response<Value> = self
            .call(
                Method::GET,
                suffix,
                Some(query),
                None::<&()>,
                None,
                Headers::default(),
                None,
            )
            .await?;
        let decode_error = |reason| Error::ResponseDecode {
            status: response.status,
            request_id: response
                .headers
                .get("x-request-id")
                .and_then(|v| v.to_str().ok())
                .map(crate::error::redact),
            reason,
        };
        let items = response
            .body
            .get(key)
            .cloned()
            .ok_or_else(|| decode_error(crate::error::DecodeFailure::MissingEnvelope))?;
        let items = serde_json::from_value(items)
            .map_err(|_| decode_error(crate::error::DecodeFailure::InvalidDocument))?;
        let next_after = response
            .body
            .get("pagination")
            .and_then(|p| p.get("next_after"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        Ok(response.map(|_| Page { items, next_after }))
    }
}
macro_rules! handle {
    ($name:ident) => {
        #[derive(Clone)]
        pub struct $name(pub(super) Resource);
    };
}
macro_rules! get {
    ($name:ident,$path:literal,$response:ty,$root:expr) => {
        pub async fn $name(&self) -> Result<Response<$response>> {
            self.0
                .call(
                    Method::GET,
                    $path,
                    None::<&()>,
                    None::<&()>,
                    None,
                    Headers::default(),
                    $root,
                )
                .await
        }
    };
}
macro_rules! query_get {
    ($name:ident,$path:literal,$query:ty,$response:ty,$root:expr) => {
        pub async fn $name(&self, query: &$query) -> Result<Response<$response>> {
            self.0
                .call(
                    Method::GET,
                    $path,
                    Some(query),
                    None::<&()>,
                    None,
                    Headers::default(),
                    $root,
                )
                .await
        }
    };
}
macro_rules! list {
    ($name:ident,$path:literal,$query:ty,$response:ty,$root:literal) => {
        pub async fn $name(&self, query: &$query) -> Result<Response<Page<$response>>> {
            self.0.page($path, query, $root).await
        }
    };
}
macro_rules! write {
    ($name:ident,$method:ident,$path:literal,$request:ty,$body_root:expr,$response:ty,$root:expr) => {
        pub async fn $name(&self, request: &$request) -> Result<Response<$response>> {
            self.0
                .call(
                    Method::$method,
                    $path,
                    None::<&()>,
                    Some(request),
                    $body_root,
                    Headers::default(),
                    $root,
                )
                .await
        }
    };
}
macro_rules! create {
    ($name:ident,$path:literal,$request:ty,$body_root:expr,$response:ty,$root:expr) => {
        pub async fn $name(
            &self,
            request: &$request,
            idempotency_key: &str,
        ) -> Result<Response<$response>> {
            self.0
                .call(
                    Method::POST,
                    $path,
                    None::<&()>,
                    Some(request),
                    $body_root,
                    Headers {
                        idempotency_key: Some(idempotency_key),
                        ..Default::default()
                    },
                    $root,
                )
                .await
        }
    };
}
macro_rules! command {
    ($name:ident,$method:ident,$path:literal,$response:ty,$root:expr) => {
        pub async fn $name(&self) -> Result<Response<$response>> {
            self.0
                .call(
                    Method::$method,
                    $path,
                    None::<&()>,
                    None::<&()>,
                    None,
                    Headers::default(),
                    $root,
                )
                .await
        }
    };
}
macro_rules! child {
    ($name:ident,$path:literal,$child:ident) => {
        pub fn $name(&self) -> $child {
            $child(self.0.child($path))
        }
    };
}
macro_rules! child_id {
    ($name:ident,$path:literal,$child:ident) => {
        pub fn $name(&self, public_id: &str) -> Result<$child> {
            Ok($child(self.0.child($path).id(public_id)?))
        }
    };
}
macro_rules! client {
    ($name:ident,$plane:ident,$prefix:literal) => {
        #[derive(Clone)]
        pub struct $name(Resource);
        impl $name {
            pub fn new(base_url: &str, token: impl Into<String>) -> Result<Self> {
                Self::with_credentials(
                    base_url,
                    StaticCredential::new(Plane::$plane, token),
                    ClientOptions::default(),
                )
            }
            pub fn with_credentials(
                base_url: &str,
                credentials: Arc<dyn CredentialProvider>,
                options: ClientOptions,
            ) -> Result<Self> {
                Ok(Self(Resource {
                    transport: Arc::new(Transport::new(
                        base_url,
                        credentials,
                        Plane::$plane,
                        options,
                    )?),
                    path: $prefix.into(),
                }))
            }
        }
    };
}
client!(Client, Member, "/agent_api/v1");
client!(ExecutorClient, Executor, "/agent_api/v1/executor");
client!(PlatformClient, Platform, "/api/v1");
mod conversations;
mod executor;
mod member;
mod platform;
mod runs;
mod shared;
mod work;
pub use conversations::*;
pub use executor::*;
pub use member::*;
pub use platform::*;
pub use runs::*;
pub use shared::*;
pub use work::*;
