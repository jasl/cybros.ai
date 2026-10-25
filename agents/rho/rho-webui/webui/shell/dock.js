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
  let visible = true;

  const strip = el("div", { class: "dock__tabs", role: "tablist", "aria-label": t("shell.side_panel_tabs") });
  const addButton = iconButton({ icon: "plus", label: t("shell.new_tab"), onClick: showTools });
  const closeButton = iconButton({ icon: "close", label: t("shell.close_side_panel"), onClick: () => close() });
  const body = el("div", { class: "dock__body" });
  const element = el("aside", { class: "dock", "aria-label": t("shell.side_panel"), hidden: true },
    el("div", { class: "dock__strip" }, strip, addButton, closeButton), body);
  element.addEventListener("keydown", (event) => {
    if (mode === "fullscreen" && event.key === "Escape" && !event.defaultPrevented) {
      // Native pickers can close before their Escape reaches this handler.
      if (event.target.matches("select, input[type=datetime-local], input[type=date], input[type=time]")) return;
      event.preventDefault();
      close();
    }
  });

  const conversationKey = () => shell.conversations.selection.get().id ?? "new";
  function currentSet() {
    const key = conversationKey();
    if (!sets.has(key)) sets.set(key, { tabs: [], active: null });
    return sets.get(key);
  }
  const titleOf = (tab) => {
    if (tab.key === null) return t("shell.new_tab");
    const registration = slots.winner("dock.tab", tab.key);
    try { return registration?.meta.title(tab.params) || tab.key; } catch { return tab.key; }
  };
  const props = (tab) => ({ conversation: shell.conversations.selection.get(), params: tab.params, actions: instances.get(tab.id)?.actions, beforeClose(handler) { instances.get(tab.id).beforeClose = handler; }, updateParams(params) {
    tab.params = params;
    render();
  }, close: () => closeTab(tab.id) });

  function publish() {
    const set = currentSet();
    state.set({ open: visible && layout.get().dockOpen, mode, conversation: conversationKey(), tabs: set.tabs.map((tab) => ({ ...tab, title: titleOf(tab) })), active: set.active });
  }

  // `open(null)` shows the dock with whatever it holds (the guide when empty).
  function open(key, { id = key, params } = {}) {
    if (key !== null) {
      const set = currentSet();
      const existing = set.tabs.find((tab) => tab.id === id);
      if (!existing) set.tabs.push({ id, key, params: params || {} });
      else if (params !== undefined) {
        existing.params = params;
        instances.get(id)?.outlet.update(props(existing));
      }
      set.active = id;
    }
    if (!layout.get().dockOpen) layout.update((current) => ({ ...current, dockOpen: true }));
    render();
  }
  function showTools() {
    const set = currentSet();
    if (!set.tabs.some((tab) => tab.id === "new-tab")) set.tabs.push({ id: "new-tab", key: null, params: {} });
    set.active = "new-tab";
    open(null);
  }
  function close() {
    if (layout.get().dockOpen) layout.update((current) => ({ ...current, dockOpen: false }));
    render();
  }
  function toggle() { if (layout.get().dockOpen) close(); else open(null); }
  async function closeTab(id) {
    const set = currentSet();
    const index = set.tabs.findIndex((tab) => tab.id === id);
    if (index === -1) return;
    const tab = set.tabs[index];
    const instance = instances.get(id);
    if (instance?.closing) return;
    if (instance?.beforeClose) {
      const registration = slots.winner("dock.tab", tab.key);
      instance.closing = true;
      render();
      try { if (await instance.beforeClose() === false) return; }
      catch (error) { shell.renderError(error, { registration, phase: "close" }); return; }
      finally { instance.closing = false; render(); }
    }
    // Selection may change while a panel completes its close operation.
    const currentIndex = set.tabs.indexOf(tab);
    if (currentIndex === -1) return;
    set.tabs.splice(currentIndex, 1);
    if (instance && instances.get(id) === instance) { instance.outlet?.dispose(); instance.pane.remove(); instances.delete(id); }
    if (set.active === id) set.active = (set.tabs[currentIndex] || set.tabs[currentIndex - 1])?.id ?? null;
    render();
  }
  function activate(id) { currentSet().active = id; render(); }

  function dropInstances() {
    for (const instance of instances.values()) { instance.outlet?.dispose(); instance.pane.remove(); }
    instances.clear();
  }

  function guide() {
    const conversation = shell.conversations.selection.get();
    const entries = slots.entries("dock.tab").filter((registration) => registration.meta.description);
    return el("div", { class: "dock__guide" },
      el("span", { class: "dock__guide-icon" }, icon("compass")),
      el("p", { class: "dock__guide-title", text: t("shell.dock_guide_title") }),
      el("p", { class: "dock__guide-description", text: conversation.id || entries.some(({ meta }) => meta.requiresConversation === false) ? t("shell.dock_guide_description") : t("shell.dock_guide_needs_conversation") }),
      el("div", { class: "dock__guide-entries" }, entries.map((registration) => el("button", {
        type: "button", class: "dock__guide-entry", disabled: !conversation.id && registration.meta.requiresConversation !== false, onclick: () => { open(registration.cell); closeTab("new-tab"); } },
      el("span", { class: "dock__guide-glyph" }, icon(registration.meta.icon || "dock")),
      el("span", { class: "dock__guide-text" }, el("span", { class: "dock__guide-entry-title", text: titleOf({ key: registration.cell, params: {} }) }),
        el("span", { class: "dock__guide-entry-description", text: registration.meta.description() }))))));
  }

  function render() {
    const set = currentSet();
    const openNow = visible && layout.get().dockOpen;
    element.hidden = !openNow;

    if (openNow) {
      if (!set.tabs.length) {
        dropInstances();
        body.replaceChildren(guide());
      } else {
        for (const child of [...body.children]) { if (child.classList.contains("dock__guide")) child.remove(); }
        for (const tab of set.tabs) {
          if (!instances.has(tab.id)) {
            const pane = el("div", { class: "dock__pane", role: "tabpanel", id: `dock-pane-${tab.id}`, "aria-labelledby": `dock-tab-${tab.id}` });
            if (tab.key === null) {
              pane.append(guide());
              instances.set(tab.id, { pane });
              continue;
            }
            pane.classList.toggle("dock__pane--fill", !!slots.winner("dock.tab", tab.key)?.meta.fill);
            const outlet = keyedOutlet(slots, "dock.tab", pane, { onError: shell.renderError,
              fallback: () => ({ element: emptyState({ title: titleOf(tab), description: "" }) }) });
            instances.set(tab.id, { pane, outlet, key: tab.key, actions: el("span", { class: "dock__tab-actions" }) });
            outlet.show(tab.key, props(tab));
          }
        }
        for (const tab of set.tabs) instances.get(tab.id).pane.hidden = tab.id !== set.active;
        placeChildren(body, set.tabs.map((tab) => instances.get(tab.id).pane));
      }
    }
    strip.replaceChildren(...set.tabs.map((tab) => {
      const selected = tab.id === set.active;
      const chip = el("div", { class: `dock__tab${selected ? " dock__tab--active" : ""}` },
        el("button", { type: "button", role: "tab", class: "dock__tab-button", title: titleOf(tab), "aria-selected": String(selected), tabindex: selected ? "0" : "-1",
          id: `dock-tab-${tab.id}`, "aria-controls": `dock-pane-${tab.id}`, onclick: () => activate(tab.id),
          onkeydown: (event) => {
            const tabs = [...strip.querySelectorAll("[role=tab]")];
            const index = tabs.indexOf(event.currentTarget);
            if (event.key === "ArrowRight") { event.preventDefault(); tabs[(index + 1) % tabs.length]?.focus(); }
            if (event.key === "ArrowLeft") { event.preventDefault(); tabs[(index - 1 + tabs.length) % tabs.length]?.focus(); }
          } }, icon(slots.winner("dock.tab", tab.key)?.meta.icon || "dock"), el("span", { class: "dock__tab-title", text: titleOf(tab) })),
        instances.get(tab.id)?.actions,
        el("button", { type: "button", class: "dock__tab-close", disabled: !!instances.get(tab.id)?.closing, "aria-label": t("shell.close_tab", { title: titleOf(tab) }), onclick: () => closeTab(tab.id) }, icon("close")));
      return chip;
    }));
    if (openNow) revealActive();
    publish();
  }

  function revealActive() {
    strip.querySelector(".dock__tab--active")?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  let lastConversation = conversationKey();
  const unsubscribe = shell.conversations.selection.subscribe(() => {
    const key = conversationKey();
    if (key !== lastConversation) { lastConversation = key; dropInstances(); body.replaceChildren(); render(); return; }
    for (const [id, instance] of instances) {
      const tab = currentSet().tabs.find((row) => row.id === id);
      if (tab) instance.outlet?.update(props(tab));
    }
  });
  const unsubscribeSlots = slots.subscribe("dock.tab", () => {
    // Removing a contribution removes its views, without invoking user Close.
    for (const set of sets.values()) {
      set.tabs = set.tabs.filter((tab) => tab.key === null || slots.winner("dock.tab", tab.key));
      if (!set.tabs.some((tab) => tab.id === set.active)) set.active = set.tabs.at(-1)?.id ?? null;
    }
    for (const [id, instance] of instances) {
      if (instance.key && !slots.winner("dock.tab", instance.key)) {
        instance.outlet?.dispose(); instance.pane.remove(); instances.delete(id);
      }
    }
    for (const instance of instances.values()) {
      if (!instance.outlet) instance.pane.replaceChildren(guide());
    }
    render();
  });

  return {
    element, state, open, close, toggle, closeTab,
    focusClose: () => closeButton.focus(),
    update({ mode: next, visible: nextVisible = true }) {
      mode = next;
      visible = nextVisible;
      element.classList.toggle("dock--overlay", next === "overlay");
      element.classList.toggle("dock--fullscreen", next === "fullscreen");
      if (element.hidden === (visible && layout.get().dockOpen)) render(); else publish();
      if (!element.hidden) revealActive();
    },
    dispose() { unsubscribe(); unsubscribeSlots(); dropInstances(); element.remove(); },
  };
}
