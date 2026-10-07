import { test, expect } from "bun:test";
import { usagePresentation, contextPresentation, createConversationMetrics } from "../webui/conversation_usage.js";

const usage = {
  request_count: 3, input_tokens: 4000, cache_read_tokens: 1000, uncached_input_tokens: 3000,
  cache_creation_tokens: 500, cache_hit_rate: 0.25, output_tokens: 400, reasoning_tokens: 100,
  total_tokens: 4400, cost_amount: "0.123456789012345678", cost_complete: true, cost_unit: "credits",
};
const context = {
  used_tokens: 1100, input_tokens: 1000, output_tokens: 100, cache_read_tokens: 0,
  window_tokens: 32000, used_percent: 3.4375, as_of_model: { provider_id: "local", model_ref: "actual-fallback" },
};

test("usage preserves exact decimal cost and the Account unit while showing every recorded counter", () => {
  const view = usagePresentation(usage);
  expect(view.summary).toBe("Usage · 4,400 tokens · Cost 0.123456789012345678 credits");
  expect(Object.fromEntries(view.facts)).toEqual({
    Requests: "3", "Input tokens": "4,000", "Cached input tokens": "1,000", "Uncached input tokens": "3,000",
    "Cache creation tokens": "500", "Cache hit rate": "25%", "Output tokens": "400", "Reasoning tokens": "100",
    "Total tokens": "4,400", Cost: "0.123456789012345678 credits", "Cost unit": "credits",
  });
  expect(view.note).toContain("including retries and background work");
});

test("unknown prices expose an incomplete known subtotal, even when the known amount is zero", () => {
  for (const amount of ["0.0", "0.123456789012345678"]) {
    const view = usagePresentation({ ...usage, cost_amount: amount, cost_complete: false });
    expect(view.summary).toBe(`Usage · 4,400 tokens · Known subtotal ${amount} credits (incomplete)`);
    expect(Object.fromEntries(view.facts).Cost).toBe(`Known subtotal ${amount} credits (incomplete)`);
    expect(view.note).toContain("Some request costs are unknown");
  }
});

test("zero requests are real zero usage while a missing report or cache ratio stays unknown", () => {
  const view = usagePresentation({ ...usage, request_count: 0, input_tokens: 0, cache_read_tokens: 0,
    uncached_input_tokens: 0, cache_creation_tokens: 0, cache_hit_rate: null, output_tokens: 0,
    reasoning_tokens: 0, total_tokens: 0, cost_amount: "0.0", cost_unit: null });
  expect(view.summary).toBe("Usage · 0 tokens · Cost 0.0");
  expect(Object.fromEntries(view.facts)).toMatchObject({ Requests: "0", "Cache hit rate": "Unknown", "Cost unit": "Not set" });
  expect(usagePresentation(null).summary).toBe("Usage · Unavailable");
  expect(usagePresentation(null).facts).toEqual([]);
});

test("context uses the latest successful request and actual model without adding cumulative tokens", () => {
  const view = contextPresentation(context);
  expect(view.summary).toBe("Context · 1,100 / 32,000 tokens (3.4%)");
  expect(Object.fromEntries(view.facts)).toMatchObject({ Model: "local/actual-fallback", "Used tokens": "1,100",
    "Input tokens": "1,000", "Output tokens": "100", "Cached input tokens": "0" });
  expect(view.note).toContain("Latest successful request");
  expect(view.note).toContain("separate from cumulative");
});

test("missing context fields never imply zero occupancy or a made-up window", () => {
  expect(contextPresentation(null).summary).toBe("Context · Unavailable");
  expect(contextPresentation(null).note).toBe("No current provider usage report is available.");
  expect(contextPresentation({ ...context, window_tokens: null, used_percent: null }).summary)
    .toBe("Context · 1,100 tokens · window unknown");
  const unknown = contextPresentation({ used_tokens: null, window_tokens: 32000, as_of_model: null });
  expect(unknown.summary).toBe("Context · Unknown / 32,000 tokens");
  expect(Object.fromEntries(unknown.facts)).toMatchObject({ Model: "Unknown", Occupancy: "Unknown" });
  expect(contextPresentation({ ...context, used_tokens: 0, used_percent: 0 }).summary)
    .toBe("Context · 0 / 32,000 tokens (0%)");
});

// Double only the text/child replacement seam: the disclosure elements and
// their open state must survive repeated status updates on the same conversation.
function withDocument(run) {
  const previous = globalThis.document;
  const node = (tagName = "") => ({
    nodeType: 1, tagName: tagName.toUpperCase(), children: [], hidden: false, open: false,
    setAttribute(name, value) { if (name === "hidden") this.hidden = true; else this[name] = value; },
    addEventListener() {},
    append(child) { this.children.push(child); },
    replaceChildren(...children) { this.children = children; this.value = ""; },
    set textContent(value) { this.children = []; this.value = value; },
    get textContent() { return (this.value || "") + this.children.map((child) => child.textContent).join(""); },
  });
  globalThis.document = { createElement: node, createTextNode: (text) => ({ nodeType: 3, textContent: text }) };
  try { run(); } finally { globalThis.document = previous; }
}

test("same-conversation refreshes retain disclosure state and replace totals after background work", () => withDocument(() => {
  const metrics = createConversationMetrics();
  const [usageDetails, contextDetails] = metrics.element.children;
  const usageSummary = usageDetails.children[0];
  expect(usageDetails.tagName).toBe("DETAILS");
  expect(usageSummary.tagName).toBe("SUMMARY");
  expect(metrics.element.tabindex).toBe("0");
  expect(metrics.element["aria-label"]).toBe("Conversation usage and context");
  expect(metrics.element.hidden).toBe(true);
  metrics.update({ public_id: "conversation-a", usage_summary: usage, context });
  usageDetails.open = true; contextDetails.open = true;
  metrics.update({ public_id: "conversation-a", usage_summary: { ...usage, request_count: 4, total_tokens: 5500 }, context });
  expect(metrics.element.hidden).toBe(false);
  expect(usageDetails.open).toBe(true);
  expect(contextDetails.open).toBe(true);
  expect(usageDetails.children[0]).toBe(usageSummary);
  expect(usageSummary.textContent).toContain("5,500 tokens");
  expect(contextDetails.textContent).toContain("1,100 / 32,000");

  metrics.update({ public_id: "conversation-a", usage_summary: usage, context }, "loading");
  expect(metrics.element.hidden).toBe(true);
  expect(usageDetails.open).toBe(true);
  metrics.update({ public_id: "conversation-a", usage_summary: usage, context });
  expect(metrics.element.hidden).toBe(false);
  expect(usageDetails.open).toBe(true);

  metrics.update({ public_id: "conversation-b", usage_summary: null, context: null });
  expect(usageDetails.open).toBe(false);
  expect(contextDetails.open).toBe(false);
  expect(usageDetails.textContent).not.toContain("5,500");
  expect(contextDetails.textContent).not.toContain("actual-fallback");
  metrics.update({ public_id: "conversation-a", usage_summary: usage, context }, "read-only");
  expect(metrics.element.hidden).toBe(false);
  metrics.update({ public_id: "conversation-a", usage_summary: usage, context }, "unavailable");
  expect(metrics.element.hidden).toBe(true);
  expect(metrics.element.textContent).not.toContain(usage.cost_amount);
  metrics.update(null);
  expect(metrics.element.hidden).toBe(true);
}));
