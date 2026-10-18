import { el } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";

export const modelLabel = (row) => row.display_name ? `${row.display_name} · ${row.ref}` : row.ref;

export function paintModels(control, models, value, emptyLabel) {
  const options = emptyLabel === null ? [] : [el("option", { value: "", text: emptyLabel })];
  options.push(...models.map((row) => el("option", { value: row.ref, text: modelLabel(row) })));
  if (value && !models.some((row) => row.ref === value)) {
    options.push(el("option", { value, text: t("common.unavailable_item", { name: value }) }));
  }
  control.replaceChildren(...options);
  control.value = value || "";
}
