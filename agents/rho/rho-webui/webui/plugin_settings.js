import { el } from "./views.js";
import { jsonSetting } from "./settings_state.js";
import { configurationEdits, hasSecrets, pluginDraft, pluginSaveMessage, schemaAt } from "./plugin_draft.js";

const button = (text, onclick, attrs = {}) => el("button", { type: "button", text, onclick, ...attrs });
const pathName = (path) => path.join(" / ");
const json = (value) => JSON.stringify(value, null, 2);
const samePath = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const sourceLabel = (source = {}) => [source.kind || "installed", source.name || source.feature || source.path,
  source.version].filter(Boolean).join(" · ");

export function pluginFieldValue(schema, text) {
  if ((schema.type === "string" || (schema.writeOnly && Array.isArray(schema.type) && schema.type.includes("string"))) && !schema.enum) return text;
  let value;
  try { value = JSON.parse(text); }
  catch { throw new Error("Enter a valid JSON value."); }
  if (schema.type === "integer" && !Number.isSafeInteger(value)) throw new Error("Enter a whole number.");
  if (schema.type === "number" && typeof value !== "number") throw new Error("Enter a number.");
  if (schema.minimum !== undefined && value < schema.minimum) throw new Error(`Enter at least ${schema.minimum}.`);
  if (schema.maximum !== undefined && value > schema.maximum) throw new Error(`Enter at most ${schema.maximum}.`);
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

function diagnosticsText(diagnostics = []) {
  return diagnostics.map((row) => typeof row === "string" ? row : `${pathName(row.path || [])}${row.path?.length ? ": " : ""}${row.message || row.reason || row.code || "Configuration issue"}`).join("\n");
}

export function enabledDependents(inventory, id) {
  const affected = new Set([id]);
  let expanded;
  do {
    expanded = false;
    for (const plugin of inventory) {
      if (!affected.has(plugin.id) && plugin.requires.some((dependency) => affected.has(dependency))) {
        affected.add(plugin.id); expanded = true;
      }
    }
  } while (expanded);
  return inventory.filter((plugin) => plugin.id !== id && plugin.enabled && affected.has(plugin.id));
}

export function pluginSettings({ call, signal, showError, changed = async () => {} }) {
  const cards = new Map();
  let inventory = [];
  let reading = 0;
  let recovery = "rho extensions enable rho.webui";
  const list = el("div", { class: "plugin-list" });
  const inventoryIssues = el("p", { class: "plugin-issues bad", role: "status", hidden: true });
  const element = el("section", { class: "settings-section", "aria-label": "Plugins" },
    el("h3", { text: "Plugins" }),
    el("p", { class: "faint", text: "Choose which capabilities rho provides. Disabled plugins keep their configuration. Save configuration changes separately from enabling or disabling a plugin." }), inventoryIssues, list);

  async function refresh() {
    const request = ++reading;
    const answer = await call("/extensions", { signal });
    if (!signal?.aborted && request === reading) update(answer);
  }

  function update(answer) {
    inventory = answer.plugins; recovery = answer.recovery_command || recovery;
    inventoryIssues.textContent = (answer.failures || []).map((failure) => `${failure.id}: ${failure.message}`).join("\n");
    inventoryIssues.hidden = !inventoryIssues.textContent;
    for (const row of inventory) {
      if (!cards.has(row.id)) cards.set(row.id, pluginCard(row));
      cards.get(row.id).update(row);
    }
    for (const [id, card] of cards) if (!inventory.some((row) => row.id === id) && !card.dirty()) {
      card.element.remove(); cards.delete(id);
    }
    list.replaceChildren(...[...cards.values()].map((card) => card.element));
    if (!inventory.length) list.append(el("p", { class: "muted", text: "No optional plugins are installed." }));
  }

  function pluginCard(initial) {
    const draft = pluginDraft(initial);
    const controls = [];
    const secrets = new Map();
    const secretAdders = new Map();
    const addedSecrets = new Map();
    const invalid = new Map();
    let saving = false;
    let uncertain = false;
    let jsonInvalid = false;
    const heading = el("strong");
    const summary = el("p", { class: "plugin-status muted" });
    const description = el("p", { class: "faint" });
    const capabilities = el("p", { class: "faint" });
    const issues = el("p", { class: "plugin-issues bad", role: "status", hidden: true });
    const feedback = el("p", { role: "status", class: "plugin-feedback", hidden: true });
    const enabled = button("", () => toggle());
    const dependents = el("div", { class: "plugin-dependents" });
    const dependentDetails = el("details", { class: "plugin-dependent-options" }, el("summary", { text: "Also disable…" }),
      el("p", { class: "faint", text: "Select affected plugins when disabling a capability they need." }), dependents);
    const recoveryHint = el("p", { class: "plugin-recovery faint", hidden: initial.id !== "rho.webui" });
    const fields = el("div", { class: "settings-fields" });
    const secretFields = el("div", { class: "settings-fields plugin-secrets" });
    const raw = el("textarea", { rows: 9, spellcheck: "false", autocomplete: "off", class: "mono", "aria-label": `${initial.name} non-secret overrides` });
    const rawError = el("p", { class: "bad", role: "status", hidden: true });
    const save = el("button", { type: "submit", text: "Save configuration" });
    const discard = button("Discard", () => { draft.discard(); invalid.clear(); jsonInvalid = false; feedback.hidden = true; paint(); });
    const reset = button("Restore defaults", () => {
      const keys = new Set([...Object.keys(draft.view().configuration.overrides), ...draft.operations().map((op) => op.path[0])]);
      for (const row of draft.view().configuration.secrets) if (row.set) keys.add(row.path[0]);
      for (const key of keys) draft.unset([key]);
      invalid.clear(); jsonInvalid = false; paint();
    });
    const form = el("form", { class: "settings-form plugin-form", onsubmit: async (event) => { event.preventDefault(); await persist(); } },
      fields, secretFields,
      el("details", { class: "settings-details plugin-json" }, el("summary", { text: "Advanced JSON" }),
        el("p", { class: "faint", text: "Explicit non-secret overrides only. Omitted credentials are kept. Removing a named connection removes its credentials too." }), raw, rawError),
      el("div", { class: "settings-actions plugin-actions" }, save, discard, reset), feedback);
    const element = el("details", { class: "settings-details plugin-card", "data-plugin-id": initial.id },
      el("summary", {}, heading), description, summary, capabilities, issues,
      el("div", { class: "settings-actions" }, enabled), recoveryHint, dependentDetails, form);

    for (const definition of fieldDefinitions(initial.configuration.schema)) addField(definition);
    raw.addEventListener("input", () => {
      try {
        draft.editJSON(jsonSetting(raw.value, "Plugin configuration")); jsonInvalid = false; rawError.hidden = true;
        invalid.clear(); paint(raw);
      } catch (error) { jsonInvalid = true; rawError.textContent = error.message; rawError.hidden = false; paintActions(); }
    });

    function addField({ path, schema }) {
      const label = schema.title || pathName(path);
      const compound = ["object", "array"].includes(schema.type);
      const secretArray = schema.type === "array" && hasSecrets(schema);
      const input = schema.enum || schema.type === "boolean"
        ? el("select", { "aria-label": label })
        : compound || !["string", "number", "integer"].includes(schema.type)
          ? el("textarea", { rows: compound ? 5 : 2, spellcheck: "false", class: "mono", "aria-label": label })
          : el("input", { type: schema.type === "string" ? "text" : "number", "aria-label": label,
            min: schema.minimum, max: schema.maximum, step: schema.type === "integer" ? 1 : "any" });
      if (schema.enum || schema.type === "boolean") {
        input.append(el("option", { value: "", text: "Not set" }));
        for (const value of schema.enum || [true, false]) input.append(el("option", { value: JSON.stringify(value), text: String(value) }));
      }
      input.disabled = schema.readOnly || secretArray;
      const source = el("p", { class: "faint" });
      const error = el("p", { class: "bad", role: "status", hidden: true });
      const restore = button("Restore default", () => { draft.unset(path); invalid.delete(pathName(path)); paint(); }, { disabled: schema.readOnly });
      fields.append(el("div", { class: "plugin-field" }, el("label", {}, label, input),
        ...(schema.description ? [el("p", { class: "faint", text: schema.description })] : []),
        source, ...(secretArray ? [el("p", { class: "faint", text: "This list contains secrets. Use its dedicated setup controls to replace it." })] : []), restore, error));
      controls.push({ path, schema, input, source, error });
      input.addEventListener("input", () => {
        try {
          const value = pluginFieldValue(schema, input.value);
          if (schema.type === "object") {
            const previous = draft.field(path).value ?? {};
            for (const operation of configurationEdits(previous, value, schema, path)) {
              if (operation.op === "unset") draft.unset(operation.path); else draft.set(operation.path, operation.value);
            }
          } else draft.set(path, value);
          invalid.delete(pathName(path)); error.hidden = true; paint(input);
        } catch (failure) { invalid.set(pathName(path), failure.message); error.textContent = failure.message; error.hidden = false; paintActions(); }
      });
    }

    function paintSecrets() {
      const view = draft.view().configuration;
      const removed = (path) => draft.operations().some((op) => op.op === "unset" && op.path.length < path.length && op.path.every((key, index) => path[index] === key));
      const maps = [...secretMaps(view.schema, view.value), ...secretMaps(view.schema, draft.overrides())];
      for (const path of maps) {
        const key = JSON.stringify(path);
        if (secretAdders.has(key)) continue;
        const input = el("input", { type: "text", autocomplete: "off", "aria-label": `${pathName(path)} credential name`, placeholder: "Credential name" });
        const add = button("Add credential", () => {
          const name = input.value.trim();
          if (!name) return;
          const child = [...path, name];
          addedSecrets.set(JSON.stringify(child), child);
          input.value = ""; paintSecrets(); secrets.get(JSON.stringify(child)).input.focus();
        });
        const node = el("div", { class: "plugin-field" }, el("label", {}, `${pathName(path)} — add a secret value`, input), add);
        secretAdders.set(key, { path, node }); secretFields.append(node);
      }
      for (const { path, node } of secretAdders.values()) node.hidden = removed([...path, ""]);
      const paths = [...secretPaths(view.schema, draft.overrides()), ...view.secrets.map((row) => row.path), ...addedSecrets.values()];
      for (const path of paths) {
        const key = JSON.stringify(path);
        if (secrets.has(key)) continue;
        const schema = schemaAt(view.schema, path);
        const label = schema.title || pathName(path);
        const stringSecret = schema.type === "string" || (Array.isArray(schema.type) && schema.type.includes("string"));
        const input = el(stringSecret ? "input" : "textarea", {
          ...(stringSecret ? { type: "password" } : { rows: 3, class: "mono" }),
          autocomplete: "new-password", spellcheck: "false", "aria-label": `${label} replacement`, placeholder: "Leave blank to keep" });
        const status = el("p", { class: "faint" });
        const error = el("p", { class: "bad", role: "status", hidden: true });
        const node = el("div", { class: "plugin-field" }, el("label", {}, label, input), status,
          el("div", { class: "settings-actions" }, button("Keep", () => { draft.keep(path); input.value = ""; invalid.delete(key); paint(); }),
            button("Clear", () => { draft.unset(path); input.value = ""; invalid.delete(key); paint(); })), error);
        secrets.set(key, { path, input, status, error, node }); secretFields.append(node);
        input.addEventListener("input", () => {
          try {
            if (!input.value) draft.keep(path); else draft.set(path, pluginFieldValue(schema, input.value));
            invalid.delete(key); error.hidden = true; paint(input);
          } catch (failure) { invalid.set(key, failure.message); error.textContent = failure.message; error.hidden = false; paintActions(); }
        });
      }
      for (const { path, status, input, error, node } of secrets.values()) {
        node.hidden = removed(path);
        const pending = draft.operations().findLast((op) => samePath(op.path, path));
        status.textContent = pending ? (pending.op === "unset" ? "Will clear on save." : "Replacement pending.")
          : view.secrets.some((row) => row.set && samePath(row.path, path)) ? "Configured. Current value is never shown." : "Not configured.";
        if (!pending) input.value = "";
        if (!invalid.has(JSON.stringify(path))) error.hidden = true;
      }
    }

    function paintActions() {
      save.disabled = saving || jsonInvalid || invalid.size > 0 || !draft.dirty();
      discard.disabled = !draft.dirty() && !jsonInvalid && invalid.size === 0;
      enabled.disabled = saving || (!draft.view().enabled && draft.view().configurable === false);
      save.textContent = saving ? "Saving…" : "Save configuration";
      form.classList.toggle("is-dirty", draft.dirty() || jsonInvalid || invalid.size > 0);
    }

    function paint(skip) {
      const row = draft.view();
      heading.textContent = row.name || row.id;
      const savedSource = sourceLabel(row.source);
      const activeSource = row.active_source && sourceLabel(row.active_source);
      description.textContent = `${row.description || ""} ${row.id} · Saved source: ${savedSource}${activeSource && activeSource !== savedSource ? ` · Running source: ${activeSource}` : ""}`.trim();
      form.hidden = row.configurable === false;
      summary.textContent = `Requested: ${row.enabled ? "enabled" : "disabled"} · Running: ${row.active ? "active" : "inactive"} · ${row.readiness.ready ? "Ready" : "Setup needed"}${row.restart_required ? " · Restart required" : ""}`;
      const tools = row.capabilities.tools;
      const commands = row.capabilities.commands;
      capabilities.textContent = [tools.length ? `Tools: ${tools.join(", ")}` : "", commands.length ? `Commands: ${commands.join(", ")}` : ""].filter(Boolean).join(" · ");
      capabilities.hidden = !capabilities.textContent;
      const text = diagnosticsText([...row.configuration.diagnostics, ...row.readiness.issues]);
      issues.textContent = text; issues.hidden = !text;
      enabled.textContent = row.enabled ? "Disable plugin" : "Enable plugin";
      dependentDetails.hidden = !row.enabled || !dependents.childElementCount;
      recoveryHint.textContent = `Disabling this plugin closes WebUI access. Restore it from the terminal with: ${recovery}`;
      for (const { path, schema, input, source, error } of controls) {
        const field = draft.field(path);
        source.textContent = field.overridden ? "Explicit override." : field.value === undefined ? "Not set." : "Inherited default or file fallback.";
        if (input !== skip && !invalid.has(pathName(path))) input.value = field.value === undefined ? "" : schema.type === "string" && !schema.enum ? field.value : json(field.value);
        if (!invalid.has(pathName(path))) error.hidden = true;
      }
      if (skip !== raw && !jsonInvalid) raw.value = json(draft.overrides());
      if (!jsonInvalid) rawError.hidden = true;
      paintSecrets(); paintActions();
    }

    async function operation(path, body, method, submitted = []) {
      if (saving) return;
      saving = true; paintActions(); feedback.hidden = true;
      try {
        if (uncertain) { await refresh(); uncertain = false; }
        ++reading;
        const answer = await call(path, { method, body, signal });
        if (signal?.aborted) return;
        if (answer.saved || answer.published) draft.acknowledge(submitted, answer.plugin);
        else if (answer.plugin) draft.update(answer.plugin);
        feedback.textContent = [pluginSaveMessage(answer), diagnosticsText(answer.diagnostics)].filter(Boolean).join(" ");
        feedback.hidden = false; paint();
        try { await changed(answer); } catch (error) { showError(error); }
      } catch (error) {
        if (signal?.aborted) return;
        const answer = error.details || {};
        if (answer.published || answer.saved) {
          draft.acknowledge(submitted, answer.plugin);
          feedback.textContent = pluginSaveMessage(answer); feedback.hidden = false;
        } else {
          uncertain = !error.status;
          feedback.textContent = uncertain ? "Save outcome is unknown. Your draft is kept; the saved state will be read before another attempt." : error.message;
          feedback.hidden = false;
        }
        showError(error); paint();
      } finally { saving = false; paintActions(); }
    }

    async function persist() {
      if (invalid.size || jsonInvalid || !draft.dirty()) return;
      const submitted = draft.operations();
      await operation(`/extensions/${encodeURIComponent(initial.id)}/configuration`, { operations: submitted }, "PATCH", submitted);
    }
    async function toggle() {
      const row = draft.view();
      const selected = [...dependents.querySelectorAll("input:checked")].map((input) => input.value);
      await operation(`/extensions/${encodeURIComponent(row.id)}/${row.enabled ? "disable" : "enable"}`, { dependents: selected }, "POST");
    }
    return { element, dirty: () => draft.dirty() || jsonInvalid || invalid.size > 0,
      update: (row) => {
        draft.update(row);
        const checked = new Set([...dependents.querySelectorAll("input:checked")].map((input) => input.value));
        dependents.replaceChildren(...enabledDependents(inventory, row.id).map((plugin) =>
          el("label", { class: "check" }, el("input", { type: "checkbox", value: plugin.id, checked: checked.has(plugin.id) }), plugin.name || plugin.id)));
        paint();
      }, clearSecrets: () => {
        draft.clearSecrets();
        for (const [key, { input }] of secrets) { input.value = ""; invalid.delete(key); }
        paint();
      } };
  }

  return { element, update, refresh, clearSecrets: () => { for (const card of cards.values()) card.clearSecrets(); } };
}
