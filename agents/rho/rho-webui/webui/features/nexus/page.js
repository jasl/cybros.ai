import { el, safeUrl } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, emptyState, group, iconButton, input, link, menuButton, modal, page, section, skeleton, switchControl, tag } from "../../primitives/index.js";
import { connectionEditor, modelEditor } from "./editors.js";

const PROVIDERS = "/api/v1/admin/model_providers";
const MODELS = "/api/v1/admin/models";
const COST_UNIT = "/api/v1/admin/account/cost_unit";
// Why a model is not available, in the admin catalog's words. The
// provider's reasons — it is off, it has no usable credential — are the
// provider's to say, once, on its card; a model says only its own.
const REASONS = {
  provider_disabled: () => t("nexus.reason_provider_disabled"), model_unavailable: () => t("nexus.reason_model_unavailable"),
  model_hidden: () => t("nexus.reason_model_hidden"), missing_credential: () => t("nexus.reason_missing_credential"),
  reauthorization_required: () => t("nexus.reason_reauthorization_required"), credential_unusable: () => t("nexus.reason_credential_unusable"),
};
const PROVIDER_REASONS = new Set(["provider_disabled", "missing_credential", "reauthorization_required", "credential_unusable"]);

export const providerName = (provider) => provider.display_name || provider.id;
export const reasonText = (reason) => (REASONS[reason] ? REASONS[reason]() : reason || t("nexus.reason_unknown"));
const providerPath = (provider, rest = "") => `${PROVIDERS}/${encodeURIComponent(provider.id)}${rest}`;

// What on the provider needs attention, or nothing: a sign-in it has lost,
// a key or a connection it never had, a credential its models cannot use.
// A saved key, a standing connection, no credential needed — the normal
// states — say nothing; the switch says whether it is on.
export function providerMark(provider, models = []) {
  if (provider.reauthorization_required) return t("nexus.credential_sign_in_required");
  if (provider.credentials === "api_key" && !provider.configured) return t("nexus.credential_key_needed");
  if (provider.credentials === "oauth_tokens" && !provider.configured) return t("nexus.credential_not_connected");
  const shared = models.length && models.every((model) => !model.available && model.unavailable_reason === models[0].unavailable_reason) ? models[0].unavailable_reason : null;
  return shared && PROVIDER_REASONS.has(shared) && shared !== "provider_disabled" ? reasonText(shared) : null;
}

// What a model row says about its own availability: nothing while it is
// available, hidden (its switch is off) or held back by its provider; its
// own reason otherwise — marked invalid by discovery, or one the catalog
// has no word for.
export function modelMark(model) {
  if (model.available || model.unavailable_reason === "model_hidden" || PROVIDER_REASONS.has(model.unavailable_reason)) return null;
  return reasonText(model.unavailable_reason);
}

// The Nexus admin HTML page for a provider's OAuth ceremony, beside the
// model settings link the daemon already names; nothing when the daemon
// names no web address.
export function authorizationUrl(settingsUrl, providerId) {
  const base = safeUrl(settingsUrl);
  return base ? `${base.replace(/\/$/, "")}/${encodeURIComponent(providerId)}/authorization` : null;
}

// Which gate the account's administration is behind for this page: a
// Nexus sign-in, a role, the model plane — or none.
export function gateOf(error) {
  if (!error) return null;
  if (error.code === "human_login_required") return "sign_in";
  if (error.code === "administrator_required" || error.status === 403) return "member";
  if (error.code === "model_plane_unavailable") return "unavailable";
  return null;
}

// A model's price line from the catalog row, when it is priced.
export function priceLine(pricing) {
  if (!pricing || pricing.state !== "priced") return null;
  return t("nexus.token_rates", { unit: pricing.unit || "", input: pricing.input_per_mtok ?? "?", output: pricing.output_per_mtok ?? "?" });
}

