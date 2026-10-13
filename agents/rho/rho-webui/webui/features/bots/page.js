import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, emptyState, field, group, iconButton, input, modal, page, section, select, skeleton, tag } from "../../primitives/index.js";
import { listOutlet } from "../../kernel/outlets.js";
import { botActivity } from "./activity.js";
import { homeWorkspace } from "./home.js";
import { agentEditor, NAME_FORMAT, purposeOptions } from "./editor.js";

export const PANEL = "bots";
const botName = (bot) => bot.display_name || bot.name;
// New is the only reserved address beside a Bot public identity.
const NEW = "new";

// What a bot's row says under its name: the default agent's part, its
// description, and who published it when another member did.
export function botDetail(bot) {
  if (bot.own) return t("agents.own_description");
  const parts = [bot.description];
  if (bot.from) parts.push(t("agents.published_by", { handle: bot.from }));
  return parts.filter(Boolean).join(" · ");
}

// The selected Preset and effective model are projections, not Bot settings.
// A plugin owns its own configuration and channel workflow.
export function standingMarks(bot) {
  if (bot.own) return [];
  if (bot.registered) return [tag({ tone: "quiet", text: t("agents.plugin") })];
  const marks = bot.preset_name ? [tag({ tone: "quiet", text: bot.preset_name })] : [];
  if (bot.model_standing === "unset") marks.push(tag({ tone: "warning", text: t("agents.model_unset") }));
  else if (bot.model_standing === "unavailable") marks.push(tag({ tone: "warning", text: t("agents.model_unavailable", { model: bot.model }) }));
  else if (bot.model) marks.push(tag({ tone: "outline", text: bot.model }));
  if (bot.tools?.length) marks.push(tag({ tone: "outline", text: bot.tools.length === 1 ? t("agents.tool_one") : t("agents.tools", { count: bot.tools.length }) }));
  return marks;
}

// Whose settings page this is: the default agent's, the person's own bot's,
// or nobody's here (a sibling instance's, a plugin's).
export const editable = (bot) => !!bot && !bot.own && !bot.from && !bot.registered;

// A group of the page: its rows, or one line when it has none.
function shelf(title, actions = []) {
  const shelfGroup = group({ title, actions });
  const rows = el("div", { class: "bots-page__rows" });
  const note = el("p", { class: "bots-page__note text-tertiary", hidden: true });
  shelfGroup.body.append(note, rows);
  return {
    element: shelfGroup.element,
    paint(items, row, emptyText = "", { counted = true } = {}) {
      shelfGroup.setCount(counted ? items.length : null);
      rows.replaceChildren(...items.map(row));
      note.textContent = emptyText;
      note.hidden = !!items.length || !emptyText;
    },
  };
}

// The breadcrumb an agent's page opens with, the way a plugin's page does:
// the list, then the one page — its title — and Refresh at the row's end.
function crumbs(name, back, refresh) {
  return el("div", { class: "crumbs-row" },
    el("nav", { class: "crumbs", "aria-label": t("agents.breadcrumb") },
      el("ol", {}, el("li", {}, el("button", { type: "button", class: "link-button", text: t("common.bots"), onclick: back })),
        el("li", {}, el("span", { "aria-current": "page", text: name })))),
    iconButton({ icon: "refresh", label: t("common.refresh"), onClick: refresh }));
}

