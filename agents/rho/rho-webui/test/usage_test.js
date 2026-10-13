import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";
import { createSlots } from "../webui/kernel/slots.js";
import { contextPresentation, usagePresentation, usageChipText } from "../webui/features/usage/presentation.js";
import { register } from "../webui/features/usage/index.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const usage = {
  request_count: 3, input_tokens: 4000, cache_read_tokens: 1000, uncached_input_tokens: 3000, cache_creation_tokens: 500,
  cache_hit_rate: 0.25, output_tokens: 400, reasoning_tokens: 100, total_tokens: 4400, cost_amount: "0.123456789012345678", cost_complete: true, cost_unit: "credits",
};
const context = { used_tokens: 1100, input_tokens: 1000, output_tokens: 100, cache_read_tokens: 0, window_tokens: 32000, used_percent: 3.4375,
  as_of_model: { provider_id: "local", model_ref: "actual-fallback" } };

test("usage keeps the exact decimal cost and Account unit and shows every recorded counter", () => {
  const view = usagePresentation(usage);
  expect(view.summary).toBe("Usage · 4,400 tokens · Cost 0.123456789012345678 credits");
  expect(Object.fromEntries(view.facts)).toEqual({
    Requests: "3", "Input tokens": "4,000", "Cached input tokens": "1,000", "Uncached input tokens": "3,000", "Cache creation tokens": "500",
    "Cache hit rate": "25%", "Output tokens": "400", "Reasoning tokens": "100", "Total tokens": "4,400", Cost: "0.123456789012345678 credits", "Cost unit": "credits",
  });
  expect(view.note).toContain("including retries and background work");
});

test("unknown prices show an incomplete known subtotal, even when the known amount is zero", () => {
  for (const amount of ["0.0", "0.123456789012345678"]) {
    const view = usagePresentation({ ...usage, cost_amount: amount, cost_complete: false });
    expect(view.summary).toBe(`Usage · 4,400 tokens · Known subtotal ${amount} credits (incomplete)`);
    expect(Object.fromEntries(view.facts).Cost).toBe(`Known subtotal ${amount} credits (incomplete)`);
    expect(view.note).toContain("Some request costs are unknown");
  }
});

test("zero requests are real zero usage while a missing report or cache ratio stays unknown", () => {
  const view = usagePresentation({ ...usage, request_count: 0, input_tokens: 0, cache_read_tokens: 0, uncached_input_tokens: 0, cache_creation_tokens: 0,
    cache_hit_rate: null, output_tokens: 0, reasoning_tokens: 0, total_tokens: 0, cost_amount: "0.0", cost_unit: null });
  expect(view.summary).toBe("Usage · 0 tokens · Cost 0.0");
  expect(Object.fromEntries(view.facts)).toMatchObject({ Requests: "0", "Cache hit rate": "Unknown", "Cost unit": "Not set" });
  expect(usagePresentation(null)).toMatchObject({ summary: "Usage · Unavailable", facts: [] });
});

test("context uses the latest successful request and its actual model, never cumulative tokens", () => {
  const view = contextPresentation(context);
  expect(view.summary).toBe("Context · 1,100 / 32,000 tokens (3.4%)");
  expect(Object.fromEntries(view.facts)).toMatchObject({ Model: "local/actual-fallback", "Used tokens": "1,100", "Input tokens": "1,000", "Cached input tokens": "0" });
  expect(view.note).toContain("separate from cumulative");
});

test("missing context fields never imply zero occupancy or a made-up window", () => {
  expect(contextPresentation(null)).toMatchObject({ summary: "Context · Unavailable", note: "No current provider usage report is available." });
  expect(contextPresentation({ ...context, window_tokens: null, used_percent: null }).summary).toBe("Context · 1,100 tokens · window unknown");
  const unknown = contextPresentation({ used_tokens: null, window_tokens: 32000, as_of_model: null });
  expect(unknown.summary).toBe("Context · Unknown / 32,000 tokens");
  expect(Object.fromEntries(unknown.facts)).toMatchObject({ Model: "Unknown", Occupancy: "Unknown" });
  expect(contextPresentation({ ...context, used_tokens: 0, used_percent: 0 }).summary).toBe("Context · 0 / 32,000 tokens (0%)");
});

test("the header chip shows occupancy when reported, else the token total", () => {
  expect(usageChipText({ context, usage_summary: usage })).toBe("3.4%");
  expect(usageChipText({ context: null, usage_summary: usage })).toBe("4,400 tokens");
  expect(usageChipText(null)).toBe("Usage");
});

function contributions() {
  const slots = createSlots();
  const opened = [];
  register({ slots: { register: (name, options, component) => slots.register(name, options, component) } }, { dock: { open: (key) => opened.push(key) } });
  return { slots, opened };
}
const conversation = (fields = {}) => ({ id: "c-a", access: "ready", detail: { public_id: "c-a", usage_summary: usage, context }, ...fields });

test("the chip opens the usage tab and hides for a new, loading or unavailable conversation", () => {
  const { slots, opened } = contributions();
  const chip = slots.winner("conversation.header.utilities", "usage").component({ conversation: conversation() });
  expect(chip.element.textContent).toBe("3.4%");
  expect(chip.element.getAttribute("aria-label")).toBe("Usage · 4,400 tokens · Cost 0.123456789012345678 credits — Context · 1,100 / 32,000 tokens (3.4%)");
  chip.element.click();
  expect(opened).toEqual(["usage"]);
  for (const fields of [{ id: null }, { access: "loading" }, { access: "unavailable" }]) {
    chip.update({ conversation: conversation(fields) });
    expect(chip.element.hidden).toBe(true);
  }
  chip.update({ conversation: conversation({ access: "read-only" }) });
  expect(chip.element.hidden).toBe(false);
});

test("the usage tab replaces its totals on refresh and shows nothing it may no longer read", () => {
  const { slots } = contributions();
  const registration = slots.winner("dock.tab", "usage");
  expect(registration.meta.title({})).toBe("Usage");
  expect(registration.meta.description()).toContain("Tokens, cost and context");
  const panel = registration.component({ conversation: conversation() });
  const element = panel.element;
  expect(element.querySelectorAll(".usage__summary").map((node) => node.textContent)).toEqual([
    "Usage · 4,400 tokens · Cost 0.123456789012345678 credits", "Context · 1,100 / 32,000 tokens (3.4%)"]);
  panel.update({ conversation: conversation({ detail: { public_id: "c-a", usage_summary: { ...usage, total_tokens: 5500 }, context } }) });
  expect(panel.element).toBe(element);
  expect(element.textContent).toContain("5,500 tokens");
  panel.update({ conversation: conversation({ access: "unavailable" }) });
  expect(element.textContent).not.toContain(usage.cost_amount);
  expect(element.querySelector(".usage__summary").textContent).toBe("Usage · Unavailable");
});