// NEXUS: the account's administration from rho — every provider lane laid
// flat with its models under it, as Nexus's own provider page shows one.
// A lane's switch and its menu sit on its title row; the models' own
// actions sit on the models' title row; each model's on its row, the
// rarer ones behind its menu. Everything goes through the Human-credential
// proxy; authoring here is the same declaration Nexus's forms write, and
// every key the form does not show stands.
export function nexusPage(shell) {
  const reads = new AbortController();
  const failure = alert({ tone: "error" });
  const gate = el("div", { class: "nexus-page__gate", hidden: true });
  const loading = el("div", { class: "nexus-page__loading", "aria-hidden": "true" }, skeleton({ lines: 3 }), skeleton({ lines: 3 }));
  const editorSlot = el("div", { class: "nexus-page__editor-slot" });
  const lanes = el("div", { class: "nexus-page__lanes" });
  const refresh = iconButton({ icon: "refresh", label: t("common.refresh"), onClick: () => load() });
  // A provider is added into the Providers group: its action sits on that group's head.
  const add = button({ label: t("nexus.add_provider"), size: "sm", variant: "primary", icon: "plus", onClick: () => openEditor(null, connectionEditor({
    save: (id, definition) => saveConnection({ id, lock_version: null }, definition), onClose: closeEditor })) });
  const open = el("span", { class: "nexus-page__open" });
  const providers = group({ title: t("nexus.providers"), actions: [add] });
  providers.body.append(editorSlot, lanes);
  const scaffold = page({ title: t("brand.nexus"), description: t("nexus.description"), actions: [refresh, open] });
  scaffold.body.append(failure.element, gate, loading, providers.element);
  let rows = { providers: [], models: [], configurations: {}, costUnit: null };
  let busy = false;
  let loaded = false;
  let editor = null;
  // Each lane's open editors and key forms are the lane's own, by id.
  const laneEditors = new Map();

  const alive = () => !reads.signal.aborted;
  const settingsUrl = () => shell.setup.state.get().document?.nexus?.model_settings_url;
  const nexus = (path, options = {}) => shell.nexus.request(path, { ...options, signal: reads.signal });
  const configuration = (provider) => rows.configurations[provider.id] || { definition: null, source: null, models: [] };

  function problem(error) {
    if (!alive() || error.name === "AbortError" || error.status === 401) return;
    failure.show(error.message || t("nexus.request_failed"));
  }

  // A write: one Nexus command, then everything again; a stale version is
  // said and the reread is what settles it; any other refusal is answered
  // to the caller (an editor keeps it) or shown on the page.
  async function write(run, done, { report = true } = {}) {
    if (!alive()) return null;
    if (busy) return Object.assign(new Error(t("nexus.busy")), { code: "busy" });
    busy = true;
    paint();
    let refused = null;
    try {
      const answer = await run();
      if (!alive()) return null;
      if (done) shell.toast(done(answer), { tone: "success" });
    } catch (error) {
      if (error.code === "stale_object") shell.toast(t("nexus.changed_meanwhile"), { tone: "error" });
      else refused = error;
    } finally { busy = false; }
    await load();
    if (refused && report) problem(refused);
    return refused;
  }

  const command = (provider, extra = {}) => ({ command: { expected_lock_version: provider.lock_version, ...extra } });
  const lane = (provider, enabled) => write(() => nexus(providerPath(provider, "/lane"), { method: "PUT", body: command(provider, { enabled }) }),
    () => (enabled ? t("nexus.enabled", { name: providerName(provider) }) : t("nexus.disabled", { name: providerName(provider) })));
  const discover = (provider) => write(() => nexus(providerPath(provider, "/model_discovery"), { method: "POST", body: command(provider), timeout: 45 }),
    (answer) => t("nexus.discovered", { count: (answer.models || []).length, name: providerName(provider) }));
  const visibility = (provider, model, visible) => write(
    () => nexus(providerPath(provider, "/model_visibility"), { method: "PUT", body: command(provider, { model: model.ref, visible }) }),
    () => (visible ? t("nexus.shown", { ref: model.ref }) : t("nexus.hidden", { ref: model.ref })));
  const restoreModel = (provider, ref) => write(
    () => nexus(providerPath(provider, "/model_availability"), { method: "PUT", body: command(provider, { model: ref, available: true }) }),
    () => t("nexus.invalid_cleared", { ref }));
  const resetModel = (provider, ref) => write(() => nexus(providerPath(provider, "/model_definition/reset"), { method: "POST", body: command(provider, { model: ref }) }),
    () => t("nexus.model_reset", { ref }));
  // An editor's save answers the refusal sentence, so the form keeps it.
  const saveConnection = async (provider, definition) => {
    const refused = await write(() => nexus(providerPath(provider, "/definition"), { method: "PUT", body: command(provider, { definition }) }),
      () => t("nexus.connection_saved", { name: definition.display_name || provider.id }), { report: false });
    if (!refused) closeEditor();
    return refused ? refused.message || t("nexus.request_failed") : null;
  };
  const saveModel = async (provider, ref, definition) => {
    const refused = await write(() => nexus(providerPath(provider, "/model_definition"), { method: "PUT", body: command(provider, { model: ref, definition }) }),
      () => t("nexus.model_saved", { ref }), { report: false });
    if (!refused) closeEditor();
    return refused ? refused.message || t("nexus.request_failed") : null;
  };

  function confirm({ title, body, label, onConfirm }) {
    const go = button({ label, variant: "danger", onClick: () => { dialog.close(); onConfirm(); } });
    const dialog = modal({ title, body: el("p", { class: "text-secondary", text: body }),
      actions: [button({ label: t("common.cancel"), onClick: () => dialog.close() }), go], onClose: () => dialog.element.remove() });
    dialog.open();
    go.focus();
  }
  const confirmClearKey = (provider) => confirm({ title: t("nexus.clear_key_title", { name: providerName(provider) }), body: t("nexus.clear_key_body"), label: t("common.remove"),
    onConfirm: () => write(() => nexus(providerPath(provider, "/api_key"), { method: "DELETE" }), () => t("nexus.key_cleared", { name: providerName(provider) })) });
  const confirmDeleteConnection = (provider) => confirm({
    title: t("nexus.delete_connection_title", { name: providerName(provider) }),
    body: configuration(provider).source === "custom" ? t("nexus.delete_connection_custom") : t("nexus.delete_connection_file"), label: t("nexus.delete_connection"),
    onConfirm: () => write(() => nexus(providerPath(provider, "/definition"), { method: "DELETE", body: command(provider) }), () => t("nexus.connection_deleted", { name: providerName(provider) })) });
  const confirmRemoveModel = (provider, ref) => confirm({ title: t("nexus.remove_model_title", { ref }), body: t("nexus.remove_model_body"), label: t("nexus.remove_model"),
    onConfirm: () => write(() => nexus(providerPath(provider, "/model_definition"), { method: "DELETE", body: command(provider, { model: ref }) }), () => t("nexus.model_removed", { ref })) });
  function confirmTest(provider, model) {
    const test = button({ label: t("nexus.test"), variant: "primary", onClick: () => {
      dialog.close();
      write(() => nexus(providerPath(provider, "/model_test"), { method: "POST", body: command(provider, { model: model.ref }), timeout: 45 }),
        (answer) => t("nexus.tested", { ref: model.ref, outcome: answer.model_test?.outcome || "?", ms: answer.model_test?.duration_ms ?? "?" }));
    } });
    const dialog = modal({ title: t("nexus.test_title", { ref: model.ref }), body: el("p", { class: "text-secondary", text: t("nexus.test_body") }),
      actions: [button({ label: t("common.cancel"), onClick: () => dialog.close() }), test], onClose: () => dialog.element.remove() });
    dialog.open();
    test.focus();
  }

  // One editor at a time on the page: the new-provider editor at the top,
  // a lane's own inside its card.
  function closeEditor(laneId = null) {
    if (laneId === null) { editor?.dispose(); editor = null; }
    const own = laneId === null ? [...laneEditors.entries()] : [[laneId, laneEditors.get(laneId)]];
    let closed = false;
    for (const [id, view] of own) { if (view) { view.dispose(); closed = true; } laneEditors.delete(id); }
    if (closed) paint();
  }
  function openEditor(provider, view) {
    closeEditor();
    if (provider) { laneEditors.set(provider.id, view); paint(); }
    else { editor = view; editorSlot.replaceChildren(view.element); }
    view.form.querySelector("input, select")?.focus();
  }

  // THE KEY, a field of every API-key provider's card, as Nexus's own
  // page has it: one password field — the key is never shown again — Save,
  // and, while a key is saved, Remove. The field's hint says whether one
  // is saved, since the field cannot.
  function keyField(provider) {
    const key = input({ name: "api_key", type: "password", autocomplete: "new-password", spellcheck: "false", placeholder: t("nexus.key_placeholder") });
    const save = button({ label: t("common.save"), variant: "primary", size: "sm", type: "submit", disabled: busy });
    const remove = provider.configured ? button({ label: t("common.remove"), variant: "danger", size: "sm", disabled: busy, onClick: () => confirmClearKey(provider) }) : null;
    const form = el("form", { class: "nexus-page__key", onsubmit: (event) => {
      event.preventDefault();
      const value = key.value.trim();
      if (!value) { key.focus(); return; }
      write(() => nexus(providerPath(provider, "/api_key"), { method: "PUT", body: { command: { api_key: value } } }), () => t("nexus.key_saved", { name: providerName(provider) }));
    } }, el("div", { class: "nexus-page__key-row" }, key, save, remove),
    el("p", { class: "field__hint", text: provider.configured ? t("nexus.key_saved_hint") : t("nexus.key_hint") }));
    key.id = `nexus-key-${provider.id}`;
    return el("div", { class: "field" }, el("label", { class: "field__label", for: key.id, text: t("nexus.api_key") }), form);
  }

  // The sign-in an OAuth provider needs, on its card while it needs one;
  // the menu keeps the way to sign in again at any time.
  function signInRow(provider) {
    const url = authorizationUrl(settingsUrl(), provider.id);
    return el("div", { class: "row" }, button({ label: t("nexus.authorize_in_nexus"), variant: "primary", size: "sm", icon: "external", disabled: !url,
      onClick: () => window.open(url, "_blank", "noopener") }));
  }

  function laneMenu(provider) {
    const config = configuration(provider);
    const items = [];
    if (provider.credentials === "oauth_tokens") {
      const url = authorizationUrl(settingsUrl(), provider.id);
      items.push({ type: "item", label: t("nexus.authorize_in_nexus"), icon: "external", disabled: !url, onSelect: () => window.open(url, "_blank", "noopener") });
    }
    items.push({ type: "item", label: t("nexus.edit_connection"), icon: "rename", onSelect: () => openEditor(provider, connectionEditor({ provider, definition: config.definition,
      save: (_id, definition) => saveConnection(provider, definition), onClose: () => closeEditor(provider.id) })) });
    const dangers = [];
    if (config.source && config.source !== "removed") dangers.push({ type: "item", label: config.source === "custom" ? t("nexus.delete_connection") : t("nexus.restore_file_connection"), danger: true,
      onSelect: () => confirmDeleteConnection(provider) });
    return dangers.length ? [...items, { type: "separator" }, ...dangers] : items;
  }

  function modelMenu(provider, model, entry) {
    const items = [{ type: "item", label: t("nexus.test"), icon: "play", onSelect: () => confirmTest(provider, model) },
      { type: "item", label: t("nexus.edit_model"), icon: "rename", onSelect: () => openEditor(provider, modelEditor({ provider, format: configuration(provider).definition?.api_format,
        model: model.ref, definition: entry?.definition, modelDefinitions: configuration(provider).model_definitions,
        costUnit: rows.costUnit, save: (ref, definition) => saveModel(provider, ref, definition), onClose: () => closeEditor(provider.id) })) }];
    if (model.unavailable_reason === "model_unavailable") items.push({ type: "item", label: t("nexus.clear_invalid"), icon: "restore", onSelect: () => restoreModel(provider, model.ref) });
    return [...items, { type: "separator" }, { type: "item", label: t("nexus.remove_model"), danger: true, onSelect: () => confirmRemoveModel(provider, model.ref) }];
  }

  function modelRow(provider, model) {
    const entry = configuration(provider).models.find((row) => row.model === model.ref);
    const toggle = switchControl({ label: "", checked: model.visible, attrs: { name: "visible", value: model.ref, "aria-label": t("nexus.visible_label", { ref: model.ref }) },
      onChange: (event) => visibility(provider, model, event.target.checked) });
    toggle.input.disabled = busy || model.unavailable_reason === "model_unavailable";
    const name = entry?.definition?.display_name || model.ref;
    const mark = modelMark(model);
    const abilities = [model.capabilities?.tool_calls ? t("nexus.tools") : null, model.capabilities?.streaming ? t("nexus.streaming") : null].filter(Boolean);
    const kind = [t(`nexus.workload_${model.workload}`, {}, model.workload), ...abilities].join(" · ");
    const price = priceLine(model.pricing);
    return el("div", { class: "settings-row toolset__row nexus-page__model", "data-model": model.ref },
      el("div", { class: "settings-row__text" },
        el("p", { class: "settings-row__label" }, el("span", { class: name === model.ref ? "bots-tool__name" : "", text: name }), mark ? tag({ tone: "warning", text: mark }) : null),
        el("p", { class: "settings-row__description", text: [kind, name !== model.ref ? model.ref : null].filter(Boolean).join(" · ") }),
        price ? el("p", { class: "settings-row__description", text: price }) : null),
      el("div", { class: "nexus-page__model-actions" }, toggle.element,
        menuButton({ variant: "icon", icon: "more", label: t("nexus.model_actions", { ref: model.ref }), align: "end", items: () => modelMenu(provider, model, entry) }).element));
  }

  // The provider's models, a group inside its card with the models'
  // actions on its head; the models removed from the provider, each with
  // the way back, in a group of their own under it.
  function modelsOf(provider) {
    const list = rows.models.filter((model) => model.provider === provider.id);
    const removed = configuration(provider).models.filter((entry) => entry.removed);
    const models = group({ title: t("nexus.models"), level: 3, attrs: { class: "group nexus-page__models-head" }, actions: [
      provider.credentials === "oauth_tokens" ? null : button({ label: t("nexus.discover"), size: "sm", icon: "search", disabled: busy, onClick: () => discover(provider) }),
      button({ label: t("nexus.add_model"), size: "sm", icon: "plus", disabled: busy, onClick: () => openEditor(provider, modelEditor({ provider,
        format: configuration(provider).definition?.api_format, modelDefinitions: configuration(provider).model_definitions,
        costUnit: rows.costUnit, save: (ref, definition) => saveModel(provider, ref, definition), onClose: () => closeEditor(provider.id) })) })].filter(Boolean) });
    models.setCount(list.length);
    models.body.append(list.length ? el("div", { class: "nexus-page__models" }, ...list.map((model) => modelRow(provider, model)))
      : el("p", { class: "bots-page__note text-tertiary", text: t("nexus.no_models_here") }));
    const parts = [models.element];
    if (removed.length) {
      const gone = group({ title: t("nexus.removed_models"), level: 3, attrs: { "data-removed": provider.id } });
      gone.setCount(removed.length);
      gone.body.append(...removed.map((entry) => el("div", { class: "settings-row toolset__row" },
        el("div", { class: "settings-row__text" }, el("p", { class: "settings-row__label bots-tool__name", text: entry.model })),
        button({ label: t("nexus.configure_again"), size: "sm", disabled: busy, onClick: () => resetModel(provider, entry.model) }))));
      parts.push(gone.element);
    }
    return el("section", { class: "nexus-page__models-section" }, ...parts);
  }

  // A provider's card: its name and id, what needs attention, its switch
  // and its menu on the title row; its key, or the sign-in it needs; then
  // its models. The provider's state is said here once — a model row
  // repeats none of it.
  function laneCard(provider) {
    const models = rows.models.filter((model) => model.provider === provider.id);
    const mark = providerMark(provider, models);
    const availability = switchControl({ label: provider.enabled ? t("nexus.enabled_tag") : t("nexus.disabled_tag"), checked: provider.enabled,
      attrs: { name: "enabled", value: provider.id, "aria-label": t("nexus.availability_label", { name: providerName(provider) }) },
      onChange: (event) => lane(provider, event.target.checked) });
    availability.input.disabled = busy;
    const menu = menuButton({ variant: "icon", icon: "more", label: t("nexus.provider_actions", { name: providerName(provider) }), align: "end", items: () => laneMenu(provider) });
    const card = section({ title: providerName(provider), actions: [availability.element, menu.element] });
    card.element.classList.add("nexus-page__provider");
    card.element.dataset.provider = provider.id;
    card.element.querySelector(".card__heading").append(el("div", { class: "nexus-page__facts" },
      provider.display_name ? el("span", { class: "nexus-page__id", text: provider.id }) : null, mark ? tag({ tone: "warning", text: mark }) : null));
    const own = laneEditors.get(provider.id);
    const credential = provider.credentials === "api_key" ? keyField(provider)
      : provider.credentials === "oauth_tokens" && (!provider.configured || provider.reauthorization_required) ? signInRow(provider) : null;
    card.body.append(...(own ? [own.element] : []), ...(credential ? [credential] : []), modelsOf(provider));
    return card.element;
  }

  function paintGate(error) {
    const kind = gateOf(error);
    gate.hidden = !kind;
    lanes.hidden = !!kind;
    add.hidden = !!kind;
    if (!kind) { gate.replaceChildren(); return; }
    const copy = { sign_in: { title: t("nexus.gate_sign_in_title"), description: t("nexus.gate_sign_in_body") },
      member: { title: t("nexus.gate_member_title"), description: t("nexus.gate_member_body") },
      unavailable: { title: t("nexus.gate_unavailable_title"), description: t("nexus.gate_unavailable_body") } }[kind];
    gate.replaceChildren(emptyState({ icon: "gauge", ...copy,
      action: kind === "sign_in" ? button({ label: t("settings.sign_in_with_nexus"), icon: "key", onClick: () => shell.signIn() }) : null }));
  }

  function paint() {
    loading.hidden = loaded;
    const url = safeUrl(settingsUrl());
    open.replaceChildren(...(url ? [link({ href: url, text: t("settings.open_nexus_model_settings"), external: true })] : []));
    lanes.replaceChildren(...(rows.providers.length ? rows.providers.map(laneCard)
      : [el("p", { class: "bots-page__note text-tertiary", text: t("nexus.no_providers") })]));
  }

  // The lanes, the catalog, each lane's declaration (for its editors and
  // its removed models) and the account's cost unit, read together.
  async function load() {
    try {
      const [listed, catalog, costUnit] = await Promise.all([nexus(PROVIDERS), nexus(MODELS), nexus(COST_UNIT).catch(() => null)]);
      const providers = listed.model_providers || [];
      const configurations = await Promise.all(providers.map((provider) => nexus(providerPath(provider)).then((answer) => [provider.id, answer.configuration || {}]).catch(() => [provider.id, {}])));
      if (!alive()) return;
      rows = { providers, models: catalog.models || [], configurations: Object.fromEntries(configurations), costUnit: costUnit?.account?.cost_unit || null };
      loaded = true;
      failure.hide();
      paintGate(null);
    } catch (error) {
      if (!alive() || error.name === "AbortError") return;
      loaded = true;
      if (gateOf(error)) paintGate(error); else { paintGate(null); problem(error); }
    }
    paint();
  }

  paint();
  load();
  let visible = true;

  return {
    element: scaffold.element,
    update({ visible: next = true } = {}) {
      if (next && !visible) load();
      visible = next;
    },
    dispose() { reads.abort(); closeEditor(); scaffold.element.remove(); },
  };
}
