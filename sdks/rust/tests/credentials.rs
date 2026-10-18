use async_trait::async_trait;
use cybros_agent::{
    Error, Result,
    credentials::*,
    error::{CredentialFailure, SendOutcome, TransportCategory},
    oauth::TokenGrant,
};
use serde_json::{Value, json};
use std::sync::{
    Arc,
    atomic::{AtomicI64, AtomicUsize, Ordering},
};
use tokio::sync::{Mutex, OwnedMutexGuard, Semaphore};
#[derive(Default)]
struct Stored {
    value: Option<Value>,
    writes: usize,
    deletes: usize,
}
#[derive(Clone, Default)]
struct Store {
    data: Arc<Mutex<Stored>>,
    failure: Arc<AtomicUsize>,
}
struct Transaction {
    data: OwnedMutexGuard<Stored>,
    failure: Arc<AtomicUsize>,
}
#[async_trait]
impl CredentialStore for Store {
    fn description(&self) -> &str {
        "application test store"
    }
    async fn read(&self) -> Result<Option<Value>> {
        Ok(self.data.lock().await.value.clone())
    }
    async fn acquire(&self) -> Result<Box<dyn CredentialTransaction>> {
        Ok(Box::new(Transaction {
            data: self.data.clone().lock_owned().await,
            failure: self.failure.clone(),
        }))
    }
}
#[async_trait]
impl CredentialTransaction for Transaction {
    async fn read(&mut self) -> Result<Option<Value>> {
        Ok(self.data.value.clone())
    }
    async fn write_atomic(&mut self, document: &CredentialDocument) -> Result<Publication> {
        let failure = self.failure.swap(0, Ordering::SeqCst);
        if failure == 1 {
            return Err(Error::Credential {
                kind: CredentialFailure::Store,
            });
        }
        self.data.value = Some(serde_json::to_value(document).unwrap());
        self.data.writes += 1;
        Ok(if failure == 2 {
            Publication::Published
        } else {
            Publication::Durable
        })
    }
    async fn delete(&mut self) -> Result<()> {
        self.data.value = None;
        self.data.deletes += 1;
        Ok(())
    }
}
struct TestClock(AtomicI64);
impl Clock for TestClock {
    fn unix_seconds(&self) -> i64 {
        self.0.load(Ordering::SeqCst)
    }
}
struct Authority {
    rotations: AtomicUsize,
    revocations: AtomicUsize,
    mode: AtomicUsize,
    gate: Semaphore,
    hold: bool,
}
impl Authority {
    fn new(hold: bool) -> Arc<Self> {
        Arc::new(Self {
            rotations: AtomicUsize::new(0),
            revocations: AtomicUsize::new(0),
            mode: AtomicUsize::new(0),
            gate: Semaphore::new(0),
            hold,
        })
    }
}
#[async_trait]
impl CredentialAuthority for Authority {
    async fn rotate(&self, _: &SecretString) -> Result<TokenGrant> {
        let n = self.rotations.fetch_add(1, Ordering::SeqCst) + 1;
        if self.hold {
            self.gate.acquire().await.unwrap().forget();
        }
        match self.mode.load(Ordering::SeqCst) {
            1 => Err(Error::Transport {
                outcome: SendOutcome::Unknown,
                timeout: true,
                category: TransportCategory::Timeout,
            }),
            2 => Err(Error::Transport {
                outcome: SendOutcome::NotSent,
                timeout: false,
                category: TransportCategory::Connect,
            }),
            _ => Ok(grant(n)),
        }
    }
    async fn revoke(&self, _: &SecretString) -> Result<()> {
        let n = self.revocations.fetch_add(1, Ordering::SeqCst) + 1;
        if self.mode.load(Ordering::SeqCst) == 3 && n == 2 {
            return Err(Error::Protocol("revocation refused"));
        }
        Ok(())
    }
}
fn grant(n: usize) -> TokenGrant {
    TokenGrant::decode(json!({"plane":"member","token_type":"Bearer","access_token":format!("sk-member-{n}"),"executor_access_token":format!("sk-executor-{n}"),"refresh_token":format!("rt-refresh-{n}"),"expires_in":3600}),false).unwrap()
}
async fn setup(
    hold: bool,
) -> (
    CredentialManager,
    Arc<Store>,
    Arc<Authority>,
    Arc<TestClock>,
) {
    let store = Arc::new(Store::default());
    let authority = Authority::new(hold);
    let clock = Arc::new(TestClock(AtomicI64::new(1_700_000_000)));
    let document =
        CredentialDocument::oauth(&grant(0), "connection-1", 0, clock.unix_seconds()).unwrap();
    store.data.lock().await.value = Some(serde_json::to_value(document).unwrap());
    let manager =
        CredentialManager::load_with_clock(store.clone(), authority.clone(), clock.clone())
            .await
            .unwrap();
    (manager, store, authority, clock)
}
async fn wait_count(counter: &AtomicUsize, n: usize) {
    tokio::time::timeout(std::time::Duration::from_secs(2), async {
        while counter.load(Ordering::SeqCst) < n {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}
#[tokio::test]
async fn concurrent_refreshes_coalesce_and_canceled_waiter_cannot_lose_rotation() {
    let (manager, store, authority, _) = setup(true).await;
    let started = Arc::new(AtomicUsize::new(0));
    let mut tasks = vec![];
    for _ in 0..8 {
        let m = manager.clone();
        let s = started.clone();
        tasks.push(tokio::spawn(async move {
            s.fetch_add(1, Ordering::SeqCst);
            m.refresh(None).await
        }));
    }
    wait_count(&started, 8).await;
    wait_count(&authority.rotations, 1).await;
    tasks.remove(0).abort();
    authority.gate.add_permits(1);
    for task in tasks {
        task.await.unwrap().unwrap();
    }
    manager.drain().await;
    assert_eq!(authority.rotations.load(Ordering::SeqCst), 1);
    assert_eq!(manager.rotation().await, Some(1));
    assert_eq!(store.data.lock().await.writes, 1);
    assert_eq!(
        manager
            .token(Plane::Member)
            .await
            .unwrap()
            .unwrap()
            .expose(),
        "sk-member-1"
    );
}
#[tokio::test]
async fn persistence_failure_retains_new_pair_and_refuses_another_rotation() {
    let (manager, store, authority, clock) = setup(false).await;
    store.failure.store(1, Ordering::SeqCst);
    assert!(matches!(
        manager.refresh(None).await,
        Err(Error::Credential {
            kind: CredentialFailure::NotDurable
        })
    ));
    assert_eq!(
        manager
            .token(Plane::Member)
            .await
            .unwrap()
            .unwrap()
            .expose(),
        "sk-member-1"
    );
    assert!(matches!(
        manager.refresh(None).await,
        Err(Error::Credential {
            kind: CredentialFailure::NotDurable
        })
    ));
    clock.0.fetch_add(3601, Ordering::SeqCst);
    assert!(matches!(
        manager.token(Plane::Member).await,
        Err(Error::Credential {
            kind: CredentialFailure::NotDurable
        })
    ));
    assert_eq!(authority.rotations.load(Ordering::SeqCst), 1);
    manager.persist().await.unwrap();
    assert_eq!(manager.durability().await, Durability::Durable);
    let stored = CredentialDocument::decode(store.read().await.unwrap().unwrap()).unwrap();
    assert_eq!(stored.refresh_token.unwrap().expose(), "rt-refresh-1");
}
#[tokio::test]
async fn published_document_is_distinct_from_failed_publication() {
    let (manager, store, _, _) = setup(false).await;
    store.failure.store(2, Ordering::SeqCst);
    manager.refresh(None).await.unwrap();
    assert_eq!(manager.durability().await, Durability::Published);
    assert_eq!(manager.rotation().await, Some(1));
}
#[tokio::test]
async fn unknown_rotation_latches_loss_but_known_unsent_preserves_authority() {
    let (manager, _, authority, _) = setup(false).await;
    authority.mode.store(1, Ordering::SeqCst);
    assert!(manager.refresh(None).await.is_err());
    assert!(matches!(
        manager.token(Plane::Member).await,
        Err(Error::Credential {
            kind: CredentialFailure::AuthorityLost
        })
    ));
    assert!(manager.refresh(None).await.is_err());
    assert_eq!(authority.rotations.load(Ordering::SeqCst), 1);
    let (manager, _, authority, _) = setup(false).await;
    authority.mode.store(2, Ordering::SeqCst);
    assert!(matches!(
        manager.refresh(None).await,
        Err(Error::Transport {
            outcome: SendOutcome::NotSent,
            ..
        })
    ));
    assert!(manager.token(Plane::Member).await.is_ok());
    authority.mode.store(0, Ordering::SeqCst);
    manager.refresh(None).await.unwrap();
}
#[tokio::test]
async fn reconnect_uses_store_authority_and_supersedes_old_owner_after_inflight_rotation() {
    let (old, store, authority, clock) = setup(true).await;
    let old_refresh = {
        let old = old.clone();
        tokio::spawn(async move { old.refresh(None).await })
    };
    wait_count(&authority.rotations, 1).await;
    let document =
        CredentialDocument::oauth(&grant(90), "connection-2", 0, clock.unix_seconds()).unwrap();
    let store_clone = store.clone();
    let authority_clone = authority.clone();
    let new_issue = tokio::spawn(async move {
        CredentialManager::issue(document, store_clone, authority_clone).await
    });
    authority.gate.add_permits(1);
    old_refresh.await.unwrap().unwrap();
    let new = new_issue.await.unwrap().unwrap();
    assert_eq!(new.snapshot().await.connection, "connection-2");
    assert!(matches!(
        old.refresh(None).await,
        Err(Error::Credential {
            kind: CredentialFailure::Superseded
        })
    ));
    assert_eq!(
        CredentialDocument::decode(store.read().await.unwrap().unwrap())
            .unwrap()
            .connection,
        "connection-2"
    );
}
#[tokio::test]
async fn api_keys_never_refresh_and_partial_revoke_keeps_document() {
    let store = Arc::new(Store::default());
    let authority = Authority::new(false);
    let document=CredentialDocument::decode(json!({"version":2,"authentication_kind":"api_key","connection":"keys","access_token":"sk-member","executor_access_token":"sk-executor"})).unwrap();
    let manager = CredentialManager::issue(document, store.clone(), authority.clone())
        .await
        .unwrap();
    assert!(manager.refresh(None).await.is_err());
    assert!(manager.token(Plane::Platform).await.is_err());
    authority.mode.store(3, Ordering::SeqCst);
    assert!(manager.revoke().await.is_err());
    assert!(store.read().await.unwrap().is_some());
    manager.revoke().await.unwrap();
    assert!(store.read().await.unwrap().is_none());
    assert_eq!(authority.rotations.load(Ordering::SeqCst), 0);
}
#[test]
fn documents_reject_unknown_kinds_and_secret_debug_is_redacted() {
    for value in [
        json!({"version":1,"authentication_kind":"api_key","connection":"x","access_token":"sk-secret"}),
        json!({"version":2,"authentication_kind":"unknown","connection":"x","access_token":"sk-secret"}),
        json!({"version":2,"authentication_kind":"api_key","connection":"x"}),
    ] {
        assert!(CredentialDocument::decode(value).is_err());
    }
    assert!(!format!("{:?}", grant(1)).contains("sk-member"));
}

#[tokio::test]
async fn failed_initial_publication_returns_a_recoverable_holder() {
    let store = Arc::new(Store::default());
    store.failure.store(1, Ordering::SeqCst);
    let authority = Authority::new(false);
    let failure = CredentialManager::issue(
        CredentialDocument::oauth(
            &grant(1),
            "new-connection",
            0,
            chrono::Utc::now().timestamp(),
        )
        .unwrap(),
        store.clone(),
        authority.clone(),
    )
    .await
    .expect_err("publication must fail");
    assert!(matches!(
        failure.error,
        Error::Credential {
            kind: CredentialFailure::NotDurable
        }
    ));
    let holder = failure.holder.expect("issued pair retained");
    assert_eq!(
        holder.token(Plane::Member).await.unwrap().unwrap().expose(),
        "sk-member-1"
    );
    holder.persist().await.unwrap();
    assert_eq!(holder.durability().await, Durability::Durable);
    assert_eq!(authority.rotations.load(Ordering::SeqCst), 0);
    assert!(store.read().await.unwrap().is_some());
}

#[tokio::test]
async fn failed_reissue_can_publish_over_its_unchanged_predecessor_but_not_a_new_connection() {
    let (_, store, authority, _) = setup(false).await;
    let document = |connection: &str| {
        CredentialDocument::oauth(&grant(1), connection, 0, chrono::Utc::now().timestamp()).unwrap()
    };
    store.failure.store(1, Ordering::SeqCst);
    let holder =
        CredentialManager::issue(document("connection-2"), store.clone(), authority.clone())
            .await
            .unwrap_err()
            .holder
            .unwrap();
    holder.persist().await.unwrap();
    assert_eq!(
        CredentialDocument::decode(store.read().await.unwrap().unwrap())
            .unwrap()
            .connection,
        "connection-2"
    );
    store.failure.store(1, Ordering::SeqCst);
    let stale =
        CredentialManager::issue(document("connection-3"), store.clone(), authority.clone())
            .await
            .unwrap_err()
            .holder
            .unwrap();
    CredentialManager::issue(document("connection-4"), store.clone(), authority.clone())
        .await
        .unwrap();
    assert!(matches!(
        stale.persist().await,
        Err(Error::Credential {
            kind: CredentialFailure::Superseded
        })
    ));
    assert_eq!(
        CredentialDocument::decode(store.read().await.unwrap().unwrap())
            .unwrap()
            .connection,
        "connection-4"
    );
}

#[tokio::test]
async fn deleted_predecessor_fences_a_failed_reissue() {
    let (_, store, authority, _) = setup(false).await;
    store.failure.store(1, Ordering::SeqCst);
    let document =
        CredentialDocument::oauth(&grant(1), "replacement", 0, chrono::Utc::now().timestamp())
            .unwrap();
    let holder = CredentialManager::issue(document, store.clone(), authority)
        .await
        .unwrap_err()
        .holder
        .unwrap();
    store.data.lock().await.value = None;
    assert!(matches!(
        holder.persist().await,
        Err(Error::Credential {
            kind: CredentialFailure::Superseded
        })
    ));
    assert!(store.read().await.unwrap().is_none());
}

#[tokio::test]
async fn durable_holder_cannot_resurrect_a_deleted_connection() {
    let (holder, store, _, _) = setup(false).await;
    store.data.lock().await.value = None;
    assert!(matches!(
        holder.persist().await,
        Err(Error::Credential {
            kind: CredentialFailure::Superseded
        })
    ));
    assert!(store.read().await.unwrap().is_none());
}
