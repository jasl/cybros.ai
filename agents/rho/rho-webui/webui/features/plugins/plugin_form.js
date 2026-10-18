import { el } from "../../kernel/dom.js";
import { t, pluginText } from "../../kernel/i18n.js";
import { jsonObject } from "../../kernel/forms.js";
import { button, field, input, select, textarea } from "../../primitives/index.js";
import { configurationEdits, diagnosticsText, hasSecrets, pathName, pluginDraft, pluginSaveMessage, schemaAt } from "./plugin_draft.js";

const json = (value) => JSON.stringify(value, null, 2);
const samePath = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const types = (schema) => [].concat(schema.type ?? []);
// A string, or a string that may also be null, without a closed set of values: typed as text.
export const stringField = (schema) => !schema.enum && types(schema).includes("string") && types(schema).every((type) => type === "string" || type === "null");
const nullable = (schema) => types(schema).includes("null");
// `x-rho-choices` names the daemon catalog the field is chosen from; the daemon refuses any other shape.
const choicesOf = (schema) => schema["x-rho-choices"] || null;
const catalogKey = (schema) => `${choicesOf(schema).source}:${choicesOf(schema).workload}`;

export function pluginFieldValue(schema, text) {
  if (stringField(schema)) return text;
  let value;
  try { value = JSON.parse(text); }
  catch { throw new Error(t("plugin_settings.enter_a_valid_json_value")); }
  if (schema.type === "integer" && !Number.isSafeInteger(value)) throw new Error(t("plugin_settings.enter_a_whole_number"));
  if (schema.type === "number" && typeof value !== "number") throw new Error(t("plugin_settings.enter_a_number"));
  if (schema.minimum !== undefined && value < schema.minimum) throw new Error(t("plugin_settings.enter_at_least", { minimum: schema.minimum }));
  if (schema.maximum !== undefined && value > schema.maximum) throw new Error(t("plugin_settings.enter_at_most", { maximum: schema.maximum }));
  return value;
}

function secretPaths(schema, value, path = []) {
  if (schema.writeOnly) return [path];
  const declared = Object.entries(schema.properties || {}).flatMap(([key, child]) => secretPaths(child, value?.[key], [...path, key]));
  if (object(schema.additionalProperties) && object(value)) {
    for (const [key, child] of Object.entries(value)) {
      if (!Object.hasOwn(schema.properties || {}, key)) declared.push(...secretPaths(schema.additionalProperties, child, [...path, key]));
    }
  }
  return declared;
}

// Named maps whose entries are secrets: each gets an "add credential" row.
function secretMaps(schema, value, path = []) {
  if (schema.writeOnly) return [];
  if (schema.additionalProperties?.writeOnly) return [path];
  const paths = Object.entries(schema.properties || {}).flatMap(([key, child]) => secretMaps(child, value?.[key], [...path, key]));
  if (object(schema.additionalProperties) && object(value)) {
    for (const [key, child] of Object.entries(value)) {
      if (!Object.hasOwn(schema.properties || {}, key)) paths.push(...secretMaps(schema.additionalProperties, child, [...path, key]));
    }
  }
  return paths;
}

function fieldDefinitions(schema, path = []) {
  return Object.entries(schema.properties || {}).flatMap(([key, child]) => {
    const keys = [...path, key];
    if (child.writeOnly) return [];
    if (child.type === "object" && child.properties && !child.additionalProperties) return fieldDefinitions(child, keys);
    return [{ path: keys, schema: child }];
  });
}

function control(schema) {
  if (choicesOf(schema)) return select({ options: [{ value: "", label: t("common.not_set") }] });
  if (schema.enum || schema.type === "boolean") {
    return select({ options: [{ value: "", label: t("common.not_set") }, ...(schema.enum || [true, false]).map((value) => ({
      value: JSON.stringify(value), label: value === true ? t("common.boolean_true") : value === false ? t("common.boolean_false") : String(value) }))] });
  }
  if (stringField(schema)) return input({ type: "text" });
  if (["number", "integer"].includes(schema.type)) {
    return input({ type: "number", min: schema.minimum, max: schema.maximum, step: schema.type === "integer" ? 1 : "any" });
  }
  return textarea({ rows: ["object", "array"].includes(schema.type) ? 5 : 2, mono: true });
}

