import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { input, textarea, select, field, checkbox } from "../../primitives/field.js";
import { button } from "../../primitives/button.js";

// Drafts contain control text, not coerced answers. Conversion happens only
// when submitting, so an unfinished number survives an ordinary refresh.
export function questionForm(ask, { writable, draft, save, respond }) {
  let pending = false;
  const rows = ask.fields.map((definition) => {
    const { name, label, type, required, options } = definition;
    const state = Object.hasOwn(draft, name) ? draft[name]
      : (draft[name] = { included: !!required, value: type === "multichoice" ? [] : "" });
    let control;
    let read;
    let focus;
    if (type === "multichoice") {
      const choices = options.map((option) => checkbox({ label: option, checked: state.value.includes(option) }));
      control = el("fieldset", { class: "question-form__choices" },
        el("legend", { class: "sr-only", text: label }), choices.map((choice) => choice.element));
      read = () => options.filter((_, index) => choices[index].input.checked);
      focus = () => choices[0].input.focus();
    } else if (type === "boolean" || type === "choice") {
      const choices = type === "boolean"
        ? [{ value: "true", label: t("question.yes") }, { value: "false", label: t("question.no") }]
        : options.map((option, index) => ({ value: String(index), label: option }));
      control = select({ value: state.value, options: [{ value: "", label: t("question.choose") }, ...choices] });
      read = () => control.value;
      focus = () => control.focus();
    } else {
      control = type === "string" ? textarea({ value: state.value, rows: 2 })
        : input({ value: state.value, inputmode: "decimal", autocomplete: "off" });
      read = () => control.value;
      focus = () => control.focus();
    }
    const view = field({ label, control, hint: required ? t("question.required") : t("question.optional") });
    const include = required ? null : checkbox({ label: t("question.include", { label }), checked: state.included });
    const capture = () => { state.value = read(); save(); view.setError(""); };
    control.addEventListener("input", capture);
    control.addEventListener("change", capture);
    include?.input.addEventListener("change", () => { state.included = include.input.checked; save(); paint(); view.setError(""); });
    function paint() {
      if (include) include.input.disabled = !writable || pending;
      const disabled = !writable || pending || !state.included;
      control.disabled = disabled;
      for (const child of control.querySelectorAll("input")) child.disabled = disabled;
    }
    paint();
    return { name, state, focus, paint, element: el("div", { class: "question-form__field" }, include?.element, view.element),
      value() {
        const raw = read();
        if (type === "boolean" || type === "choice") {
          if (raw === "") { view.setError(t("question.choose")); return { valid: false }; }
          return { valid: true, value: type === "boolean" ? raw === "true" : options[Number(raw)] };
        }
        if (type === "integer" || type === "number") {
          const number = Number(raw);
          if (!raw.trim() || !Number.isFinite(number) || (type === "integer" && !Number.isSafeInteger(number))) {
            view.setError(type === "integer" ? t("question.integer") : t("question.number"));
            return { valid: false };
          }
          return { valid: true, value: number };
        }
        return { valid: true, value: raw };
      },
    };
  });
  const submit = button({ label: t("seat.send_answer"), variant: "primary", size: "sm", type: "submit", disabled: !writable });
  const form = el("form", { class: "ask__form question-form", onsubmit: async (event) => {
    event.preventDefault();
    if (!writable || pending) return;
    const answer = {};
    let invalid;
    for (const row of rows) {
      if (!row.state.included) continue;
      const result = row.value();
      if (!result.valid) invalid ||= row;
      else answer[row.name] = result.value;
    }
    if (invalid) { invalid.focus(); return; }
    pending = true; submit.disabled = true; rows.forEach((row) => row.paint());
    if (!await respond({ answer }) && form.isConnected) {
      pending = false; submit.disabled = !writable; rows.forEach((row) => row.paint());
    }
  } }, el("div", { class: "question-form__fields" }, rows.map((row) => row.element)),
  el("div", { class: "ask__actions" }, submit));
  return { element: form, focus: () => (form.querySelector("input:not([disabled]), select:not([disabled]), textarea:not([disabled])") || submit).focus() };
}
