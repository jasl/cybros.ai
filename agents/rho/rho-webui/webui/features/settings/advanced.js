import { el, uniqueId } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { changedFields } from "../../kernel/forms.js";
import { alert, button, field, input, section, select, switchControl } from "../../primitives/index.js";
import { orderedModels } from "./model_choices.js";
import { modelLabel, paintModels } from "../../primitives/model_choices.js";
import { kernelToolsControl } from "./kernel_tools.js";

// Every field is a choice over what the daemon can list, unless the value is
// a path or an address only the operator knows.
const groups = () => [
  [t("settings_editor.agent_behavior"), t("settings_editor.agent_behavior_help"), [
    ["default_model", t("presets.global_model"), "model", t("presets.global_model_help")],
    ["fallback_models", t("presets.fallback_models"), "models"],
    ["adaptations", t("settings_editor.model_adaptations"), "adaptation", t("settings_editor.adaptations_help")],
    ["adaptations_dir", t("settings_editor.local_adaptations_directory"), "text"],
    ["subagent_default", t("settings_editor.subagent_default"), "boolean", t("settings_editor.subagent_default_help")],
    ["conversation_title_model", t("settings_editor.conversation_title_model"), "title_model", t("settings_editor.conversation_title_model_help")],
  ]],
  [t("settings_editor.nexus_tools"), t("settings_editor.kernel_tools_help"), [
    ["kernel_tools", t("settings_editor.nexus_tools"), "tools"],
  ]],
  [t("settings_editor.tools_and_working_location"), null, [
    ["runner", t("settings_editor.default_runner"), "runner", t("settings_editor.used_for_future_requests_without_an_explicit_runner")],
    ["workspace", t("settings_editor.default_workspace"), "workspace", t("settings_editor.used_for_new_conversations_leave_automatic_to_use")],
    ["tools_root", t("settings_editor.default_working_directory"), "text", t("settings_editor.used_when_no_environment_or_conversation_directory_is")],
  ]],
  [t("settings_editor.connection"), null, [
    ["nexus_public_url", t("settings_editor.nexus_browser_url"), "text", t("settings_editor.the_address_your_browser_can_reach_including_any")],
  ]],
];

// A blank text field clears the setting; a blank choice is the automatic one.
export function editedSetting(kind, text) {
  return kind === "adaptation" ? text || "auto" : text.trim() || null;
}

const option = (value, text) => el("option", { value, text });

// A select over `[value, label]` rows, the automatic choice first, keeping a
// saved value the list no longer has.
function paintChoices(box, value, rows) {
  box.replaceChildren(...rows.map(([key, text]) => option(key, text)));
  if (value && !rows.some(([key]) => key === value)) box.append(option(value, t("settings_editor.currently_unavailable", { value })));
  box.value = value || "";
}

const named = (row) => row.display_name || row.name || row.public_id;

