mod support;

use cybros_agent::Client;
use cybros_agent::types::requests::{
    ConversationArchiveFilter, ConversationFieldQuery, ConversationSearchQuery,
};
use serde_json::Value;
use support::{Reply, Server};

fn fixture(key: &str) -> Value {
    serde_json::from_str::<Value>(include_str!("../../../contracts/nexus/v1/history.json")).unwrap()
        [key]
        .clone()
}

#[tokio::test]
async fn search_keeps_archive_answerer_and_excerpt_location() {
    let body = fixture("search_fixture");
    let mut server = Server::script(vec![Reply::json(200, body.to_string())]).await;
    let page = Client::new(&server.url, "member")
        .unwrap()
        .workspace("workspace")
        .unwrap()
        .search_conversations(&ConversationSearchQuery {
            query: Some("needle".into()),
            archived: Some(ConversationArchiveFilter::Only),
            answering_user_public_id: Some("answerer".into()),
            after: Some("previous".into()),
            ..Default::default()
        })
        .await
        .unwrap()
        .body;
    assert_eq!(
        page.matches[0].location.as_deref(),
        body["matches"][0]["location"].as_str()
    );
    let request = server.next().await;
    assert!(request.path.contains("archived=only"));
    assert!(request.path.contains("answering_user_public_id=answerer"));
    assert!(request.path.contains("after=previous"));
}

#[tokio::test]
async fn exact_field_has_explicit_location_and_continuation() {
    let body = fixture("field_fixture");
    let mut server = Server::script(vec![
        Reply::json(200, body.to_string()),
        Reply::json(200, body.to_string()),
    ])
    .await;
    let variant = Client::new(&server.url, "member")
        .unwrap()
        .workspace("workspace")
        .unwrap()
        .conversation("conversation")
        .unwrap()
        .turns()
        .turn("turn")
        .unwrap()
        .variant("variant/id")
        .unwrap();
    let page = variant
        .field(
            "steers",
            &ConversationFieldQuery {
                location: Some("opaque-location".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .body;
    assert_eq!(page.text, body["text"].as_str().unwrap());
    assert_eq!(
        page.variant_public_id,
        body["variant_public_id"].as_str().unwrap()
    );
    assert_eq!(
        page.pagination.next_after.as_deref(),
        body["pagination"]["next_after"].as_str()
    );
    assert_eq!(
        server.next().await.path,
        "/agent_api/v1/workspaces/workspace/conversations/conversation/turns/turn/variants/variant%2Fid/fields/steers?location=opaque-location"
    );
    variant
        .field(
            "steers",
            &ConversationFieldQuery {
                after: page.pagination.next_after.clone(),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert!(
        server
            .next()
            .await
            .path
            .ends_with(&format!("?after={}", page.pagination.next_after.unwrap()))
    );
    assert!(server.try_next().is_none());
}
