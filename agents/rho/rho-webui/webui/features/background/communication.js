import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button } from "../../primitives/index.js";

// Links authorize messages, not assignments. Closing one leaves accepted
// requests and their original completion intact.
export function communicationPanel(shell, initialProps) {
  let props = initialProps;
  let identity = null;
  let rows = [];
  let after = null;
  let loading = false;
  let closing = null;
  let generation = 0;
  const reads = new AbortController();
  const failure = alert({ tone: "error" });
  const body = el("div");
  const refresh = button({ label: t("communication.refresh"), size: "sm", onClick: () => load() });
  const more = button({ label: t("communication.more"), size: "sm", onClick: () => load(after) });
  const element = el("section", { class: "background__group", "aria-label": t("communication.title") },
    el("h3", { class: "background__group-title", text: t("communication.title") }),
    el("p", { class: "background__help", text: t("communication.help") }),
    refresh, failure.element, body, more);
  const state = () => shell.conversations.state.get();
  const current = (version) => !reads.signal.aborted && generation === version;

  function paint() {
    element.hidden = !identity;
    refresh.disabled = loading || !!closing;
    more.hidden = !after;
    more.disabled = loading || !!closing;
    body.replaceChildren(...rows.map((link) => el("div", { class: "background__row", "data-link-id": link.public_id },
      el("span", { class: "background__text" },
        el("span", { class: "background__name", text: t("communication.peer") }),
        el("span", { class: "background__meta", text: link.peer.conversation_public_id })),
      button({ label: t("communication.close"), size: "sm", disabled: !props.conversation.writable || loading || !!closing,
        onClick: () => close(link.public_id) }))));
    if (!rows.length) body.append(el("p", { class: "background__meta", text: loading ? t("communication.loading") : t("communication.empty") }));
  }

  async function load(cursor = null) {
    const { id, workspace } = state();
    if (!id) return;
    const version = ++generation;
    loading = true;
    paint();
    const query = new URLSearchParams({ public_id: id, ...(workspace ? { workspace_public_id: workspace } : {}), ...(cursor ? { after: cursor } : {}) });
    try {
      const result = await shell.call(`/conversations/links?${query}`, { signal: reads.signal, conversation: id });
      if (!current(version)) return;
      rows = cursor ? [...rows, ...result.links] : result.links;
      after = result.pagination.next_after;
      failure.hide();
    } catch (problem) {
      if (current(version) && problem.name !== "AbortError" && problem.status !== 401) failure.show(problem.message || t("conversation.request_failed"));
    } finally {
      if (current(version)) { loading = false; paint(); }
    }
  }

  async function close(linkId) {
    if (closing || !props.conversation.writable) return;
    const { id, workspace } = state();
    const version = generation;
    closing = linkId;
    paint();
    try {
      await shell.call("/conversations/links/close", { method: "POST", signal: reads.signal, conversation: id,
        body: { public_id: id, link_public_id: linkId, ...(workspace ? { workspace_public_id: workspace } : {}) } });
      if (!current(version)) return;
      rows = rows.filter((link) => link.public_id !== linkId);
      failure.hide();
    } catch (problem) {
      if (current(version) && problem.name !== "AbortError" && problem.status !== 401) failure.show(problem.message || t("conversation.request_failed"));
    } finally {
      if (current(version)) { closing = null; paint(); }
    }
  }

  function sync() {
    const { id, workspace } = state();
    const next = id ? `${workspace}:${id}` : null;
    if (identity === next) return;
    identity = next;
    generation++;
    rows = [];
    after = null;
    closing = null;
    loading = false;
    failure.hide();
    paint();
    if (identity) load();
  }
  const unsubscribe = shell.conversations.state.subscribe(sync);
  sync();
  return { element, update(next) { props = next; paint(); }, dispose() { reads.abort(); unsubscribe(); } };
}
