import { el } from "./views.js";
import { jsonSetting, settingsChanges } from "./settings_state.js";

const groups = [
  ["Agent behavior", [
    ["fallback_model", "Fallback model", "text", "Optional provider/model for the existing refusal and overload fallback."],
    ["adaptations", "Model adaptations", "text", "auto, off, or an installed adaptation row name."],
    ["adaptations_dir", "Local adaptations directory", "text"],
    ["kernel_tools", "Nexus tools", "lines", "One canonical tool name per line. Changes apply to new runs; an existing run keeps its captured tool list."],
  ]],
  ["Tools and working location", [
    ["runner", "Default runner", "runner", "Used for future requests without an explicit Runner. Existing accepted tasks keep their original Runner."],
    ["workspace", "Default workspace", "workspace", "Used for new conversations. Leave automatic to use rho's dedicated workspace."],
    ["tools_root", "Default working directory", "text", "Used when no environment or conversation directory is selected."],
  ]],
  ["Connection", [
    ["nexus_public_url", "Nexus browser URL", "text", "The address your browser can reach, including any deployment path prefix."],
  ]],
];

function displayValue(kind, value) {
  if (kind === "secret-json") return "";
  if (kind === "json") return JSON.stringify(value || {}, null, 2);
  if (kind === "lines") return (value || []).join("\n");
  return value ?? "";
}

export function editedSetting(kind, text, label) {
  switch (kind) {
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
        for (const { key, kind, label, input } of controls) {
          if (!entry.dirty.has(key)) continue;
          if (kind === "secret-json" && !input.value.trim()) continue;
          edited[key] = editedSetting(kind, input.value, label);
        }
        const changes = settingsChanges(observed, edited);
        if (!Object.keys(changes).length) return;
        const answer = await save(changes);
        if (!answer) return;
        entry.dirty.clear();
        for (const { kind, input } of controls) if (kind === "secret-json") {
          input.value = "";
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
          : el("input", { name: key, type: kind === "number" ? "number" : "text",
            ...(kind === "number" ? { min: 1, max: 540, step: 1, required: true } : {}) });
      if (Array.isArray(kind)) for (const value of kind) input.append(el("option", { value, text: value }));
      input.addEventListener("input", () => entry.dirty.add(key));
      input.addEventListener("change", () => entry.dirty.add(key));
      const known = kind === "secret-json" ? el("p", { class: "faint" }) : null;
      controls.push({ key, kind, label, input, known });
      fields.append(el("label", {}, label, input));
      if (hint) fields.append(el("p", { class: "faint", text: hint }));
      if (known) fields.append(known);
    }
    fields.append(el("button", { type: "submit", text: `Save ${title.toLowerCase()}` }));
    forms.push(entry); element.append(form);
  }
  element.append(el("details", { class: "settings-details" }, el("summary", { text: "Deployment information" }),
    el("p", { class: "faint", text: "Process role, listening address and installed runtime paths are controlled by your deployment." }), deployment));

  function update(answer, available = choices) {
    document = answer; observed = answer.settings; choices = available;
    for (const { controls, dirty } of forms) {
      for (const { key, kind, input, known } of controls) {
        if (known) {
          const configured = answer.configured?.[key];
          known.textContent = configured?.length ? `Configured: ${configured.join(", ")}` : "No saved entries.";
        }
        if (dirty.has(key)) continue;
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
    for (const { controls, dirty } of forms) for (const { key, kind, input } of controls) {
      if (kind === "secret-json") {
        input.value = ""; dirty.delete(key);
      }
    }
  }, document: () => document };
}
