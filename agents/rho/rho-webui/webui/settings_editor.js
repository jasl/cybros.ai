import { el } from "./views.js";
import { jsonSetting, settingsChanges } from "./settings_state.js";

const groups = [
  ["Agent behavior", [
    ["fallback_model", "Fallback model", "text", "Optional provider/model for the existing refusal and overload fallback."],
    ["image_model", "Image model", "text", "Optional provider/model used by image generation."],
    ["compose", "Compose", ["auto", "on", "off"]],
    ["compaction", "History compaction", "json", 'For example: {"mode":"kernel"}; add "model" to choose a summary model.'],
    ["adaptations", "Model adaptations", "text", "auto, off, or an installed adaptation row name."],
    ["adaptations_dir", "Local adaptations directory", "text"],
    ["kernel_tools", "Nexus tools", "lines", "One canonical tool name per line. Changes apply to new loops; an existing loop keeps its captured tool list."],
    ["lifecycle_hooks", "Lifecycle hooks", "json", "The lifecycle hook configuration declared by this agent."],
  ]],
  ["Tools and working location", [
    ["runner", "Default runner", "runner", "Used for new conversations. Existing conversations keep their runner; switching those requires a handoff."],
    ["workspace", "Default workspace", "workspace", "Used for new conversations. Leave automatic to use rho's dedicated workspace."],
    ["tools_root", "Default working directory", "text", "Used when no environment or conversation directory is selected."],
    ["bash_timeout_seconds", "Default shell timeout (seconds)", "number"],
    ["checkpoints", "Checkpoints", "json", "Configure enabled, retention_days, max_file_bytes, max_tree_bytes and capture_timeout_seconds."],
  ]],
  ["Extensions and connections", [
    ["extensions", "Additional extensions", "lines", "One installed feature per line, such as rho/browser. Installed extensions run on this machine."],
    ["extension_paths", "Additional extension files", "lines", "One local Ruby extension path per line."],
    ["web", "Web reader", "json", 'For example: {"allow_private_network":false}.'],
    ["mcp_servers", "MCP server configuration", "secret-json", "Replace the complete server object. Existing credentials are not returned to this page. Leave blank to keep the saved configuration; {} removes all configured servers."],
    ["acp_agents", "ACP agent configuration", "secret-json", "Replace the complete agent object. Existing environment values are not returned to this page. Leave blank to keep the saved configuration; {} removes all configured agents."],
    ["nexus_public_url", "Nexus browser URL", "text", "The address your browser can reach, including any deployment path prefix."],
    ["access_passphrase", "Console access passphrase", "secret-text", "Leave blank to keep the current passphrase. A new passphrase applies immediately; it is never returned to this page."],
  ]],
];

function displayValue(kind, value) {
  if (["secret-json", "secret-text"].includes(kind)) return "";
  if (kind === "json") return JSON.stringify(value || {}, null, 2);
  if (kind === "lines") return (value || []).join("\n");
  return value ?? "";
}

