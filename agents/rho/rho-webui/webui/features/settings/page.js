import { el, uniqueId } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { keyedOutlet } from "../../kernel/outlets.js";
import { alert, emptyState, iconButton, page, spinner } from "../../primitives/index.js";

// Settings is a main page — the container the conversation uses — at
// `/panels/settings`: the sections down one side, the chosen section
// beside them; each `settings.section` registration is one section. The
// document every section edits comes from the shell's setup owner, so a
// save in one is visible in the others. `shell.settings.request` carries
// the section an opener asked for (the setup notice: General), a fresh
// request each time; choosing a tab here is the page's own state.
export function settingsPage(shell) {
  const { slots } = shell;
  const prefix = uniqueId("settings");
  const nav = el("nav", { class: "settings-page__nav", role: "tablist", "aria-orientation": "vertical", "aria-label": t("shell.settings_sections") });
  const heading = el("h2", { class: "settings-page__section-title" });
  const busy = spinner({ label: t("common.connecting") });
  const content = el("div", { class: "settings-page__content", role: "tabpanel" });
  const refresh = iconButton({ icon: "refresh", label: t("common.refresh"), onClick: () => shell.setup.refresh() });
  const loadError = alert({ tone: "error" });
  const scaffold = page({ title: t("common.settings"), description: t("settings.guide"), actions: [busy, refresh] });
  scaffold.body.append(loadError.element, el("div", { class: "settings-page" }, nav, el("div", { class: "settings-page__main" }, heading, content)));
  const outlet = keyedOutlet(slots, "settings.section", content, { onError: shell.renderError,
    fallback: () => ({ element: emptyState({ title: t("common.settings"), description: "" }) }) });
  let current = shell.settings.request.get()?.section ?? null;
  let visible = true;

  const sectionProps = () => {
    const { document, status, identity } = shell.setup.state.get();
    return { document, status, identity, visible, request: shell.settings.request.get(), save: shell.setup.save, refresh: shell.setup.refresh };
  };

  function paintNav() {
    const sections = slots.entries("settings.section");
    if (current === null || !sections.some((section) => section.cell === current)) current = sections[0]?.cell ?? null;
    nav.replaceChildren(...sections.map((section) => {
      const selected = section.cell === current;
      return el("button", { type: "button", role: "tab", id: `${prefix}-${section.cell}`, class: `settings-page__tab${selected ? " settings-page__tab--active" : ""}`,
        "aria-selected": String(selected), tabindex: selected ? "0" : "-1", text: section.meta.label(),
        onclick: () => show(section.cell),
        onkeydown: (event) => {
          const all = [...nav.querySelectorAll("[role=tab]")];
          const index = all.indexOf(event.currentTarget);
          if (event.key === "ArrowDown" || event.key === "ArrowRight") { event.preventDefault(); all[(index + 1) % all.length]?.focus(); }
          if (event.key === "ArrowUp" || event.key === "ArrowLeft") { event.preventDefault(); all[(index - 1 + all.length) % all.length]?.focus(); }
        } });
    }));
    const active = sections.find((section) => section.cell === current);
    heading.textContent = active ? active.meta.label() : "";
    if (active) { content.setAttribute("aria-labelledby", `${prefix}-${active.cell}`); outlet.show(active.cell, sectionProps()); }
  }

  function show(key) {
    current = key;
    scaffold.element.scrollTop = 0;
    paintNav();
    nav.querySelector("[aria-selected=true]")?.focus({ preventScroll: true });
  }

  const disposers = [
    slots.subscribe("settings.section", paintNav),
    shell.setup.state.subscribe((state) => {
      busy.hidden = !state.loading;
      if (state.error) loadError.show([t("settings.refresh_failed"), state.error.message].filter(Boolean).join(" "));
      else loadError.hide();
      outlet.update(sectionProps());
    }, { immediate: true }),
    // An opener naming a section moves the page to it; its own tab choice stands otherwise.
    shell.settings.request.subscribe((request) => {
      if (request?.section && request.section !== current) {
        current = request.section;
        scaffold.element.scrollTop = 0;
        paintNav();
      }
      else outlet.update(sectionProps());
    }),
  ];
  paintNav();
  // The documents are reread whenever the page comes into view: the main
  // outlet keeps it mounted behind other panels and says when it returns.
  shell.setup.refresh();

  return {
    element: scaffold.element,
    update({ visible: next = true } = {}) {
      if (next && !visible) shell.setup.refresh();
      visible = next;
      outlet.update(sectionProps());
    },
    dispose() { for (const dispose of disposers) dispose(); outlet.dispose(); scaffold.element.remove(); },
  };
}
