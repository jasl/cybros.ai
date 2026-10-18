import { el, placeChildren } from "../../kernel/dom.js";
import { t, pluginText } from "../../kernel/i18n.js";
import { alert, emptyState, group, iconButton, page, skeleton, switchControl, tag } from "../../primitives/index.js";
import { pluginDetail } from "./detail.js";
import { packagesCard } from "./packages.js";
import { CATEGORIES, categoryLabel, hasSettings, initial, lockReason, moduleFailure, pageLocks, pluginStatus, pluginVersion } from "./switching.js";

const SKELETONS = 4;

function pluginCard(id, { open, switching, slots }) {
  const tile = el("span", { class: "plugin-tile", "aria-hidden": "true" });
  const title = el("button", { type: "button", class: "plugin-card__title", onclick: () => open(id) });
  const version = el("span", { class: "plugin-card__version text-tertiary", hidden: true });
  const description = el("p", { class: "plugin-card__description" });
  const status = el("span", { class: "plugin-card__status" });
  const failure = alert({ tone: "error" });
  let row = null;
  let lock = null;
  const toggle = switchControl({ label: "", onChange: () => {
    const done = switching.change(row, toggle.input.checked);
    paintSwitch();
    done.then(paintSwitch);
  } });
  // The gear opens the same page as the title; it is there so a plugin
  // with settings looks like one.
  const settings = iconButton({ icon: "settings", label: "", onClick: () => open(id) });
  const element = el("article", { class: "plugin-card", "data-plugin-id": id },
    el("div", { class: "plugin-card__head" }, tile,
      el("div", { class: "plugin-card__text" }, el("div", { class: "plugin-card__name" }, title, version), description)),
    failure.element, el("div", { class: "plugin-card__foot" }, status, el("span", { class: "row" }, settings, toggle.element)));

  // A locked switch stays on and says why on hover; the detail page says it in full.
  function paintSwitch() {
    const busy = switching.busy(id);
    toggle.input.setAttribute("aria-label", t("plugin_page.switch_label", { name: pluginText(row, "name") }));
    toggle.set(busy ? toggle.input.checked : row.enabled, { disabled: busy || !!lock || (!row.enabled && row.configurable === false) });
    if (lock) toggle.element.dataset.tip = lockReason(lock, row); else delete toggle.element.dataset.tip;
  }

  return {
    element,
    focus() { title.focus(); },
    paint(next, module, nextLock) {
      row = next;
      lock = nextLock;
      const name = pluginText(row, "name");
      tile.textContent = initial(name);
      title.textContent = name;
      const shown = pluginVersion(row);
      version.textContent = shown ? t("plugin_page.version", { version: shown }) : "";
      version.hidden = !shown;
      description.textContent = pluginText(row, "description");
      const state = pluginStatus(row);
      status.replaceChildren(...(state ? [tag(state)] : []));
      settings.hidden = !hasSettings(row, slots);
      settings.setAttribute("aria-label", t("plugin_page.settings_for", { name }));
      settings.dataset.tip = settings.getAttribute("aria-label");
      if (module?.status === "failed") failure.show(moduleFailure(module)); else failure.hide();
      paintSwitch();
    },
  };
}

// A category's group of cards, shown when it holds any.
function categoryGroup(title) {
  const cards = group({ title, attrs: { class: "group plugins__group" } });
  const grid = el("div", { class: "plugins__grid" });
  cards.body.append(grid);
  cards.element.hidden = true;
  return { element: cards.element, grid, setCount: cards.setCount };
}

