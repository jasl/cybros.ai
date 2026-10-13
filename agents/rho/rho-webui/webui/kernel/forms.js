import { t } from "./i18n.js";

// Advanced editors accept JSON only for whole objects; a scalar or a list is
// a typo in a settings field, not a configuration.
export function jsonObject(text, label) {
  let value;
  try { value = JSON.parse(text); }
  catch { throw new Error(t("forms.must_be_valid_json", { label })); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(t("forms.must_be_a_json_object", { label }));
  return value;
}

// Only fields whose value differs from the saved document are written, so a
// form that re-submits untouched fields never overwrites a concurrent change.
export function changedFields(previous, edited) {
  return Object.fromEntries(Object.entries(edited).filter(([key, value]) => JSON.stringify(value) !== JSON.stringify(previous[key])));
}
