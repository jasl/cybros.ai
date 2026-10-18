import { test, expect } from "bun:test";
import { compactStamp, relativeStamp } from "../webui/kernel/format.js";

const NOW = Date.parse("2026-10-11T12:00:00Z");
const ago = (seconds) => new Date(NOW - seconds * 1000).toISOString();

test("a row's compact stamp and its spoken form read the same clock", () => {
  const cases = [
    [20, "now", "this minute"],
    [3 * 60, "3m", "3 minutes ago"],
    [59 * 60, "59m", "59 minutes ago"],
    [2 * 3600, "2h", "2 hours ago"],
    [23 * 3600, "23h", "23 hours ago"],
    [26 * 3600, "1d", "yesterday"],
    [3 * 86400, "3d", "3 days ago"],
  ];
  for (const [seconds, compact, spoken] of cases) {
    expect(compactStamp(ago(seconds), NOW)).toBe(compact);
    expect(relativeStamp(ago(seconds), NOW)).toBe(spoken);
  }
  // A week or more is a date in both forms.
  expect(compactStamp(ago(8 * 86400), NOW)).toBe(relativeStamp(ago(8 * 86400), NOW));
  expect(compactStamp(ago(8 * 86400), NOW)).toMatch(/^Oct 3$/);
  expect(compactStamp(null, NOW)).toBe("");
  expect(compactStamp("not a date", NOW)).toBe("");
});
