import { el } from "../../kernel/dom.js";
import { t, pluginText } from "../../kernel/i18n.js";
import { button, checkbox, modal } from "../../primitives/index.js";
import { pluginSaveMessage } from "./plugin_draft.js";

// Enabled plugins that need `id`, directly or through another dependent;
// cycles end because each plugin joins the set once.
export function enabledDependents(inventory, id) {
  const affected = new Set([id]);
  let expanded;
  do {
    expanded = false;
    for (const plugin of inventory) {
      if (!affected.has(plugin.id) && plugin.requires.some((dependency) => affected.has(dependency))) {
        affected.add(plugin.id); expanded = true;
      }
    }
  } while (expanded);
  return inventory.filter((plugin) => plugin.id !== id && plugin.enabled && affected.has(plugin.id));
}

// The switches this page must not offer: the plugin that serves the page
// (`capabilities.page` on its row) and, transitively, what that plugin
// requires. Turning any of them off would end the page itself, so the
// terminal keeps that authority. Keyed by plugin id; the value names why.
export function pageLocks(inventory) {
  const owner = inventory.find((plugin) => plugin.capabilities?.page);
  const locks = new Map();
  if (!owner) return locks;
  locks.set(owner.id, { kind: "page", owner });
  const queue = [owner];
  while (queue.length) {
    for (const id of queue.shift().requires || []) {
      const plugin = inventory.find((row) => row.id === id);
      if (!plugin || locks.has(id)) continue;
      locks.set(id, { kind: "dependency", owner });
      queue.push(plugin);
    }
  }
  return locks;
}

export function lockReason(lock, plugin) {
  const command = `rho extensions disable ${plugin.id}`;
  if (lock.kind === "page") return t("plugin_page.locked_page", { command });
  return t("plugin_page.locked_dependency", { page: pluginText(lock.owner, "name"), command });
}

// Requested and running state are separate facts; the tag names the one the
// person has to act on first.
// Only a plugin that needs something says so: a restart, a repair or its
// setup. A running plugin and a disabled one need no label; the switch shows
// which they are.
export function pluginStatus(plugin) {
  if (plugin.restart_required) return { tone: "warning", text: t("plugin_page.status_restart") };
  if (!plugin.enabled) return null;
  if (!plugin.active) return { tone: "danger", text: t("plugin_page.status_failed") };
  if (!plugin.readiness?.ready) return { tone: "warning", text: t("plugin_page.status_setup") };
  return null;
}

// A managed package's version is a digest of its bytes; its head is enough
// to tell versions apart. Null when the source names none.
export function pluginVersion(plugin) {
  const version = plugin.version ? String(plugin.version) : "";
  if (!version) return null;
  return plugin.source?.kind === "package" ? version.slice(0, 12) : version;
}

// A plugin has settings when its schema declares fields or a running module
// brings its own configuration body; otherwise there is nothing to open.
export function hasSettings(plugin, slots) {
  const fields = Object.keys(plugin.configuration?.schema?.properties || {}).length > 0;
  return plugin.configurable !== false && (fields || !!slots?.winner("plugins.item.config", plugin.id));
}

// The Plugins page groups by category, in this order; a category the page
// has no copy for is shown by its key.
export const CATEGORIES = ["interface", "channels", "agents", "tools", "conversation", "system", "other"];
export function categoryLabel(category) {
  return { interface: t("plugin_page.category_interface"), channels: t("plugin_page.category_channels"), agents: t("plugin_page.category_agents"),
    tools: t("plugin_page.category_tools"), conversation: t("plugin_page.category_conversation"), system: t("plugin_page.category_system"),
    other: t("plugin_page.category_other") }[category] ?? category;
}

export function moduleFailure(state) {
  const phase = { import: t("shell.phase_import"), register: t("shell.phase_register"), render: t("shell.phase_render") }[state.phase] || state.phase;
  return t("shell.module_failed_detail", { name: state.name, phase, message: state.message });
}

export const initial = (name) => ([...name.trim()][0] || "?").toUpperCase();

// Resolves to the dependents to disable with the plugin, or null if cancelled.
function confirmDisable(plugin, dependents) {
  return new Promise((resolve) => {
    const boxes = dependents.map((row) => {
      const box = checkbox({ name: "dependents", label: pluginText(row, "name") });
      box.input.value = row.id;
      return box;
    });
    let answer = null;
    const body = el("div", { class: "stack" },
      el("fieldset", { class: "stack stack--tight" },
        el("legend", { class: "field__label", text: t("plugin_settings.also_disable") }),
        el("p", { class: "field__hint", text: t("plugin_settings.select_affected_plugins_when_disabling_a_capability_they") }),
        boxes.map((box) => box.element)));
    const dialog = modal({ title: t("plugin_page.disable_title", { name: pluginText(plugin, "name") }), body,
      actions: [
        button({ label: t("common.cancel"), onClick: () => dialog.close() }),
        button({ label: t("plugin_settings.disable_plugin"), variant: "primary", onClick: () => {
          answer = boxes.filter((box) => box.input.checked).map((box) => box.input.value);
          dialog.close();
        } }),
      ],
      onClose: () => { dialog.element.remove(); resolve(answer); } });
    dialog.open();
  });
}

// Enablement goes through the plugin manager; its answer carries the new
// row, which the inventory applies in place. Nothing is retried on its own.
export function createSwitching(shell) {
  const pending = new Set();

  async function report(answer) {
    await shell.inventory.accept(answer);
    shell.toast(pluginSaveMessage(answer), { tone: answer.saved && answer.applied && !answer.restart_required ? "success" : "info" });
  }

  async function failed(error) {
    if (error.name === "AbortError" || error.status === 401) return;
    const details = error.details || {};
    if (details.saved || details.published) {
      await shell.inventory.accept(details);
      shell.toast(pluginSaveMessage(details), { tone: "error" });
      return;
    }
    shell.toast(error.status ? error.message : t("plugin_page.outcome_unknown"), { tone: "error" });
    if (!error.status) shell.inventory.refresh();
  }

  async function run(plugin, action, body) {
    pending.add(plugin.id);
    try { await report(await shell.call(`/extensions/${encodeURIComponent(plugin.id)}/${action}`, { method: "POST", body })); }
    catch (error) { await failed(error); }
    finally { pending.delete(plugin.id); }
  }

  return {
    busy: (id) => pending.has(id),
    // Disabling what other enabled plugins need asks first; what the page
    // itself needs is not offered at all.
    async change(plugin, enable) {
      if (pending.has(plugin.id)) return;
      if (enable) { await run(plugin, "enable", { dependents: [] }); return; }
      const { plugins } = shell.inventory.state.get();
      if (pageLocks(plugins).has(plugin.id)) return;
      const affected = enabledDependents(plugins, plugin.id);
      let dependents = [];
      if (affected.length) {
        const chosen = await confirmDisable(plugin, affected);
        if (chosen === null) return;
        dependents = chosen;
      }
      await run(plugin, "disable", { dependents });
    },
    async retry(plugin) {
      if (!pending.has(plugin.id)) await run(plugin, "enable", {});
    },
  };
}
