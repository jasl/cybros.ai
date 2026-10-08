import { t } from "./i18n.js";
import { el } from "./views.js";

// Prompt text is literal user content. A separate switch preserves the
// difference between an empty replacement and the built-in base prompt.
export function promptSettings({ save, showError }) {
  let saving = false;
  const dirty = new Set();
  const preset = el("select", { name: "work_preset" },
    ...["standard", "compact"].map((value) => el("option", { value, text: t(`prompt_settings.preset_${value}`) })));
  const instructions = el("textarea", { name: "custom_instructions", rows: 5, spellcheck: "false", autocomplete: "off" });
  const replace = el("input", { name: "replace_base_prompt", type: "checkbox" });
  const base = el("textarea", { name: "base_prompt", rows: 10, spellcheck: "false", autocomplete: "off", class: "mono" });
  const replacementNotice = el("p", { class: "faint", hidden: true, text: t("prompt_settings.replacement_precedence") });
  const baseEditor = el("div", { class: "settings-fields", hidden: true },
    el("label", {}, t("prompt_settings.base_prompt"), base),
    el("p", { class: "faint", text: t("prompt_settings.empty_replacement") }));
  const restore = el("button", { type: "button", text: t("prompt_settings.restore_builtin"), onclick: () => {
    replace.checked = false; base.value = ""; dirty.add("base_prompt"); paintReplacement();
  } });
  const fields = el("fieldset", { class: "settings-fields", disabled: true },
    el("label", {}, t("prompt_settings.preset"), preset),
    el("p", { class: "faint", text: t("prompt_settings.preset_help") }),
    replacementNotice,
    el("label", {}, t("prompt_settings.additional_instructions"), instructions),
    el("p", { class: "faint", text: t("prompt_settings.additional_help") }),
    el("details", { class: "settings-details" },
      el("summary", { text: t("prompt_settings.advanced") }),
      el("p", { class: "faint", text: t("prompt_settings.replacement_help") }),
      el("label", { class: "check" }, replace, t("prompt_settings.replace_base_prompt")), baseEditor, restore),
    el("button", { type: "submit", text: t("prompt_settings.save") }));
  const form = el("form", { class: "settings-form", onsubmit: async (event) => {
    event.preventDefault();
    if (saving) return;
    const values = draftValues();
    // A failed publication may already be visible in GET /settings. Keep
    // unacknowledged fields so another deliberate save can publish them again.
    const changes = Object.fromEntries([...dirty].map((key) => [key, values[key]]));
    if (!Object.keys(changes).length) return;
    saving = true; fields.disabled = true;
    try {
      const answer = await save(changes);
      if (!answer) return;
      const current = draftValues();
      for (const [key, value] of Object.entries(changes)) if (current[key] === value) dirty.delete(key);
      update(answer);
    } catch (error) { showError(error); }
    finally { saving = false; fields.disabled = false; }
  } }, fields);
  const element = el("section", { class: "settings-section", "aria-label": t("prompt_settings.working_style") },
    el("h3", { text: t("prompt_settings.working_style") }),
    el("p", { class: "faint", text: t("prompt_settings.apply_help") }), form);

  for (const [key, input] of [["work_preset", preset], ["custom_instructions", instructions], ["base_prompt", base]]) {
    input.addEventListener("input", () => dirty.add(key));
    input.addEventListener("change", () => dirty.add(key));
  }
  replace.addEventListener("change", () => { dirty.add("base_prompt"); paintReplacement(); });

  function draftValues() {
    return { work_preset: preset.value, custom_instructions: instructions.value === "" ? null : instructions.value,
      base_prompt: replace.checked ? base.value : null };
  }
  function paintReplacement() {
    baseEditor.hidden = !replace.checked;
    replacementNotice.hidden = !replace.checked;
    restore.disabled = !replace.checked;
  }
  function update(answer) {
    const observed = answer.settings;
    if (!dirty.has("work_preset")) preset.value = observed.work_preset;
    if (!dirty.has("custom_instructions")) instructions.value = observed.custom_instructions ?? "";
    if (!dirty.has("base_prompt")) {
      replace.checked = observed.base_prompt !== null;
      base.value = observed.base_prompt ?? "";
    }
    fields.disabled = saving;
    paintReplacement();
  }

  return { element, update };
}
