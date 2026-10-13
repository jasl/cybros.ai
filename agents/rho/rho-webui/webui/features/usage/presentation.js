import { locale, t } from "../../kernel/i18n.js";

const integer = new Intl.NumberFormat(locale);
const decimal = new Intl.NumberFormat(locale, { maximumFractionDigits: 1 });
const tokens = (value) => (value == null ? t("common.unknown") : integer.format(value));
const percent = (value) => (value == null ? t("common.unknown") : `${decimal.format(value)}%`);

// Cumulative recorded usage of the conversation, retries and background work
// included. The ledger's decimal and Account unit are kept verbatim, and a
// known subtotal never looks like the price of requests still unpriced.
export function usagePresentation(usage) {
  if (!usage) return { summary: t("conversation_usage.usage_unavailable"), facts: [], note: t("conversation_usage.recorded_usage_is_unavailable") };
  const amount = `${usage.cost_amount}${usage.cost_unit ? ` ${usage.cost_unit}` : ""}`;
  const cost = usage.cost_complete ? amount : t("conversation_usage.incomplete_amount", { amount });
  const costLabel = usage.cost_complete ? t("common.cost") : t("conversation_usage.known_subtotal_2");
  return {
    summary: t("conversation_usage.usage_tokens", { tokens: tokens(usage.total_tokens), costLabel, cost }),
    facts: [
      [t("conversation_usage.requests"), tokens(usage.request_count)],
      [t("common.input_tokens"), tokens(usage.input_tokens)],
      [t("common.cached_input_tokens"), tokens(usage.cache_read_tokens)],
      [t("conversation_usage.uncached_input_tokens"), tokens(usage.uncached_input_tokens)],
      [t("conversation_usage.cache_creation_tokens"), tokens(usage.cache_creation_tokens)],
      [t("conversation_usage.cache_hit_rate"), percent(usage.cache_hit_rate == null ? null : usage.cache_hit_rate * 100)],
      [t("common.output_tokens"), tokens(usage.output_tokens)],
      [t("conversation_usage.reasoning_tokens"), tokens(usage.reasoning_tokens)],
      [t("conversation_usage.total_tokens"), tokens(usage.total_tokens)],
      [t("common.cost"), usage.cost_complete ? cost : t("conversation_usage.known_subtotal", { cost })],
      [t("conversation_usage.cost_unit"), usage.cost_unit || t("common.not_set")],
    ],
    note: t("conversation_usage.cumulative_recorded_usage_for_this_conversation_including_retries")
      + (usage.cost_complete ? "" : t("conversation_usage.some_request_costs_are_unknown_the_subtotal_is")),
  };
}

// The latest successful request's reported occupancy and actual model,
// separate from the cumulative totals; a missing report stays unknown.
export function contextPresentation(context) {
  if (!context) return { summary: t("conversation_usage.context_unavailable"), facts: [], note: t("conversation_usage.no_current_provider_usage_report_is_available") };
  const window = context.window_tokens == null ? t("conversation_usage.window_unknown") : t("conversation_usage.token_count", { count: tokens(context.window_tokens) });
  const occupancy = context.window_tokens == null ? t("conversation_usage.unknown_occupancy", { count: tokens(context.used_tokens), window })
    : `${tokens(context.used_tokens)} / ${window}`;
  const model = [context.as_of_model?.provider_id, context.as_of_model?.model_ref].filter(Boolean).join("/") || t("common.unknown");
  return {
    summary: t("conversation_usage.context", { occupancy, share: context.used_percent == null ? "" : ` (${percent(context.used_percent)})` }),
    facts: [
      [t("common.model"), model],
      [t("conversation_usage.used_tokens"), tokens(context.used_tokens)],
      [t("conversation_usage.context_window"), tokens(context.window_tokens)],
      [t("conversation_usage.occupancy"), percent(context.used_percent)],
      [t("common.input_tokens"), tokens(context.input_tokens)],
      [t("common.output_tokens"), tokens(context.output_tokens)],
      [t("common.cached_input_tokens"), tokens(context.cache_read_tokens)],
    ],
    note: t("conversation_usage.latest_successful_request_separate_from_cumulative_conversation_usage"),
  };
}

// The header chip: context occupancy when reported, else the token total.
export function usageChipText(conversation) {
  if (conversation?.context?.used_percent != null) return percent(conversation.context.used_percent);
  if (conversation?.usage_summary?.total_tokens != null) return t("conversation_usage.token_count", { count: tokens(conversation.usage_summary.total_tokens) });
  return t("common.usage");
}
