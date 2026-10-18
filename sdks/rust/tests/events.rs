use async_trait::async_trait;
use cybros_agent::{
    Error, Result,
    events::*,
    execution::{Execution, MaterializationState, select_candidate},
    types::member::{Event, EventPage, Variant},
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};
struct Pages(Mutex<VecDeque<EventPage>>);
#[async_trait]
impl ReplaySource for Pages {
    async fn replay(&self, _: &Position) -> Result<EventPage> {
        Ok(self
            .0
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected replay"))
    }
}
fn event(n: i64) -> Event {
    serde_json::from_value(json!({"public_id":format!("e{n}"),"sequence":n,"cursor":format!("c{n}"),"type":"future_type","resource":{"type":"conversation","public_id":"conversation"},"occurred_at":"2026-10-15T00:00:00Z","payload":{}})).unwrap()
}
fn page(items: Vec<Event>, watermark: i64) -> EventPage {
    serde_json::from_value(
        json!({"events":items,"pagination":{"next_after":null,"watermark":watermark}}),
    )
    .unwrap()
}
fn feed(pages: Vec<EventPage>) -> KernelFeed {
    KernelFeed::new(
        Arc::new(Pages(Mutex::new(pages.into()))),
        Position::default(),
    )
    .unwrap()
}
#[tokio::test]
async fn replay_freezes_watermark_orders_and_deduplicates_without_ack_on_yield() {
    let mut feed = feed(vec![
        page(vec![event(2), event(1), event(2), event(3)], 2),
        page(vec![event(2), event(3)], 3),
    ]);
    let first = feed.next_replayed().await.unwrap().unwrap();
    assert_eq!(first.sequence, 1);
    assert_eq!(feed.position().sequence, 0);
    assert_eq!(feed.next_replayed().await.unwrap().unwrap().sequence, 1);
    assert!(feed.ack(&event(2)).is_err());
    feed.ack(&first).unwrap();
    let mut seen = vec![];
    let report = feed
        .consume(|event, _| {
            seen.push(event.sequence);
            async { Ok(()) }
        })
        .await
        .unwrap();
    assert_eq!(seen, vec![2]);
    assert_eq!(report.watermark, 2);
    assert!(!report.retention_gap);
    let report = feed
        .consume(|event, _| {
            seen.push(event.sequence);
            async { Ok(()) }
        })
        .await
        .unwrap();
    assert!(!report.retention_gap);
    assert_eq!(seen, vec![2, 3]);
}
#[tokio::test]
async fn consumer_failure_keeps_the_same_event_pending_and_retention_never_fabricates_cursor() {
    let mut feed = feed(vec![page(vec![event(3)], 5), page(vec![], 5)]);
    assert!(
        feed.consume(|_, _| async { Err(Error::Protocol("consumer failed")) })
            .await
            .is_err()
    );
    assert_eq!(feed.position(), &Position::default());
    let report = feed.consume(|_, _| async { Ok(()) }).await.unwrap();
    assert!(report.retention_gap);
    assert_eq!(report.watermark, 5);
    assert_eq!(
        report.position,
        Position {
            cursor: Some("c3".into()),
            sequence: 3
        }
    );
}
#[test]
fn transcript_snapshots_are_utf8_bounded_and_replace_failed_attempt_text() {
    let mut text = TranscriptAccumulator::new(7);
    text.accumulate("old!", Some("first"));
    text.accumulate("你好世界", Some("second"));
    assert_eq!(text.text(), "世界");
    assert_eq!(text.length(), 12);
    assert_eq!(text.replace_snapshot("你好世界!", Some(13)), "!");
    assert!(!text.replaced());
    assert_eq!(text.replace_on_settle("different"), "different");
    assert!(text.replaced());
    assert_eq!(text.text(), "fferent");
}
fn variant(id: &str, origin: Option<&str>, source: &str, run: &str) -> Variant {
    serde_json::from_value(json!({"public_id":id,"source":source,"status":"completed","active":true,"run_public_id":run,"origin_variant_public_id":origin,"created_at":"now","index":0,"model":null,"runner_effects":null,"checkpoint":null})).unwrap()
}
#[test]
fn automatic_fallback_is_followed_but_active_manual_regeneration_is_not() {
    let original = Execution {
        turn_public_id: "turn".into(),
        variant_public_id: Some("original".into()),
        run_public_id: Some("r1".into()),
    };
    let deck = vec![
        variant("manual", Some("fallback"), "regeneration", "manual-run"),
        variant("fallback", Some("original"), "fallback", "r2"),
        variant("original", None, "input", "r1"),
    ];
    assert_eq!(
        select_candidate(&deck, &original)
            .unwrap()
            .unwrap()
            .public_id,
        "fallback"
    );
    let known_run = Execution {
        variant_public_id: None,
        ..original
    };
    assert_eq!(
        select_candidate(&deck, &known_run)
            .unwrap()
            .unwrap()
            .public_id,
        "fallback"
    );
    let cycle = vec![
        variant("original", Some("fallback"), "fallback", "r1"),
        variant("fallback", Some("original"), "fallback", "r2"),
    ];
    assert!(select_candidate(&cycle, &known_run).is_err());
}
#[test]
fn materialization_keeps_original_identity_and_ignores_run_held_noise() {
    let mut state = MaterializationState::default();
    let mut e = event(1);
    e.r#type = "input_materialized".into();
    e.payload = json!({"input_public_id":"input","turn_public_id":"turn","run_public_id":"r1"});
    state.apply("input", &e);
    e.payload["turn_public_id"] = Value::String("later".into());
    state.apply("input", &e);
    assert_eq!(state.original.unwrap().turn_public_id, "turn");
}
