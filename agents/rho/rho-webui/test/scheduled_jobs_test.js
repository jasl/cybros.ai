import { test, expect } from "bun:test";
import { scheduledRule, scheduledRuleText, scheduledJobChanges } from "../webui/scheduled_jobs.js";
import { Submissions } from "../webui/lifecycle.js";

test("the one-time and interval authoring clocks carry explicit instants", () => {
  expect(scheduledRule("once", { at: "2026-10-02T09:00:00+08:00" })).toEqual({ kind: "once", run_at: "2026-10-02T01:00:00.000Z" });
  expect(scheduledRule("interval", { seconds: "90", at: "2026-10-02T09:00:00Z" })).toEqual({ kind: "interval", every_seconds: 90, starts_at: "2026-10-02T09:00:00.000Z" });
  expect(() => scheduledRule("once", { at: "2026-10-02T09:00" })).toThrow("time zone");
  expect(() => scheduledRule("interval", { seconds: "0", at: "2026-10-02T09:00:00Z" })).toThrow("positive");
});

test("daily schedules retain local civil time and the named time zone", () => {
  const rule = scheduledRule("daily", { localTime: "09:15", timeZone: "Asia/Shanghai" });
  expect(rule).toEqual({ kind: "daily", local_time: "09:15", time_zone: "Asia/Shanghai" });
  expect(scheduledRuleText(rule)).toBe("Daily · 09:15 Asia/Shanghai");
  expect(() => scheduledRule("daily", { localTime: "24:00", timeZone: "UTC" })).toThrow("HH:MM");
  expect(() => scheduledRule("daily", { localTime: "09:00", timeZone: "Bad/Zone" })).toThrow();
});

test("retrying the same scheduled intent retains its creation key and frozen time", () => {
  let serial = 0;
  const pending = new Submissions(() => `key-${++serial}`);
  const body = { public_id: "conversation", prompt: "Report progress", rule: scheduledRule("once", { at: "2026-10-02T09:00:00Z" }) };
  const first = pending.prepare("/conversations/scheduled_jobs/create", body);
  expect(pending.prepare("/conversations/scheduled_jobs/create", { ...body })).toBe(first);
  expect(first.body.idempotency_key).toBe("key-1");
  pending.accepted(first, new Map());
  expect(pending.prepare("/conversations/scheduled_jobs/create", body).body.idempotency_key).toBe("key-2");
});

test("editing the prompt preserves the schedule and inherited policy", () => {
  const displayed = { prompt: "Report progress", name: "Daily", model: "dev/model", approval_mode: "ask",
    rule: scheduledRule("interval", { seconds: "3600", at: "2026-10-02T09:00:00Z" }) };
  expect(scheduledJobChanges(displayed, { ...displayed, prompt: "Report blockers", name: null }))
    .toEqual({ prompt: "Report blockers", name: null });
  const changedRule = scheduledRule("daily", { localTime: "09:00", timeZone: "Asia/Shanghai" });
  expect(scheduledJobChanges(displayed, { ...displayed, rule: changedRule })).toEqual({ rule: changedRule });
});