// Persistent identities remain separate from the Presets that configure them.
// Each Bot edits its identity and Preset reference here. Removed names stay
// reserved with readable history.
export function botsPage(shell) {
  const reads = new AbortController();
  const dialogs = new Set();
  const failure = alert({ tone: "error" });
  const loading = el("div", { class: "bots-page__loading", "aria-hidden": "true" }, skeleton({ lines: 3 }), skeleton({ lines: 3 }));
  const create = button({ label: t("agents.new"), size: "sm", variant: "primary", icon: "plus", onClick: () => openDetail(NEW) });
  const bots = shelf(t("common.bots"), [create]);
  const refresh = iconButton({ icon: "refresh", label: t("common.refresh"), onClick: () => { shell.setup.refresh(); load(); } });
  const scaffold = page({ title: t("common.bots"), description: t("agents.description"), actions: [refresh] });
  scaffold.body.append(failure.element, loading, bots.element);
  const list = scaffold.element;
  const element = el("div", { class: "bots-page" }, list);
  let busy = null;
  let catalog = null;
  let choicesError = null;
  let detail = null;
  let item = null;
  let visible = true;

  const alive = () => !reads.signal.aborted;
  const startWith = (bot) => { openDetail(bot.public_id); detail?.openCurrent?.(); };

  function error(problem) {
    if (!alive() || problem.name === "AbortError" || problem.status === 401) return;
    failure.show(problem.code === "member_plane_unavailable" ? t("conversation.member_plane_unavailable") : problem.message || t("agents.load_failed"));
  }

  async function readChoices() {
    try {
      const answer = await shell.call("/presets", { signal: reads.signal });
      if (alive()) { catalog = answer; choicesError = null; }
    } catch (problem) { choicesError = problem; error(problem); }
  }

  async function write(path, body, done) {
    if (busy || !alive()) return false;
    busy = body;
    paint();
    let written = false;
    try {
      const answer = await shell.call(path, { method: "POST", body, signal: reads.signal });
      if (!alive()) return false;
      failure.hide();
      shell.toast(done(answer), { tone: "success" });
      written = true;
    } catch (problem) { error(problem); }
    finally { busy = null; }
    await load();
    return written;
  }

  async function saveDuplicate(path, body, fields, localFailure, dialog) {
    if (fields.disabled || !alive()) return;
    fields.disabled = true;
    localFailure.hide();
    try {
      const answer = await shell.call(path, { method: "POST", body, signal: reads.signal });
      if (!alive()) return;
      shell.toast(t("agents.created", { name: botName(answer.agent) }), { tone: "success" });
      await load();
      if (dialog.element.open) { dialog.close(); openDetail(answer.agent.public_id); }
    } catch (problem) {
      if (alive() && problem.name !== "AbortError") localFailure.show(problem.message || t("conversation.request_failed"));
    } finally { fields.disabled = false; }
  }

  function openDialog(title, form, submitLabel, focus) {
    const dialog = modal({ title, body: form,
      actions: [button({ label: t("common.cancel"), onClick: () => dialog.close() }),
        button({ label: submitLabel, variant: "primary", onClick: () => form.requestSubmit() })],
      onClose: () => { dialogs.delete(dialog); dialog.element.remove(); } });
    dialogs.add(dialog);
    dialog.open();
    focus.focus();
    return dialog;
  }

  function duplicate(bot) {
    const name = input({ name: "name", autocomplete: "off", required: true });
    const nameField = field({ label: t("agents.name"), control: name, hint: t("agents.name_hint") });
    const displayName = input({ name: "display_name", value: bot.display_name || "", autocomplete: "off" });
    const purpose = select({ name: "audience", value: bot.audience || "owner", options: purposeOptions() });
    const localFailure = alert({ tone: "error" });
    const fields = el("fieldset", { class: "settings-form__fields" }, nameField.element,
      field({ label: t("agents.display_name"), control: displayName }).element,
      field({ label: t("agents.purpose"), control: purpose }).element);
    const form = el("form", { class: "settings-form", onsubmit: (event) => {
      event.preventDefault();
      if (!NAME_FORMAT.test(name.value.trim())) { nameField.setError(t("agents.name_hint")); name.focus(); return; }
      nameField.setError(null);
      saveDuplicate("/agents/duplicate", { source_name: bot.name, name: name.value.trim(),
        display_name: displayName.value.trim() || null, audience: purpose.value }, fields, localFailure, dialog);
    } }, el("p", { class: "field__hint", text: t("agents.duplicate_hint") }), fields, localFailure.element);
    const dialog = openDialog(t("agents.duplicate_title", { name: botName(bot) }), form, t("agents.duplicate"), name);
  }

  function duplicateCard(getBot) {
    const card = section({ title: t("agents.duplicate"), description: t("agents.duplicate_hint") });
    card.body.append(button({ label: t("agents.duplicate"), size: "sm", onClick: () => duplicate(getBot()) }));
    return card;
  }

  function confirmRemoval(bot) {
    const remove = button({ label: t("common.remove"), variant: "danger", onClick: async () => {
      dialog.close();
      if (await write("/agents/rm", { name: bot.name }, () => t("agents.removed", { name: botName(bot) }))) openList();
    } });
    const dialog = modal({ title: t("agents.remove_title", { name: botName(bot) }),
      body: el("p", { class: "text-secondary", text: t("agents.remove_body") }),
      actions: [button({ label: t("common.cancel"), onClick: () => dialog.close() }), remove],
      onClose: () => dialog.element.remove() });
    dialog.open();
    remove.focus();
  }

  // ---- the list ----

  // The same two actions on every row, as icons: a conversation, settings.
  // A bot another instance published, or a plugin's, has no settings here.
  function botRow(bot) {
    const settingsLabel = editable(bot) ? t("agents.settings") : t("agents.settings_unavailable");
    const name = el("button", { type: "button", class: "bots-page__name link-button", text: botName(bot), onclick: () => openDetail(bot.public_id),
      disabled: !(editable(bot)) });
    const actions = el("div", { class: "bots-page__actions" },
      iconButton({ icon: "new", label: t("bots.open_current"), disabled: !editable(bot), onClick: () => startWith(bot) }),
      iconButton({ icon: "settings", label: settingsLabel, disabled: !(editable(bot)), onClick: () => openDetail(bot.public_id) }));
    return el("article", { class: "bots-page__bot", "data-bot": bot.name },
      el("div", { class: "bots-page__text" },
        el("div", { class: "bots-page__head" }, name, el("span", { class: "bots-page__marks" }, standingMarks(bot))),
        el("p", { class: "bots-page__detail", text: botDetail(bot) })),
      actions);
  }

  function paint() {
    const value = shell.bots.state.get();
    loading.hidden = value.loaded || !value.loading;
    bots.paint(value.bots, botRow, t("agents.no_bots"));
    if (value.error || choicesError) error(value.error || choicesError); else failure.hide();
  }

  // ---- one agent's settings page ----

  // The breadcrumb, the form, and — last, for one of this instance's own
  // bots — its removal. A new bot's page is the form alone.
  function agentPage(id) {
    let bot = id === NEW ? null : shell.bots.state.get().bots.find((row) => row.public_id === id) || null;
    if (id !== NEW && (!bot || !editable(bot))) {
      // Before the listing answers, or for an identity it does not hold.
      const missing = emptyState({ icon: "bot", title: t("agents.missing"), action: button({ label: t("common.back"), size: "sm", onClick: openList }) });
      return { element: el("div", { class: "bots-page__page" }, crumbs(t("agents.missing"), openList, load), missing), missing: true, focus() {}, dispose() {} };
    }
    const editor = agentEditor({ shell, bot, catalog, onClose: openList,
      onCreated: async (created) => { await load(); openDetail(created.public_id); }, onSaved: (saved) => { bot = { ...bot, ...saved }; shell.bots.refresh(); activity?.refresh(); } });
    const pluginHost = el("div", { class: "stack bots-page__connections" });
    let pluginOutlet = null;
    const refresh = () => Promise.all([load(), activity?.refresh()]);
    const updateBot = (next) => {
      bot = { ...bot, ...next };
      home?.update(bot, true);
      pluginOutlet?.update({ bot, refresh });
    };
    const home = bot ? homeWorkspace(shell, bot, { saved: () => { activity.refresh(); shell.bots.refresh(); } }) : null;
    const activity = bot ? botActivity(shell, bot, { updated: updateBot }) : null;
    if (bot) pluginOutlet = listOutlet(shell.slots, "bots.item.config", pluginHost, { bot, refresh }, { onError: shell.renderError });
    const duplicate = bot && editable(bot) ? duplicateCard(() => bot) : null;
    const removal = bot && editable(bot) ? section({ title: t("agents.remove"), description: t("agents.remove_help") }) : null;
    if (removal) {
      removal.body.append(button({ label: t("common.remove"), size: "sm", variant: "danger", icon: "close", onClick: () => confirmRemoval(bot) }));
      removal.element.classList.add("bots-page__removal");
    }
    const view = el("div", { class: "bots-page__page", tabindex: "-1" }, crumbs(bot ? botName(bot) : t("agents.new"), openList, refresh), activity?.element || null, home?.element || null, editor.element, pluginHost,
      duplicate?.element || null, removal?.element || null);
    return { element: view, focus: () => bot ? view.focus({ preventScroll: true }) : editor.focus(), openCurrent: () => activity?.open(), updateChoices: () => editor.updateChoices(catalog),
      dispose() { editor.dispose(); home?.dispose(); activity?.dispose(); pluginOutlet?.dispose(); view.remove(); } };
  }

  function route(next) {
    if (next === item && (next === null || detail)) return;
    item = next;
    detail?.dispose();
    detail = null;
    if (next === null) { element.replaceChildren(list); return; }
    detail = agentPage(next);
    element.replaceChildren(detail.element);
    element.scrollTop = 0;
    if (visible) detail.focus();
  }
  function openDetail(next) { shell.router.push({ panel: PANEL, item: next }); route(next); }
  function openList() { shell.router.push({ item: null }); route(null); }

  async function load() {
    await Promise.all([shell.bots.refresh(), readChoices()]);
    if (!alive()) return;
    paint();
    // A bot's page opened before the listing answered is drawn once it has.
    if (detail?.missing) {
      detail.dispose();
      detail = agentPage(item);
      element.replaceChildren(detail.element);
    } else detail?.updateChoices();
  }

  const stops = [shell.bots.state.subscribe(paint, { immediate: true }),
    shell.router.subscribe((address) => { if (address.panel === PANEL) route(address.item || null); })];
  route(shell.router.read().panel === PANEL ? shell.router.read().item || null : null);
  load();

  return {
    element,
    // The main outlet keeps the page mounted behind other panels and says
    // when it returns: the agents are reread then, and the address's item shown.
    update({ visible: next = true } = {}) {
      if (next && !visible) { load(); route(shell.router.read().panel === PANEL ? shell.router.read().item || null : item); }
      if (!next) for (const dialog of dialogs) dialog.close();
      visible = next;
    },
    dispose() { reads.abort(); for (const dialog of dialogs) dialog.close(); detail?.dispose(); for (const stop of stops) stop(); element.remove(); },
  };
}
