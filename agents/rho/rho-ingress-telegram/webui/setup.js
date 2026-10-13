import { accessLists } from "./access.js";

// The media models are chosen from the account's usable models for each
// workload, read through rho's model listing.
const MODEL_WORKLOADS = { transcription_model: "transcription", speech_model: "speech_generation" };

// The next step a person has to take, or null once the bot is connected with
// a bound owner. Each connection has its own switch; the Plugins page owns
// the extension-wide switch.
export function setupPrompt(document, t) {
  if (!document.configuration?.connection_public_id) return t("prompt.choose_connection");
  if (!document.configuration?.target) return t("prompt.choose_target");
  if (!document.configuration?.owner_id) return t("prompt.bind_account");
  if (document.enabled === false) return t("prompt.enable_bot");
  return document.connection === "running" ? null : t("prompt.check_connection");
}

// The chosen connection owns transport status; the target form names any
// state that needs attention.
function statusLine(document, t) {
  if (!document.configuration?.connection_public_id || document.connection === "running") return null;
  const state = document.connection || "starting";
  return t("status.connection", { state: t(`connection.${state}`, {}, state.replaceAll("_", " ")) });
}

// One fixed Telegram target belongs to the Bot; credentials belong only to
// shared Connections. Saved and in-progress fields retain separate ownership.
export function telegramSetup(ui, t, initial, { agent, refreshDirectory = () => {} }) {
  const { el, primitives: p } = ui;
  const reads = new AbortController();
  let props = initial;
  let current = null;
  let connectDirty = false;
  let optionsDirty = false;
  let available = true;
  let connections = null;
  let reading = 0;
  let connectionsReading = 0;
  const busy = new Set();
  const path = `/telegram?agent_public_id=${encodeURIComponent(agent.public_id)}`;
  const addressed = (body) => ({ ...body, agent_public_id: agent.public_id });
  const savedMessage = (text) => t("bots.saved", { name: agent.display_name || agent.name, message: text });

  const alert = p.alert({ tone: "error" });
  const guidance = el("p", { class: "strong", role: "status", hidden: true });
  const status = el("p", { class: "text-secondary", role: "status", text: t("status.loading") });
  const botLink = el("p", { hidden: true });

  const enabled = p.checkbox({ name: "enabled", label: t("setup.enabled") });
  const pluginDisabled = el("p", { class: "notice", text: t("setup.plugin_disabled"), hidden: true });
  const connection = p.select({ name: "connection_public_id" });
  const chat = p.input({ name: "chat_id", inputmode: "numeric", pattern: "-?[0-9]+" });
  const topic = p.input({ name: "topic_id", type: "number", min: 1, step: 1 });
  const owner = p.input({ name: "owner_id", inputmode: "numeric", pattern: "[0-9]+", placeholder: t("owner.placeholder") });
  const submit = p.button({ label: t("setup.save"), variant: "primary", type: "submit" });
  const connectFields = el("fieldset", { class: "stack", disabled: true }, enabled.element,
    p.field({ label: t("target.connection"), control: connection, hint: t("target.connection_hint") }).element,
    p.field({ label: t("target.chat"), control: chat, hint: t("target.chat_hint") }).element,
    p.field({ label: t("target.topic"), control: topic, hint: t("target.topic_hint") }).element,
    p.field({ label: t("owner.label"), control: owner, hint: t("owner.hint") }).element,
    el("div", { class: "row row--end" }, submit));
  const connectForm = el("form", { oninput: editConnection, onsubmit: saveConnection }, connectFields);

  const stale = p.input({ type: "number", name: "stale_after", min: 1, step: 1, required: true });
  const grouping = p.input({ type: "number", name: "input_debounce_seconds", min: 0, max: 10, step: 1, required: true });
  const transcription = p.select({ name: "transcription_model" });
  const speech = p.select({ name: "speech_model" });
  const modelSelects = { transcription_model: transcription, speech_model: speech };
  const catalogs = { transcription_model: null, speech_model: null };
  const optionFields = el("fieldset", { class: "stack", disabled: true },
    p.field({ label: t("options.stale_after"), control: stale }).element,
    p.field({ label: t("options.grouping"), control: grouping, hint: t("options.grouping_hint") }).element,
    p.field({ label: t("options.transcription_model"), control: transcription }).element,
    p.field({ label: t("options.speech_model"), control: speech, hint: t("options.hint") }).element,
    el("div", { class: "row row--end" }, p.button({ label: t("options.save"), variant: "primary", type: "submit" })));
  // How the bot handles messages: a card of its own, with a Save of its own.
  const options = p.section({ title: t("options.title"), description: t("options.description"), level: 3 });
  options.body.append(el("form", { oninput: () => { optionsDirty = true; }, onsubmit: saveOptions }, optionFields));

  const access = accessLists(ui, t, { signal: reads.signal, changed: paint, agentPublicId: agent.public_id });
  const accessHost = el("div");
  const ownerOnly = el("p", { class: "notice", text: t("setup.owner_only"), hidden: true });
  const refresh = p.iconButton({ icon: "refresh", label: t("status.refresh"), onClick: () => { alert.hide(); read(); readConnections(); readModels(); refreshDirectory(); } });
  const connect = p.section({ title: t("setup.title"), description: t("setup.description"), actions: [refresh], level: 3 });
  connect.body.append(pluginDisabled, ownerOnly, guidance, status, botLink, connectForm);
  const element = el("div", { class: "stack" }, alert.element, connect.element, options.element, accessHost);

  async function read() {
    const version = ++reading;
    try {
      const document = await ui.call(path, { signal: reads.signal });
      if (!reads.signal.aborted && version === reading) paint(document);
    } catch (error) {
      if (version === reading) fail(error);
    }
  }

  function fail(error) {
    if (!reads.signal.aborted && error.name !== "AbortError") alert.show(error.message);
  }

  // Each workload's catalog, read beside the document; a read that fails
  // leaves the saved model as the one choice beside Not set.
  async function readModels() {
    await Promise.all(Object.entries(MODEL_WORKLOADS).map(async ([key, workload]) => {
      try {
        catalogs[key] = (await ui.call(`/models?workload=${encodeURIComponent(workload)}`, { signal: reads.signal })).models;
      } catch (error) {
        if (error.name === "AbortError") return;
      }
    }));
    for (const [key, select] of Object.entries(modelSelects)) paintModels(select, key, select.value);
  }

  // Not set, the catalog's models, and the current value when the catalog
  // does not list it, so a saved reference stays visible and selectable.
  function paintModels(select, key, value) {
    const rows = catalogs[key] || [];
    select.replaceChildren(el("option", { value: "", text: t("options.model_not_set") }),
      ...rows.map((row) => el("option", { value: row.ref, text: row.display_name ? `${row.display_name} · ${row.ref}` : row.ref })));
    if (value && !rows.some((row) => row.ref === value)) select.append(el("option", { value, text: t("options.model_unavailable", { model: value }) }));
    select.value = value || "";
  }

  function paintConnections(value) {
    const rows = connections || [];
    connection.replaceChildren(el("option", { value: "", text: t("target.connection_none") }),
      ...rows.map((row) => el("option", { value: row.public_id, text: row.bot?.username ? `${row.name} · @${row.bot.username}` : row.name })));
    if (value && !rows.some((row) => row.public_id === value)) connection.append(el("option", { value, text: t("target.connection_unavailable") }));
    connection.value = value || "";
  }

  async function readConnections() {
    const version = ++connectionsReading;
    try {
      const answer = await ui.call("/telegram/connections", { signal: reads.signal });
      if (reads.signal.aborted || version !== connectionsReading) return;
      connections = answer.connections;
      paintConnections(connectDirty ? connection.value : current?.configuration.connection_public_id);
    } catch (error) { if (version === connectionsReading) { connections = null; fail(error); } }
    finally { if (version === connectionsReading) paintAvailability(); }
  }

  function editConnection() { connectDirty = true; }

  function saveConnection(event) {
    event.preventDefault();
    const chatId = chat.value.trim();
    const topicId = topic.value.trim();
    if ((chatId && (!/^-?[0-9]+$/.test(chatId) || /^-?0+$/.test(chatId))) ||
        (topicId && (!chatId.startsWith("-") || !/^[1-9][0-9]*$/.test(topicId)))) {
      alert.show(t("target.invalid")); return;
    }
    const body = { connection_public_id: connection.value || null,
      target: chatId ? { chat_id: chatId, topic_id: topicId ? Number(topicId) : null } : null,
      owner_id: owner.value.trim() || null, enabled: enabled.input.checked };
    return write(connectFields, body, () => {
      connectDirty = false;
      ui.toast(savedMessage(t("setup.saved")), { tone: "success" });
    });
  }

  function saveOptions(event) {
    event.preventDefault();
    return write(optionFields, {
      stale_after: Number(stale.value), input_debounce_seconds: Number(grouping.value),
      transcription_model: transcription.value, speech_model: speech.value,
    }, () => {
      optionsDirty = false;
      ui.toast(savedMessage(t("options.saved")), { tone: "success" });
    });
  }

  // Each form writes only its own fields, then refreshes the Bot projection.
  async function write(fields, body, saved) {
    if (!available || !current || busy.has(fields) || (fields === connectFields && connections === null)) return;
    alert.hide();
    busy.add(fields);
    paintAvailability();
    try {
      await ui.call("/telegram/configuration", { method: "POST", body: addressed(body), signal: reads.signal });
      if (reads.signal.aborted) return;
      saved();
      await Promise.all([read(), ui.inventory.refresh(), props.refresh?.()]);
    } catch (error) {
      fail(error);
    } finally {
      busy.delete(fields);
      paintAvailability();
    }
  }

  function paint(document) {
    current = document;
    const personal = document.owner_only !== false;
    ownerOnly.hidden = !personal;
    accessHost.replaceChildren(...(personal ? [] : [access.element]));
    accessHost.hidden = personal;
    pluginDisabled.hidden = document.plugin_enabled !== false;
    const prompt = setupPrompt(document, t);
    guidance.textContent = prompt || "";
    guidance.hidden = !prompt;
    const trouble = statusLine(document, t);
    status.textContent = trouble || "";
    status.hidden = !trouble;
    const username = document.bot?.username;
    botLink.replaceChildren(...(username
      ? [p.link({ href: `https://t.me/${encodeURIComponent(username)}`, text: t("setup.open_bot", { username }) })] : []));
    botLink.hidden = !username;
    const configuration = document.configuration || {};
    if (!connectDirty) {
      paintConnections(configuration.connection_public_id);
      chat.value = configuration.target?.chat_id || "";
      topic.value = configuration.target?.topic_id ?? "";
      owner.value = configuration.owner_id || "";
      enabled.input.checked = document.enabled;
    }
    if (!optionsDirty) {
      stale.value = configuration.stale_after || 600;
      grouping.value = configuration.input_debounce_seconds ?? 2;
      paintModels(transcription, "transcription_model", configuration.transcription_model || "");
      paintModels(speech, "speech_model", configuration.speech_model || "");
    }
    paintAvailability();
    access.update(document);
  }

  function paintAvailability() {
    for (const fields of [connectFields, optionFields]) fields.disabled = !available || !current || busy.has(fields) || (fields === connectFields && connections === null);
    access.setAvailable(available);
  }

  read();
  readConnections();
  readModels();
  return { element,
    update(next) { props = next; },
    setAvailable(value) { available = value; paintAvailability(); },
    dispose() { reads.abort(); },
  };
}
