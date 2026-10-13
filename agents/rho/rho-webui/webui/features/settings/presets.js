import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, field, input, modal, section, select, tag } from "../../primitives/index.js";
import { presetEditor } from "./preset_editor.js";

// Presets own reusable behavior. A published role points to that same
// Preset, while the two defaults choose where new work begins.
export function presetsSection(shell, initialProps) {
  let props = initialProps;
  let catalog = null;
  let tools = [];
  let selected = null;
  let editor = null;
  let busy = false;
  let loading = false;
  let revision = 0;
  let openedRequest = null;
  const reads = new AbortController();
  const dialogs = new Set();
  const defaultsDirty = new Set();
  const failure = alert({ tone: "error" });
  const note = el("p", { class: "field__hint", text: t("presets.loading") });
  const list = el("div", { class: "preset-catalog" });
  const detail = el("div", { class: "preset-detail", hidden: true });
  const main = select({ name: "main_preset_public_id", required: true });
  const bot = select({ name: "default_bot_preset_public_id", required: true });
  const defaults = section({ title: t("presets.defaults"), description: t("presets.defaults_help") });
  const defaultFields = el("fieldset", { class: "settings-form__fields", disabled: true },
    field({ label: t("presets.main_default"), control: main }).element,
    field({ label: t("presets.bot_default"), control: bot }).element,
    button({ label: t("common.save"), variant: "primary", size: "sm", type: "submit" }));
  defaults.body.append(el("form", { class: "settings-form", onsubmit: async (event) => {
    event.preventDefault();
    const body = Object.fromEntries([[main.name, main], [bot.name, bot]].filter(([key]) => defaultsDirty.has(key)).map(([key, box]) => [key, box.value]));
    if (!Object.keys(body).length) return;
    try { await write("/presets/defaults", "PUT", body); defaultsDirty.clear(); paint(); }
    catch (error) { showError(error); }
  } }, defaultFields));
  main.addEventListener("change", () => defaultsDirty.add(main.name));
  bot.addEventListener("change", () => defaultsDirty.add(bot.name));
  const create = button({ label: t("presets.new"), icon: "plus", size: "sm", variant: "primary", onClick: () => open(null) });
  const upload = button({ label: t("presets.import"), icon: "download", size: "sm", onClick: importDocument });
  const importProject = button({ label: t("presets.import_project"), size: "sm", onClick: importFiles });
  const refresh = button({ label: t("common.refresh"), size: "sm", onClick: load });
  const library = section({ title: t("presets.library"), description: t("presets.library_help") });
  library.body.append(el("div", { class: "row row--wrap" }, create, upload, importProject, refresh), note, list);
  const element = el("div", { class: "settings-section presets-section" }, failure.element, defaults.element, library.element, detail);

  const models = () => props.status?.model?.eligible || [];
  const alive = () => !reads.signal.aborted;
  function showError(error) { if (alive() && error.name !== "AbortError") failure.show(error.message || t("conversation.request_failed")); }

  async function write(path, method, body) {
    if (busy) throw new Error(t("presets.saving"));
    busy = true; revision += 1; paint();
    try {
      const answer = await shell.call(path, { method, body, signal: reads.signal });
      if (!alive()) return null;
      catalog = answer;
      failure.hide();
      shell.toast(t("presets.saved"), { tone: "success" });
      shell.bots?.refresh();
      props.refresh?.();
      return answer;
    } finally { busy = false; if (alive()) paint(); }
  }

  function open(preset) {
    selected = preset?.public_id || "new";
    detail.hidden = false;
    const card = section({ title: preset ? t("presets.edit", { name: preset.name }) : t("presets.new"), level: 3 });
    editor = presetEditor({ preset, models: models(), tools, close, save: async (body) => {
      const previous = new Set(catalog.presets.map((row) => row.public_id));
      const answer = await write("/presets", preset ? "PUT" : "POST", body);
      if (!answer) return;
      const saved = answer.preset || answer.presets.find((row) => preset ? row.public_id === body.public_id : !previous.has(row.public_id));
      if (saved) open(saved);
      return saved;
    } });
    card.body.append(editor.element);
    detail.replaceChildren(card.element);
    if (preset) detail.append(exportCard(preset).element, roleCard(preset).element);
    paint(); editor.focus();
  }

  function close() { selected = null; editor = null; detail.replaceChildren(); detail.hidden = true; paint(); }

  function openRequested() {
    const request = props.request;
    if (!catalog || !request || request === openedRequest || request.section !== "presets") return;
    openedRequest = request;
    const preset = catalog.presets.find((row) => row.public_id === request.item);
    if (preset) open(preset);
    else if (!request.item) close();
  }

  function dialogForm(title, form, label, focus) {
    const dialog = modal({ title, body: form, actions: [button({ label: t("common.cancel"), onClick: () => dialog.close() }),
      button({ label, variant: "primary", onClick: () => form.requestSubmit() })],
    onClose: () => { dialogs.delete(dialog); dialog.element.remove(); } });
    dialogs.add(dialog); dialog.open(); focus.focus(); return dialog;
  }

  function importDocument() {
    let document = null;
    let reading = 0;
    const file = input({ name: "preset_file", type: "file", required: true, attrs: { accept: ".md,.markdown,.json,text/markdown,application/json" } });
    const format = select({ name: "format", value: "md", options: [{ value: "md", label: "Markdown" }, { value: "json", label: "JSON" }] });
    const name = input({ name: "import_name", autocomplete: "off" });
    const error = alert({ tone: "error" });
    const fields = el("fieldset", { class: "settings-form__fields" },
      field({ label: t("presets.import_file"), control: file }).element,
      field({ label: t("presets.import_format"), control: format }).element,
      field({ label: t("presets.import_name"), control: name, hint: t("presets.import_name_help") }).element);
    const form = el("form", { class: "settings-form", onsubmit: async (event) => {
      event.preventDefault();
      if (fields.disabled) return;
      if (!document) { error.show(t("presets.import_required")); file.focus(); return; }
      fields.disabled = true; error.hide();
      const previous = new Set(catalog.presets.map((row) => row.public_id));
      try {
        const answer = await write("/presets/import_document", "POST", { ...document, format: format.value, ...(name.value.trim() ? { name: name.value.trim() } : {}) });
        if (!answer || !dialog.element.open) return;
        dialog.close();
        const imported = answer.presets.find((row) => !previous.has(row.public_id));
        if (imported) open(imported);
      } catch (problem) { error.show(problem.message || t("conversation.request_failed")); }
      finally { fields.disabled = false; }
    } }, el("p", { class: "field__hint", text: t("presets.import_help") }), fields, error.element);
    file.addEventListener("change", async () => {
      const version = ++reading;
      const selected = file.files?.[0];
      document = null;
      if (!selected) return;
      format.value = selected.name.toLowerCase().endsWith(".json") ? "json" : "md";
      try {
        const content = await selected.text();
        if (version === reading && dialog.element.open) { document = { content, filename: selected.name }; error.hide(); }
      } catch { if (version === reading) error.show(t("presets.import_read_failed")); }
    });
    const dialog = dialogForm(t("presets.import"), form, t("presets.import"), file);
  }

  async function importFiles() {
    try {
      const answer = await write("/presets/import", "POST", {});
      if (!answer) return;
      const results = section({ title: t("presets.import_result", { count: answer.imported.length }), level: 3 });
      results.body.append(el("p", { class: "field__hint", text: t("presets.import_project_help") }),
        ...answer.skipped.map((entry) => el("p", { class: "field__hint", text: `${entry.path}: ${entry.reason}` })));
      close(); detail.hidden = false; detail.append(results.element);
    } catch (error) { showError(error); }
  }

  function exportCard(preset) {
    const card = section({ title: t("presets.export"), description: t("presets.export_help"), level: 3 });
    const error = alert({ tone: "error" });
    async function download(format, control) {
      control.disabled = true; error.hide();
      try {
        const answer = await shell.call(`/presets/export?public_id=${encodeURIComponent(preset.public_id)}&format=${format}`, { signal: reads.signal });
        if (!alive()) return;
        const url = URL.createObjectURL(new Blob([answer.content], { type: format === "json" ? "application/json" : "text/markdown;charset=utf-8" }));
        const link = el("a", { href: url, download: `${answer.name}.${answer.format}`, hidden: true });
        document.body.append(link); link.click(); link.remove();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
      } catch (problem) { if (alive() && problem.name !== "AbortError") error.show(problem.message || t("conversation.request_failed")); }
      finally { control.disabled = false; }
    }
    const markdown = button({ label: t("presets.export_markdown"), size: "sm", onClick: () => download("md", markdown) });
    const json = button({ label: t("presets.export_json"), size: "sm", onClick: () => download("json", json) });
    card.body.append(el("div", { class: "row row--wrap" }, markdown, json), error.element);
    return card;
  }

  function duplicate(preset) {
    const name = input({ name: "duplicate_name", value: t("presets.copy_name", { name: preset.name }), required: true });
    const error = alert({ tone: "error" });
    const fields = el("fieldset", { class: "settings-form__fields" }, field({ label: t("presets.name"), control: name }).element);
    const form = el("form", { class: "settings-form", onsubmit: async (event) => {
      event.preventDefault();
      if (fields.disabled || !name.value.trim()) return;
      fields.disabled = true; error.hide();
      try {
        const previous = new Set(catalog.presets.map((row) => row.public_id));
        const answer = await write("/presets/duplicate", "POST", { public_id: preset.public_id, name: name.value.trim() });
        if (!answer || !dialog.element.open) return;
        dialog.close();
        open(answer.preset || answer.presets.find((row) => !previous.has(row.public_id)));
      } catch (problem) { error.show(problem.message || t("conversation.request_failed")); }
      finally { fields.disabled = false; }
    } }, fields, error.element);
    const dialog = dialogForm(t("presets.duplicate"), form, t("presets.duplicate"), name);
  }

  function remove(preset) {
    const error = alert({ tone: "error" });
    const removeButton = button({ label: t("common.remove"), variant: "danger", onClick: async () => {
      removeButton.disabled = true;
      try { await write("/presets/rm", "POST", { public_id: preset.public_id }); if (selected === preset.public_id) close(); dialog.close(); }
      catch (problem) { error.show(problem.message || t("conversation.request_failed")); }
      finally { removeButton.disabled = false; }
    } });
    const dialog = modal({ title: t("presets.remove_title", { name: preset.name }),
      body: el("div", { class: "stack" }, el("p", { text: t("presets.remove_help") }), error.element),
      actions: [button({ label: t("common.cancel"), onClick: () => dialog.close() }), removeButton],
      onClose: () => { dialogs.delete(dialog); dialog.element.remove(); } });
    dialogs.add(dialog); dialog.open(); removeButton.focus();
  }

  function roleCard(preset) {
    const card = section({ title: t("roles.title"), description: preset.role ?
      t("roles.published_as", { name: preset.role.name }) : t("roles.preset_help"), level: 3 });
    card.body.append(button({ label: t("roles.manage"), size: "sm", onClick: () => shell.settings.open("roles", preset.public_id) }));
    return card;
  }

  function paint() {
    note.hidden = !!catalog || !loading;
    create.disabled = busy || !catalog;
    upload.disabled = busy || !catalog;
    importProject.disabled = busy || !catalog;
    refresh.disabled = loading || busy;
    defaultFields.disabled = busy || !catalog;
    if (!catalog) return;
    for (const box of [main, bot]) {
      const value = defaultsDirty.has(box.name) ? box.value : catalog[box.name];
      box.replaceChildren(...catalog.presets.map((row) => el("option", { value: row.public_id, text: row.name })));
      box.value = value;
    }
    list.replaceChildren(...catalog.presets.map((preset) => el("article", { class: "preset-catalog__row", "data-preset": preset.public_id },
      el("div", { class: "settings-row__text" },
        el("button", { type: "button", class: "link-button preset-catalog__name", text: preset.name, disabled: busy,
          "aria-expanded": String(selected === preset.public_id), onclick: () => open(preset) }),
        preset.description ? el("p", { class: "settings-row__description", text: preset.description }) : null,
        preset.role ? tag({ tone: "quiet", text: t("presets.role_tag", { name: preset.role.name }) }) : null),
      el("div", { class: "row row--wrap" },
        button({ label: t("presets.duplicate"), size: "sm", disabled: busy, onClick: () => duplicate(preset) }),
        button({ label: t("common.remove"), size: "sm", disabled: busy || [catalog.main_preset_public_id, catalog.default_bot_preset_public_id].includes(preset.public_id),
          onClick: () => remove(preset) })))));
  }

  async function load() {
    if (loading || busy) return;
    const requestedRevision = revision;
    loading = true; paint();
    try {
      const [answer, choices] = await Promise.all([shell.call("/presets", { signal: reads.signal }),
        shell.call("/presets/tools", { signal: reads.signal }).catch(() => null)]);
      if (!alive() || requestedRevision !== revision) return;
      catalog = answer; tools = choices?.tools || tools;
      failure.hide();
      editor?.updateChoices({ models: models(), tools });
      openRequested();
    } catch (error) { showError(error); note.hidden = true; }
    finally { loading = false; if (alive()) paint(); }
  }
  load();
  return {
    element,
    update(next) {
      const refresh = (!props.visible && next.visible) || (!props.status?.connected && next.status?.connected);
      props = next; editor?.updateChoices({ models: models(), tools });
      openRequested();
      if (refresh) load();
    },
    dispose() { reads.abort(); for (const dialog of dialogs) dialog.close(); element.remove(); },
  };
}
