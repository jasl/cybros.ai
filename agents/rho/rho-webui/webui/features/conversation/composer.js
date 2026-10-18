import { el, icon, uniqueId } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { menuButton } from "../../primitives/index.js";
import { composerState } from "./lifecycle.js";

const MAX_HEIGHT = 336;
const DOUBLE_ESCAPE = 1000;
const APPROVALS = ["ask", "rules", "bypass"];
// IME composition never sends: Enter confirms the candidate instead.
const composing = (event) => event.isComposing || event.keyCode === 229;

// Permissions in the words other agent products use: ask before changes,
// rules only, bypass. The kernel's modes behind them are `ask`, `rules`, `bypass`.
const approvalLabel = (mode) => ({ ask: t("common.ask_before_changes"), bypass: t("common.bypass_permissions"), rules: t("common.rules_only") })[mode];
const approvalDetail = (mode) => ({ ask: t("composer.ask_detail"), bypass: t("composer.bypass_detail"), rules: t("composer.rules_detail") })[mode];
const deliveryLabel = (mode) => (mode === "queue" ? t("composer.after_current_reply") : t("composer.steer_current_work"));

function modelLabel({ models, model, choicesError }) {
  if (models === null) return t("composer.loading_models");
  const row = models.find((entry) => entry.ref === model);
  if (row) return row.display_name || row.ref;
  if (model) return t("common.unavailable_item", { name: model });
  if (!models.length) return choicesError ? t("composer.models_unavailable") : t("composer.no_available_models");
  return t("composer.automatic_model");
}

function sendLabel(value, gate) {
  if (value.busy) return t("composer.sending");
  if (!gate.running) return t("common.send");
  return value.delivery === "queue" ? t("composer.queue_after_reply") : t("composer.steer_hint");
}

