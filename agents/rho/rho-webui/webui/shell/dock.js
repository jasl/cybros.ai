import { el, placeChildren } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";
import { observable } from "../kernel/observable.js";
import { keyedOutlet } from "../kernel/outlets.js";
import { icon, iconButton } from "../primitives/button.js";
import { emptyState } from "../primitives/feedback.js";

// The right dock: tab types are `dock.tab` registrations; open tabs belong
// to the conversation they were opened in and come back when it is shown
// again. Open state and width are the frame's layout preferences.
export function createDock({ slots, shell, layout }) {
  const sets = new Map();
  const instances = new Map();
  const state = observable({ open: false, mode: "closed", conversation: null, tabs: [], active: null });
  let mode = "closed";

  const strip = el("div", { class: "dock__tabs", role: "tablist", "aria-label": t("shell.side_panel_tabs") });
  const closeButton = iconButton({ icon: "close", label: t("shell.close_side_panel"), onClick: () => close() });
  const body = el("div", { class: "dock__body" });
  const element = el("aside", { class: "dock", "aria-label": t("shell.side_panel"), hidden: true },
    el("div", { class: "dock__strip" }, strip, closeButton), body);

  const conversationKey = () => shell.conversations.selection.get().id ?? "new";
  function currentSet() {
    const key = conversationKey();
    if (!sets.has(key)) sets.set(key, { tabs: [], active: null });
    return sets.get(key);
  }
  const titleOf = (tab) => {
    const registration = slots.winner("dock.tab", tab.key);
    try { return registration?.meta.title(tab.params) || tab.key; } catch { return tab.key; }
  };
  const props = (tab) => ({ conversation: shell.conversations.selection.get(), params: tab.params, close: () => closeTab(tab.id) });

  function publish() {
    const set = currentSet();
    state.set({ open: layout.get().dockOpen, mode, conversation: conversationKey(), tabs: set.tabs.map((tab) => ({ ...tab, title: titleOf(tab) })), active: set.active });
  }

  // `open(null)` shows the dock with whatever it holds (the guide when empty).
  function open(key, { id = key, params = {} } = {}) {
    if (key !== null) {
      const set = currentSet();
      if (!set.tabs.some((tab) => tab.id === id)) set.tabs.push({ id, key, params });
      set.active = id;
    }
    if (!layout.get().dockOpen) layout.update((current) => ({ ...current, dockOpen: true }));
    render();
  }
  function close() {
    if (layout.get().dockOpen) layout.update((current) => ({ ...current, dockOpen: false }));
    render();
  }
  function toggle() { if (layout.get().dockOpen) close(); else open(null); }
  function closeTab(id) {
    const set = currentSet();
    const index = set.tabs.findIndex((tab) => tab.id === id);
    if (index === -1) return;
    set.tabs.splice(index, 1);
    const instance = instances.get(id);
    if (instance) { instance.outlet.dispose(); instance.pane.remove(); instances.delete(id); }
    if (set.active === id) set.active = (set.tabs[index] || set.tabs[index - 1])?.id ?? null;
    render();
  }
  function activate(id) { currentSet().active = id; render(); }

  function dropInstances() {
    for (const instance of instances.values()) { instance.outlet.dispose(); instance.pane.remove(); }
    instances.clear();
  }

  function guide() {
    const conversation = shell.conversations.selection.get();
    const entries = slots.entries("dock.tab").filter((registration) => registration.meta.description);
    return el("div", { class: "dock__guide" },
      el("span", { class: "dock__guide-icon" }, icon("compass")),
      el("p", { class: "dock__guide-title", text: t("shell.dock_guide_title") }),
      el("p", { class: "dock__guide-description", text: conversation.id ? t("shell.dock_guide_description") : t("shell.dock_guide_needs_conversation") }),
      el("div", { class: "dock__guide-entries" }, entries.map((registration) => el("button", {
        type: "button", class: "dock__guide-entry", disabled: !conversation.id, onclick: () => open(registration.cell) },
      el("span", { class: "dock__guide-glyph" }, icon(registration.meta.icon || "dock")),
      el("span", { class: "dock__guide-text" }, el("span", { class: "dock__guide-entry-title", text: titleOf({ key: registration.cell, params: {} }) }),
        el("span", { class: "dock__guide-entry-description", text: registration.meta.description() }))))));
  }

  function render() {
    const set = currentSet();
    const openNow = layout.get().dockOpen;
    element.hidden = !openNow;
    strip.replaceChildren(...set.tabs.map((tab) => {
      const selected = tab.id === set.active;
      const chip = el("div", { class: `dock__tab${selected ? " dock__tab--active" : ""}` },
        el("button", { type: "button", role: "tab", class: "dock__tab-button", "aria-selected": String(selected), tabindex: selected ? "0" : "-1",
          id: `dock-tab-${tab.id}`, "aria-controls": `dock-pane-${tab.id}`, onclick: () => activate(tab.id),
          onkeydown: (event) => {
            const tabs = [...strip.querySelectorAll("[role=tab]")];
            const index = tabs.indexOf(event.currentTarget);
            if (event.key === "ArrowRight") { event.preventDefault(); tabs[(index + 1) % tabs.length]?.focus(); }
            if (event.key === "ArrowLeft") { event.preventDefault(); tabs[(index - 1 + tabs.length) % tabs.length]?.focus(); }
          } }, el("span", { class: "dock__tab-title", text: titleOf(tab) })),
        el("button", { type: "button", class: "dock__tab-close", "aria-label": t("shell.close_tab", { title: titleOf(tab) }), onclick: () => closeTab(tab.id) }, icon("close")));
      return chip;
    }));
    if (openNow) {
      if (!set.tabs.length) {
        dropInstances();
        body.replaceChildren(guide());
      } else {
        body.querySelector(".dock__guide")?.remove();
        for (const tab of set.tabs) {
          if (!instances.has(tab.id)) {
            const pane = el("div", { class: "dock__pane", role: "tabpanel", id: `dock-pane-${tab.id}`, "aria-labelledby": `dock-tab-${tab.id}` });
            const outlet = keyedOutlet(slots, "dock.tab", pane, { onError: shell.renderError,
              fallback: () => ({ element: emptyState({ title: titleOf(tab), description: "" }) }) });
            instances.set(tab.id, { pane, outlet, key: tab.key });
            outlet.show(tab.key, props(tab));
          }
          instances.get(tab.id).pane.hidden = tab.id !== set.active;
        }
        placeChildren(body, set.tabs.map((tab) => instances.get(tab.id).pane));
      }
    }
    publish();
  }

  let lastConversation = conversationKey();
  const unsubscribe = shell.conversations.selection.subscribe(() => {
    const key = conversationKey();
    if (key !== lastConversation) { lastConversation = key; dropInstances(); body.replaceChildren(); render(); return; }
    for (const [id, instance] of instances) {
      const tab = currentSet().tabs.find((row) => row.id === id);
      if (tab) instance.outlet.update(props(tab));
    }
  });
  const unsubscribeSlots = slots.subscribe("dock.tab", () => { if (layout.get().dockOpen) render(); });

  return {
    element, state, open, close, toggle, closeTab,
    update({ mode: next }) {
      mode = next;
      element.classList.toggle("dock--overlay", next === "overlay");
      element.classList.toggle("dock--fullscreen", next === "fullscreen");
      if (layout.get().dockOpen && element.hidden) render(); else publish();
    },
    dispose() { unsubscribe(); unsubscribeSlots(); dropInstances(); element.remove(); },
  };
}
