import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { button, field, select } from "../../primitives/index.js";
import { modelLabel, paintModels } from "../../primitives/model_choices.js";

// A complete ordered override. Inheritance, no fallback, and an authored
// list stay distinct; the initial model is never inserted into this list.
export function orderedModels({ value = [], models = [], inherit = false, onChange = () => {} } = {}) {
  let ordered = [...(value || [])];
  let mode = value === null && inherit ? "inherit" : ordered.length ? "custom" : "off";
  const choice = select({ name: "fallback_models_mode", value: mode, options: [
    ...(inherit ? [{ value: "inherit", label: t("presets.fallback_inherit") }] : []),
    { value: "off", label: t("presets.fallback_off") }, { value: "custom", label: t("presets.fallback_custom") },
  ] });
  const rows = el("ol", { class: "ordered-models__rows" });
  const available = select({ name: "fallback_model_add", attrs: { "aria-label": t("presets.fallback_add_model") } });
  const add = button({ label: t("presets.fallback_add"), size: "sm", onClick: () => {
    if (!available.value || ordered.includes(available.value)) return;
    ordered.push(available.value); paint(); onChange();
  } });
  const custom = el("div", { class: "ordered-models__custom" }, rows,
    el("div", { class: "ordered-models__add" }, available, add));
  const element = el("div", { class: "ordered-models" },
    field({ label: t("presets.fallback_models"), control: choice, hint: t("presets.fallback_help") }).element, custom);
  choice.addEventListener("change", () => { mode = choice.value; paint(); onChange(); });

  function move(index, direction) {
    const next = index + direction;
    [ordered[index], ordered[next]] = [ordered[next], ordered[index]];
    paint(); onChange();
    rows.children[next]?.querySelector(direction < 0 ? "[data-move=up]" : "[data-move=down]")?.focus();
  }

  function paint() {
    choice.value = mode;
    custom.hidden = mode !== "custom";
    rows.replaceChildren(...ordered.map((ref, index) => {
      const row = models.find((entry) => entry.ref === ref);
      const label = row ? modelLabel(row) : t("common.unavailable_item", { name: ref });
      return el("li", { class: "ordered-models__row", "data-model": ref },
        el("span", { class: "ordered-models__name", text: label }),
        el("div", { class: "row" },
          button({ label: t("presets.move_up"), size: "sm", disabled: index === 0,
            attrs: { "data-move": "up", "aria-label": t("presets.move_model_up", { model: ref }) }, onClick: () => move(index, -1) }),
          button({ label: t("presets.move_down"), size: "sm", disabled: index === ordered.length - 1,
            attrs: { "data-move": "down", "aria-label": t("presets.move_model_down", { model: ref }) }, onClick: () => move(index, 1) }),
          button({ label: t("common.remove"), size: "sm", attrs: { "aria-label": t("presets.remove_model", { model: ref }) },
            onClick: () => { ordered.splice(index, 1); paint(); onChange(); available.focus(); } })));
    }));
    const remaining = models.filter((row) => !ordered.includes(row.ref));
    paintModels(available, remaining, "", t("presets.fallback_add_model"));
    available.disabled = remaining.length === 0;
    add.disabled = remaining.length === 0;
  }
  paint();
  return {
    element,
    read: () => mode === "inherit" ? null : mode === "off" ? [] : [...ordered],
    set(next) { ordered = [...(next || [])]; mode = next === null && inherit ? "inherit" : ordered.length ? "custom" : "off"; paint(); },
    update(next) { models = next; paint(); },
  };
}
