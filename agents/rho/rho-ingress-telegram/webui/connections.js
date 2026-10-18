// A blank password field preserves a write-only token; clearing is deliberate.
export function connectionPatch({ name, enabled, token, clearToken }) {
  return { name: name.trim(), enabled, ...(clearToken ? { token: null } : token.trim() ? { token: token.trim() } : {}) };
}

function connectionEditor(ui, t, connection, initial, { saved }) {
  const { el, primitives: p } = ui;
  const reads = new AbortController();
  let props = initial;
  let current = connection;
  let dirty = false;
  let busy = false;
  let reading = 0;
  const failure = p.alert({ tone: "error" });
  const status = el("p", { class: "text-secondary", role: "status" });
  const identity = el("p");
  const name = p.input({ name: "connection_name", value: connection?.name || "", autocomplete: "off", required: true });
  const enabled = p.checkbox({ name: "connection_enabled", label: t("connections.enabled") });
  enabled.input.checked = connection?.enabled ?? true;
  const token = p.input({ name: "token", type: "password", autocomplete: "new-password", spellcheck: "false" });
  const tokenField = p.field({ label: t("token.label"), control: token, hint: t("token.hint") });
  const clear = p.checkbox({ name: "clear_token", label: t("token.clear") });
  const clearRow = el("div", { class: "stack stack--tight" }, clear.element,
    el("p", { class: "field__hint", text: t("token.clear_hint") }));
  const submit = p.button({ label: t("token.save"), variant: "primary", type: "submit" });
  const fields = el("fieldset", { class: "stack" },
    p.field({ label: t("connections.name"), control: name }).element, enabled.element, tokenField.element, clearRow,
    el("div", { class: "row row--end" }, submit));
  const form = el("form", { oninput: () => { dirty = true; paint(); }, onsubmit: save }, fields);
  const card = p.section({ title: connection ? t("connections.edit") : t("connections.new"), description: t("connections.editor_hint"), level: 3 });
  card.body.append(failure.element, status, identity, form);

  function paint() {
    fields.disabled = busy;
    token.disabled = clear.input.checked;
    clearRow.hidden = !current?.token?.present;
    tokenField.setHint(current?.token?.present ? t("token.hint_saved") : t("token.hint"));
    submit.querySelector(".btn__label").textContent = token.value.trim() || !current?.token?.present || clear.input.checked ? t("token.save") : t("token.save_kept");
    const state = current?.connection;
    status.textContent = state ? t("status.connection", { state: t(`connection.${state}`, {}, state.replaceAll("_", " ")) }) : "";
    status.hidden = !status.textContent;
    const username = current?.bot?.username;
    identity.replaceChildren(...(username ? [p.link({ href: `https://t.me/${encodeURIComponent(username)}`, text: t("connections.identity", { username }) })] : []));
    identity.hidden = !username;
  }

  async function refresh() {
    if (!current?.public_id || reads.signal.aborted) return;
    const version = ++reading;
    try {
      const answer = await ui.call(`/telegram/connection?connection_public_id=${encodeURIComponent(current.public_id)}`, { signal: reads.signal });
      if (reads.signal.aborted || version !== reading) return;
      current = answer.connection;
      if (!dirty) { name.value = current.name; enabled.input.checked = current.enabled; }
      failure.hide(); paint();
    } catch (error) { if (!reads.signal.aborted && version === reading && error.name !== "AbortError") failure.show(error.message); }
  }

  async function save(event) {
    event.preventDefault();
    if (busy || reads.signal.aborted) return;
    busy = true; failure.hide(); paint();
    const body = { ...connectionPatch({ name: name.value, enabled: enabled.input.checked, token: token.value, clearToken: clear.input.checked }),
      ...(current?.public_id ? { connection_public_id: current.public_id } : {}) };
    try {
      const answer = await ui.call("/telegram/connection", { method: "POST", body, signal: reads.signal });
      if (reads.signal.aborted) return;
      current = answer.connection;
      dirty = false; clearSecret();
      ui.toast(t("connections.saved", { name: current.name }), { tone: "success" });
      saved(current);
      await (props.refresh || ui.inventory.refresh)();
    } catch (error) { if (!reads.signal.aborted && error.name !== "AbortError") failure.show(error.message); }
    finally { busy = false; paint(); }
  }

  function clearSecret() { token.value = ""; clear.input.checked = false; paint(); }
  paint(); refresh();
  return { element: card.element, refresh, clearSecret,
    update(next) { props = next; if (next.visible === false) clearSecret(); },
    dispose() { clearSecret(); reads.abort(); card.element.remove(); },
  };
}

