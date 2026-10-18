import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, field, input, section, select, textarea } from "../../primitives/index.js";

// Publication adds selection metadata to a Preset. All execution settings
// remain editable through the existing Preset editor.
export function rolesSection(shell, initialProps) {
  let props = initialProps;
  let catalog = null;
  let selected = null;
  let openedRequest = null;
  let loading = false;
  let busy = false;
  let revision = 0;
  const reads = new AbortController();
  const failure = alert({ tone: "error" });
  const note = el("p", { class: "field__hint", text: t("roles.loading") });
  const list = el("div", { class: "preset-catalog" });
  const detail = el("div", { class: "preset-detail", hidden: true });
  const create = button({ label: t("roles.new"), icon: "plus", size: "sm", variant: "primary", onClick: () => open(null) });
  const refresh = button({ label: t("common.refresh"), size: "sm", onClick: load });
  const library = section({ title: t("roles.directory"), description: t("roles.help") });
  library.body.append(el("div", { class: "row row--wrap" }, create, refresh), note, list);
  const element = el("div", { class: "settings-section presets-section roles-section" }, failure.element, library.element, detail);
  const alive = () => !reads.signal.aborted;
  const available = () => catalog.presets.filter((preset) => !preset.role);

  function close() { selected = null; detail.replaceChildren(); detail.hidden = true; paint(); }

  function open(preset) {
    selected = preset?.public_id || "new";
    const editing = !!preset?.role;
    const card = section({ title: editing ? t("roles.edit", { name: preset.role.name }) : t("roles.new"), level: 3 });
    const choice = select({ name: "preset_public_id", required: true, value: preset?.public_id || "", options: [
      { value: "", label: t("roles.choose_preset"), disabled: true },
      ...(editing ? [preset] : available()).map((row) => ({ value: row.public_id, label: row.name })),
    ] });
    choice.disabled = editing;
    const name = input({ name: "role_name", value: preset?.role?.name || "", required: true, autocomplete: "off" });
    const description = textarea({ name: "role_description", value: preset?.role?.description || "", rows: 3, required: true });
    const error = alert({ tone: "error" });
    const editPreset = button({ label: t("roles.edit_preset"), size: "sm", disabled: !choice.value,
      onClick: () => shell.settings.open("presets", choice.value) });
    choice.addEventListener("change", () => { editPreset.disabled = !choice.value; });
    const fields = el("fieldset", { class: "settings-form__fields" },
      el("div", { class: "stack stack--tight" }, field({ label: t("roles.preset"), control: choice,
        hint: t(editing ? "roles.preset_fixed" : "roles.preset_reference_help") }).element, el("div", { class: "row" }, editPreset)),
      field({ label: t("roles.name"), control: name, hint: t("roles.name_help") }).element,
      field({ label: t("roles.description"), control: description, hint: t("roles.description_help") }).element,
      el("div", { class: "row row--wrap" },
        button({ label: t(editing ? "roles.save" : "roles.publish"), type: "submit", variant: "primary", size: "sm" }),
        button({ label: t("common.cancel"), size: "sm", onClick: close }),
        editing ? button({ label: t("roles.unpublish"), size: "sm", onClick: () => publish("DELETE") }) : null));
    async function publish(method) {
      if (busy) return;
      fields.disabled = true; error.hide();
      try {
        const body = { public_id: choice.value, ...(method === "PUT" ? { name: name.value.trim(), description: description.value.trim() } : {}) };
        const answer = await write(method, body);
        if (!answer) return;
        if (method === "DELETE") close();
        else open(answer.presets.find((row) => row.public_id === choice.value));
      } catch (problem) { if (alive() && problem.name !== "AbortError") error.show(problem.message || t("conversation.request_failed")); }
      finally { fields.disabled = false; }
    }
    card.body.append(el("form", { class: "settings-form role-editor", onsubmit: (event) => {
      event.preventDefault();
      if (!choice.value) { choice.focus(); return; }
      if (!name.value.trim()) { name.focus(); return; }
      if (!description.value.trim()) { description.focus(); return; }
      publish("PUT");
    } }, fields, error.element));
    detail.replaceChildren(card.element); detail.hidden = false;
    paint(); (editing || preset ? name : choice).focus();
  }

  async function write(method, body) {
    busy = true; revision += 1; paint();
    try {
      const answer = await shell.call("/presets/role", { method, body, signal: reads.signal });
      if (!alive()) return null;
      catalog = answer; failure.hide();
      shell.toast(t(method === "DELETE" ? "roles.unpublished" : "roles.saved"), { tone: "success" });
      props.refresh?.();
      return answer;
    } finally { busy = false; if (alive()) paint(); }
  }

  function openRequested() {
    const request = props.request;
    if (!catalog || !request || request === openedRequest || request.section !== "roles") return;
    openedRequest = request;
    const preset = catalog.presets.find((row) => row.public_id === request.item);
    if (preset) open(preset);
    else if (!request.item) close();
  }

  function paint() {
    create.disabled = busy || !catalog || !available().length;
    refresh.disabled = busy || loading;
    if (!catalog) { note.hidden = !loading; return; }
    const published = catalog.presets.filter((preset) => preset.role);
    note.hidden = !!published.length;
    note.textContent = t("roles.empty");
    list.replaceChildren(...published.map((preset) => el("article", { class: "preset-catalog__row", "data-role": preset.public_id },
      el("div", { class: "settings-row__text" },
        el("button", { type: "button", class: "link-button preset-catalog__name", text: preset.role.name, disabled: busy,
          "aria-expanded": String(selected === preset.public_id), onclick: () => open(preset) }),
        el("p", { class: "settings-row__description", text: preset.role.description }),
        el("p", { class: "field__hint", text: t("roles.uses_preset", { name: preset.name }) })),
      button({ label: t("roles.edit_preset"), size: "sm", disabled: busy, onClick: () => shell.settings.open("presets", preset.public_id) }))));
  }

  async function load() {
    if (loading || busy) return;
    const requestedRevision = revision;
    loading = true; paint();
    try {
      const answer = await shell.call("/presets", { signal: reads.signal });
      if (!alive() || requestedRevision !== revision) return;
      catalog = answer; failure.hide(); openRequested();
    } catch (error) { if (alive() && error.name !== "AbortError") failure.show(error.message || t("conversation.request_failed")); }
    finally { loading = false; if (alive()) paint(); }
  }
  load();
  return {
    element,
    update(next) {
      const refresh = (!props.visible && next.visible) || (!props.status?.connected && next.status?.connected);
      props = next; openRequested(); if (refresh) load();
    },
    dispose() { reads.abort(); element.remove(); },
  };
}
