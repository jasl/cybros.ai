import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, field, input, list, modal, section, select } from "../../primitives/index.js";

const scopes = ["conversation", "workspace", "agent", "speaker"];
const scopeLabel = (scope) => t(`memory_bindings.scope_${scope}`);
const accessLabel = (access) => t(`memory_bindings.access_${access}`);
const sourceKey = (source) => source.collection_public_id ? `collection:${source.collection_public_id}` : `scope:${source.scope}`;

// Authoring replaces the future selection. The effective rows remain server
// projections; neither a picker choice nor a saved alias grants permission.
export function openMemoryBindings({ editor, writable, id }) {
  let disposed = false;
  let entries = [];
  let inventory = [];
  let after = null;
  let loaded = false;
  let saving = false;
  const error = alert();
  const loading = el("p", { class: "text-secondary", text: t("memory_bindings.loading") });
  const mode = select({ options: ["automatic", "custom", "disabled"].map((value) => ({ value, label: t(`memory_bindings.mode_${value}`) })) });
  const rows = el("div", { class: "memory-bindings__rows" });
  const effective = list({ empty: t("memory_bindings.empty") });
  const effectiveSection = section({ title: t("memory_bindings.effective"), description: t("memory_bindings.effective_help"), level: 3 });
  effectiveSection.body.append(effective.element);
  const add = button({ label: t("memory_bindings.add"), icon: "plus", size: "sm", onClick: () => addRow({ name: "", source: { scope: "workspace" }, access: "read" }) });
  const more = button({ label: t("memory_bindings.load_collections"), size: "sm", onClick: loadCollections });
  const custom = el("div", { class: "memory-bindings__custom" }, rows, el("div", { class: "memory-bindings__actions" }, add, more));
  const controls = el("fieldset", { class: "memory-bindings__fields", disabled: true },
    field({ label: t("memory_bindings.mode"), control: mode, hint: t("memory_bindings.mode_help") }).element, custom);
  const save = button({ label: t("common.save"), variant: "primary", type: "submit", disabled: true });
  const form = el("form", { class: "memory-bindings", onsubmit: submit },
    el("p", { class: "text-secondary", text: t("memory_bindings.help") }),
    !writable ? alert({ tone: "info", text: t("memory_bindings.read_only") }).element : null,
    error.element, loading, controls, effectiveSection.element,
    el("div", { class: "memory-bindings__actions" }, button({ label: t("common.cancel"), onClick: () => dialog.close() }), writable ? save : null));
  const dialog = modal({ title: t("memory_bindings.title"), size: "md", body: form, onClose: () => { disposed = true; dialog.element.remove(); } });
  mode.addEventListener("change", paintMode);
  dialog.open();
  load();

  function paintMode() {
    custom.hidden = mode.value !== "custom";
    for (const entry of entries) entry.element.disabled = mode.value !== "custom";
    add.disabled = entries.length >= 16;
  }

  function choices(source) {
    const values = scopes.map((scope) => ({ value: `scope:${scope}`, label: t("memory_bindings.default_scope", { scope: scopeLabel(scope) }) }));
    // A saved Human source remains visible but is never invented for an Agent.
    if (source.scope === "user") values.push({ value: "scope:user", label: scopeLabel("user") });
    for (const row of inventory) values.push({ value: `collection:${row.public_id}`,
      label: `${row.name || t(row.is_default ? "memory_bindings.default_collection" : "memory_bindings.unnamed")} · ${scopeLabel(row.scope)} · ${row.public_id}` });
    const selected = sourceKey(source);
    if (!values.some((value) => value.value === selected)) values.push({ value: selected, label: source.collection_public_id });
    return values;
  }

  function addRow(binding) {
    const name = input({ value: binding.name, required: true, pattern: "[a-z](?:[a-z0-9_]|-){0,31}", attrs: { maxlength: 32 } });
    const source = select({ options: choices(binding.source), value: sourceKey(binding.source) });
    const access = select({ options: ["read", "read_write"].map((value) => ({ value, label: accessLabel(value) })), value: binding.access });
    const subject = input({ value: binding.source.conversation_public_id || binding.source.speaker_public_id || "", mono: true });
    const subjectField = field({ label: t("memory_bindings.subject"), control: subject, hint: t("memory_bindings.subject_help") });
    const entry = { source, element: el("fieldset", { class: "memory-binding" }), value() {
      const [kind, value] = source.value.split(":");
      const selected = kind === "collection" ? { collection_public_id: value } : { scope: value };
      if (kind === "scope" && ["conversation", "speaker"].includes(value) && subject.value.trim()) selected[`${value}_public_id`] = subject.value.trim();
      return { name: name.value.trim(), source: selected, access: access.value };
    } };
    const syncSource = () => {
      subjectField.element.hidden = !["scope:conversation", "scope:speaker"].includes(source.value);
      subject.disabled = subjectField.element.hidden;
    };
    source.addEventListener("change", () => { subject.value = ""; syncSource(); });
    syncSource();
    entry.element.append(el("legend", { class: "sr-only", text: t("memory_bindings.binding") }),
      field({ label: t("memory_bindings.name"), control: name, hint: t("memory_bindings.name_help") }).element,
      field({ label: t("memory_bindings.source"), control: source }).element,
      subjectField.element, field({ label: t("memory_bindings.access"), control: access }).element,
      button({ label: t("memory_bindings.remove"), size: "sm", variant: "ghost", onClick: () => {
        entries = entries.filter((row) => row !== entry); entry.element.remove(); paintMode();
      } }));
    entries.push(entry); rows.append(entry.element); paintMode();
  }

  async function load() {
    try {
      const detail = await editor.read();
      if (disposed) return;
      const selection = detail.memory_context;
      mode.value = selection == null || selection.automatic ? "automatic" : selection.bindings.length ? "custom" : "disabled";
      const bindings = selection == null || selection.automatic
        ? scopes.map((scope) => ({ name: scope, source: { scope }, access: "read_write" })) : selection.bindings;
      for (const binding of bindings) addRow(binding);
      effective.update(detail.effective_memory_context.bindings.map((binding) => ({ key: binding.name,
        label: `${binding.name}/ · ${scopeLabel(binding.scope)} · ${accessLabel(binding.access)}`,
        detail: `${t(`memory_bindings.state_${binding.state}`)}${binding.collection_public_id ? ` · ${binding.collection_public_id}` : ""}` })));
      loaded = true; controls.disabled = !writable; save.disabled = !writable; loading.hidden = true; paintMode();
      loadCollections();
    } catch (failure) {
      if (!disposed) { loading.hidden = true; error.show(failure.message); }
    }
  }

  async function loadCollections() {
    more.disabled = true;
    try {
      const page = await editor.collections(after);
      if (disposed) return;
      inventory = [...inventory, ...page.memory_collections]; after = page.pagination.next_after;
      for (const entry of entries) {
        const source = entry.value().source;
        entry.source.replaceChildren(...choices(source).map((option) => el("option", { value: option.value, text: option.label })));
        entry.source.value = sourceKey(source);
      }
      more.hidden = !after;
      more.querySelector(".btn__label").textContent = t("memory_bindings.more_collections");
      error.hide();
    } catch (failure) { if (!disposed) error.show(failure.message); }
    finally { if (!disposed) more.disabled = false; }
  }

  async function submit(event) {
    event.preventDefault();
    if (!loaded || saving || !writable || disposed) return;
    const bindings = entries.map((entry) => entry.value());
    if (mode.value === "custom" && (!bindings.length || new Set(bindings.map((entry) => entry.name)).size !== bindings.length)) {
      error.show(t("memory_bindings.unique_names")); return;
    }
    const selection = mode.value === "automatic" ? null : { bindings: mode.value === "disabled" ? [] : bindings };
    saving = true; save.disabled = true; controls.disabled = true; error.hide();
    try { await editor.save(selection); if (!disposed) dialog.close(); }
    catch (failure) { if (!disposed) error.show(failure.message); }
    finally { if (!disposed) { saving = false; save.disabled = false; controls.disabled = false; } }
  }

  return { id, element: dialog.element, dispose() { disposed = true; dialog.close(); dialog.element.remove(); } };
}