// Settings and the plugin detail use this same configuration owner. Switching
// connections discards unsaved secrets while preserving ordinary form drafts.
export function telegramConnections(ui, t, initial = {}) {
  const { el, primitives: p } = ui;
  const reads = new AbortController();
  const failure = p.alert({ tone: "error" });
  const picker = p.select({ name: "connection_public_id" });
  const add = p.button({ label: t("connections.new"), onClick: () => select("new") });
  const refresh = p.iconButton({ icon: "refresh", label: t("status.refresh"), onClick: () => { read(); active()?.refresh(); } });
  const card = p.section({ title: t("connections.telegram"), description: t("connections.description"), actions: [add, refresh] });
  const selection = p.field({ label: t("connections.select"), control: picker });
  const empty = el("p", { class: "text-secondary", text: t("connections.empty") });
  const host = el("div", { class: "stack" });
  card.body.append(failure.element, el("p", {}, p.link({ href: "https://t.me/BotFather", text: t("setup.botfather") })), selection.element, empty, host);
  let props = initial;
  let rows = [];
  let selected = null;
  let reading = 0;
  const editors = new Map();
  const active = () => editors.get(selected);

  function paint() {
    picker.replaceChildren(...rows.map((row) => el("option", { value: row.public_id,
      text: row.bot?.username ? `${row.name} · @${row.bot.username}` : row.name })));
    if (selected === "new") picker.append(el("option", { value: "new", text: t("connections.new") }));
    picker.value = selected || "";
    selection.element.hidden = rows.length === 0 && selected !== "new";
    empty.hidden = rows.length > 0 || selected === "new";
  }

  function select(id) {
    if (id === selected && active()) return;
    active()?.clearSecret();
    selected = id;
    if (id && !editors.has(id)) {
      const connection = id === "new" ? null : rows.find((row) => row.public_id === id);
      if (id !== "new" && !connection) return;
      let editorKey = id;
      const editor = connectionEditor(ui, t, connection, props, { saved: (saved) => {
        rows = [...rows.filter((row) => row.public_id !== saved.public_id), saved];
        if (editorKey === "new") {
          editors.delete(editorKey); editors.set(saved.public_id, editor);
          if (selected === editorKey) selected = saved.public_id;
          editorKey = saved.public_id;
        }
        paint();
      } });
      editors.set(id, editor);
    }
    host.replaceChildren(...(active() ? [active().element] : []));
    active()?.update(props);
    paint();
  }

  async function read() {
    const version = ++reading;
    try {
      const answer = await ui.call("/telegram/connections", { signal: reads.signal });
      if (reads.signal.aborted || version !== reading) return;
      rows = answer.connections;
      failure.hide();
      if (!selected) select(rows[0]?.public_id || null);
      paint();
    } catch (error) { if (!reads.signal.aborted && version === reading && error.name !== "AbortError") failure.show(error.message); }
  }

  function clearSecrets() { for (const editor of editors.values()) editor.clearSecret(); }
  function onVisibility() { if (document.hidden) clearSecrets(); }
  document.addEventListener("visibilitychange", onVisibility);
  picker.addEventListener("change", () => select(picker.value));
  read(); paint();
  return { element: card.element,
    update(next) {
      const returning = next.visible !== false && props.visible === false;
      props = next;
      for (const editor of editors.values()) editor.update(next);
      if (returning) { read(); active()?.refresh(); }
    },
    dispose() { reads.abort(); document.removeEventListener("visibilitychange", onVisibility); for (const editor of editors.values()) editor.dispose(); },
  };
}
