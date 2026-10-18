import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { link, switchControl, tag } from "../../primitives/index.js";
import { navigationLink } from "../../primitives/navigation.js";

// Store only exclusions. Catalog refreshes retain these choices while making
// newly connected services and newly discovered tools available by default.
export function mcpToolPicker({ value = {}, directory, openPlugin }) {
  let disabledConnections = (value.disabled_connections || []).map((row) => ({ ...row }));
  let disabledTools = (value.disabled_tools || []).map((row) => ({ ...row }));
  let current = directory;
  const status = el("p", { class: "field__hint", role: "status" });
  const manage = el("div", { class: "settings-row__link stack stack--tight" });
  const groups = el("div", { class: "toolset__groups" });
  const element = el("div", { class: "stack stack--tight mcp-tool-picker" },
    el("p", { class: "field__hint", text: t("presets.mcp_help") }), manage, status, groups);

  const key = (ref) => ref.source === "nexus" ? `nexus:${ref.connection_public_id}` : `executor:${ref.executor_public_id}:${ref.server_key}`;
  const matches = (entry, ref) => key(entry) === key(ref);
  const connectionOff = (ref) => disabledConnections.some((entry) => matches(entry, ref));
  const toolOff = (ref, name) => disabledTools.some((entry) => matches(entry, ref) && entry.tool_name === name);

  function row(connection, tool) {
    const ref = connection.ref;
    const available = connection.available && !tool.missing;
    const control = switchControl({ label: "", checked: !connectionOff(ref) && !toolOff(ref, tool.name),
      disabled: connectionOff(ref), attrs: { name: "mcp_tool", value: tool.name,
        "aria-label": t("presets.mcp_select", { connection: connection.name, tool: tool.name }) },
      onChange: (event) => {
        disabledTools = disabledTools.filter((entry) => !matches(entry, ref) || entry.tool_name !== tool.name);
        if (!event.target.checked) disabledTools.push({ ...ref, tool_name: tool.name });
        paint();
      } });
    return el("div", { class: "mcp-tool-picker__tool", "data-connection": key(ref), "data-tool": tool.name },
      el("div", { class: "settings-row toolset__row" },
        el("div", { class: "settings-row__text" },
          el("p", { class: "settings-row__label" }, el("span", { class: "bots-tool__name", text: tool.name }),
            available ? null : tag({ tone: "warning", text: t("presets.mcp_unavailable") })),
          tool.description ? el("p", { class: "settings-row__description", text: tool.description }) : null), control.element));
  }

  function paintGroups() {
    const connections = [...current.connections];
    for (const selection of [...disabledConnections, ...disabledTools]) {
      if (!connections.some((connection) => matches(selection, connection.ref))) {
        const { tool_name, ...ref } = selection;
        connections.push({ ref, name: ref.connection_public_id || ref.server_key, available: false, tools: [] });
      }
    }
    groups.replaceChildren(...connections.map((connection) => {
      const ref = connection.ref;
      const tools = [...connection.tools];
      for (const entry of disabledTools.filter((entry) => matches(entry, ref))) {
        if (!tools.some((tool) => tool.name === entry.tool_name)) tools.push({ name: entry.tool_name, missing: true });
      }
      const control = switchControl({ label: "", checked: !connectionOff(ref),
        attrs: { name: "mcp_connection", value: key(ref), "aria-label": t("presets.mcp_use_connection", { connection: connection.name }) },
        onChange: (event) => {
          disabledConnections = disabledConnections.filter((entry) => !matches(entry, ref));
          if (!event.target.checked) disabledConnections.push({ ...ref });
          paint();
        } });
      return el("section", { class: "toolset__group", "data-mcp-connection": key(ref) },
        el("div", { class: "settings-row" },
          el("div", { class: "settings-row__text" },
            el("h4", { class: "toolset__title", text: connection.account_label ? `${connection.name} · ${connection.account_label}` : connection.name }),
            el("p", { class: "field__hint", text: ref.source === "nexus" ? t("presets.mcp_source_nexus") : t("presets.mcp_source_local") }),
            connection.available ? null : tag({ tone: "warning", text: t("presets.mcp_unavailable") })), control.element),
        tools.length ? tools.map((tool) => row(connection, tool)) : el("p", { class: "field__hint", text: t("presets.mcp_no_tools") }));
    }));
  }

  function paint() {
    manage.replaceChildren(...(current.managementUrl ? [link({ href: current.managementUrl, text: t("presets.mcp_manage") })] : []),
      navigationLink({ class: "link", href: "/plugins/rho.mcp", text: t("presets.mcp_manage_local"), navigate: () => openPlugin("rho.mcp") }));
    status.textContent = current.loading ? t("presets.mcp_loading") : current.error ? t("presets.mcp_load_failed", { message: current.error })
      : current.connections.length ? t("presets.mcp_disabled", { connections: disabledConnections.length, tools: disabledTools.length }) : t("presets.mcp_empty");
    paintGroups();
  }
  paint();
  return {
    element,
    read: () => ({ disabled_connections: disabledConnections.map((row) => ({ ...row })), disabled_tools: disabledTools.map((row) => ({ ...row })) }),
    update(next) {
      const changed = ["connections", "loading", "error", "managementUrl"].some((key) => current[key] !== next[key]);
      current = next;
      if (changed) paint();
    },
  };
}
