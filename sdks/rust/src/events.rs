//! Durable replay positions advance only after successful processing or explicit ack.
use crate::{
    Error, Result,
    resources::{ConversationContext, InferenceRequestContext, RunContext},
    types::{
        member::{Event, EventPage},
        requests::EventQuery,
    },
};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::{collections::VecDeque, future::Future, sync::Arc};
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Position {
    pub cursor: Option<String>,
    pub sequence: i64,
}
#[async_trait]
pub trait ReplaySource: Send + Sync {
    async fn replay(&self, position: &Position) -> Result<EventPage>;
}
#[async_trait]
impl ReplaySource for ConversationContext {
    async fn replay(&self, p: &Position) -> Result<EventPage> {
        Ok(self
            .events(&EventQuery {
                after: p.cursor.clone(),
                ..Default::default()
            })
            .await?
            .body)
    }
}
#[async_trait]
impl ReplaySource for RunContext {
    async fn replay(&self, p: &Position) -> Result<EventPage> {
        Ok(self
            .events(&EventQuery {
                after: p.cursor.clone(),
                ..Default::default()
            })
            .await?
            .body)
    }
}
#[async_trait]
impl ReplaySource for InferenceRequestContext {
    async fn replay(&self, p: &Position) -> Result<EventPage> {
        let p = self
            .events(&EventQuery {
                after: p.cursor.clone(),
                ..Default::default()
            })
            .await?
            .body;
        Ok(EventPage {
            pagination: p.pagination,
            items: p
                .items
                .into_iter()
                .map(|e| Event {
                    public_id: e.public_id,
                    sequence: e.sequence,
                    cursor: e.cursor,
                    r#type: e.r#type.as_str().to_owned().into(),
                    resource: e.resource,
                    occurred_at: e.occurred_at,
                    payload: e.payload,
                    extra: e.extra,
                })
                .collect(),
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
#[must_use = "inspect retention_gap and recover application state explicitly"]
pub struct DrainReport {
    pub watermark: i64,
    pub retention_gap: bool,
    pub position: Position,
}
/// Frozen-watermark replay followed by optional Cable acceleration.
/// Returning an event never acknowledges it. Persist its position with your
/// application projection and then call ack, or use consume's successful handler.
pub struct KernelFeed {
    source: Arc<dyn ReplaySource>,
    position: Position,
    pending: VecDeque<Event>,
    head: Option<i64>,
    gap: bool,
}
impl KernelFeed {
    pub fn new(source: Arc<dyn ReplaySource>, position: Position) -> Result<Self> {
        if position.sequence < 0 || (position.sequence > 0 && position.cursor.is_none()) {
            return Err(Error::Configuration(
                "a resumed position requires its cursor and nonnegative sequence",
            ));
        }
        Ok(Self {
            source,
            position,
            pending: VecDeque::new(),
            head: None,
            gap: false,
        })
    }
    pub fn position(&self) -> &Position {
        &self.position
    }
    pub async fn next_replayed(&mut self) -> Result<Option<Event>> {
        if let Some(event) = self.pending.front() {
            return Ok(Some(event.clone()));
        }
        if self.head.is_some_and(|head| self.position.sequence >= head) {
            return Ok(None);
        }
        let page = self.source.replay(&self.position).await?;
        let head = *self.head.get_or_insert(page.pagination.watermark);
        let mut items = page.items;
        items.sort_by_key(|e| e.sequence);
        let mut previous = self.position.sequence;
        for event in items {
            if event.sequence <= previous || event.sequence > head {
                continue;
            }
            if event.sequence > previous + 1 {
                self.gap = true;
            }
            previous = event.sequence;
            self.pending.push_back(event);
        }
        if self.pending.is_empty() {
            if self.position.sequence < head {
                self.gap = true;
            }
            return Ok(None);
        }
        Ok(self.pending.front().cloned())
    }
    pub fn ack(&mut self, event: &Event) -> Result<()> {
        let pending = self.pending.front().ok_or(Error::Configuration(
            "no delivered event awaits acknowledgement",
        ))?;
        if event.public_id != pending.public_id
            || event.sequence != pending.sequence
            || event.cursor != pending.cursor
        {
            return Err(Error::Configuration(
                "acknowledgement does not match delivered event",
            ));
        }
        self.position = Position {
            cursor: Some(event.cursor.clone()),
            sequence: event.sequence,
        };
        self.pending.pop_front();
        Ok(())
    }
    pub async fn consume<F, Fut>(&mut self, mut handler: F) -> Result<DrainReport>
    where
        F: FnMut(Event, Position) -> Fut,
        Fut: Future<Output = Result<()>>,
    {
        while let Some(event) = self.next_replayed().await? {
            let next = Position {
                cursor: Some(event.cursor.clone()),
                sequence: event.sequence,
            };
            handler(event.clone(), next).await?;
            self.ack(&event)?;
        }
        Ok(self.finish_pass())
    }
    pub fn finish_pass(&mut self) -> DrainReport {
        let report = DrainReport {
            watermark: self.head.unwrap_or(self.position.sequence),
            retention_gap: self.gap,
            position: self.position.clone(),
        };
        self.head = None;
        self.gap = false;
        report
    }
    /// A live forward gap triggers replay. It never permits skipping unseen events.
    pub async fn live_hint<F, Fut>(&mut self, event: Event, handler: F) -> Result<DrainReport>
    where
        F: FnMut(Event, Position) -> Fut,
        Fut: Future<Output = Result<()>>,
    {
        if event.sequence <= self.position.sequence {
            return Ok(DrainReport {
                watermark: self.position.sequence,
                retention_gap: false,
                position: self.position.clone(),
            });
        }
        // Replaying also authenticates the durable payload instead of trusting ordering
        // on the socket. This handles duplicates, gaps, overflow, and reconnect uniformly.
        self.consume(handler).await
    }
}
/// Ephemeral transcript preview. Final HTTP content replaces streamed content.
#[derive(Clone, Debug)]
pub struct TranscriptAccumulator {
    bound: usize,
    text: String,
    length: usize,
    key: Option<String>,
    replaced: bool,
}
impl Default for TranscriptAccumulator {
    fn default() -> Self {
        Self::new(64 * 1024)
    }
}
impl TranscriptAccumulator {
    pub fn new(bound: usize) -> Self {
        Self {
            bound,
            text: String::new(),
            length: 0,
            key: None,
            replaced: false,
        }
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn length(&self) -> usize {
        self.length
    }
    pub fn replaced(&self) -> bool {
        self.replaced
    }
    pub fn reset(&mut self, key: Option<String>) {
        self.text.clear();
        self.length = 0;
        self.key = key;
        self.replaced = false;
    }
    pub fn accumulate(&mut self, text: &str, key: Option<&str>) {
        if key.is_some() && key != self.key.as_deref() {
            self.reset(key.map(str::to_owned));
        }
        self.text.push_str(text);
        self.length += text.len();
        self.trim();
    }
    pub fn replace_snapshot(&mut self, text: &str, length: Option<usize>) -> String {
        let total = length.unwrap_or(text.len()).max(text.len());
        let growth = total.checked_sub(self.length);
        let continuation = growth
            .filter(|g| *g <= text.len())
            .and_then(|g| text.get(..text.len() - g))
            .is_some_and(|overlap| {
                overlap.is_empty() || self.text.ends_with(overlap) || overlap.ends_with(&self.text)
            });
        self.replaced = self.length > 0 && !continuation;
        let count = if self.replaced {
            text.len()
        } else {
            growth.unwrap_or(0).min(text.len())
        };
        let mut start = text.len() - count;
        while !text.is_char_boundary(start) {
            start += 1;
        }
        let remainder = text[start..].to_owned();
        self.text = text.into();
        self.length = total;
        self.trim();
        remainder
    }
    pub fn replace_on_settle(&mut self, text: &str) -> String {
        self.replace_snapshot(text, None)
    }
    fn trim(&mut self) {
        if self.text.len() > self.bound {
            let mut start = self.text.len() - self.bound;
            while !self.text.is_char_boundary(start) {
                start += 1;
            }
            self.text.drain(..start);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FeedControl {
    Continue,
    Stop,
}
#[derive(Clone, Debug)]
pub struct FollowOptions {
    pub max_reconnects: usize,
    pub retry_backoff: std::time::Duration,
}
impl Default for FollowOptions {
    fn default() -> Self {
        Self {
            max_reconnects: 8,
            retry_backoff: std::time::Duration::from_millis(500),
        }
    }
}
#[cfg(feature = "realtime")]
impl KernelFeed {
    /// Replay to a frozen head, confirm the subscription, replay the gap, then use
    /// Cable messages as hints to replay again. Each disconnect repeats this barrier.
    /// The recovery callback receives retention gaps; no invented cursor is committed.
    pub async fn follow<F, Fut, R, RFut, C>(
        &mut self,
        cable: &crate::realtime::CableClient,
        channel: crate::realtime::Channel,
        options: FollowOptions,
        mut handler: F,
        mut recover: R,
        mut confirmed: C,
    ) -> Result<()>
    where
        F: FnMut(Event, Position) -> Fut,
        Fut: Future<Output = Result<FeedControl>>,
        R: FnMut(DrainReport) -> RFut,
        RFut: Future<Output = Result<FeedControl>>,
        C: FnMut() -> Result<()>,
    {
        if options.retry_backoff.is_zero() {
            return Err(Error::Configuration("feed retry backoff must be positive"));
        }
        let mut reconnects = 0;
        let mut subscription = None;
        'follow: loop {
            loop {
                let event = match self.next_replayed().await {
                    Ok(Some(event)) => event,
                    Ok(None) => break,
                    Err(error) => {
                        if !retryable(&error) || reconnects >= options.max_reconnects {
                            return Err(error);
                        }
                        reconnects += 1;
                        subscription = None;
                        tokio::time::sleep(options.retry_backoff).await;
                        continue 'follow;
                    }
                };
                let next = Position {
                    cursor: Some(event.cursor.clone()),
                    sequence: event.sequence,
                };
                let control = handler(event.clone(), next).await?;
                self.ack(&event)?;
                if control == FeedControl::Stop {
                    return Ok(());
                }
            }
            let report = self.finish_pass();
            if recover(report).await? == FeedControl::Stop {
                return Ok(());
            }
            if subscription.is_none() {
                match cable.subscribe(channel.clone()).await {
                    Ok(sub) => {
                        subscription = Some(sub);
                        confirmed()?;
                        continue;
                    }
                    Err(error) => {
                        if !retryable(&error) || reconnects >= options.max_reconnects {
                            return Err(error);
                        }
                        reconnects += 1;
                        tokio::time::sleep(options.retry_backoff).await;
                        continue;
                    }
                }
            }
            match subscription
                .as_mut()
                .expect("installed subscription")
                .next()
                .await
            {
                Ok(Some(crate::realtime::Frame::Event(_))) => {}
                Ok(Some(_)) => continue,
                Ok(None) => return Ok(()),
                Err(error) => {
                    if !retryable(&error) || reconnects >= options.max_reconnects {
                        return Err(error);
                    }
                    reconnects += 1;
                    subscription = None;
                    tokio::time::sleep(options.retry_backoff).await;
                }
            }
        }
    }
}
#[cfg(feature = "realtime")]
fn retryable(error: &Error) -> bool {
    matches!(
        error,
        Error::Realtime {
            kind: crate::error::RealtimeFailure::Disconnected
                | crate::error::RealtimeFailure::BufferOverflow
                | crate::error::RealtimeFailure::Timeout
        } | Error::Transport { .. }
            | Error::Api {
                status: 429 | 500..=599,
                ..
            }
    )
}
