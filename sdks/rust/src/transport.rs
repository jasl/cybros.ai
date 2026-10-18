//! Finite, single-attempt HTTP transport. Returned byte streams belong to the caller.
use crate::{
    Error, Result,
    credentials::{CredentialProvider, Plane},
};
use bytes::Bytes;
use futures_util::{Stream, StreamExt};
use reqwest::{
    Method,
    header::{HeaderMap, HeaderValue},
};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::{pin::Pin, sync::Arc, time::Duration};

#[derive(Clone, Debug)]
pub struct ClientOptions {
    pub request_timeout: Duration,
    pub connect_timeout: Duration,
    pub read_timeout: Duration,
    pub pool_max_idle_per_host: usize,
}
impl Default for ClientOptions {
    fn default() -> Self {
        Self {
            request_timeout: Duration::from_secs(30),
            connect_timeout: Duration::from_secs(10),
            read_timeout: Duration::from_secs(130),
            pool_max_idle_per_host: 8,
        }
    }
}
#[derive(Clone, Debug)]
pub struct Response<T> {
    pub body: T,
    pub status: u16,
    pub headers: HeaderMap,
    pub replayed: bool,
}
impl<T> Response<T> {
    pub fn map<U>(self, f: impl FnOnce(T) -> U) -> Response<U> {
        Response {
            body: f(self.body),
            status: self.status,
            headers: self.headers,
            replayed: self.replayed,
        }
    }
}
pub type ByteStream = Pin<Box<dyn Stream<Item = Result<Bytes>> + Send>>;
pub struct Download {
    pub status: u16,
    pub headers: HeaderMap,
    pub bytes: ByteStream,
}
impl std::fmt::Debug for Download {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Download")
            .field("status", &self.status)
            .finish_non_exhaustive()
    }
}
impl Download {
    pub fn etag(&self) -> Option<&str> {
        self.headers.get("etag").and_then(|h| h.to_str().ok())
    }
    pub fn unchanged(&self) -> bool {
        self.status == 304
    }
}
/// Bytes or a caller-provided stream; the SDK never opens a local path.
pub struct UploadBody {
    pub filename: String,
    pub content_type: String,
    body: reqwest::Body,
    length: Option<u64>,
}
impl UploadBody {
    pub fn bytes(filename: impl Into<String>, bytes: impl Into<Bytes>) -> Self {
        let bytes = bytes.into();
        let length = Some(bytes.len() as u64);
        Self {
            filename: filename.into(),
            content_type: "application/octet-stream".into(),
            body: bytes.into(),
            length,
        }
    }
    pub fn stream<S>(filename: impl Into<String>, stream: S, length: Option<u64>) -> Self
    where
        S: Stream<Item = std::result::Result<Bytes, std::io::Error>> + Send + 'static,
    {
        Self {
            filename: filename.into(),
            content_type: "application/octet-stream".into(),
            body: reqwest::Body::wrap_stream(stream),
            length,
        }
    }
}

