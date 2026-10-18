//! Application-owned credential storage. Tokens are never included in Debug output.
use crate::{Error, Result, error::CredentialFailure};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::{fmt, sync::Arc};

#[derive(Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(transparent)]
pub struct SecretString(String);
impl SecretString {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }
    pub fn expose(&self) -> &str {
        &self.0
    }
}
impl fmt::Debug for SecretString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("[REDACTED]")
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Plane {
    Member,
    Executor,
    Platform,
}

#[async_trait]
pub trait CredentialProvider: Send + Sync {
    async fn token(&self, plane: Plane) -> Result<Option<SecretString>>;
}
#[derive(Clone, Debug)]
pub struct StaticCredential {
    plane: Plane,
    token: SecretString,
}
impl StaticCredential {
    pub fn new(plane: Plane, token: impl Into<String>) -> Arc<Self> {
        Arc::new(Self {
            plane,
            token: SecretString::new(token),
        })
    }
}
#[async_trait]
impl CredentialProvider for StaticCredential {
    async fn token(&self, plane: Plane) -> Result<Option<SecretString>> {
        if plane != self.plane {
            return Err(Error::Credential {
                kind: CredentialFailure::MissingPlane,
            });
        }
        Ok(Some(self.token.clone()))
    }
}
pub(crate) struct Anonymous;
#[async_trait]
impl CredentialProvider for Anonymous {
    async fn token(&self, _: Plane) -> Result<Option<SecretString>> {
        Ok(None)
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthenticationKind {
    OAuth,
    ApiKey,
}
/// Compatible with the version-2 application credential document.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CredentialDocument {
    pub version: u32,
    pub authentication_kind: AuthenticationKind,
    pub connection: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rotation: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<SecretString>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub access_token: Option<SecretString>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub executor_access_token: Option<SecretString>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform_access_token: Option<SecretString>,
}
impl CredentialDocument {
    pub fn decode(value: serde_json::Value) -> Result<Self> {
        let document: Self =
            serde_json::from_value(value).map_err(|_| failure(CredentialFailure::Store))?;
        document.validate()?;
        Ok(document)
    }
    pub fn validate(&self) -> Result<()> {
        if self.version != 2
            || self.connection.is_empty()
            || [
                &self.access_token,
                &self.executor_access_token,
                &self.platform_access_token,
            ]
            .iter()
            .all(|t| t.is_none())
            || [
                &self.access_token,
                &self.executor_access_token,
                &self.platform_access_token,
                &self.refresh_token,
            ]
            .iter()
            .any(|t| t.as_ref().is_some_and(|t| t.expose().is_empty()))
        {
            return Err(failure(CredentialFailure::Store));
        }
        if self.authentication_kind == AuthenticationKind::OAuth
            && (self.rotation.is_none() || self.refresh_token.is_none() || self.expiry().is_err())
        {
            return Err(failure(CredentialFailure::Store));
        }
        Ok(())
    }
    pub fn oauth(
        grant: &crate::oauth::TokenGrant,
        connection: impl Into<String>,
        rotation: u64,
        now: i64,
    ) -> Result<Self> {
        let seconds =
            i64::try_from(grant.expires_in).map_err(|_| failure(CredentialFailure::Store))?;
        let expiry = chrono::DateTime::from_timestamp(
            now.checked_add(seconds)
                .ok_or_else(|| failure(CredentialFailure::Store))?,
            0,
        )
        .ok_or_else(|| failure(CredentialFailure::Store))?;
        Ok(Self {
            version: 2,
            authentication_kind: AuthenticationKind::OAuth,
            connection: connection.into(),
            rotation: Some(rotation),
            refresh_token: Some(grant.refresh_token.clone()),
            expires_at: Some(expiry.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
            access_token: grant.access_token.clone(),
            executor_access_token: grant.executor_access_token.clone(),
            platform_access_token: grant.platform_access_token.clone(),
        })
    }
    fn expiry(&self) -> Result<i64> {
        chrono::DateTime::parse_from_rfc3339(
            self.expires_at
                .as_deref()
                .ok_or_else(|| failure(CredentialFailure::Store))?,
        )
        .map(|d| d.timestamp())
        .map_err(|_| failure(CredentialFailure::Store))
    }
    fn token(&self, plane: Plane) -> Result<SecretString> {
        match plane {
            Plane::Member => &self.access_token,
            Plane::Executor => &self.executor_access_token,
            Plane::Platform => &self.platform_access_token,
        }
        .clone()
        .ok_or_else(|| failure(CredentialFailure::MissingPlane))
    }
}
/// Publication is an explicit outcome: Published means the new document is visible
/// even if the application could not confirm power-loss durability.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Publication {
    Durable,
    Published,
}
#[async_trait]
pub trait CredentialStore: Send + Sync {
    fn description(&self) -> &str;
    async fn read(&self) -> Result<Option<serde_json::Value>>;
    /// Acquire the application's one mutation authority for this store. The guard
    /// must cover read, remote rotation/revocation, and publication until dropped.
    async fn acquire(&self) -> Result<Box<dyn CredentialTransaction>>;
}
#[async_trait]
pub trait CredentialTransaction: Send {
    async fn read(&mut self) -> Result<Option<serde_json::Value>>;
    async fn write_atomic(&mut self, document: &CredentialDocument) -> Result<Publication>;
    async fn delete(&mut self) -> Result<()>;
}
#[async_trait]
pub trait CredentialAuthority: Send + Sync {
    async fn rotate(&self, refresh_token: &SecretString) -> Result<crate::oauth::TokenGrant>;
    async fn revoke(&self, token: &SecretString) -> Result<()>;
}
#[async_trait]
impl CredentialAuthority for crate::oauth::OAuthClient {
    async fn rotate(&self, t: &SecretString) -> Result<crate::oauth::TokenGrant> {
        self.rotate(t).await
    }
    async fn revoke(&self, t: &SecretString) -> Result<()> {
        self.revoke(t).await
    }
}
pub trait Clock: Send + Sync {
    fn unix_seconds(&self) -> i64;
}
struct SystemClock;
impl Clock for SystemClock {
    fn unix_seconds(&self) -> i64 {
        chrono::Utc::now().timestamp()
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Durability {
    Durable,
    Published,
    NotDurable,
}
struct State {
    document: CredentialDocument,
    lost: bool,
    durability: Durability,
    revoked: bool,
    publication_base: Option<Option<(String, Option<u64>)>>,
}
struct Owner {
    state: tokio::sync::Mutex<State>,
    store: Arc<dyn CredentialStore>,
    authority: Arc<dyn CredentialAuthority>,
    clock: Arc<dyn Clock>,
    pending: std::sync::atomic::AtomicUsize,
    drained: tokio::sync::Notify,
    rotation: std::sync::atomic::AtomicU64,
    refreshable: bool,
}
/// Mutations share the application store transaction authority. Use one manager
/// per active connection; reissue explicitly supersedes it. Owned mutation tasks
/// survive cancellation of their waiting caller.
#[derive(Clone)]
pub struct CredentialManager {
    owner: Arc<Owner>,
}
impl fmt::Debug for CredentialManager {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CredentialManager").finish_non_exhaustive()
    }
}
/// A failed first publication retains the live holder so the application can retry
/// persistence without repeating its authorization ceremony.
#[derive(Debug)]
pub struct IssueFailure {
    pub holder: Option<CredentialManager>,
    pub error: Error,
}
impl fmt::Display for IssueFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.error.fmt(f)
    }
}
impl std::error::Error for IssueFailure {}
impl CredentialManager {
    pub async fn load(
        store: Arc<dyn CredentialStore>,
        authority: Arc<dyn CredentialAuthority>,
    ) -> Result<Self> {
        Self::load_with_clock(store, authority, Arc::new(SystemClock)).await
    }
    pub async fn load_with_clock(
        store: Arc<dyn CredentialStore>,
        authority: Arc<dyn CredentialAuthority>,
        clock: Arc<dyn Clock>,
    ) -> Result<Self> {
        let value = store
            .read()
            .await?
            .ok_or_else(|| failure(CredentialFailure::Store))?;
        let document = CredentialDocument::decode(value)?;
        Ok(Self::from_document(
            document,
            store,
            authority,
            clock,
            Durability::Durable,
        ))
    }
    fn from_document(
        document: CredentialDocument,
        store: Arc<dyn CredentialStore>,
        authority: Arc<dyn CredentialAuthority>,
        clock: Arc<dyn Clock>,
        durability: Durability,
    ) -> Self {
        Self {
            owner: Arc::new(Owner {
                rotation: std::sync::atomic::AtomicU64::new(document.rotation.unwrap_or(0)),
                refreshable: document.authentication_kind == AuthenticationKind::OAuth,
                state: tokio::sync::Mutex::new(State {
                    document,
                    lost: false,
                    durability,
                    revoked: false,
                    publication_base: None,
                }),
                store,
                authority,
                clock,
                pending: std::sync::atomic::AtomicUsize::new(0),
                drained: tokio::sync::Notify::new(),
            }),
        }
    }
    /// The application provides the connection UUID; the SDK never invents identity.
    pub async fn issue(
        document: CredentialDocument,
        store: Arc<dyn CredentialStore>,
        authority: Arc<dyn CredentialAuthority>,
    ) -> std::result::Result<Self, IssueFailure> {
        document.validate().map_err(|error| IssueFailure {
            holder: None,
            error,
        })?;
        let manager = Self::from_document(
            document,
            store,
            authority,
            Arc::new(SystemClock),
            Durability::NotDurable,
        );
        if let Err(error) = manager.mutate(Mutation::Issue).await {
            return Err(IssueFailure {
                holder: Some(manager),
                error,
            });
        }
        Ok(manager)
    }
    pub async fn rotation(&self) -> Option<u64> {
        self.owner.state.lock().await.document.rotation
    }
    pub async fn durability(&self) -> Durability {
        self.owner.state.lock().await.durability
    }
    pub async fn snapshot(&self) -> CredentialDocument {
        self.owner.state.lock().await.document.clone()
    }
    pub async fn refresh(&self, after: Option<u64>) -> Result<()> {
        // Capture this generation before enqueueing. Concurrent forced refreshes coalesce.
        if !self.owner.refreshable {
            return Err(Error::Configuration("API keys do not refresh"));
        }
        let generation = Some(after.unwrap_or_else(|| {
            self.owner
                .rotation
                .load(std::sync::atomic::Ordering::Acquire)
        }));
        self.mutate(Mutation::Refresh(generation)).await
    }
    pub async fn revoke(&self) -> Result<()> {
        self.mutate(Mutation::Revoke).await
    }
    pub async fn persist(&self) -> Result<()> {
        self.mutate(Mutation::Persist).await
    }
    async fn mutate(&self, mutation: Mutation) -> Result<()> {
        let owner = self.owner.clone();
        owner
            .pending
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let task = tokio::spawn(async move {
            let _completion = Completion(owner.clone());
            owner.mutate(mutation).await
        });
        task.await
            .map_err(|_| Error::Protocol("credential owner task failed"))?
    }
    /// Drain only already-started mutations before shutting down the Tokio runtime.
    pub async fn drain(&self) {
        loop {
            let notified = self.owner.drained.notified();
            if self.owner.pending.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                return;
            }
            notified.await;
        }
    }
}
enum Mutation {
    Refresh(Option<u64>),
    Revoke,
    Persist,
    Issue,
}
struct Completion(Arc<Owner>);
impl Drop for Completion {
    fn drop(&mut self) {
        self.0
            .pending
            .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        self.0.drained.notify_waiters();
    }
}
impl Owner {
    async fn mutate(&self, mutation: Mutation) -> Result<()> {
        let mut transaction = self.store.acquire().await?;
        let mut state = self.state.lock().await;
        if state.revoked {
            return Err(failure(CredentialFailure::AuthorityLost));
        }
        let stored = transaction
            .read()
            .await?
            .map(CredentialDocument::decode)
            .transpose()?;
        let identity = stored.as_ref().map(|d| (d.connection.clone(), d.rotation));
        if matches!(mutation, Mutation::Issue) {
            state.publication_base = Some(identity.clone());
        } else if stored
            .as_ref()
            .is_some_and(|d| d.connection != state.document.connection)
            || stored.is_none()
        {
            let pending_publication = matches!(mutation, Mutation::Persist)
                && state.publication_base.as_ref() == Some(&identity);
            if !pending_publication {
                return Err(failure(CredentialFailure::Superseded));
            }
        }
        match mutation {
            Mutation::Refresh(after) => {
                if state.lost {
                    return Err(failure(CredentialFailure::AuthorityLost));
                }
                if state.durability == Durability::NotDurable {
                    return Err(failure(CredentialFailure::NotDurable));
                }
                if after != state.document.rotation {
                    return Ok(());
                }
                let grant = match self
                    .authority
                    .rotate(
                        state
                            .document
                            .refresh_token
                            .as_ref()
                            .ok_or_else(|| failure(CredentialFailure::Store))?,
                    )
                    .await
                {
                    Ok(grant) => grant,
                    Err(
                        e @ Error::Transport {
                            outcome: crate::error::SendOutcome::NotSent,
                            ..
                        },
                    ) => return Err(e),
                    Err(e @ Error::Api { status: 429, .. }) => return Err(e),
                    Err(_) => {
                        state.lost = true;
                        return Err(failure(CredentialFailure::AuthorityLost));
                    }
                };
                // Install the live pair before persistence. Failure must never revive its parent.
                let next = match state
                    .document
                    .rotation
                    .unwrap_or(0)
                    .checked_add(1)
                    .and_then(|rotation| {
                        CredentialDocument::oauth(
                            &grant,
                            state.document.connection.clone(),
                            rotation,
                            self.clock.unix_seconds(),
                        )
                        .ok()
                    }) {
                    Some(next) => next,
                    None => {
                        state.lost = true;
                        return Err(failure(CredentialFailure::AuthorityLost));
                    }
                };
                state.document = next;
                self.rotation.store(
                    state.document.rotation.unwrap_or(0),
                    std::sync::atomic::Ordering::Release,
                );
                self.persist(&mut state, transaction.as_mut()).await
            }
            Mutation::Persist | Mutation::Issue => {
                self.persist(&mut state, transaction.as_mut()).await
            }
            Mutation::Revoke => {
                if state.document.authentication_kind == AuthenticationKind::OAuth {
                    if !state.lost {
                        self.authority
                            .revoke(
                                state
                                    .document
                                    .refresh_token
                                    .as_ref()
                                    .ok_or_else(|| failure(CredentialFailure::Store))?,
                            )
                            .await?;
                    }
                } else {
                    for token in [
                        &state.document.access_token,
                        &state.document.executor_access_token,
                        &state.document.platform_access_token,
                    ]
                    .into_iter()
                    .flatten()
                    {
                        self.authority.revoke(token).await?;
                    }
                }
                transaction.delete().await?;
                state.revoked = true;
                Ok(())
            }
        }
    }
    async fn persist(
        &self,
        state: &mut State,
        transaction: &mut dyn CredentialTransaction,
    ) -> Result<()> {
        match transaction.write_atomic(&state.document).await {
            Ok(Publication::Durable) => {
                state.durability = Durability::Durable;
                state.publication_base = None;
                Ok(())
            }
            Ok(Publication::Published) => {
                state.durability = Durability::Published;
                state.publication_base = None;
                Ok(())
            }
            Err(_) => {
                state.durability = Durability::NotDurable;
                Err(failure(CredentialFailure::NotDurable))
            }
        }
    }
}
#[async_trait]
impl CredentialProvider for CredentialManager {
    async fn token(&self, plane: Plane) -> Result<Option<SecretString>> {
        let refresh = {
            let state = self.owner.state.lock().await;
            if state.lost || state.revoked {
                return Err(failure(CredentialFailure::AuthorityLost));
            }
            if state.durability == Durability::NotDurable
                && self.owner.clock.unix_seconds() >= state.document.expiry()?
            {
                return Err(failure(CredentialFailure::NotDurable));
            }
            state.document.authentication_kind == AuthenticationKind::OAuth
                && state.durability != Durability::NotDurable
                && self.owner.clock.unix_seconds() >= state.document.expiry()?.saturating_sub(60)
        };
        if refresh {
            self.refresh(None).await?;
        }
        let state = self.owner.state.lock().await;
        state.document.token(plane).map(Some)
    }
}
fn failure(kind: CredentialFailure) -> Error {
    Error::Credential { kind }
}
