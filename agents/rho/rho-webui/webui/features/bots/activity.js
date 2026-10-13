import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { relativeStamp } from "../../kernel/format.js";
import { formatAddress } from "../../kernel/address.js";
import { uuidv7 } from "../../kernel/uuid.js";
import { alert, button, field, section, select, spinner, tag } from "../../primitives/index.js";

// Current selection belongs to the Bot. History rows carry their own workspace,
// including after Home changes; the browser never substitutes its workspace.
export function botActivity(shell, bot, { updated = () => {} } = {}) {
  const reads = new AbortController();
  const failure = alert({ tone: "error" });
  const welcome = el("p", { class: "bots-page__welcome", hidden: true });
  const note = el("p", { class: "text-secondary", role: "status" });
  const open = button({ label: t("bots.open_current"), size: "sm", onClick: () => switchTo("current") });
  const create = button({ label: t("common.new_conversation"), size: "sm", onClick: () => switchTo("new") });
  const current = section({ title: t("bots.current"), description: t("bots.current_hint"), actions: [open, create] });
  current.element.classList.add("bots-page__current");
  current.body.append(note, welcome);
  const filter = select({ name: "bot_history_archived", value: "all", options: [
    { value: "all", label: t("bots.history_all") }, { value: "0", label: t("bots.history_active") }, { value: "1", label: t("bots.history_archived") },
  ] });
  const rows = el("ul", { class: "bots-page__history" });
  const empty = el("p", { class: "text-secondary" });
  const more = button({ label: t("browser.show_more"), size: "sm", onClick: () => readHistory(true) });
  const history = section({ title: t("bots.history"), description: t("bots.history_hint") });
  history.body.append(field({ label: t("bots.history_filter"), control: filter }).element, rows, empty, more);
  const element = el("div", { class: "stack" }, failure.element, current.element, history.element);
  const operations = new Map();
  let detail = null;
  let entries = [];
  let next = null;
  let reading = 0;
  let detailReading = 0;
  let loading = false;
  let busy = false;

  function show(locator) {
    shell.conversations.select(locator.public_id, { workspace: locator.workspace_public_id });
  }

  function fail(error) {
    if (!reads.signal.aborted && error.name !== "AbortError") failure.show(error.message || t("conversation.request_failed"));
  }

  async function switchTo(action, row = null) {
    if (busy || reads.signal.aborted) return;
    const key = `${action}:${row?.public_id || ""}`;
    if (!operations.has(key)) operations.set(key, uuidv7());
    const body = { agent_public_id: bot.public_id, operation_id: operations.get(key), ...(row ? {
      conversation_public_id: row.public_id, workspace_public_id: row.workspace_public_id,
    } : {}) };
    busy = true; failure.hide(); paint();
    try {
      const answer = await shell.call(`/bots/${action}`, { method: "POST", body, signal: reads.signal });
      if (reads.signal.aborted) return;
      operations.delete(key);
      // A replay can name an earlier selected row. Open the current winner.
      show(answer.current);
      await refresh();
    } catch (error) { fail(error); }
    finally { busy = false; paint(); }
  }

  function paint() {
    const ready = !!detail;
    const home = detail?.bot.home_workspace_public_id;
    open.disabled = busy || !ready || (!detail.current && !home);
    create.disabled = busy || !ready || !home;
    note.textContent = !ready ? t("common.connecting") : detail.current ? t("bots.current_ready") : home ? t("bots.current_empty") : t("bots.home_required");
    welcome.textContent = detail?.effective_welcome_message || "";
    welcome.hidden = !welcome.textContent;
    rows.replaceChildren(...entries.map((row) => {
      const active = row.public_id === detail?.current?.public_id;
      const marks = [active ? tag({ tone: "quiet", text: t("bots.current") }) : null,
        row.archived_at ? tag({ tone: "quiet", text: t("bots.history_archived") }) : null,
        row.active_turn_public_id ? spinner({ label: t("browser.working") }) : row.attention ? tag({ tone: "warning", text: t("browser.attention") }) : null];
      const link = el("a", { class: "link-button", href: formatAddress({ conversation: row.public_id, workspace: row.workspace_public_id }),
        text: row.title || t("conversation.untitled"), onclick: (event) => {
          if ((event.button ?? 0) !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
          event.preventDefault(); show(row);
        } });
      return el("li", { class: "bots-page__history-row", "data-conversation": row.public_id },
        el("div", { class: "stack stack--tight grow" }, link, el("div", { class: "row row--wrap" }, ...marks.filter(Boolean),
          el("span", { class: "text-xxs text-tertiary", text: relativeStamp(row.last_activity_at || row.updated_at) }))),
        button({ label: t("bots.resume"), size: "sm", disabled: busy || active, onClick: () => switchTo("resume", row) }));
    }));
    empty.textContent = loading ? t("common.connecting") : t("bots.history_empty");
    empty.hidden = entries.length > 0;
    more.hidden = !next;
    more.disabled = loading || busy;
    filter.disabled = busy;
  }

  async function readDetail() {
    const version = ++detailReading;
    try {
      const answer = await shell.call(`/bots/detail?agent_public_id=${encodeURIComponent(bot.public_id)}`, { signal: reads.signal });
      if (reads.signal.aborted || version !== detailReading) return;
      detail = answer;
      updated(answer.bot);
      paint();
    } catch (error) { if (version === detailReading) fail(error); }
  }

  async function readHistory(more = false) {
    if (more && (!next || loading)) return;
    const version = ++reading;
    loading = true; paint();
    const query = new URLSearchParams({ agent_public_id: bot.public_id, limit: 30,
      ...(filter.value === "all" ? {} : { archived: filter.value }), ...(more ? { after: next } : {}) });
    try {
      const answer = await shell.call(`/bots/history?${query}`, { signal: reads.signal });
      if (reads.signal.aborted || version !== reading) return;
      entries = more ? [...entries, ...answer.conversations] : answer.conversations;
      next = answer.pagination?.next_after || null;
    } catch (error) { if (version === reading) fail(error); }
    finally { if (version === reading) { loading = false; paint(); } }
  }

  function refresh() { failure.hide(); return Promise.all([readDetail(), readHistory()]); }
  filter.addEventListener("change", () => { entries = []; next = null; readHistory(); });
  paint(); refresh();
  return { element, refresh, open: () => switchTo("current"), dispose() { reads.abort(); element.remove(); } };
}