// The composer card. Its draft is the controller's (one per conversation),
// so a refresh, a send racing a refresh or a hidden card never loses text.
export function createComposer({ conversations }) {
  const get = () => conversations.state.get();
  const hint = el("p", { class: "sr-only", id: uniqueId("composer-hint"), text: t("composer.enter_to_send_shift_enter_for_a_new") });
  const draft = el("textarea", { class: "composer__draft", name: "message", rows: "1", "aria-label": t("common.message"),
    "aria-describedby": hint.id, placeholder: t("composer.ask_rho_to_work_on_something") });
  const approval = menuButton({ label: approvalLabel("ask"), items: () => [
    { type: "title", label: t("common.permissions") },
    ...APPROVALS.map((mode) => ({ type: "radio", label: approvalLabel(mode), detail: approvalDetail(mode), checked: get().approval === mode,
      onSelect: () => conversations.setApproval(mode) })),
  ] });
  const modeButtons = [
    { name: "code_mode", label: t("composer.code_mode"), hint: t("composer.code_mode_explained") },
    { name: "subagent", label: t("composer.subagent"), hint: t("composer.subagent_explained") },
  ].map(({ name, label, hint: modeHint }) => ({ name, label, hint: modeHint,
    element: el("button", { type: "button", class: "chip composer__mode",
      "data-tip": modeHint,
      onclick: () => conversations.setMode(name, !get().modes[name]) },
    el("span", { class: "chip__label" })),
  }));
  const delivery = menuButton({ label: deliveryLabel("steer"), items: () => {
    const value = get();
    return [
      { type: "radio", label: t("composer.steer_current_work"), checked: value.delivery !== "queue", onSelect: () => conversations.setDelivery("steer") },
      { type: "radio", label: t("composer.after_current_reply"), checked: value.delivery === "queue", onSelect: () => conversations.setDelivery("queue") },
      { type: "separator" },
      { type: "item", label: t("composer.send_now"), detail: t("composer.send_now_help"), icon: "send",
        disabled: !composerState(value).sendNow, onSelect: () => conversations.sendNow() },
    ];
  } });
  const model = menuButton({ label: t("composer.loading_models"), icon: "spark", attrs: { class: "chip composer__model" }, items: () => {
    const value = get();
    if (value.models === null) return [{ type: "item", label: t("composer.loading_models"), disabled: true }];
    const rows = [{ type: "radio", label: t("composer.automatic_model"), detail: t("composer.automatic_model_detail"),
      checked: !value.model, onSelect: () => conversations.setModel("") },
    ...value.models.map((row) => ({ type: "radio", label: row.display_name || row.ref, detail: row.display_name ? row.ref : undefined,
      checked: row.ref === value.model, onSelect: () => conversations.setModel(row.ref) }))];
    // A saved choice the catalog no longer lists stays visible, never selectable.
    if (value.model && !value.models.some((row) => row.ref === value.model)) {
      rows.push({ type: "radio", label: t("common.unavailable_item", { name: value.model }), checked: true, disabled: true });
    }
    if (!value.models.length) rows.push({ type: "item", label: modelLabel(value), disabled: true });
    if (value.actualModel) rows.push({ type: "separator" }, { type: "title", label: t("composer.last_response_model", { model: value.actualModel }) });
    return rows;
  } });
  const send = el("button", { type: "submit", class: "send" }, icon("send"));
  const form = el("form", { class: "composer", onsubmit: (event) => { event.preventDefault(); conversations.send(); } },
    hint, draft,
    el("div", { class: "composer__toolbar" },
      el("div", { class: "composer__group" }, approval.element, modeButtons.map(({ element }) => element)),
      el("div", { class: "composer__group" }, delivery.element, model.element, send)));
  let stopMode = false;
  let lastEscape = 0;
  let focusRequest = get().focus;

  const grow = () => { draft.style.height = "auto"; draft.style.height = `${Math.min(draft.scrollHeight, MAX_HEIGHT)}px`; };
  draft.addEventListener("input", () => { conversations.setDraft(draft.value); grow(); });
  draft.addEventListener("keydown", (event) => {
    if (composing(event)) return;
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      if (event.ctrlKey || event.metaKey) conversations.sendNow(); else conversations.send();
    } else if (event.key === "Escape") {
      const gate = composerState(get());
      if (!gate.running || !gate.stop) return;
      const now = Date.now();
      if (now - lastEscape <= DOUBLE_ESCAPE) { lastEscape = 0; conversations.stop(); } else lastEscape = now;
    }
  });
  // While running with an empty draft the circle is Stop; it never submits then.
  send.addEventListener("click", (event) => {
    if (!stopMode) return;
    event.preventDefault();
    conversations.stop();
  });

  function chip(menu, name, label, disabled, value = label) {
    menu.update({ label });
    menu.element.setAttribute("aria-label", t("composer.chip_label", { name, value }));
    menu.element.disabled = disabled;
  }

  function paint(value) {
    if (draft.value !== value.draft) { draft.value = value.draft; grow(); }
    const gate = composerState(value);
    const channelOwned = !!value.detail?.bot_public_id || !!value.detail?.ingresses?.length;
    const locked = !!value.id && !gate.controls.send;
    form.classList.toggle("composer--hero", !value.id);
    draft.disabled = !!value.detail?.archived_at || channelOwned;
    chip(approval, t("common.permissions"), approvalLabel(value.approval), channelOwned);
    for (const { name, label: modeLabel, hint: modeHint, element } of modeButtons) {
      const enabled = value.modes?.[name];
      const codeUnavailable = name === "code_mode" && value.modes && !value.modes.code_mode_available;
      const label = t("composer.mode_state", { name: modeLabel,
        value: value.modes ? enabled ? t("composer.on") : t("composer.off") : t("composer.loading_modes") });
      element.querySelector(".chip__label").textContent = modeLabel;
      element.setAttribute("aria-label", label);
      element.dataset.tip = codeUnavailable ? t("composer.code_mode_unavailable") : modeHint;
      if (value.modes) element.setAttribute("aria-pressed", String(enabled)); else element.removeAttribute("aria-pressed");
      if (value.modesBusy) element.setAttribute("aria-busy", "true"); else element.removeAttribute("aria-busy");
      element.classList.toggle("is-on", !!enabled);
      const unavailable = locked || value.busy || !value.modes?.available || codeUnavailable;
      // Serial saves block both toggles without dimming their saved on/off state.
      element.classList.toggle("is-unavailable", unavailable);
      element.disabled = unavailable || value.modesBusy;
    }
    delivery.element.hidden = !gate.running;
    chip(delivery, t("composer.send_behavior"), deliveryLabel(value.delivery), locked || value.busy || value.modesBusy);
    chip(model, t("common.model"), modelLabel(value), channelOwned);
    stopMode = gate.running && gate.stop && !value.draft.trim();
    const label = stopMode ? t("common.stop") : sendLabel(value, gate);
    send.setAttribute("aria-label", label);
    send.dataset.tip = stopMode ? t("composer.stop_hint") : label;
    send.querySelector(".icon").dataset.icon = stopMode ? "stop" : "send";
    send.classList.toggle("send--stop", stopMode);
    send.disabled = stopMode ? value.stopping : !gate.send;
    if (value.busy || value.stopping) send.setAttribute("aria-busy", "true"); else send.removeAttribute("aria-busy");
    if (value.focus !== focusRequest) {
      focusRequest = value.focus;
      // After the panel has placed the card (hero or seat) for this view.
      requestAnimationFrame(() => { if (draft.isConnected && !draft.disabled) draft.focus(); });
    }
  }

  const stop = conversations.state.subscribe(paint, { immediate: true });
  return {
    element: form,
    focus() { draft.focus(); },
    dispose() { stop(); for (const menu of [approval, delivery, model]) menu.dispose(); },
  };
}
