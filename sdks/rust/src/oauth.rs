//! First-party device authorization and Human application login.
//! Exchanges and rotations are single-attempt; polling alone has bounded retries.
use crate::{
    Error, Result,
    credentials::{Anonymous, Plane, SecretString},
    error::CredentialFailure,
    transport::{ClientOptions, Headers, Transport},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthorizationBranch {
    Agent,
    Runner,
    Application,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentClaims {
    pub agent_identifier: String,
    pub agent_display_name: String,
    pub executor_display_name: String,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutorKind {
    Runner,
    ToolProvider,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunnerClaims {
    pub registration_identifier: String,
    pub runner_display_name: String,
    pub executor_kind: ExecutorKind,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ConnectionClaims {
    Agent(AgentClaims),
    Runner(RunnerClaims),
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionMode {
    Connect,
    Login,
}
#[derive(Clone, Debug, Deserialize)]
pub struct Authorization {
    pub device_code: SecretString,
    pub user_code: String,
    pub verification_uri: String,
    pub verification_uri_complete: String,
    pub expires_in: u64,
    pub interval: u64,
    #[serde(skip, default = "tokio::time::Instant::now")]
    deadline: tokio::time::Instant,
    #[serde(skip, default = "default_branch")]
    branch: AuthorizationBranch,
}
fn default_branch() -> AuthorizationBranch {
    AuthorizationBranch::Agent
}
impl Authorization {
    pub fn remaining(&self) -> Duration {
        self.deadline
            .saturating_duration_since(tokio::time::Instant::now())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Human {
    pub public_id: String,
    pub display_name: String,
    pub role: String,
}
/// Each child is its own refresh lineage. A Human token never serves Member calls.
#[derive(Clone, Debug)]
pub struct TokenGrant {
    pub access_token: Option<SecretString>,
    pub executor_access_token: Option<SecretString>,
    pub platform_access_token: Option<SecretString>,
    pub refresh_token: SecretString,
    pub expires_in: u64,
    pub user: Option<Human>,
    pub agent_public_id: Option<String>,
    pub agent: Option<Box<TokenGrant>>,
    pub runner: Option<Box<TokenGrant>>,
}
impl TokenGrant {
    pub fn decode(value: Value, application: bool) -> Result<Self> {
        let bad = || Error::Credential {
            kind: CredentialFailure::AuthorityLost,
        };
        let obj = value.as_object().ok_or_else(bad)?;
        let text = |key: &str| -> Result<String> {
            obj.get(key)
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .ok_or_else(bad)
        };
        if text("token_type")? != "Bearer" {
            return Err(bad());
        }
        let plane = text("plane")?;
        if (application && (plane != "platform" || text("scope")? != "application"))
            || (!application && !matches!(plane.as_str(), "member" | "executor_transport"))
        {
            return Err(bad());
        }
        if plane == "executor_transport"
            && ["executor_access_token", "runner"]
                .iter()
                .any(|k| obj.get(*k).is_some_and(|v| !v.is_null()))
        {
            return Err(bad());
        }
        let leading = SecretString::new(text("access_token")?);
        let refresh_token = SecretString::new(text("refresh_token")?);
        let expires_in = obj
            .get("expires_in")
            .and_then(Value::as_u64)
            .filter(|v| *v > 0)
            .ok_or_else(bad)?;
        let extra_executor = if obj
            .get("executor_access_token")
            .is_some_and(|v| !v.is_null())
        {
            Some(SecretString::new(text("executor_access_token")?))
        } else {
            None
        };
        let user = if application {
            Some(
                serde_json::from_value(obj.get("user").cloned().ok_or_else(bad)?)
                    .map_err(|_| bad())?,
            )
        } else {
            None
        };
        let child = |key: &str| -> Result<Option<Box<Self>>> {
            match obj.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(v) => {
                    if !application {
                        return Err(bad());
                    }
                    let v = v.clone();
                    Self::decode(v, false).map(|g| Some(Box::new(g)))
                }
            }
        };
        let agent = child("agent")?;
        let runner = child("runner")?;
        if agent.as_ref().is_some_and(|g| g.access_token.is_none())
            || runner
                .as_ref()
                .is_some_and(|g| g.executor_access_token.is_none() || g.access_token.is_some())
        {
            return Err(bad());
        }
        Ok(Self {
            access_token: (plane == "member").then(|| leading.clone()),
            executor_access_token: if plane == "executor_transport" {
                Some(leading.clone())
            } else {
                extra_executor
            },
            platform_access_token: (plane == "platform").then_some(leading),
            refresh_token,
            expires_in,
            user,
            agent_public_id: obj
                .get("agent_public_id")
                .and_then(Value::as_str)
                .map(str::to_owned),
            agent,
            runner,
        })
    }
    fn validate_branch(&self, branch: AuthorizationBranch) -> Result<()> {
        let valid = match branch {
            AuthorizationBranch::Agent => {
                self.access_token.is_some()
                    && self.executor_access_token.is_some()
                    && self.runner.is_none()
            }
            AuthorizationBranch::Runner => {
                self.access_token.is_none() && self.executor_access_token.is_some()
            }
            AuthorizationBranch::Application => self.platform_access_token.is_some(),
        };
        if valid {
            Ok(())
        } else {
            Err(Error::Credential {
                kind: CredentialFailure::AuthorityLost,
            })
        }
    }
}
#[derive(Clone, Debug)]
pub enum Poll {
    Pending,
    SlowDown,
    Throttled { retry_after: Duration },
    Authorized(TokenGrant),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cancellation {
    Canceled,
    Consumed,
}
#[derive(Clone)]
pub struct OAuthClient {
    transport: Transport,
    client_id: &'static str,
    application: bool,
    public_url: url::Url,
    request_timeout: Duration,
}
impl OAuthClient {
    pub fn device(base_url: &str) -> Result<Self> {
        Self::new(base_url, base_url, false, ClientOptions::default())
    }
    pub fn application(base_url: &str, public_url: &str) -> Result<Self> {
        Self::new(base_url, public_url, true, ClientOptions::default())
    }
    pub fn new(
        base_url: &str,
        public_url: &str,
        application: bool,
        options: ClientOptions,
    ) -> Result<Self> {
        let request_timeout = options.request_timeout;
        let transport = Transport::new(base_url, Arc::new(Anonymous), Plane::Platform, options)?;
        let public = Transport::new(
            public_url,
            Arc::new(Anonymous),
            Plane::Platform,
            ClientOptions::default(),
        )?
        .base;
        Ok(Self {
            transport,
            public_url: public,
            application,
            request_timeout,
            client_id: if application {
                "cybros-application"
            } else {
                "cybros-first-party-connector"
            },
        })
    }
    pub fn authorization_url(
        &self,
        redirect_uri: &str,
        state: &str,
        code_challenge: &str,
        claims: Option<&ConnectionClaims>,
        mode: ConnectionMode,
    ) -> Result<url::Url> {
        if !self.application {
            return Err(Error::Configuration(
                "authorization code login requires application OAuth",
            ));
        }
        let mut fields = self.claims(claims, Some(mode))?;
        fields.extend([
            ("response_type".into(), "code".into()),
            ("redirect_uri".into(), redirect_uri.into()),
            ("state".into(), state.into()),
            ("code_challenge".into(), code_challenge.into()),
            ("code_challenge_method".into(), "S256".into()),
        ]);
        let mut url = self
            .public_url
            .join("oauth/authorize")
            .map_err(|_| Error::Configuration("invalid public URL"))?;
        url.query_pairs_mut().extend_pairs(fields);
        Ok(url)
    }
    pub fn pkce_challenge(verifier: &str) -> Result<String> {
        if !(43..=128).contains(&verifier.len())
            || !verifier
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-._~".contains(&b))
        {
            return Err(Error::Configuration(
                "PKCE verifier must be 43 to 128 unreserved ASCII characters",
            ));
        }
        Ok(URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes())))
    }
    fn claims(
        &self,
        claims: Option<&ConnectionClaims>,
        mode: Option<ConnectionMode>,
    ) -> Result<Vec<(String, String)>> {
        let mut fields = vec![("client_id".into(), self.client_id.into())];
        if let Some(claims) = claims {
            let value = serde_json::to_value(claims)
                .map_err(|_| Error::Configuration("invalid connection claims"))?;
            for (k, v) in value
                .as_object()
                .ok_or(Error::Configuration("invalid claims"))?
            {
                if let Some(v) = v.as_str() {
                    fields.push((k.clone(), v.into()));
                }
            }
        }
        if self.application {
            fields.push(("scope".into(), "application".into()));
            fields.push((
                "connection_mode".into(),
                match mode.unwrap_or(ConnectionMode::Connect) {
                    ConnectionMode::Connect => "connect",
                    ConnectionMode::Login => "login",
                }
                .into(),
            ));
        }
        Ok(fields)
    }
    pub async fn request_authorization(
        &self,
        claims: Option<&ConnectionClaims>,
        mode: ConnectionMode,
    ) -> Result<Authorization> {
        let branch = if self.application {
            AuthorizationBranch::Application
        } else {
            match claims {
                Some(ConnectionClaims::Agent(_)) => AuthorizationBranch::Agent,
                Some(ConnectionClaims::Runner(_)) => AuthorizationBranch::Runner,
                None => return Err(Error::Configuration("device connection requires claims")),
            }
        };
        let started = tokio::time::Instant::now();
        let (status, headers, value) = self
            .post(
                "/oauth/device_authorization",
                self.claims(claims, Some(mode))?,
                None,
            )
            .await?;
        if status != 200 {
            return Err(oauth_error(status, &headers, &value));
        }
        let mut result: Authorization = serde_json::from_value(value)
            .map_err(|_| Error::Protocol("invalid device authorization response"))?;
        if result.expires_in == 0 || result.interval == 0 || result.device_code.expose().is_empty()
        {
            return Err(Error::Protocol("invalid authorization lifetime"));
        }
        for value in [&result.verification_uri, &result.verification_uri_complete] {
            let u =
                url::Url::parse(value).map_err(|_| Error::Protocol("invalid verification URL"))?;
            if !matches!(u.scheme(), "http" | "https") || u.host_str().is_none() {
                return Err(Error::Protocol("invalid verification URL"));
            }
        }
        result.deadline = started
            .checked_add(Duration::from_secs(result.expires_in))
            .ok_or(Error::Protocol("invalid authorization deadline"))?;
        result.branch = branch;
        if self.application {
            result.verification_uri = self.browser_uri(&result.verification_uri)?;
            result.verification_uri_complete =
                self.browser_uri(&result.verification_uri_complete)?;
        }
        Ok(result)
    }
    fn browser_uri(&self, value: &str) -> Result<String> {
        let u = url::Url::parse(value).map_err(|_| Error::Protocol("invalid verification URL"))?;
        let path = u
            .path()
            .strip_prefix(self.transport.base.path().trim_end_matches('/'))
            .unwrap_or(u.path());
        let mut target = self
            .public_url
            .join(path.trim_start_matches('/'))
            .map_err(|_| Error::Protocol("invalid verification URL"))?;
        target.set_query(u.query());
        Ok(target.to_string())
    }
    pub async fn poll(&self, authorization: &Authorization) -> Result<Poll> {
        let remaining = authorization.remaining();
        if remaining.is_zero() {
            return Err(Error::ObservationTimeout {
                elapsed: Duration::from_secs(authorization.expires_in),
            });
        }
        let (status, headers, value) = self
            .post(
                "/oauth/token",
                vec![
                    ("client_id".into(), self.client_id.into()),
                    (
                        "grant_type".into(),
                        "urn:ietf:params:oauth:grant-type:device_code".into(),
                    ),
                    (
                        "device_code".into(),
                        authorization.device_code.expose().into(),
                    ),
                ],
                Some(remaining.min(self.request_timeout)),
            )
            .await?;
        if authorization.remaining().is_zero() {
            return Err(Error::ObservationTimeout {
                elapsed: Duration::from_secs(authorization.expires_in),
            });
        }
        if status == 200 {
            let grant = TokenGrant::decode(value, self.application)?;
            grant.validate_branch(authorization.branch)?;
            return Ok(Poll::Authorized(grant));
        }
        if status == 429 {
            return Ok(Poll::Throttled {
                retry_after: Duration::from_secs(
                    headers
                        .get("retry-after")
                        .and_then(|v| v.to_str().ok())
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(5),
                ),
            });
        }
        match (status, value.get("error").and_then(Value::as_str)) {
            (400, Some("authorization_pending")) => Ok(Poll::Pending),
            (400, Some("slow_down")) => Ok(Poll::SlowDown),
            _ => Err(oauth_error(status, &headers, &value)),
        }
    }
    pub async fn await_credentials(&self, authorization: &Authorization) -> Result<TokenGrant> {
        let mut interval = Duration::from_secs(authorization.interval);
        let mut failures = 0;
        loop {
            let delay = match self.poll(authorization).await {
                Ok(Poll::Authorized(grant)) => return Ok(grant),
                Ok(Poll::SlowDown) => {
                    failures = 0;
                    interval += Duration::from_secs(5);
                    interval
                }
                Ok(Poll::Throttled { retry_after }) => {
                    failures = 0;
                    interval.max(retry_after)
                }
                Ok(Poll::Pending) => {
                    failures = 0;
                    interval
                }
                Err(e)
                    if matches!(e, Error::Transport { .. })
                        || e.status().is_some_and(|s| s >= 500) =>
                {
                    failures += 1;
                    if failures > 3 {
                        return Err(e);
                    }
                    Duration::from_secs(5)
                }
                Err(e) => return Err(e),
            };
            tokio::time::sleep(delay.min(authorization.remaining())).await;
        }
    }
    pub async fn cancel_authorization(
        &self,
        authorization: &Authorization,
    ) -> Result<Cancellation> {
        let (status, headers, value) = self
            .post(
                "/oauth/device_authorization/cancellation",
                vec![
                    ("client_id".into(), self.client_id.into()),
                    (
                        "device_code".into(),
                        authorization.device_code.expose().into(),
                    ),
                ],
                None,
            )
            .await?;
        match status {
            200 => Ok(Cancellation::Canceled),
            409 if value.get("error").and_then(Value::as_str) == Some("too_late") => {
                Ok(Cancellation::Consumed)
            }
            _ => Err(oauth_error(status, &headers, &value)),
        }
    }
    pub async fn exchange_code(
        &self,
        code: &SecretString,
        redirect_uri: &str,
        verifier: &SecretString,
    ) -> Result<TokenGrant> {
        if !self.application {
            return Err(Error::Configuration(
                "code exchange requires application OAuth",
            ));
        }
        let result = self
            .post(
                "/oauth/token",
                vec![
                    ("client_id".into(), self.client_id.into()),
                    ("grant_type".into(), "authorization_code".into()),
                    ("code".into(), code.expose().into()),
                    ("redirect_uri".into(), redirect_uri.into()),
                    ("code_verifier".into(), verifier.expose().into()),
                ],
                None,
            )
            .await;
        self.rotating_result(result)
    }
    pub async fn rotate(&self, refresh_token: &SecretString) -> Result<TokenGrant> {
        let result = self
            .post(
                "/oauth/token",
                vec![
                    ("client_id".into(), self.client_id.into()),
                    ("grant_type".into(), "refresh_token".into()),
                    ("refresh_token".into(), refresh_token.expose().into()),
                ],
                None,
            )
            .await;
        self.rotating_result(result)
    }
    fn rotating_result(
        &self,
        result: Result<(u16, reqwest::header::HeaderMap, Value)>,
    ) -> Result<TokenGrant> {
        match result {
            Ok((200, _, value)) => TokenGrant::decode(value, self.application),
            Ok((s, _, _)) if s >= 500 => Err(Error::Credential {
                kind: CredentialFailure::AuthorityLost,
            }),
            Ok((s, h, v)) => Err(oauth_error(s, &h, &v)),
            Err(
                e @ Error::Transport {
                    outcome: crate::error::SendOutcome::NotSent,
                    ..
                },
            ) => Err(e),
            Err(_) => Err(Error::Credential {
                kind: CredentialFailure::AuthorityLost,
            }),
        }
    }
    pub async fn revoke(&self, token: &SecretString) -> Result<()> {
        let (s, h, v) = self
            .post(
                "/oauth/revoke",
                vec![
                    ("client_id".into(), self.client_id.into()),
                    ("token".into(), token.expose().into()),
                ],
                None,
            )
            .await?;
        if s == 200 {
            Ok(())
        } else {
            Err(oauth_error(s, &h, &v))
        }
    }
    async fn post(
        &self,
        path: &str,
        form: Vec<(String, String)>,
        timeout: Option<Duration>,
    ) -> Result<(u16, reqwest::header::HeaderMap, Value)> {
        let response = self
            .transport
            .request(
                reqwest::Method::POST,
                path,
                None::<&()>,
                Headers::default(),
                timeout,
            )
            .await?
            .form(&form)
            .send()
            .await
            .map_err(Error::transport)?;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let bytes = response.bytes().await.map_err(Error::transport)?;
        let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        Ok((status, headers, value))
    }
}
fn oauth_error(status: u16, headers: &reqwest::header::HeaderMap, value: &Value) -> Error {
    Error::Api {
        status,
        code: if status < 500 {
            value
                .get("error")
                .and_then(Value::as_str)
                .map(str::to_owned)
        } else {
            None
        },
        message: None,
        request_id: headers
            .get("x-request-id")
            .and_then(|v| v.to_str().ok())
            .map(crate::error::redact),
        details: None,
        retry_after: headers
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned),
    }
}
