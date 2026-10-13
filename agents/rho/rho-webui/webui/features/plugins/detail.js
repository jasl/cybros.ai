import { el, uniqueId } from "../../kernel/dom.js";
import { t, pluginText, statusText } from "../../kernel/i18n.js";
import { keyedOutlet } from "../../kernel/outlets.js";
import { alert, button, emptyState, switchControl, tag } from "../../primitives/index.js";
import { diagnosticsText } from "./plugin_draft.js";
import { pluginForm } from "./plugin_form.js";
import { hasSettings, initial, lockReason, moduleFailure, pageLocks, pluginStatus, pluginVersion } from "./switching.js";

const sourceLabel = (source = {}) => [statusText(source.kind || "installed"), source.name || source.feature || source.path, source.version]
  .filter(Boolean).join(" · ");

function fact(term, ...details) {
  return [el("dt", { text: term }), el("dd", {}, ...details)];
}

// One plugin's page. Its configuration body is the `plugins.item.config`
// contribution for this id when one is registered (a running plugin's own
// module), otherwise the generic schema form.
export function pluginDetail(shell, { id, switching, back }) {
  const crumbName = el("span", { "aria-current": "page" });
  const crumbs = el("nav", { class: "crumbs", "aria-label": t("plugin_page.breadcrumb") },
    el("ol", {}, el("li", {}, el("button", { type: "button", class: "link-button", text: t("common.plugins"), onclick: back })), el("li", {}, crumbName)));
  const tile = el("span", { class: "plugin-tile plugin-tile--lg", "aria-hidden": "true" });
  const name = el("h1", { class: "plugin-detail__name", tabindex: "-1" });
  const version = el("span", { class: "plugin-detail__version text-tertiary", hidden: true });
  const status = el("span", { class: "plugin-detail__status" });
  const toggle = switchControl({ label: "", onChange: () => {
    const done = switching.change(row, toggle.input.checked);
    paintSwitch();
    done.then(paintSwitch);
  } });
  // Why the switch above stays on: this page needs the plugin.
  const lock = el("p", { class: "notice plugin-detail__lock", hidden: true });
  const description = el("p", { class: "plugin-detail__description" });
  const facts = el("dl", { class: "plugin-detail__facts" });
  const issues = alert({ tone: "warning" });
  const failure = alert({ tone: "error" });
  const reload = button({ label: t("shell.reload_page"), size: "sm", icon: "refresh", onClick: () => location.reload() });
  const failureRow = el("div", { class: "plugin-detail__failure", hidden: true }, failure.element, reload);
  const retry = button({ label: t("plugin_settings.retry_activation"), size: "sm", icon: "retry", onClick: () => {
    const done = switching.retry(row);
    paintSwitch();
    done.then(paintSwitch);
  } });
  // A module's body brings its own cards; only the generic form is one.
  const configBody = el("div", { class: "plugin-detail__config" });
  const heading = uniqueId("configuration");
  const configuration = el("section", { class: "plugin-detail__configuration", "aria-labelledby": heading },
    el("h2", { class: "plugin-detail__section-title", id: heading, text: t("plugin_page.settings") }), configBody);
  const actions = el("div", { class: "plugin-detail__actions", hidden: true }, retry);
  const content = el("div", { class: "plugin-detail" }, crumbs,
    el("header", { class: "plugin-detail__head" }, tile,
      el("div", { class: "plugin-detail__title" }, el("div", { class: "plugin-detail__heading" }, name, version), status), toggle.element),
    lock, description, issues.element, failureRow, actions, facts, configuration);
  const missing = emptyState({ icon: "plugins", title: t("plugin_page.missing"), action: button({ label: t("common.back"), size: "sm", onClick: back }) });
  const element = el("div", { class: "plugins__detail" }, content, missing);
  let row = null;
  let outlet = null;
  let visible = true;

  const configProps = () => ({ plugin: row, refresh: () => shell.inventory.refresh(), visible });

  function paintSwitch() {
    if (!row) return;
    const label = pluginText(row, "name");
    const busy = switching.busy(row.id);
    const locked = pageLocks(shell.inventory.state.get().plugins).get(row.id) || null;
    toggle.input.setAttribute("aria-label", t("plugin_page.switch_label", { name: label }));
    // While a change is in flight the switch keeps the position asked for.
    toggle.set(busy ? toggle.input.checked : row.enabled, { disabled: busy || !!locked || (!row.enabled && row.configurable === false) });
    lock.textContent = locked ? lockReason(locked, row) : "";
    lock.hidden = !locked;
    retry.disabled = switching.busy(row.id) || row.configurable === false;
  }

  function paint() {
    const { plugins, loaded } = shell.inventory.state.get();
    row = plugins.find((entry) => entry.id === id) || null;
    content.hidden = !row;
    missing.hidden = !!row || !loaded;
    if (!row) return;
    const label = pluginText(row, "name");
    crumbName.textContent = label;
    tile.textContent = initial(label);
    name.textContent = label;
    const shown = pluginVersion(row);
    version.textContent = shown ? t("plugin_page.version", { version: shown }) : "";
    version.hidden = !shown;
    const tone = pluginStatus(row);
    status.replaceChildren(...(tone ? [tag(tone)] : []));
    description.textContent = pluginText(row, "description");
    description.hidden = !description.textContent;
    const text = diagnosticsText([...row.configuration.diagnostics, ...row.readiness.issues]);
    if (text) issues.show(text, "warning"); else issues.hide();
    const module = shell.modules.state.get().get(id);
    failureRow.hidden = module?.status !== "failed";
    if (module?.status === "failed") failure.show(moduleFailure(module));
    actions.hidden = !row.enabled || row.active;
    paintSwitch();
    const saved = sourceLabel(row.source);
    const running = row.active_source && sourceLabel(row.active_source);
    const { tools, commands } = row.capabilities;
    facts.replaceChildren(
      ...fact(t("plugin_page.identifier"), el("span", { class: "mono", text: row.id })),
      ...fact(t("plugin_page.state"), t("plugin_settings.requested_running", {
        value1: statusText(row.enabled ? "enabled" : "disabled"), value2: statusText(row.active ? "active" : "inactive"),
        value3: row.readiness.ready ? t("common.ready") : t("plugin_settings.setup_needed"),
        value4: row.restart_required ? t("plugin_settings.restart_required") : "" })),
      ...fact(t("plugin_page.saved_source"), saved),
      ...(running && running !== saved ? fact(t("plugin_page.running_source"), running) : []),
      ...(tools.length ? fact(t("plugin_page.tools"), el("span", { class: "plugin-detail__tags" }, tools.map((tool) => tag({ text: tool })))) : []),
      ...(commands.length ? fact(t("plugin_page.commands"), el("span", { class: "plugin-detail__tags" }, commands.map((command) => tag({ text: command })))) : []));
    // No fields and no module body: nothing to configure, so no section.
    configuration.hidden = !hasSettings(row, shell.slots);
    if (configuration.hidden || !shell.slots) return;
    if (outlet) { outlet.update(configProps()); return; }
    outlet = keyedOutlet(shell.slots, "plugins.item.config", configBody, { onError: shell.renderError,
      fallback: (props) => pluginForm(shell, props) });
    outlet.show(id, configProps());
  }

  const stops = [shell.inventory.state.subscribe(paint), shell.modules.state.subscribe(paint)];
  paint();
  return {
    element,
    focus() { name.focus(); },
    setVisible(next) {
      if (next === visible) return;
      visible = next;
      if (outlet && row) outlet.update(configProps());
    },
    dispose() { for (const stop of stops) stop(); outlet?.dispose(); element.remove(); },
  };
}