export function editedSetting(kind, text, label) {
  switch (kind) {
    case "secret-text": return text;
    case "json": case "secret-json": return jsonSetting(text, label);
    case "lines": return text.split("\n").map((line) => line.trim()).filter(Boolean);
    case "number": {
      const value = Number(text);
      if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${label} must be a positive whole number.`);
      return value;
    }
    default: return text.trim() || null;
  }
}

// Each form owns its draft. Read-only status refreshes may update its summary,
// but never replace controls that the person has edited.
export function settingsEditor({ save, showError }) {
  let observed = {};
  let document = null;
  let choices = { runners: [], workspaces: [] };
  const forms = [];
  const deployment = el("dl", { class: "settings-facts" });
  const element = el("details", { class: "settings-details settings-advanced" },
    el("summary", { text: "More settings" }),
    el("p", { class: "muted", text: "Agent behavior, tools and working-location defaults are already prepared. Change these only when you need a different setup. Saving applies your changes immediately." }));

  for (const [title, definitions] of groups) {
    const controls = [];
    const fields = el("fieldset", { class: "settings-fields" });
    const entry = { fields, controls, dirty: new Set() };
    const form = el("form", { class: "settings-form", onsubmit: async (event) => {
      event.preventDefault(); fields.disabled = true;
      try {
        const edited = {};
        for (const { key, kind, label, input, clear } of controls) {
          if (!entry.dirty.has(key)) continue;
          if (clear?.checked) { edited[key] = null; continue; }
          if (["secret-json", "secret-text"].includes(kind) && !input.value.trim()) continue;
          edited[key] = editedSetting(kind, input.value, label);
        }
        const changes = settingsChanges(observed, edited);
        if (!Object.keys(changes).length) return;
        const answer = await save(changes);
        if (!answer) return;
        entry.dirty.clear();
        for (const { kind, input, clear } of controls) if (["secret-json", "secret-text"].includes(kind)) {
          input.value = ""; if (clear) clear.checked = false;
        }
        update(answer, choices);
      } catch (error) { showError(error); }
      finally { fields.disabled = false; }
    } }, el("h4", { text: title }), fields);
    for (const [key, label, kind, hint] of definitions) {
      const input = ["json", "secret-json", "lines"].includes(kind)
        ? el("textarea", { name: key, rows: kind === "lines" ? 4 : 6, spellcheck: "false", autocomplete: "off", class: "mono" })
        : Array.isArray(kind) || ["runner", "workspace"].includes(kind)
          ? el("select", { name: key })
          : el("input", { name: key, type: kind === "number" ? "number" : kind === "secret-text" ? "password" : "text",
            ...(kind === "secret-text" ? { autocomplete: "new-password" } : {}), ...(kind === "number" ? { min: 1, max: 540, step: 1, required: true } : {}) });
      if (Array.isArray(kind)) for (const value of kind) input.append(el("option", { value, text: value }));
      input.addEventListener("input", () => entry.dirty.add(key));
      input.addEventListener("change", () => entry.dirty.add(key));
      const known = ["secret-json", "secret-text"].includes(kind) ? el("p", { class: "faint" }) : null;
      const clear = kind === "secret-text" ? el("input", { type: "checkbox", onchange: () => { entry.dirty.add(key); input.disabled = clear.checked; } }) : null;
      controls.push({ key, kind, label, input, known, clear });
      fields.append(el("label", {}, label, input));
      if (hint) fields.append(el("p", { class: "faint", text: hint }));
      if (known) fields.append(known);
      if (clear) fields.append(el("label", { class: "check" }, clear, "Clear the saved console access passphrase"));
    }
    fields.append(el("button", { type: "submit", text: `Save ${title.toLowerCase()}` }));
    forms.push(entry); element.append(form);
  }
  element.append(el("details", { class: "settings-details" }, el("summary", { text: "Deployment information" }),
    el("p", { class: "faint", text: "Process role, listening address and installed runtime paths are controlled by your deployment." }), deployment));

  function update(answer, available = choices) {
    document = answer; observed = answer.settings; choices = available;
    for (const { controls, dirty } of forms) {
      for (const { key, kind, input, known, clear } of controls) {
        if (known) {
          const configured = answer.configured?.[key];
          known.textContent = kind === "secret-text" ? configured ? "A passphrase is configured." : "No passphrase is configured."
            : configured?.length ? `Configured: ${configured.join(", ")}` : "No saved entries.";
        }
        if (dirty.has(key)) continue;
        if (clear) { clear.checked = false; input.disabled = false; }
        const value = observed[key];
        if (kind === "runner" || kind === "workspace") {
          const rows = kind === "runner" ? choices.runners : choices.workspaces;
          input.replaceChildren(el("option", { value: "", text: kind === "runner" ? "Automatic · rho's own runner" : "Automatic · rho's workspace" }),
            ...rows.map((row) => el("option", { value: row.public_id, text: row.display_name || row.name || row.public_id })));
          if (value && !rows.some((row) => row.public_id === value)) input.append(el("option", { value, text: `${value} · currently unavailable` }));
        }
        input.value = displayValue(kind, value);
      }
    }
    deployment.replaceChildren(...Object.entries(answer.deployment || {}).flatMap(([key, value]) => [
      el("dt", { text: key.replaceAll("_", " ") }), el("dd", { text: typeof value === "object" ? JSON.stringify(value) : String(value ?? "Not set") }),
    ]));
  }

  return { element, update, clearSecrets: () => {
    for (const { controls, dirty } of forms) for (const { key, kind, input, clear } of controls) {
      if (["secret-json", "secret-text"].includes(kind)) {
        input.value = ""; dirty.delete(key); if (clear) { clear.checked = false; input.disabled = false; }
      }
    }
  }, document: () => document };
}
