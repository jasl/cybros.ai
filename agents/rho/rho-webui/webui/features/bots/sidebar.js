import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { uuidv7 } from "../../kernel/uuid.js";
import { iconButton, panelRow } from "../../primitives/index.js";
import { editable, PANEL } from "./page.js";

export function botsSidebar(ui, shell, initial) {
  let props = initial;
  const reads = new AbortController();
  const pending = new Set();
  const operations = new Map();
  const row = panelRow({ key: PANEL, icon: "bot", label: t("common.bots"), navigate: ui.navigate,
    onSelect: () => shell.router.push({ item: null }, { notify: true }) });
  const items = el("ul", { class: "sidebar__bots" });
  const element = el("div", {}, row.element, items);

  function settings(bot) {
    shell.router.push({ panel: PANEL, item: bot.public_id, plugin: null, conversation: null, workspace: null }, { notify: true });
    shell.navigate(PANEL);
  }

  async function open(bot) {
    if (pending.has(bot.public_id)) return;
    if (!operations.has(bot.public_id)) operations.set(bot.public_id, uuidv7());
    pending.add(bot.public_id); paint();
    try {
      const answer = await shell.call("/bots/current", { method: "POST", signal: reads.signal,
        body: { agent_public_id: bot.public_id, operation_id: operations.get(bot.public_id) } });
      if (reads.signal.aborted) return;
      operations.delete(bot.public_id);
      shell.conversations.select(answer.current.public_id, { workspace: answer.current.workspace_public_id });
    } catch (error) {
      if (!reads.signal.aborted && error.name !== "AbortError") {
        shell.toast(error.message || t("conversation.request_failed"), { tone: "error" });
        settings(bot);
      }
    } finally { pending.delete(bot.public_id); paint(); }
  }

  function paint() {
    row.update(props);
    items.hidden = !!props.collapsed;
    items.replaceChildren(...shell.bots.state.get().bots.filter(editable).map((bot) => el("li", { class: "sidebar__bot", "data-bot": bot.public_id },
      el("button", { type: "button", class: "sidebar__bot-name", text: bot.display_name || bot.name, disabled: pending.has(bot.public_id), onclick: () => open(bot) }),
      iconButton({ icon: "settings", label: t("bots.settings_for", { name: bot.display_name || bot.name }), onClick: () => settings(bot) }))));
  }

  const stop = shell.bots.state.subscribe(paint, { immediate: true });
  return { element, update(next) { props = next; paint(); }, dispose() { reads.abort(); stop(); row.dispose?.(); element.remove(); } };
}
