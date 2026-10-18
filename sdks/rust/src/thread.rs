//! Ephemeral mainline thread projection. HTTP pages and settled snapshots replace live marks.
use crate::types::{
    JsonObject,
    member::{ProgressFrame, RunTranscript, ThreadCall, ThreadCalls, ThreadRow, TranscriptItem},
};
use serde::Serialize;
use std::collections::BTreeSet;

#[derive(Clone, Debug, Serialize)]
pub struct ThreadSnapshot {
    pub rows: Vec<ThreadRow>,
    pub live: Vec<String>,
}
#[derive(Clone, Debug)]
pub struct ThreadAccumulator {
    rows: Vec<ThreadRow>,
    live: Vec<String>,
    branches: BTreeSet<String>,
    max_rows: usize,
}
impl Default for ThreadAccumulator {
    fn default() -> Self {
        Self::new(256)
    }
}
impl ThreadAccumulator {
    pub fn new(max_rows: usize) -> Self {
        Self {
            rows: vec![],
            live: vec![],
            branches: BTreeSet::new(),
            max_rows,
        }
    }
    pub fn seed(&mut self, page: &RunTranscript) {
        self.rows = page.rounds.clone();
        self.live.clear();
        self.branches.clear();
        self.trim();
    }
    pub fn rows(&self) -> &[ThreadRow] {
        &self.rows
    }
    pub fn live(&self) -> &[String] {
        &self.live
    }
    pub fn snapshot(&self) -> ThreadSnapshot {
        ThreadSnapshot {
            rows: self.rows.clone(),
            live: self.live.clone(),
        }
    }
    pub fn settle_round(&mut self, item: &TranscriptItem) {
        let Some(row) = &item.round else {
            return;
        };
        if !row.mainline {
            self.retract(&row.task_key);
            return;
        }
        self.put(row.clone());
        self.clear_live(&row.task_key);
    }
    pub fn settle_call(&mut self, item: &TranscriptItem) {
        let Some(call) = &item.call else {
            return;
        };
        let Some(round) = round_of(&call.task_key) else {
            return;
        };
        if self.branches.contains(&round) {
            return;
        }
        self.upsert_call(&round, call.clone());
        self.live.retain(|k| k != &call.task_key);
    }
    pub fn round_started(&mut self, frame: &ProgressFrame) {
        let Some(key) = &frame.task_key else {
            return;
        };
        if frame.payload.get("mainline").and_then(|v| v.as_bool()) != Some(true) {
            self.retract(key);
            return;
        }
        let mut row = self.row(key);
        row.status = "running".into();
        for field in ["attempt", "model", "request_bytes"] {
            if let Some(value) = frame.payload.get(field).filter(|v| !v.is_null()) {
                row.extra.insert(field.into(), value.clone());
            }
        }
        self.put(row);
        self.mark(key);
    }
    pub fn step_started(&mut self, frame: &ProgressFrame) {
        self.progress_call(frame, false);
    }
    pub fn step_claimed(&mut self, frame: &ProgressFrame) {
        self.progress_call(frame, true);
    }
    fn progress_call(&mut self, frame: &ProgressFrame, claimed: bool) {
        let Some(key) = &frame.task_key else {
            return;
        };
        let Some(round) = round_of(key) else {
            return;
        };
        if self.branches.contains(&round) {
            return;
        }
        let mut call = self
            .row(&round)
            .calls
            .items
            .into_iter()
            .find(|c| &c.task_key == key)
            .unwrap_or_else(|| ThreadCall {
                task_key: key.clone(),
                name: frame.tool_name.clone().unwrap_or_default(),
                status: "waiting".into(),
                tool_call_id: None,
                tool: None,
                is_error: None,
                title: None,
                metadata: None,
                output_preview: None,
                output_bytes: None,
                started_at: None,
                completed_at: None,
                extra: JsonObject::new(),
            });
        if let Some(name) = &frame.tool_name {
            call.name = name.clone();
        }
        if claimed {
            if let Some(executor) = &frame.executor_public_id {
                call.extra
                    .insert("executor_public_id".into(), executor.clone().into());
            }
        } else if let Some(status) = frame.payload.get("status").and_then(|v| v.as_str()) {
            call.status = status.to_owned().into();
        }
        self.upsert_call(&round, call);
        self.mark(key);
    }
    fn row(&self, key: &str) -> ThreadRow {
        self.rows
            .iter()
            .find(|r| r.task_key == key)
            .cloned()
            .unwrap_or_else(|| ThreadRow {
                task_key: key.into(),
                mainline: true,
                status: "waiting".into(),
                visibility: "visible".into(),
                text_preview: None,
                text_bytes: None,
                usage: None,
                error: None,
                compacted_before: None,
                pruned_before: None,
                started_at: None,
                completed_at: None,
                calls: ThreadCalls {
                    count: 0,
                    items: vec![],
                    extra: JsonObject::new(),
                },
                branches: vec![],
                extra: JsonObject::new(),
            })
    }
    fn put(&mut self, row: ThreadRow) {
        if let Some(index) = self.rows.iter().position(|r| r.task_key == row.task_key) {
            self.rows[index] = row;
        } else {
            self.rows.push(row);
        }
        self.trim();
    }
    fn upsert_call(&mut self, key: &str, call: ThreadCall) {
        let mut row = self.row(key);
        if let Some(index) = row
            .calls
            .items
            .iter()
            .position(|c| c.task_key == call.task_key)
        {
            row.calls.items[index] = call;
        } else {
            row.calls.items.push(call);
        }
        row.calls.count = row.calls.count.max(row.calls.items.len() as i64);
        self.put(row);
    }
    fn retract(&mut self, key: &str) {
        self.rows.retain(|r| r.task_key != key);
        self.clear_live(key);
        self.branches.insert(key.into());
    }
    fn clear_live(&mut self, key: &str) {
        self.live
            .retain(|k| k != key && round_of(k).as_deref() != Some(key));
    }
    fn mark(&mut self, key: &str) {
        if !self.live.iter().any(|k| k == key) {
            self.live.push(key.into());
        }
    }
    fn trim(&mut self) {
        while self.rows.len() > self.max_rows {
            let row = self.rows.remove(0);
            self.clear_live(&row.task_key);
        }
    }
}
fn round_of(key: &str) -> Option<String> {
    let digits = key.strip_prefix('r')?;
    let (number, call) = digits.split_once('t')?;
    if number.is_empty()
        || call.is_empty()
        || !number.bytes().all(|b| b.is_ascii_digit())
        || !call.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    Some(format!("r{number}"))
}
