import { el, uniqueId } from "../kernel/dom.js";
import { icon } from "./button.js";

const attributes = (fields) => Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined && value !== null && value !== false));

export function input({ name, type = "text", value = "", placeholder, autocomplete, inputmode, pattern, min, max, step, required, disabled, spellcheck, mono = false, attrs = {} } = {}) {
  const node = el("input", attributes({ class: `control${mono ? " control--mono" : ""}`, name, type, placeholder, autocomplete, inputmode, pattern, min, max, step, required, disabled, spellcheck, ...attrs }));
  node.value = value;
  return node;
}

export function textarea({ name, rows = 3, value = "", placeholder, required, disabled, mono = false, attrs = {} } = {}) {
  const node = el("textarea", attributes({ class: `control control--textarea${mono ? " control--mono" : ""}`, name, rows, placeholder, required, disabled, spellcheck: mono ? "false" : undefined, ...attrs }));
  node.value = value;
  return node;
}

export function select({ name, options = [], value, required, disabled, attrs = {} } = {}) {
  const node = el("select", attributes({ class: "control control--select", name, required, disabled, ...attrs }),
    options.map((option) => el("option", attributes({ value: option.value, text: option.label, disabled: option.disabled }))));
  if (value !== undefined) node.value = value;
  return node;
}

// A labelled control with optional hint and error, wired for assistive
// technology through generated ids.
export function field({ label, control, hint, error }) {
  const id = control.id || uniqueId("field");
  control.id = id;
  const hintNode = el("p", { class: "field__hint", id: `${id}-hint`, text: hint, hidden: !hint });
  const errorNode = el("p", { class: "field__error", id: `${id}-error`, role: "status", text: error, hidden: !error });
  const describe = () => {
    const ids = [!hintNode.hidden && hintNode.id, !errorNode.hidden && errorNode.id].filter(Boolean).join(" ");
    if (ids) control.setAttribute("aria-describedby", ids); else control.removeAttribute("aria-describedby");
  };
  describe();
  const element = el("div", { class: "field" }, el("label", { class: "field__label", for: id, text: label }), control, hintNode, errorNode);
  return {
    element,
    setError(text) {
      errorNode.textContent = text || ""; errorNode.hidden = !text;
      control.toggleAttribute("aria-invalid", !!text);
      describe();
    },
    setHint(text) { hintNode.textContent = text || ""; hintNode.hidden = !text; describe(); },
  };
}

export function checkbox({ name, label, checked = false, disabled = false, onChange } = {}) {
  const control = el("input", attributes({ type: "checkbox", name, disabled, onchange: onChange }));
  control.checked = checked;
  return { element: el("label", { class: "check" }, control, el("span", { text: label })), input: control };
}

export function switchControl({ label, checked = false, disabled = false, onChange, attrs = {} } = {}) {
  const control = el("input", attributes({ type: "checkbox", role: "switch", class: "switch__input", disabled, onchange: onChange, ...attrs }));
  control.checked = checked;
  const element = el("label", { class: "switch" }, control, el("span", { class: "switch__track", "aria-hidden": "true" }, el("span", { class: "switch__thumb" })),
    el("span", { class: label === "" ? "sr-only" : "switch__label", text: label }));
  return { element, input: control, set(value, { disabled: off } = {}) { control.checked = !!value; if (off !== undefined) control.disabled = off; } };
}

// A radio group drawn as one segmented control.
export function segmented({ name = uniqueId("segment"), label, options, value, onChange }) {
  const inputs = options.map((option) => {
    const radio = el("input", attributes({ type: "radio", name, value: option.value, class: "segmented__input", disabled: option.disabled,
      onchange: () => onChange?.(option.value) }));
    radio.checked = option.value === value;
    return [radio, el("label", { class: "segmented__option" }, radio, option.icon ? icon(option.icon) : null, el("span", { text: option.label }))];
  });
  const element = el("fieldset", { class: "segmented" }, el("legend", { class: "sr-only", text: label }), inputs.map(([, node]) => node));
  return { element, set(next) { for (const [radio] of inputs) radio.checked = radio.value === String(next); } };
}

// Integer stepper for bounded settings such as the content size.
export function stepper({ label, value, min, max, step = 1, onChange, format = (number) => String(number) }) {
  let current = value;
  const readout = el("output", { class: "stepper__value", text: format(current), "aria-live": "polite" });
  const change = (delta) => {
    const next = Math.min(max, Math.max(min, current + delta));
    if (next === current) return;
    current = next; readout.textContent = format(current); paint(); onChange?.(current);
  };
  const minus = el("button", { type: "button", class: "btn btn--ghost btn--icon btn--sm", "aria-label": `${label} −`, onclick: () => change(-step) }, icon("minus"));
  const plus = el("button", { type: "button", class: "btn btn--ghost btn--icon btn--sm", "aria-label": `${label} +`, onclick: () => change(step) }, icon("plus"));
  function paint() { minus.disabled = current <= min; plus.disabled = current >= max; }
  paint();
  return { element: el("div", { class: "stepper", role: "group", "aria-label": label }, minus, readout, plus), set(next) { current = next; readout.textContent = format(current); paint(); } };
}
