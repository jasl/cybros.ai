import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, field, section as sectionControl, select as selectControl } from "../../primitives/index.js";

// Home belongs to the bot's settings, separately from its Telegram connection.
// The selected value never falls back to the browser or daemon workspace.
export function homeWorkspace(shell, agent, { saved }) {
  const reads = new AbortController();
  let current = agent.home_workspace_public_id || "";
  let rows = null;
  let dirty = false;
  let busy = false;
  let available = true;
  let reading = 0;
  const failure = alert({ tone: "error" });
  const select = selectControl({ name: "home_workspace_public_id" });
  const fields = el("fieldset", { class: "stack", disabled: true },
    field({ label: t("bots.home_label"), control: select, hint: t("bots.home_hint") }).element,
    el("div", { class: "row row--end" }, button({ label: t("bots.home_save"), variant: "primary", type: "submit" })));
  const markDirty = () => { dirty = true; };
  const form = el("form", { oninput: markDirty, onchange: markDirty, onsubmit: save }, fields);
  const section = sectionControl({ title: t("bots.home_title"), description: t("bots.home_description"), level: 3 });
  section.body.append(failure.element, form);

  function paint(value) {
    const choices = rows || [];
    select.replaceChildren(el("option", { value: "", text: t("bots.home_not_set") }),
      ...choices.map((row) => el("option", { value: row.public_id, text: row.name || row.public_id })));
    if (value && !choices.some((row) => row.public_id === value)) select.append(el("option", { value, text: t("bots.home_unavailable", { workspace: value }) }));
    select.value = value;
    fields.disabled = !available || rows === null || busy;
  }

  async function refresh() {
    const version = ++reading;
    try {
      const answer = await shell.call("/workspaces", { signal: reads.signal });
      if (reads.signal.aborted || version !== reading) return;
      rows = answer.workspaces;
      failure.hide();
      paint(dirty ? select.value : current);
    } catch (error) {
      if (reads.signal.aborted || version !== reading || error.name === "AbortError") return;
      rows = null;
      failure.show(error.message);
      paint(dirty ? select.value : current);
    }
  }

  async function save(event) {
    event.preventDefault();
    if (!available || rows === null || busy) return;
    const body = { agent_public_id: agent.public_id, home_workspace_public_id: select.value || null };
    busy = true;
    fields.disabled = true;
    failure.hide();
    try {
      const answer = await shell.call("/agents/settings", { method: "PUT", body, signal: reads.signal });
      if (reads.signal.aborted) return;
      current = answer.home_workspace_public_id || "";
      saved(answer.home_workspace_public_id);
      dirty = false;
      paint(current);
      shell.toast(t("bots.home_saved", { name: agent.display_name || agent.name }), { tone: "success" });
    } catch (error) {
      if (!reads.signal.aborted && error.name !== "AbortError") failure.show(error.message);
    } finally {
      busy = false;
      fields.disabled = !available || rows === null;
    }
  }

  paint(current);
  refresh();
  return { element: section.element, refresh,
    update(next, enabled) {
      available = enabled;
      if (next) current = next.home_workspace_public_id || "";
      paint(dirty ? select.value : current);
    },
    dispose() { reads.abort(); },
  };
}
