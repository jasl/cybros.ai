// The allowlists and the ignore list live in the Agent-owned Telegram state,
// so they exist only while Telegram reaches the Agent profile. Until then the
// document's `access` is null: the lists are unavailable, never shown empty.
export function accessLists(ui, t, { signal, changed, agentPublicId = null }) {
  const { el, primitives: p } = ui;
  const labels = {
    allowed_users: t("access.allowed_users"),
    allowed_chats: t("access.allowed_chats"),
    ignored_users: t("access.ignored_users"),
  };
  const alert = p.alert({ tone: "error" });
  const unavailable = el("p", { class: "notice", text: t("access.unavailable"), hidden: true });
  const lists = Object.fromEntries(Object.keys(labels).map((name) => [name, p.list({ empty: t("access.none") })]));
  const groups = el("div", { class: "stack", hidden: true }, Object.entries(lists).map(([name, list]) =>
    el("div", { class: "stack stack--tight" }, el("h4", { class: "text-xs strong text-secondary", text: labels[name] }), list.element)));
  const list = p.select({ name: "list", options: Object.entries(labels).map(([value, label]) => ({ value, label })) });
  const id = p.input({ name: "id", inputmode: "numeric", pattern: "-?[0-9]+", required: true, placeholder: t("access.id_placeholder") });
  const idField = p.field({ label: t("access.id"), control: id });
  idField.element.classList.add("grow");
  const fields = el("fieldset", { class: "stack", disabled: true }, groups,
    el("div", { class: "row row--wrap" }, p.field({ label: t("access.list"), control: list }).element, idField.element),
    el("div", { class: "row row--end" }, p.button({ label: t("access.add"), type: "submit" })));
  const form = el("form", { onsubmit: add }, fields);
  const section = p.section({ title: t("access.title"), description: t("access.description"), level: 3 });
  section.body.append(alert.element, unavailable, form);
  let current = null;
  let available = true;
  let saving = false;

  async function add(event) {
    event.preventDefault();
    if (await change(list.value, "add", id.value.trim())) id.value = "";
  }

  // The route answers the whole Telegram document, so the page repaints from
  // the answer instead of reading it again.
  async function change(name, action, value) {
    if (!available || !current?.access || saving || signal.aborted) return false;
    saving = true;
    paintAvailability();
    try {
      const body = { list: name, action, id: value, ...(agentPublicId ? { agent_public_id: agentPublicId } : {}) };
      const document = await ui.call("/telegram/access", { method: "POST", signal, body });
      if (signal.aborted) return false;
      alert.hide();
      ui.toast(t("access.updated"), { tone: "success" });
      changed(document);
      return true;
    } catch (error) {
      if (error.name !== "AbortError") alert.show(error.message);
      return false;
    } finally {
      saving = false;
      paintAvailability();
    }
  }

  function update(document) {
    current = document;
    const access = document.access;
    unavailable.hidden = !!access;
    groups.hidden = !access;
    paintAvailability();
    for (const [name, rows] of Object.entries(lists)) {
      rows.update((access?.[name] || []).map((value) => ({
        key: value, label: value, mono: true,
        action: { label: t("access.remove"), ariaLabel: t("access.remove_from", { id: value, list: labels[name] }),
          onClick: () => change(name, "remove", value) },
      })));
    }
  }

  function paintAvailability() {
    fields.disabled = !available || !current?.access || saving;
  }

  return { element: section.element, update,
    setAvailable(value) { available = value; paintAvailability(); },
  };
}
