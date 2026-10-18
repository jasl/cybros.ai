import { el } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";
import { hueOf, initialOf } from "../kernel/format.js";
import { icon, button, field, input, modal, openMenu } from "../primitives/index.js";

// What a workspace row says under its name: rho's own, or how it is shared.
export function workspaceDetail(row, selection) {
  const parts = [];
  if (row.dedicated) parts.push(t("workspaces.dedicated"));
  else parts.push(row.access_mode === "account_wide" ? t("workspaces.account_wide") : t("workspaces.private"));
  if (row.public_id === selection) parts.push(t("workspaces.default"));
  return parts.join(" · ");
}

// The sidebar's workspace row: the current workspace's mark and name, a menu
// of every workspace the account lists with the current one checked, and a
// way to create one. On the rail only the mark shows; the menu still opens
// from it.
export function workspaceSwitcher({ shell }) {
  const mark = el("span", { class: "mark", "aria-hidden": "true" });
  const name = el("span", { class: "sidebar__workspace-name" });
  let open = null;
  const trigger = el("button", { type: "button", class: "sidebar__workspace", "aria-haspopup": "menu", "aria-expanded": "false", onclick: () => {
    if (open) { open.close(); return; }
    open = openMenu({ anchor: trigger, items: items(), label: t("workspaces.title"), onClose: () => { open = null; } });
  } }, mark, name, icon("chevron-down"));

  function items() {
    const { rows, current, selection, loaded } = shell.workspaces.state.get();
    const entries = rows.map((row) => ({ type: "radio", label: row.name, detail: workspaceDetail(row, selection), checked: row.public_id === current,
      onSelect: () => shell.workspaces.switchTo(row.public_id) }));
    if (!entries.length) entries.push({ type: "item", label: loaded ? t("workspaces.none") : t("workspaces.loading"), disabled: true });
    const base = shell.setup.state.get().document?.nexus?.public_url;
    const management = base ? [
      ...(current ? [{ type: "link", label: t("workspaces.manage"), icon: "settings", href: `${base}/workspaces/${encodeURIComponent(current)}/settings` }] : []),
      { type: "link", label: t("workspaces.archived"), icon: "restore", href: `${base}/workspaces?tab=archived` },
    ] : [];
    return [{ type: "title", label: t("workspaces.title") }, ...entries, { type: "separator" },
      ...management, { type: "item", label: t("workspaces.refresh"), icon: "refresh", onSelect: refresh },
      { type: "item", label: t("workspaces.new"), icon: "plus", onSelect: openCreate }];
  }

  async function refresh() {
    const state = await shell.workspaces.refresh();
    if (state.error) shell.toast(state.error.message || t("conversation.request_failed"), { tone: "error" });
  }

  // A name is all a workspace needs; access is the account-wide default.
  function openCreate() {
    const box = input({ name: "name", autocomplete: "off", placeholder: t("workspaces.name_placeholder") });
    const nameField = field({ label: t("workspaces.name"), control: box });
    const submit = button({ label: t("workspaces.create"), variant: "primary", type: "submit" });
    const form = el("form", { class: "stack", onsubmit: async (event) => {
      event.preventDefault();
      const text = box.value.trim();
      if (!text) { nameField.setError(t("workspaces.name_required")); box.focus(); return; }
      submit.disabled = true; box.disabled = true; nameField.setError(null);
      try {
        const row = await shell.workspaces.create(text);
        dialog.close();
        shell.toast(t("workspaces.created", { name: row.name }), { tone: "success" });
      } catch (error) {
        if (error.name === "AbortError") return;
        nameField.setError(error.message || t("conversation.request_failed"));
        submit.disabled = false; box.disabled = false; box.focus();
      }
    } }, nameField.element, el("div", { class: "row row--end" }, button({ label: t("common.cancel"), onClick: () => dialog.close() }), submit));
    const dialog = modal({ title: t("workspaces.new_title"), body: form, onClose: () => dialog.element.remove() });
    dialog.open();
    box.focus();
  }

  function paint(state) {
    const row = shell.workspaces.row();
    name.textContent = row?.name || (state.loaded ? t("workspaces.none") : t("brand.rho"));
    // Before a workspace is named the mark is rho's own; a named one wears
    // its initial and colour.
    mark.classList.toggle("mark--named", !!row);
    if (row) {
      mark.textContent = initialOf(row.name);
      mark.style.setProperty("--hue", String(hueOf(row.public_id)));
    } else {
      mark.replaceChildren(icon("rho"));
      mark.style.removeProperty("--hue");
    }
    trigger.setAttribute("aria-label", t("workspaces.current", { name: name.textContent }));
    trigger.dataset.tip = trigger.getAttribute("aria-label");
  }
  const stop = shell.workspaces.state.subscribe(paint, { immediate: true });

  return {
    element: trigger,
    dispose() { stop(); open?.close(); },
  };
}
