import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { listOutlet } from "../../kernel/outlets.js";
import { iconButton, menuButton, tag } from "../../primitives/index.js";
import { conversationControls } from "./lifecycle.js";
import { openMemoryBindings } from "./memory_bindings.js";

const composing = (event) => event.isComposing || event.keyCode === 229;

export function reviewDetail(review) {
  if (!review.enabled) return t("conversation.memory_review_off");
  if (review.outcome === "failed") return t("conversation.memory_review_failed");
  return t("conversation.memory_review_on");
}

// The conversation header: its title (renamed in place), the title menu, the
// utilities other features contribute, and the corner that opens the dock.
export function createHeader({ conversations, shell }) {
  const get = () => conversations.state.get();
  const title = el("h1", { class: "conversation__title" });
  const archived = tag({ tone: "neutral", text: t("conversation.archived") });
  const runner = el("span", { class: "conversation__runner" });
  const titleRow = el("div", { class: "conversation__heading" }, title, archived, runner);
  const menu = menuButton({ variant: "icon", icon: "more", label: t("conversation.actions"), items: () => menuItems() });
  const utilities = el("div", { class: "conversation__utilities" });
  const corner = iconButton({ icon: "dock", label: t("shell.open_side_panel"), onClick: () => shell.dock.toggle(),
    attrs: { class: "btn btn--ghost btn--icon btn--sm conversation__corner" } });
  const element = el("header", { class: "conversation__header" }, titleRow, menu.element, utilities, corner);
  let editor = null;
  let outlet = null;
  let outletFor;
  let shownReview;
  let memory;

  function menuItems() {
    const value = get();
    const controls = conversationControls(value.detail, value.access);
    const restore = !!value.detail?.archived_at;
    return [
      { type: "item", label: t("conversation.rename"), icon: "rename", disabled: !controls.writable, onSelect: rename },
      { type: "item", label: restore ? t("conversation.restore") : t("common.archive"), icon: restore ? "restore" : "archive",
        disabled: !controls.writable, onSelect: () => (restore ? conversations.restore(value.id) : conversations.archive(value.id)) },
      { type: "item", label: t("memory_bindings.title"), icon: "thought", disabled: !value.detail || value.access === "unavailable",
        onSelect: () => {
          memory?.dispose();
          memory = openMemoryBindings({ editor: conversations.memoryEditor(), writable: controls.send, id: value.id });
        } },
      ...(value.review ? [{ type: "separator" }, reviewItem(value, controls)] : []),
      { type: "separator" },
      { type: "item", label: t("common.refresh"), icon: "refresh", onSelect: () => conversations.refresh() },
      { type: "item", label: t("conversation.stop_all"), detail: t("conversation.stop_all_help"), icon: "stop", danger: true,
        disabled: !controls.stop, onSelect: () => conversations.stop() },
    ];
  }

  // One switch: a background review of each completed reply that keeps the
  // person's own memory document current, at one extra model call per reply.
  function reviewItem(value, controls) {
    const review = value.review;
    return { type: "check", label: t("conversation.memory_review"), icon: "thought", checked: !!review.enabled,
      detail: reviewDetail(review), disabled: !controls.writable || value.reviewBusy,
      onSelect: () => conversations.setMemoryReview(!review.enabled) };
  }

  // Enter saves, Escape or leaving the field cancels. Only the keyboard
  // paths return focus; a click elsewhere keeps the focus it moved.
  function rename() {
    const value = get();
    if (editor || !conversationControls(value.detail, value.access).writable) return;
    const field = el("input", { class: "control conversation__rename", "aria-label": t("conversation.title_label"), autocomplete: "off" });
    field.value = value.detail?.title || "";
    let done = false;
    const close = (refocus) => {
      done = true; field.remove(); editor = null; title.hidden = false;
      if (refocus) menu.element.focus();
    };
    editor = { id: value.id, cancel: () => close(false) };
    async function finish(save, refocus) {
      if (done || field.disabled) return;
      const next = field.value.trim();
      if (!save || !next || next === (value.detail?.title || "")) { close(refocus); return; }
      field.disabled = true;
      const renamed = await conversations.rename(value.id, next);
      if (done) return;
      if (renamed) { close(refocus); return; }
      field.disabled = false;
      field.focus();
    }
    field.addEventListener("keydown", (event) => {
      if (composing(event)) return;
      if (event.key === "Enter") { event.preventDefault(); finish(true, true); }
      else if (event.key === "Escape") { event.preventDefault(); finish(false, true); }
    });
    field.addEventListener("blur", () => finish(false, false));
    title.hidden = true;
    title.after(field);
    field.focus();
    field.select();
  }

  // Contributions are bound to one conversation: a new id is a new outlet,
  // the same id only updates its instances.
  function mountUtilities(context) {
    if (!shell.slots) return;
    if (outlet && outletFor === context.id) { outlet.update({ conversation: context }); return; }
    outlet?.dispose();
    outletFor = context.id;
    outlet = listOutlet(shell.slots, "conversation.header.utilities", utilities, { conversation: context }, { onError: shell.renderError });
  }

  function paint(value) {
    if (shownReview !== value.review) { shownReview = value.review; menu.refresh(); }
    title.textContent = value.id ? value.detail?.title || t("conversation.untitled") : t("common.new_conversation");
    archived.hidden = !value.detail?.archived_at;
    const bound = value.detail?.default_runner?.executor_public_id;
    const row = (value.runners || []).find((entry) => entry.public_id === bound);
    runner.textContent = value.id ? row?.display_name || bound || t("conversation.no_default_runner") : "";
    runner.hidden = !value.id || !value.detail;
    menu.element.hidden = !value.id;
    if (editor && value.id !== editor.id) editor.cancel();
    if (memory && value.id !== memory.id) { memory.dispose(); memory = null; }
  }

  const stops = [
    conversations.state.subscribe(paint, { immediate: true }),
    conversations.selection.subscribe(mountUtilities, { immediate: true }),
  ];
  return {
    element,
    dispose() { for (const stop of stops) stop(); outlet?.dispose(); menu.dispose(); memory?.dispose(); },
  };
}
