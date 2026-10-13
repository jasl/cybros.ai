import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, field, formGroup, input, select, textarea } from "../../primitives/index.js";
import { orderedModels, paintModels } from "./model_choices.js";
import { toolPicker } from "../../primitives/tool_picker.js";

export function presetEditor({ preset = null, models = [], tools = [], save, close }) {
  let configuration = { ...(preset?.configuration || {}) };
  let saving = false;
  const failure = alert({ tone: "error" });
  const name = input({ name: "preset_name", value: preset?.name || "", required: true, autocomplete: "off" });
  const description = textarea({ name: "preset_description", value: preset?.description || "", rows: 2, required: true });
  const prompt = textarea({ name: "system_prompt", value: configuration.system_prompt || "", rows: 14, mono: true });
  const model = select({ name: "model" });
  const mode = select({ name: "model_mode", value: configuration.model_mode || "default", options: [
    { value: "default", label: t("presets.model_default") }, { value: "follow", label: t("presets.model_follow") },
  ] });
  const fallback = orderedModels({ value: configuration.fallback_models ?? null, models, inherit: true });
  const kernelTools = toolPicker({ choices: tools.filter((row) => row.kind !== "runner"), given: configuration.tools ?? null,
    name: "preset_tools", label: t("presets.kernel_tools"), allLabel: t("presets.tools_all") });
  const runnerTools = toolPicker({ choices: tools.filter((row) => row.kind === "runner"), given: configuration.runner_tool_names ?? null,
    name: "runner_tool_names", label: t("presets.runner_tools"), allLabel: t("presets.tools_all") });
  const identity = formGroup({ title: t("presets.details") });
  identity.append(field({ label: t("presets.name"), control: name }).element,
    field({ label: t("presets.description"), control: description }).element);
  const behavior = formGroup({ title: t("presets.behavior") });
  behavior.append(field({ label: t("presets.prompt"), control: prompt, hint: t("presets.prompt_help") }).element);
  const modelsGroup = formGroup({ title: t("presets.models") });
  modelsGroup.append(field({ label: t("presets.model_mode"), control: mode, hint: t("presets.model_mode_help") }).element,
    field({ label: t("presets.initial_model"), control: model, hint: t("presets.initial_model_help") }).element, fallback.element);
  const kernel = formGroup({ title: t("presets.kernel_tools") });
  kernel.append(kernelTools.element);
  const runner = formGroup({ title: t("presets.runner_tools") });
  runner.append(runnerTools.element);
  const fields = el("fieldset", { class: "settings-form__fields" }, identity.element, behavior.element, modelsGroup.element, kernel.element, runner.element,
    el("div", { class: "row" }, button({ label: preset ? t("common.save") : t("presets.create"), type: "submit", variant: "primary", size: "sm" }),
      button({ label: t("common.cancel"), size: "sm", onClick: close })));
  const element = el("form", { class: "settings-form preset-editor", onsubmit: async (event) => {
    event.preventDefault();
    if (saving) return;
    if (!name.value.trim()) { name.focus(); return; }
    if (!description.value.trim()) { description.focus(); return; }
    saving = true; fields.disabled = true; failure.hide();
    const systemPrompt = prompt.value === (configuration.system_prompt ?? "") ? configuration.system_prompt ?? null : prompt.value;
    const next = { ...configuration, system_prompt: systemPrompt, model: model.value || null, model_mode: mode.value,
      fallback_models: fallback.read(), tools: kernelTools.read(), runner_tool_names: runnerTools.read() };
    try {
      const answer = await save({ ...(preset ? { public_id: preset.public_id } : {}), name: name.value.trim(), description: description.value.trim(), configuration: next });
      configuration = { ...(answer?.configuration || next) };
    } catch (error) { if (error.name !== "AbortError") failure.show(error.message || t("conversation.request_failed")); }
    finally { saving = false; fields.disabled = false; }
  } }, fields, failure.element);
  paintModels(model, models, configuration.model, t("presets.inherit_model"));
  return {
    element,
    focus() { name.focus(); },
    updateChoices(next) {
      paintModels(model, next.models, model.value, t("presets.inherit_model"));
      fallback.update(next.models);
      kernelTools.update(next.tools.filter((row) => row.kind !== "runner"));
      runnerTools.update(next.tools.filter((row) => row.kind === "runner"));
    },
  };
}