// The Plugins page: installed plugins grouped by category, each card with
// its version, status and switch, the managed packages at the bottom, and one
// plugin's detail at `/plugins/<id>`. The inventory owner is the only reader
// of `/extensions`; the page refreshes it whenever it is shown.
export function pluginsPage(shell, switching) {
  const refresh = iconButton({ icon: "refresh", label: t("common.refresh"), onClick: () => { shell.inventory.refresh(); packages.refresh(); } });
  const loadError = alert({ tone: "error" });
  const failures = alert({ tone: "error" });
  const skeletons = el("div", { class: "plugins__grid", "aria-hidden": "true" },
    Array.from({ length: SKELETONS }, () => el("div", { class: "plugin-card plugin-card--skeleton" }, skeleton({ lines: 3 }))));
  const empty = emptyState({ icon: "plugins", title: t("plugin_settings.no_optional_plugins_are_installed") });
  // One group per category, in a fixed order, so a switch never moves a card.
  const groups = new Map(CATEGORIES.map((category) => [category, categoryGroup(categoryLabel(category))]));
  const packages = packagesCard(shell);
  const scaffold = page({ title: t("common.plugins"), description: t("plugin_settings.choose_which_capabilities_rho_provides_disabled_plugins_keep"), actions: [refresh] });
  scaffold.body.append(loadError.element, failures.element, skeletons, empty, ...[...groups.values()].map((entry) => entry.element), packages.element);
  const list = scaffold.element;
  const element = el("section", { class: "plugins", "aria-label": t("common.plugins") }, list);
  const cards = new Map();
  let detail = null;
  let detailId = null;
  let visible = false;

  const cardFor = (id) => {
    if (!cards.has(id)) cards.set(id, pluginCard(id, { open: openDetail, switching, slots: shell.slots }));
    return cards.get(id);
  };

  function fill(target, rows, modules, locks) {
    target.element.hidden = !rows.length;
    target.setCount(rows.length);
    placeChildren(target.grid, rows.map((row) => {
      const card = cardFor(row.id);
      card.paint(row, modules.get(row.id), locks.get(row.id) || null);
      return card.element;
    }));
  }

  function paint() {
    const state = shell.inventory.state.get();
    const modules = shell.modules.state.get();
    if (state.error) loadError.show(state.error.message || t("plugin_page.load_failed")); else loadError.hide();
    const text = (state.failures || []).map((failure) => `${failure.id}: ${failure.message}`).join("\n");
    if (text) failures.show(text); else failures.hide();
    skeletons.hidden = state.loaded || !!state.error;
    empty.hidden = !state.loaded || state.plugins.length > 0;
    const locks = pageLocks(state.plugins);
    for (const [category, target] of groups) {
      fill(target, state.plugins.filter((row) => (CATEGORIES.includes(row.category) ? row.category : "other") === category), modules, locks);
    }
    const present = new Set(state.plugins.map((row) => row.id));
    for (const [id, card] of cards) if (!present.has(id)) { card.element.remove(); cards.delete(id); }
  }

  function route(id) {
    if (id === detailId) return;
    const previous = detailId;
    detailId = id;
    detail?.dispose();
    detail = null;
    if (id) {
      detail = pluginDetail(shell, { id, switching, back: openList });
      element.replaceChildren(detail.element);
      if (visible) detail.focus();
    } else {
      element.replaceChildren(list);
      if (visible && previous) cards.get(previous)?.focus();
    }
  }
  function openDetail(id) { shell.router.push({ panel: "plugins", plugin: id }); route(id); }
  function openList() { shell.router.push({ plugin: null }); route(null); }

  const stops = [
    shell.inventory.state.subscribe(paint),
    shell.modules.state.subscribe(paint),
    shell.router.subscribe((address) => { if (address.panel === "plugins") route(address.plugin || null); }),
  ];
  paint();

  function show(next) {
    if (next === visible) return;
    visible = next;
    detail?.setVisible(next);
    if (next) { shell.inventory.refresh(); packages.refresh(); route(shell.router.read().plugin || null); }
    else packages.clearSecrets();
  }
  show(true);
  return {
    element,
    update({ visible: next = true } = {}) { show(next); },
    dispose() { for (const stop of stops) stop(); detail?.dispose(); },
  };
}
