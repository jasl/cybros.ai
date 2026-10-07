import { el } from "./views.js";

const integer = new Intl.NumberFormat("en-US");
const decimal = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });
const tokens = (value) => value == null ? "Unknown" : integer.format(value);
const percent = (value) => value == null ? "Unknown" : `${decimal.format(value)}%`;

export function usagePresentation(usage) {
  if (!usage) return { summary: "Usage · Unavailable", facts: [], note: "Recorded usage is unavailable." };

  // Keep the ledger's decimal and Account unit verbatim. A known subtotal
  // must not look like the price of requests whose cost is still unknown.
  const amount = `${usage.cost_amount}${usage.cost_unit ? ` ${usage.cost_unit}` : ""}`;
  const cost = usage.cost_complete ? amount : `${amount} (incomplete)`;
  const costLabel = usage.cost_complete ? "Cost" : "Known subtotal";
  return {
    summary: `Usage · ${tokens(usage.total_tokens)} tokens · ${costLabel} ${cost}`,
    facts: [
      ["Requests", tokens(usage.request_count)],
      ["Input tokens", tokens(usage.input_tokens)],
      ["Cached input tokens", tokens(usage.cache_read_tokens)],
      ["Uncached input tokens", tokens(usage.uncached_input_tokens)],
      ["Cache creation tokens", tokens(usage.cache_creation_tokens)],
      ["Cache hit rate", percent(usage.cache_hit_rate == null ? null : usage.cache_hit_rate * 100)],
      ["Output tokens", tokens(usage.output_tokens)],
      ["Reasoning tokens", tokens(usage.reasoning_tokens)],
      ["Total tokens", tokens(usage.total_tokens)],
      ["Cost", usage.cost_complete ? cost : `Known subtotal ${cost}`],
      ["Cost unit", usage.cost_unit || "Not set"],
    ],
    note: "Cumulative recorded usage for this conversation, including retries and background work."
      + (usage.cost_complete ? "" : " Some request costs are unknown; the subtotal is incomplete."),
  };
}

export function contextPresentation(context) {
  if (!context) return { summary: "Context · Unavailable", facts: [],
    note: "No current provider usage report is available." };

  const window = context.window_tokens == null ? "window unknown" : `${tokens(context.window_tokens)} tokens`;
  const occupancy = context.window_tokens == null ? `${tokens(context.used_tokens)} tokens · ${window}`
    : `${tokens(context.used_tokens)} / ${window}`;
  const model = [context.as_of_model?.provider_id, context.as_of_model?.model_ref].filter(Boolean).join("/") || "Unknown";
  return {
    summary: `Context · ${occupancy}${context.used_percent == null ? "" : ` (${percent(context.used_percent)})`}`,
    facts: [
      ["Model", model],
      ["Used tokens", tokens(context.used_tokens)],
      ["Context window", tokens(context.window_tokens)],
      ["Occupancy", percent(context.used_percent)],
      ["Input tokens", tokens(context.input_tokens)],
      ["Output tokens", tokens(context.output_tokens)],
      ["Cached input tokens", tokens(context.cache_read_tokens)],
    ],
    note: "Latest successful request, separate from cumulative conversation usage.",
  };
}

function disclosure(className) {
  const summary = el("summary");
  const body = el("div", { class: "usage-details" });
  const element = el("details", { class: className }, summary, body);
  return { element, update(presentation) {
    summary.textContent = presentation.summary;
    body.replaceChildren(el("p", { class: "muted", text: presentation.note }),
      el("dl", {}, presentation.facts.flatMap(([label, value]) => [el("dt", { text: label }), el("dd", { text: value })])));
  } };
}

export function createConversationMetrics() {
  const usage = disclosure("conversation-usage");
  const context = disclosure("conversation-context");
  const element = el("div", { class: "conversation-metrics", hidden: true, tabindex: "0", role: "region",
    "aria-label": "Conversation usage and context" }, usage.element, context.element);
  let conversationId = null;
  let previousConversation = null, previousAccess = null;
  return { element, update(conversation, access = "ready") {
    // Detail refreshes replace the document; composer edits reuse it.
    if (conversation === previousConversation && access === previousAccess) return;
    previousConversation = conversation; previousAccess = access;
    const visible = !!conversation && ["ready", "read-only"].includes(access);
    const nextId = conversation && access !== "unavailable" ? conversation.public_id : null;
    if (nextId !== conversationId) {
      usage.element.open = false; context.element.open = false;
    }
    conversationId = nextId;
    element.hidden = !visible;
    usage.update(usagePresentation(visible ? conversation.usage_summary : null));
    context.update(contextPresentation(visible ? conversation.context : null));
  } };
}
