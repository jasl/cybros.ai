import { el, icon } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { contextPresentation, usagePresentation, usageChipText } from "./presentation.js";

// Usage is shown for a conversation the page can read; a refused or loading
// one shows nothing it may no longer be allowed to see.
const readable = (conversation) => !!conversation.id && ["ready", "read-only"].includes(conversation.access);

function factsBlock() {
  const summary = el("h3", { class: "usage__summary" });
  const note = el("p", { class: "usage__note" });
  const facts = el("dl", { class: "usage__facts" });
  return {
    element: el("section", { class: "usage__block" }, summary, note, facts),
    update(presentation) {
      summary.textContent = presentation.summary;
      note.textContent = presentation.note;
      facts.replaceChildren(...presentation.facts.flatMap(([label, value]) => [el("dt", { text: label }), el("dd", { text: value })]));
    },
  };
}

function usagePanel(initialProps) {
  const usage = factsBlock();
  const context = factsBlock();
  const element = el("div", { class: "usage" }, usage.element, context.element);
  const paint = ({ conversation }) => {
    const detail = readable(conversation) ? conversation.detail : null;
    usage.update(usagePresentation(detail?.usage_summary ?? null));
    context.update(contextPresentation(detail?.context ?? null));
  };
  paint(initialProps);
  return { element, update: paint };
}

function usageChip(shell, initialProps) {
  const label = el("span", { class: "chip__label" });
  const element = el("button", { type: "button", class: "chip usage-chip", onclick: () => shell.dock.open("usage") }, icon("gauge"), label);
  const paint = ({ conversation }) => {
    element.hidden = !readable(conversation);
    if (element.hidden) return;
    const detail = conversation.detail;
    label.textContent = usageChipText(detail);
    element.setAttribute("aria-label", t("conversation_usage.chip_label", {
      usage: usagePresentation(detail?.usage_summary ?? null).summary, context: contextPresentation(detail?.context ?? null).summary }));
    element.dataset.tip = t("conversation_usage.conversation_usage_and_context");
  };
  paint(initialProps);
  return { element, update: paint };
}

export function register(ui, shell) {
  ui.slots.register("dock.tab", { key: "usage", title: () => t("common.usage"), description: () => t("conversation_usage.guide"), icon: "gauge" },
    (props) => usagePanel(props));
  ui.slots.register("conversation.header.utilities", { id: "usage", order: 30 }, (props) => usageChip(shell, props));
}