#[derive(Default)]
pub(crate) struct Headers<'a> {
    pub idempotency_key: Option<&'a str>,
    pub claim_token: Option<&'a str>,
    pub range: Option<&'a str>,
    pub etag: Option<&'a str>,
}
#[derive(Clone)]
pub(crate) struct Transport {
    pub(crate) base: url::Url,
    pub(crate) client: reqwest::Client,
    pub(crate) credentials: Arc<dyn CredentialProvider>,
    pub(crate) plane: Plane,
    timeout: Duration,
}
impl Transport {
    pub(crate) fn new(
        base: &str,
        credentials: Arc<dyn CredentialProvider>,
        plane: Plane,
        options: ClientOptions,
    ) -> Result<Self> {
        let mut base =
            url::Url::parse(base).map_err(|_| Error::Configuration("invalid Nexus base URL"))?;
        if !matches!(base.scheme(), "http" | "https")
            || base.host_str().is_none()
            || !base.username().is_empty()
            || base.password().is_some()
            || base.query().is_some()
            || base.fragment().is_some()
        {
            return Err(Error::Configuration(
                "Nexus base URL must be HTTP(S) without userinfo, query, or fragment",
            ));
        }
        for budget in [
            options.request_timeout,
            options.connect_timeout,
            options.read_timeout,
        ] {
            if budget.is_zero() {
                return Err(Error::Configuration("HTTP timeouts must be positive"));
            }
        }
        if !base.path().ends_with('/') {
            base.set_path(&format!("{}/", base.path()));
        }
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(options.connect_timeout)
            .read_timeout(options.read_timeout)
            .timeout(options.request_timeout)
            .pool_max_idle_per_host(options.pool_max_idle_per_host)
            .build()
            .map_err(Error::transport)?;
        Ok(Self {
            base,
            client,
            credentials,
            plane,
            timeout: options.request_timeout,
        })
    }
    pub(crate) async fn request<Q: Serialize + ?Sized>(
        &self,
        method: Method,
        path: &str,
        query: Option<&Q>,
        headers: Headers<'_>,
        timeout: Option<Duration>,
    ) -> Result<reqwest::RequestBuilder> {
        let budget = timeout.unwrap_or(self.timeout);
        let deadline = tokio::time::Instant::now() + budget;
        let url = self
            .base
            .join(path.trim_start_matches('/'))
            .map_err(|_| Error::Configuration("invalid resource path"))?;
        let mut request = self
            .client
            .request(method, url)
            .header("Accept", "application/json")
            .timeout(timeout.unwrap_or(self.timeout));
        if let Some(token) = tokio::time::timeout_at(deadline, self.credentials.token(self.plane))
            .await
            .map_err(|_| Error::Transport {
                outcome: crate::error::SendOutcome::NotSent,
                timeout: true,
                category: crate::error::TransportCategory::Timeout,
            })??
        {
            let mut value = HeaderValue::from_str(&format!("Bearer {}", token.expose()))
                .map_err(|_| Error::Configuration("invalid credential header"))?;
            value.set_sensitive(true);
            request = request.header("Authorization", value);
        }
        if let Some(query) = query {
            request = request.query(query);
        }
        for (name, value) in [
            ("Idempotency-Key", headers.idempotency_key),
            ("Claim-Token", headers.claim_token),
            ("Range", headers.range),
            ("If-None-Match", headers.etag),
        ] {
            if let Some(value) = value {
                if value.is_empty() {
                    return Err(Error::Configuration(
                        "request header value must not be empty",
                    ));
                }
                let mut value = HeaderValue::from_str(value)
                    .map_err(|_| Error::Configuration("invalid request header"))?;
                value.set_sensitive(name == "Claim-Token");
                request = request.header(name, value);
            }
        }
        Ok(request.timeout(deadline.saturating_duration_since(tokio::time::Instant::now())))
    }
    #[allow(clippy::too_many_arguments)] // One internal transport boundary carries method, query, body, headers and decoding.
    pub(crate) async fn json<T: DeserializeOwned, Q: Serialize + ?Sized, B: Serialize + ?Sized>(
        &self,
        method: Method,
        path: &str,
        query: Option<&Q>,
        body: Option<&B>,
        headers: Headers<'_>,
        root: Option<&str>,
        timeout: Option<Duration>,
    ) -> Result<Response<T>> {
        let mut request = self.request(method, path, query, headers, timeout).await?;
        if let Some(body) = body {
            request = request.json(body);
        }
        let response = request.send().await.map_err(Error::transport)?;
        Self::decode(response, root).await
    }
    pub(crate) async fn decode<T: DeserializeOwned>(
        response: reqwest::Response,
        root: Option<&str>,
    ) -> Result<Response<T>> {
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let bytes = response.bytes().await.map_err(Error::transport)?;
        if !(200..300).contains(&status) {
            return Err(api_error(status, &headers, &bytes));
        }
        let decoded = if bytes.is_empty() {
            Ok(serde_json::json!({}))
        } else {
            serde_json::from_slice::<Value>(&bytes)
        };
        let request_id = headers
            .get("x-request-id")
            .and_then(|v| v.to_str().ok())
            .map(crate::error::redact);
        let body = decoded.map_err(|_| Error::ResponseDecode {
            status,
            request_id: request_id.clone(),
            reason: crate::error::DecodeFailure::MalformedJson,
        })?;
        let replayed = headers
            .get("idempotency-replayed")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v == "true");
        let body = match root {
            Some(key) => body.get(key).cloned().ok_or(Error::ResponseDecode {
                status,
                request_id: request_id.clone(),
                reason: crate::error::DecodeFailure::MissingEnvelope,
            })?,
            None => body,
        };
        let body = serde_json::from_value(body).map_err(|_| Error::ResponseDecode {
            status,
            request_id: request_id.clone(),
            reason: crate::error::DecodeFailure::InvalidDocument,
        })?;
        Ok(Response {
            body,
            status,
            headers,
            replayed,
        })
    }
    pub(crate) async fn download<Q: Serialize + ?Sized>(
        &self,
        path: &str,
        query: Option<&Q>,
        headers: Headers<'_>,
    ) -> Result<Download> {
        let response = self
            .request(Method::GET, path, query, headers, None)
            .await?
            .send()
            .await
            .map_err(Error::transport)?;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        if ![200, 206, 304].contains(&status) {
            let bytes = response.bytes().await.map_err(Error::transport)?;
            return Err(api_error(status, &headers, &bytes));
        }
        Ok(Download {
            status,
            headers,
            bytes: Box::pin(response.bytes_stream().map(|v| v.map_err(Error::transport))),
        })
    }
    pub(crate) async fn upload<T: DeserializeOwned>(
        &self,
        path: &str,
        upload: UploadBody,
    ) -> Result<Response<T>> {
        let part = match upload.length {
            Some(n) => reqwest::multipart::Part::stream_with_length(upload.body, n),
            None => reqwest::multipart::Part::stream(upload.body),
        };
        let part = part
            .file_name(upload.filename)
            .mime_str(&upload.content_type)
            .map_err(Error::transport)?;
        let request = self
            .request(Method::POST, path, None::<&()>, Headers::default(), None)
            .await?;
        Self::decode(
            request
                .multipart(reqwest::multipart::Form::new().part("upload[file]", part))
                .send()
                .await
                .map_err(Error::transport)?,
            Some("upload"),
        )
        .await
    }
}
fn api_error(status: u16, headers: &HeaderMap, bytes: &[u8]) -> Error {
    // Proxies may return text or HTML. Preserve their status and a bounded
    // diagnostic without mistaking that refusal for malformed successful JSON.
    let decoded = serde_json::from_slice::<Value>(bytes);
    let fallback = decoded.as_ref().err().map(|_| diagnostic(bytes));
    let body = decoded.unwrap_or(Value::Null);
    let error = body.get("error").unwrap_or(&Value::Null);
    let code = error.get("code").and_then(Value::as_str).map(str::to_owned);
    Error::Api {
        status,
        code: code.map(|s| crate::error::redact(&s)),
        message: error
            .get("message")
            .and_then(Value::as_str)
            .map(|message| diagnostic(message.as_bytes()))
            .or(fallback),
        details: error
            .get("details")
            .cloned()
            .map(crate::error::redact_value)
            .map(Box::new),
        retry_after: headers
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned),
        request_id: headers
            .get("x-request-id")
            .and_then(|v| v.to_str().ok())
            .map(crate::error::redact),
    }
}
fn diagnostic(bytes: &[u8]) -> String {
    let mut text = crate::error::redact(&String::from_utf8_lossy(bytes));
    let mut end = text.len().min(4096);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    text
}
pub(crate) fn segment(value: &str) -> Result<String> {
    if value.is_empty() || value == "." || value == ".." {
        return Err(Error::Configuration("resource identifier must be nonempty"));
    }
    let mut url = url::Url::parse("http://localhost/").expect("literal URL");
    url.path_segments_mut()
        .expect("hierarchical URL")
        .push(value);
    Ok(url.path()[1..].to_owned())
}
