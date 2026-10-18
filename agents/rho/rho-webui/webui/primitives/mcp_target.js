import { el } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";

// The accepted task identifies the external account. Reading or approving it
// must not substitute the Agent's current selection or another connection.
export function mcpTarget(detail) {
  const target = detail.target;
  if (target?.kind !== "mcp") return null;
  const values = [
    [t("task.mcp_connection"), target.display_name || target.connection_public_id],
    [t("task.mcp_account"), target.account_label],
    [t("task.mcp_remote_tool"), target.tool_name || detail.tool_name],
  ];
  return el("dl", { class: "settings-facts mcp-target" }, values.filter(([, value]) => value).flatMap(([label, value]) =>
    [el("dt", { text: label }), el("dd", { text: value })]));
}
