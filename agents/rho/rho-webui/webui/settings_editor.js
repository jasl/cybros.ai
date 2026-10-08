import { t } from "./i18n.js";
import { el } from "./views.js";
import { jsonSetting, settingsChanges } from "./settings_state.js";

const groups = [
  [t("settings_editor.agent_behavior"), [
    ["fallback_model", t("settings_editor.fallback_model"), "text", t("settings_editor.optional_provider_model_for_the_existing_refusal_and")],
    ["adaptations", t("settings_editor.model_adaptations"), "text", t("settings_editor.auto_off_or_an_installed_adaptation_row_name")],
    ["adaptations_dir", t("settings_editor.local_adaptations_directory"), "text"],
    ["kernel_tools", t("settings_editor.nexus_tools"), "lines", t("settings_editor.one_canonical_tool_name_per_line_changes_apply")],
  ]],
  [t("settings_editor.tools_and_working_location"), [
    ["runner", t("settings_editor.default_runner"), "runner", t("settings_editor.used_for_future_requests_without_an_explicit_runner")],
    ["workspace", t("settings_editor.default_workspace"), "workspace", t("settings_editor.used_for_new_conversations_leave_automatic_to_use")],
    ["tools_root", t("settings_editor.default_working_directory"), "text", t("settings_editor.used_when_no_environment_or_conversation_directory_is")],
  ]],
  [t("settings_editor.connection"), [
    ["nexus_public_url", t("settings_editor.nexus_browser_url"), "text", t("settings_editor.the_address_your_browser_can_reach_including_any")],
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
      if (!Number.isSafeInteger(value) || value <= 0) throw new Error(t("settings_editor.must_be_a_positive_whole_number", { label: label }));
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
    el("summary", { text: t("settings_editor.more_settings") }),
    el("p", { class: "muted", text: t("settings_editor.agent_behavior_tools_and_working_location_defaults_are") }));

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
    fields.append(el("button", { type: "submit", text: t("settings_editor.save", { value1: title.toLowerCase() }) }));
    forms.push(entry); element.append(form);
  }
  element.append(el("details", { class: "settings-details" }, el("summary", { text: t("settings_editor.deployment_information") }),
    el("p", { class: "faint", text: t("settings_editor.process_role_listening_address_and_installed_runtime_paths") }), deployment));

  function update(answer, available = choices) {
    document = answer; observed = answer.settings; choices = available;
    for (const { controls, dirty } of forms) {
      for (const { key, kind, input, known } of controls) {
        if (known) {
          const configured = answer.configured?.[key];
          known.textContent = configured?.length ? t("settings_editor.configured", { value1: configured.join(", ") }) : t("settings_editor.no_saved_entries");
        }
        if (dirty.has(key)) continue;
        const value = observed[key];
        if (kind === "runner" || kind === "workspace") {
          const rows = kind === "runner" ? choices.runners : choices.workspaces;
          input.replaceChildren(el("option", { value: "", text: kind === "runner" ? t("settings_editor.automatic_rho_s_own_runner") : t("settings_editor.automatic_rho_s_workspace") }),
            ...rows.map((row) => el("option", { value: row.public_id, text: row.display_name || row.name || row.public_id })));
          if (value && !rows.some((row) => row.public_id === value)) input.append(el("option", { value, text: t("settings_editor.currently_unavailable", { value: value }) }));
        }
        input.value = displayValue(kind, value);
      }
    }
    deployment.replaceChildren(...Object.entries(answer.deployment || {}).flatMap(([key, value]) => [
      el("dt", { text: t(`settings_editor.deployment.${key}`, {}, key) }),
      el("dd", { text: typeof value === "boolean" ? t(`common.boolean_${value}`)
        : typeof value === "object" ? JSON.stringify(value) : String(value ?? t("common.not_set")) }),
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