// "Defaults": the daemon's defaults, which most people never change. Each group is its
// own form and keeps its draft; refreshes repaint only untouched fields, and
// a save writes only the fields that differ from the saved document.
export function advancedSection(shell, initialProps) {
  let props = initialProps;
  let choices = { runners: [], workspaces: [], rows: null, tools: null, toolsLoading: !!props.status?.connected, models: [] };
  const reads = new AbortController();
  const forms = [];
  const element = el("div", { class: "settings-section" },
    el("p", { class: "settings-row__description", text: t("settings_editor.agent_behavior_tools_and_working_location_defaults_are") }));

  function control(key, kind, dirty, label, hint) {
    const touched = () => dirty.add(key);
    if (kind === "models") {
      const ordered = orderedModels({ models: props.status?.model?.eligible || [], onChange: touched });
      return { node: ordered.element, read: ordered.read, write: (value) => { ordered.update(props.status?.model?.eligible || []); ordered.set(value); },
        refresh: () => ordered.update(props.status?.model?.eligible || []) };
    }
    if (kind === "tools") {
      const tools = kernelToolsControl({ onChange: touched });
      return { node: tools.element, read: () => tools.read(), write: (value) => tools.set({ saved: value || [], catalog: choices.tools, loading: choices.toolsLoading }),
        refresh: () => tools.catalog(choices.tools, { loading: choices.toolsLoading }) };
    }
    if (kind === "boolean") {
      const hintId = uniqueId("setting-hint");
      const toggle = switchControl({ label, onChange: touched, attrs: { name: key, "aria-describedby": hintId } });
      return { node: el("div", { class: "field" }, toggle.element, el("p", { class: "field__hint", id: hintId, text: hint })),
        read: () => toggle.input.checked, write: (value) => toggle.set(value) };
    }
    const box = kind === "text" ? input({ name: key, autocomplete: "off" }) : select({ name: key });
    box.addEventListener("input", touched);
    box.addEventListener("change", touched);
    const write = {
      text: (value) => { box.value = value ?? ""; },
      runner: (value) => paintChoices(box, value, [["", t("settings_editor.automatic_rho_s_own_runner")],
        ...choices.runners.map((row) => [row.public_id, named(row)])]),
      workspace: (value) => paintChoices(box, value, [["", t("settings_editor.automatic_rho_s_workspace")],
        ...choices.workspaces.map((row) => [row.public_id, named(row)])]),
      model: (value) => paintModels(box, props.status?.model?.eligible || [], value, t("agents.model_choose")),
      title_model: (value) => paintChoices(box, value, [["", t("common.none")], ["follow_current", t("settings_editor.follow_current_model")],
        ...choices.models.map((row) => [row.ref, modelLabel(row)])]),
      adaptation: (value) => paintChoices(box, value === "auto" ? "" : value, [["", t("settings_editor.automatic_adaptations")], ["off", t("settings_editor.adaptations_off")],
        ...(choices.rows || []).map((row) => [row.id, t("settings_editor.adaptation_row", { id: row.id, source: row.source })])]),
    }[kind];
    return { node: box, read: () => editedSetting(kind, box.value), write,
      // Refresh the catalog independently of the unsaved selection.
      refresh: ["model", "title_model"].includes(kind) ? () => write(box.value) : null };
  }

  for (const [title, description, definitions] of groups()) {
    const controls = [];
    const dirty = new Set();
    const feedback = alert({ tone: "success" });
    const fields = el("fieldset", { class: "settings-form__fields" });
    const form = el("form", { class: "settings-form", onsubmit: async (event) => {
      event.preventDefault();
      fields.disabled = true; feedback.hide();
      try {
        const edited = Object.fromEntries(controls.filter(({ key }) => dirty.has(key)).map(({ key, read }) => [key, read()]));
        const changes = changedFields(props.document.settings, edited);
        if (!Object.keys(changes).length) return;
        const answer = await props.save(changes);
        if (!answer) return;
        dirty.clear();
        feedback.show(t("settings.settings_saved_and_active"), "success");
        paint(answer);
      } catch (error) {
        feedback.show(error.message || t("settings.the_request_failed_your_changes_have_not_been"), "error");
      } finally { fields.disabled = false; }
    } }, fields);
    for (const [key, label, kind, hint] of definitions) {
      const entry = control(key, kind, dirty, label, hint);
      controls.push({ key, ...entry });
      fields.append(["tools", "models", "boolean"].includes(kind) ? entry.node : field({ label, control: entry.node, hint }).element);
    }
    fields.append(el("div", { class: "settings-form__actions" },
      button({ label: t("common.save"), variant: "primary", size: "sm", type: "submit" })));
    const card = section({ title, description });
    card.body.append(form, feedback.element);
    element.append(card.element);
    forms.push({ controls, dirty });
  }

  function paint(document) {
    const observed = document?.settings;
    if (!observed) return;
    for (const { controls, dirty } of forms) {
      for (const { key, write, refresh } of controls) {
        if (dirty.has(key)) refresh?.(); else write(observed[key]);
      }
    }
  }

  // The adaptation rows are the daemon's own files; runners, workspaces and
  // the kernel's tool catalog are member-plane reads, available once rho is
  // connected to Nexus. A read that fails leaves its field on the saved value.
  async function loadChoices() {
    choices.toolsLoading = !!props.status?.connected;
    paint(props.document);
    const read = async (path) => { try { return await shell.call(path, { signal: reads.signal }); } catch { return null; } };
    const [rows, runners, workspaces, tools] = await Promise.all([read("/adaptations/rows"),
      ...(props.status?.connected ? [read("/runners"), read("/workspaces"), read("/kernel_tools")] : [null, null, null])]);
    if (reads.signal.aborted) return;
    choices = { ...choices, toolsLoading: false, rows: rows?.rows ?? choices.rows, runners: runners?.runners ?? choices.runners,
      workspaces: workspaces?.workspaces ?? choices.workspaces, tools: tools?.tools ?? choices.tools };
    paint(props.document);
  }

  // Titles need text generation, not tool calls. The default Agent model's
  // eligible list is narrower, so use the existing text-model catalog.
  async function loadModels() {
    try {
      const answer = await shell.call("/models?workload=text_generation", { signal: reads.signal });
      if (reads.signal.aborted) return;
      choices.models = answer.models.filter((row) => row.available);
      paint(props.document);
    } catch { /* a saved model remains selectable when discovery is unavailable */ }
  }

  paint(props.document);
  loadChoices();
  if (props.status?.connected) loadModels();
  return {
    element,
    update(next) {
      const connected = !props.status?.connected && next.status?.connected;
      const reloadModels = props.status !== next.status && next.status?.connected;
      props = next;
      paint(next.document);
      if (connected) loadChoices();
      if (reloadModels) loadModels();
    },
    dispose() { reads.abort(); },
  };
}
