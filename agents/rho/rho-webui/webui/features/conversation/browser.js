import { el, placeChildren, uniqueId } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { compactStamp, relativeStamp } from "../../kernel/format.js";
import { formatAddress } from "../../kernel/address.js";
import { button, icon, menuButton, skeleton, spinner, stateDot } from "../../primitives/index.js";

const composing = (event) => event.isComposing || event.keyCode === 229;
// A modified click opens the row's address in another tab, as links do.
const modified = (event) => (event.button ?? 0) !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey;
const titleOf = (row) => row.title || t("conversation.untitled");
const address = (row) => formatAddress({ conversation: row.public_id, workspace: row.workspace_public_id || null });
// The ingress channels holding the row — a bound conversation continues in
// its channel, and the page only reads it (`seat.ingress`).
const channelsOf = (row) => row.ingresses || [];

function rowView(conversations) {
  const lead = el("span", { class: "browser__lead", "aria-hidden": "true" });
  const title = el("span", { class: "browser__title" });
  const state = el("span", { class: "sr-only" });
  const channel = el("span", { class: "browser__channel", "aria-hidden": "true", hidden: true }, icon("channel"));
  // The visible time is the compact form; the full phrase is spoken from
  // `state` with the row's other facts.
  const time = el("time", { class: "browser__time", "aria-hidden": "true" });
  const link = el("a", { class: "browser__link", onclick: (event) => {
    if (modified(event)) return;
    event.preventDefault();
    conversations.select(row.public_id, { workspace: row.workspace_public_id });
  } }, lead, title, state, channel, time);
  const menu = menuButton({ variant: "icon", icon: "more", label: t("conversation.actions"), align: "end", items: () => {
    const locked = !!row.bot_public_id || channelsOf(row).length > 0;
    return [
      { type: "item", label: t("conversation.rename"), icon: "rename", disabled: locked, onSelect: rename },
      row.archived_at
        ? { type: "item", label: t("conversation.restore"), icon: "restore", disabled: locked, onSelect: () => conversations.restore(row.public_id) }
        : { type: "item", label: t("common.archive"), icon: "archive", disabled: locked, onSelect: () => conversations.archive(row.public_id) },
    ];
  } });
  menu.element.classList.add("browser__menu");
  const element = el("li", { class: "browser__row" }, link, menu.element);
  let row = null;
  let editing = false;

  // Inline rename: Enter saves, Escape or leaving the field cancels.
  function rename() {
    if (editing) return;
    editing = true;
    const field = el("input", { class: "control browser__rename", "aria-label": t("conversation.title_label"), autocomplete: "off" });
    field.value = row.title || "";
    let done = false;
    const close = (refocus) => {
      done = true; editing = false; field.remove(); link.hidden = false;
      title.textContent = titleOf(row);
      if (refocus) link.focus();
    };
    async function finish(save, refocus) {
      if (done || field.disabled) return;
      const next = field.value.trim();
      if (!save || !next || next === (row.title || "")) { close(refocus); return; }
      field.disabled = true;
      const renamed = await conversations.rename(row.public_id, next);
      if (done) return;
      if (renamed) { row = { ...row, title: next }; close(refocus); return; }
      field.disabled = false;
      field.focus();
    }
    field.addEventListener("keydown", (event) => {
      if (composing(event)) return;
      if (event.key === "Enter") { event.preventDefault(); finish(true, true); }
      else if (event.key === "Escape") { event.preventDefault(); finish(false, true); }
    });
    field.addEventListener("blur", () => finish(false, false));
    link.hidden = true;
    element.prepend(field);
    field.focus();
    field.select();
  }

  return {
    element,
    paint(next, selected) {
      row = next;
      link.href = address(row);
      if (selected) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current");
      element.classList.toggle("browser__row--archived", !!row.archived_at);
      if (!editing) title.textContent = titleOf(row);
      const at = row.last_activity_at || row.updated_at;
      time.textContent = compactStamp(at);
      if (at) time.setAttribute("datetime", at);
      const working = !!row.active_turn_public_id;
      lead.replaceChildren(...(working ? [spinner()] : row.attention ? [stateDot({ tone: "warn" })] : []));
      // The mark is one glyph, so the title keeps its width; the tooltip and
      // the row's spoken state carry the ingress's full label (chat, topic).
      const channels = channelsOf(row);
      const labels = channels.map((entry) => entry.label).join(" · ");
      channel.hidden = channels.length === 0;
      if (channels.length) channel.dataset.tip = labels; else delete channel.dataset.tip;
      const notes = [working ? t("browser.working") : row.attention ? t("browser.attention") : "",
        channels.length ? t("browser.bound", { channels: labels }) : "", relativeStamp(at)];
      state.textContent = notes.filter(Boolean).join(" · ");
    },
    dispose() { menu.dispose(); element.remove(); },
  };
}

// The server lists ordinary Main Agent conversations for this workspace.
// Bot history has its own page and never participates in this pagination.
export function conversationBrowser({ conversations }) {
  const heading = uniqueId("browser");
  const options = menuButton({ variant: "icon", icon: "more", label: t("shell.conversation_options"), align: "end", items: () => [
    { type: "check", label: t("shell.show_archived"), checked: conversations.list.get().archived,
      onSelect: () => conversations.setArchived(!conversations.list.get().archived) },
    { type: "item", label: t("common.refresh"), icon: "refresh", onSelect: () => conversations.refreshList() },
  ] });
  const groups = el("ul", { class: "browser__rows" });
  const status = el("div", { class: "browser__status" });
  const more = button({ label: t("browser.show_more"), variant: "ghost", size: "sm", onClick: () => conversations.refreshList({ more: true }) });
  more.classList.add("browser__more");
  const element = el("nav", { class: "browser", "aria-labelledby": heading },
    el("div", { class: "browser__head" }, el("h2", { class: "browser__label", id: heading, text: t("shell.conversations_section") }), options.element),
    el("div", { class: "browser__scroll" }, groups, status, more));
  const views = new Map();
  let selected = conversations.selection.get().id;

  function paintStatus({ rows: listed, archived, loading, loaded, error }) {
    if (listed.length) { status.replaceChildren(); return; }
    if (loading || !loaded) { status.replaceChildren(skeleton({ lines: 3 })); return; }
    if (error) {
      status.replaceChildren(el("p", { class: "browser__empty", text: error.message || t("conversation.request_failed") }),
        button({ label: t("common.refresh"), variant: "ghost", size: "sm", onClick: () => conversations.refreshList() }));
      return;
    }
    status.replaceChildren(el("p", { class: "browser__empty", text: archived ? t("browser.no_archived") : t("browser.empty") }));
  }

  function paint() {
    const value = conversations.list.get();
    const wanted = new Set(value.rows.map((row) => row.public_id));
    for (const [id, view] of views) if (!wanted.has(id)) { view.dispose(); views.delete(id); }
    placeChildren(groups, value.rows.map((row) => {
      if (!views.has(row.public_id)) views.set(row.public_id, rowView(conversations));
      const view = views.get(row.public_id);
      view.paint(row, row.public_id === selected);
      return view.element;
    }));
    paintStatus(value);
    more.hidden = !value.next;
    more.disabled = value.loading;
  }

  const stops = [
    conversations.list.subscribe(paint),
    conversations.selection.subscribe((context) => { if (context.id !== selected) { selected = context.id; paint(); } }),
  ];
  paint();
  return {
    element,
    update({ collapsed = false } = {}) { element.hidden = collapsed; },
    dispose() {
      for (const stop of stops) stop();
      for (const view of views.values()) view.dispose();
      views.clear();
      options.dispose();
      element.remove();
    },
  };
}