// A choice field's options: Not set, the catalog's rows, and the current
// value when the catalog does not list it, so a saved reference stays visible.
function paintChoiceOptions(box, rows, value) {
  box.replaceChildren(el("option", { value: "", text: t("common.not_set") }),
    ...rows.map((row) => el("option", { value: row.value, text: row.label })));
  if (value && !rows.some((row) => row.value === value)) box.append(el("option", { value, text: t("common.unavailable_item", { name: value }) }));
}

// The generic configuration body of a plugin: fields generated from its
// schema, separate keep/replace/clear controls for secrets, and the explicit
// non-secret overrides as JSON. Both editors share one draft; the daemon
// owns validation and application, and a refresh never acknowledges a save.
export function pluginForm(shell, initialProps) {
  let props = initialProps;
  const plugin = initialProps.plugin;
  const label = (path, schema) => t(`plugins.${plugin.id}.configuration.${path.join(".")}.title`, {}, schema.title || pathName(path));
  const draft = pluginDraft(plugin);
  const controls = [];
  const catalogs = new Map();
  const reads = new AbortController();
  const secrets = new Map();
  const secretAdders = new Map();
  const addedSecrets = new Map();
  const invalid = new Map();
  let saving = false;
  let uncertain = false;
  let jsonInvalid = false;
  const fields = el("div", { class: "plugin-form__fields" });
  const secretFields = el("div", { class: "plugin-form__fields" });
  const raw = textarea({ rows: 9, mono: true, attrs: { "aria-label": t("plugin_settings.non_secret_overrides", { name: pluginText(plugin, "name") }) } });
  const rawError = el("p", { class: "field__error", role: "status", hidden: true });
  const advanced = el("details", { class: "form-group plugin-form__json" },
    el("summary", { text: t("plugin_settings.edit_as_json") }),
    el("p", { class: "field__hint", text: t("plugin_settings.explicit_non_secret_overrides_only_omitted_credentials_are") }), raw, rawError);
  const save = button({ label: t("common.save_configuration"), variant: "primary", size: "sm", type: "submit" });
  const discard = button({ label: t("plugin_settings.discard"), size: "sm", onClick: () => {
    draft.discard(); invalid.clear(); jsonInvalid = false; feedback.hidden = true; paint();
  } });
  const reset = button({ label: t("plugin_settings.restore_defaults"), variant: "ghost", size: "sm", onClick: () => {
    const keys = new Set([...Object.keys(draft.view().configuration.overrides), ...draft.operations().map((op) => op.path[0])]);
    for (const row of draft.view().configuration.secrets) if (row.set) keys.add(row.path[0]);
    for (const key of keys) draft.unset([key]);
    invalid.clear(); jsonInvalid = false; paint();
  } });
  const feedback = el("p", { class: "plugin-form__feedback", role: "status", hidden: true });
  const element = el("form", { class: "card plugin-form", onsubmit: (event) => { event.preventDefault(); persist(); } },
    fields, secretFields, advanced, el("div", { class: "plugin-form__actions" }, save, discard, reset), feedback);

  function addField({ path, schema }) {
    const box = control(schema);
    const secretList = schema.type === "array" && hasSecrets(schema);
    box.disabled = !!schema.readOnly || secretList;
    const description = schema.description ? t(`plugins.${plugin.id}.configuration.${path.join(".")}.description`, {}, schema.description) : null;
    const wrapper = field({ label: label(path, schema), control: box, hint: description });
    const source = el("span", { class: "plugin-form__source" });
    const restore = button({ label: t("plugin_settings.restore_default"), variant: "ghost", size: "sm", disabled: !!schema.readOnly,
      onClick: () => { draft.unset(path); invalid.delete(pathName(path)); paint(); } });
    fields.append(el("div", { class: "plugin-form__field" }, wrapper.element,
      secretList ? el("p", { class: "field__hint", text: t("plugin_settings.this_list_contains_secrets_use_its_dedicated_setup") }) : null,
      el("div", { class: "plugin-form__meta" }, source, restore)));
    controls.push({ path, schema, input: box, source, field: wrapper });
    const edit = () => {
      try {
        // "Not set" in a choice, or a blank nullable text, is the field's default, never a typed value.
        if (box.value === "" && (box.localName === "select" || nullable(schema))) draft.unset(path);
        else if (schema.type === "object") {
          const value = pluginFieldValue(schema, box.value);
          for (const operation of configurationEdits(draft.field(path).value ?? {}, value, schema, path)) {
            if (operation.op === "unset") draft.unset(operation.path); else draft.set(operation.path, operation.value);
          }
        } else draft.set(path, pluginFieldValue(schema, box.value));
        invalid.delete(pathName(path)); wrapper.setError(null); paint(box);
      } catch (failure) { invalid.set(pathName(path), failure.message); wrapper.setError(failure.message); paintActions(); }
    };
    box.addEventListener(box.localName === "select" ? "change" : "input", edit);
  }

  function secretRow(path, view) {
    const key = JSON.stringify(path);
    const schema = schemaAt(view.schema, path);
    const text = schema.type === "string" || (Array.isArray(schema.type) && schema.type.includes("string"));
    const box = text ? input({ type: "password", autocomplete: "new-password", spellcheck: "false", placeholder: t("plugin_settings.leave_blank_to_keep") })
      : textarea({ rows: 3, mono: true, attrs: { placeholder: t("plugin_settings.leave_blank_to_keep"), autocomplete: "off" } });
    const wrapper = field({ label: t("plugin_settings.secret_replacement", { label: label(path, schema) }), control: box });
    const status = el("span", { class: "plugin-form__source" });
    const settle = (change) => { change(); box.value = ""; invalid.delete(key); wrapper.setError(null); paint(); };
    const node = el("div", { class: "plugin-form__field" }, wrapper.element, el("div", { class: "plugin-form__meta" }, status,
      button({ label: t("plugin_settings.keep"), variant: "ghost", size: "sm", onClick: () => settle(() => draft.keep(path)) }),
      button({ label: t("plugin_settings.clear"), variant: "ghost", size: "sm", onClick: () => settle(() => draft.unset(path)) })));
    box.addEventListener("input", () => {
      try {
        if (!box.value) draft.keep(path); else draft.set(path, pluginFieldValue(schema, box.value));
        invalid.delete(key); wrapper.setError(null); paint(box);
      } catch (failure) { invalid.set(key, failure.message); wrapper.setError(failure.message); paintActions(); }
    });
    secrets.set(key, { path, input: box, status, field: wrapper, node });
    secretFields.append(node);
  }

  function adderRow(path) {
    const name = input({ autocomplete: "off", placeholder: t("plugin_settings.credential_name") });
    const add = button({ label: t("plugin_settings.add_credential"), size: "sm", onClick: () => {
      const entry = name.value.trim();
      if (!entry) return;
      const child = [...path, entry];
      addedSecrets.set(JSON.stringify(child), child);
      name.value = "";
      paintSecrets();
      secrets.get(JSON.stringify(child)).input.focus();
    } });
    const node = el("div", { class: "plugin-form__field" }, field({ label: t("plugin_settings.add_a_secret_value", { pathName: pathName(path) }), control: name }).element, add);
    secretAdders.set(JSON.stringify(path), { path, node });
    secretFields.append(node);
  }

  function paintSecrets() {
    const view = draft.view().configuration;
    // A reset of a containing entry removes its secrets with it.
    const removed = (path) => draft.operations().some((op) => op.op === "unset" && op.path.length < path.length && op.path.every((key, index) => path[index] === key));
    for (const path of [...secretMaps(view.schema, view.value), ...secretMaps(view.schema, draft.overrides())]) {
      if (!secretAdders.has(JSON.stringify(path))) adderRow(path);
    }
    for (const { path, node } of secretAdders.values()) node.hidden = removed([...path, ""]);
    for (const path of [...secretPaths(view.schema, draft.overrides()), ...view.secrets.map((row) => row.path), ...addedSecrets.values()]) {
      if (!secrets.has(JSON.stringify(path))) secretRow(path, view);
    }
    for (const { path, status, input: box, field: wrapper, node } of secrets.values()) {
      node.hidden = removed(path);
      const pending = draft.operations().findLast((op) => samePath(op.path, path));
      status.textContent = pending ? (pending.op === "unset" ? t("plugin_settings.will_clear_on_save") : t("plugin_settings.replacement_pending"))
        : view.secrets.some((row) => row.set && samePath(row.path, path)) ? t("plugin_settings.configured_current_value_is_never_shown") : t("plugin_settings.not_configured");
      if (!pending) box.value = "";
      if (!invalid.has(JSON.stringify(path))) wrapper.setError(null);
    }
  }

  function paintActions() {
    save.disabled = saving || jsonInvalid || invalid.size > 0 || !draft.dirty();
    discard.disabled = !draft.dirty() && !jsonInvalid && invalid.size === 0;
    save.querySelector(".btn__label").textContent = saving ? t("plugin_settings.saving") : t("common.save_configuration");
    element.classList.toggle("is-dirty", draft.dirty() || jsonInvalid || invalid.size > 0);
  }

  function paint(skip) {
    for (const { path, schema, input: box, source, field: wrapper } of controls) {
      const current = draft.field(path);
      source.textContent = current.overridden ? t("plugin_settings.explicit_override")
        : current.value === undefined ? t("plugin_settings.not_set") : t("plugin_settings.inherited_default_or_file_fallback");
      if (box !== skip && !invalid.has(pathName(path))) {
        const text = current.value === undefined || current.value === null ? "" : stringField(schema) ? current.value : json(current.value);
        if (choicesOf(schema)) paintChoiceOptions(box, catalogs.get(catalogKey(schema)) || [], text);
        box.value = text;
      }
      if (!invalid.has(pathName(path))) wrapper.setError(null);
    }
    if (skip !== raw && !jsonInvalid) raw.value = json(draft.overrides());
    if (!jsonInvalid) rawError.hidden = true;
    paintSecrets();
    paintActions();
  }

  function say(text, tone) {
    feedback.textContent = text;
    feedback.dataset.tone = tone;
    feedback.hidden = !text;
  }

  // After a lost response the saved state is read before another write.
  async function persist() {
    if (saving || invalid.size || jsonInvalid || !draft.dirty()) return;
    saving = true; paintActions(); feedback.hidden = true;
    let submitted = [];
    try {
      if (uncertain) { await props.refresh(); uncertain = false; }
      submitted = draft.operations();
      const answer = await shell.call(`/extensions/${encodeURIComponent(plugin.id)}/configuration`, { method: "PATCH", body: { operations: submitted } });
      if (answer.saved || answer.published) draft.acknowledge(submitted, answer.plugin);
      else if (answer.plugin) draft.update(answer.plugin);
      say([pluginSaveMessage(answer), diagnosticsText(answer.diagnostics)].filter(Boolean).join(" "), answer.saved && answer.applied ? "success" : "warning");
      await shell.inventory.accept(answer);
    } catch (error) {
      if (error.name === "AbortError" || error.status === 401) return;
      const answer = error.details || {};
      if (answer.published || answer.saved) {
        draft.acknowledge(submitted, answer.plugin);
        say(pluginSaveMessage(answer), "warning");
        await shell.inventory.accept(answer);
      } else {
        uncertain = !error.status;
        say(uncertain ? t("plugin_settings.save_outcome_is_unknown_your_draft_is_kept") : error.message, "error");
      }
    } finally {
      saving = false;
      paint();
    }
  }

  function clearSecrets() {
    draft.clearSecrets();
    for (const [key, { input: box }] of secrets) { box.value = ""; invalid.delete(key); }
    paint();
  }

  raw.addEventListener("input", () => {
    try {
      draft.editJSON(jsonObject(raw.value, t("plugin_settings.plugin_settings")));
      jsonInvalid = false; rawError.hidden = true; invalid.clear(); paint(raw);
    } catch (error) { jsonInvalid = true; rawError.textContent = error.message; rawError.hidden = false; paintActions(); }
  });
  // Each catalog a choice field names is read once; a read that fails leaves
  // the field on its saved value, still selectable.
  async function loadCatalogs() {
    const keys = new Set(controls.filter(({ schema }) => choicesOf(schema)).map(({ schema }) => catalogKey(schema)));
    await Promise.all([...keys].map(async (key) => {
      const workload = key.slice(key.indexOf(":") + 1);
      try {
        const answer = await shell.call(`/models?workload=${encodeURIComponent(workload)}`, { signal: reads.signal });
        catalogs.set(key, answer.models.map((model) => ({ value: model.ref, label: model.display_name ? `${model.display_name} · ${model.ref}` : model.ref })));
      } catch { /* the saved value stays the one option beside Not set */ }
    }));
    if (keys.size) paint();
  }

  for (const definition of fieldDefinitions(plugin.configuration.schema)) addField(definition);
  paint();
  loadCatalogs();
  if (!controls.length && !secrets.size && !secretAdders.size) fields.append(el("p", { class: "field__hint", text: t("plugin_page.no_fields") }));

  return {
    element,
    // A hidden page drops typed secrets, as closing a settings dialog did.
    update(next) {
      props = next;
      draft.update(next.plugin);
      if (next.visible === false) clearSecrets(); else paint();
    },
    dispose() { reads.abort(); },
  };
}
