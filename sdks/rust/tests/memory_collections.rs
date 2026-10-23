mod support;
use cybros_agent::types::requests::*;
use cybros_agent::{Client, Error};
use serde_json::{Value, json};
use support::{Reply, Server};

fn fixture(key: &str) -> Value {
    let pack: Value = serde_json::from_str(include_str!(
        "../../../contracts/nexus/v1/memory_collections.json"
    ))
    .unwrap();
    pack[key].clone()
}

#[tokio::test]
async fn collection_metadata_and_documents_keep_distinct_conditions() {
    let mut replies = vec![Reply::json(200, fixture("valid_list_fixture").to_string())];
    replies.extend((0..4).map(|_| Reply::json(200, fixture("valid_fixture").to_string())));
    replies.push(Reply::json(
        201,
        fixture("valid_document_fixture").to_string(),
    ));
    replies.push(Reply::json(204, ""));
    let mut server = Server::script(replies).await;
    let api = Client::new(&server.url, "member").unwrap();
    let page = api
        .memory_collections()
        .list(&Default::default())
        .await
        .unwrap();
    let uuid = &page.body.items[0].public_id;
    let collection = api.memory_collections().collection(uuid).unwrap();
    assert_eq!(collection.fetch().await.unwrap().body.scope, "workspace");
    collection
        .update(&UpdateMemoryCollection {
            lock_version: 2,
            name: "Revised".to_owned().into(),
            ..Default::default()
        })
        .await
        .unwrap();
    collection
        .archive(&MemoryCollectionVersion { lock_version: 3 })
        .await
        .unwrap();
    collection
        .restore(&MemoryCollectionVersion { lock_version: 4 })
        .await
        .unwrap();
    let input: CollectionMemoryWrite =
        serde_json::from_value(fixture("valid_write_request")["memory"].clone()).unwrap();
    let document = collection.documents().write(&input).await.unwrap().body;
    assert_eq!(&document.collection_public_id, uuid);
    assert_eq!(document.path, "notes.md");
    collection
        .delete(&MemoryCollectionVersion { lock_version: 5 })
        .await
        .unwrap();
    let mut requests = vec![];
    for _ in 0..7 {
        requests.push(server.next().await);
    }
    assert_eq!(
        requests
            .iter()
            .map(|r| r.method.as_str())
            .collect::<Vec<_>>(),
        vec!["GET", "GET", "PATCH", "POST", "POST", "POST", "DELETE"]
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&requests[5].body).unwrap(),
        fixture("valid_write_request")
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&requests[6].body).unwrap(),
        json!({"memory_collection":{"lock_version":5}})
    );
    assert!(server.try_next().is_none());
}

#[tokio::test]
async fn absent_document_writes_pin_the_collection_without_retry() {
    let uuid = fixture("valid_fixture")["memory_collection"]["public_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let bindings = json!({"bindings":[{"name":"notes","source":{"collection_public_id":uuid},"scope":"workspace","access":"read_write","collection_public_id":uuid,"owner_public_id":"workspace","speaker_public_id":null,"state":"active"}]});
    let mut server = Server::script(vec![
        Reply::json(
            200,
            json!({"memory":[],"memory_context":bindings}).to_string(),
        ),
        Reply::json(
            409,
            r#"{"error":{"code":"stale_object","message":"Changed"}}"#,
        ),
    ])
    .await;
    let api = Client::new(&server.url, "member").unwrap();
    let memory = api
        .workspace("workspace")
        .unwrap()
        .conversation("conversation")
        .unwrap()
        .memory();
    let resolved = memory.bindings(&Default::default()).await.unwrap().body;
    assert_eq!(
        resolved.bindings[0].collection_public_id.as_ref(),
        Some(&uuid)
    );
    let input = MemoryWrite {
        expected_collection_public_id: uuid.clone(),
        path: "notes/new.md".into(),
        content: "old proposal".into(),
        expected_public_id: None,
        expected_lock_version: None,
        ..Default::default()
    };
    assert!(
        matches!(memory.write(&input).await, Err(Error::Api { status: 409, code: Some(code), .. }) if code == "stale_object")
    );
    server.next().await;
    let request = server.next().await;
    assert_eq!(
        serde_json::from_slice::<Value>(&request.body).unwrap(),
        json!({"memory":{"path":"notes/new.md","content":"old proposal","expected_collection_public_id":uuid,"expected_public_id":null,"expected_lock_version":null}})
    );
    assert!(server.try_next().is_none());
}

#[test]
fn exact_sources_and_natural_root_limits_have_distinct_shapes() {
    let selected = MemoryContext {
        bindings: vec![MemoryBinding {
            name: "notes".into(),
            source: MemorySource::Collection {
                collection_public_id: "collection".into(),
            },
            access: MemoryAccess::Read,
        }],
    };
    assert_eq!(
        serde_json::to_value(selected).unwrap(),
        json!({"bindings":[{"name":"notes","source":{"collection_public_id":"collection"},"access":"read"}]})
    );
    let limit = MemoryContextLimit {
        bindings: vec![MemoryRootLimit {
            name: MemoryScope::Conversation,
            source: MemoryRootSource {
                scope: MemoryScope::Conversation,
            },
            access: MemoryAccess::Read,
        }],
    };
    assert_eq!(
        serde_json::to_value(limit).unwrap(),
        json!({"bindings":[{"name":"conversation","source":{"scope":"conversation"},"access":"read"}]})
    );
}

#[tokio::test]
async fn default_metadata_is_nullable_and_subject_discovery_does_not_create() {
    let body = json!({"memory_collections": [fixture("valid_default_fixture")["memory_collection"].clone()], "pagination": {"next_after": null}});
    let mut server = Server::script(vec![Reply::json(200, body.to_string())]).await;
    let api = Client::new(&server.url, "member").unwrap();
    let page = api
        .profile()
        .memory_collections()
        .list(&OwnedMemoryCollectionQuery {
            default: Some(true),
            speaker_public_id: Some("speaker".to_owned()),
            ..Default::default()
        })
        .await
        .unwrap()
        .body;
    assert!(page.items[0].name.is_none());
    assert!(page.items[0].description.is_none());
    let request = server.next().await;
    assert_eq!(request.method, "GET");
    assert!(request.path.contains("default=true"));
    assert!(request.path.contains("speaker_public_id=speaker"));
    assert!(server.try_next().is_none());
}
