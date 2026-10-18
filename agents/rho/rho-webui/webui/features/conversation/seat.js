import { el, uniqueId } from "../../kernel/dom.js";
import { t, statusText } from "../../kernel/i18n.js";
import { markdown } from "../../kernel/markdown.js";
import { isTerminal, isUnresolvedFailure } from "../../kernel/format.js";
import { alert, button, link, textarea } from "../../primitives/index.js";
import { conversationControls, composerState, latestPendingSteer } from "./lifecycle.js";
import { mcpTarget } from "../../primitives/mcp_target.js";

const composing = (event) => event.isComposing || event.keyCode === 229;

// Labels follow the accepted delivery mode; waiting never claims the model
// has read the message.
export function pendingInputLabel(input) {
  if (input.blocked_reason || input.state === "held") return t("seat.message_waiting");
  if (input.delivery_mode === "steer_now") return t("seat.message_steering_now");
  return input.delivery_mode === "steer" ? t("seat.message_steering") : t("seat.message_queued");
}

// Pause/Resume for a live run and Retry/Abandon for each unresolved failed step;
// Nexus rechecks the effective failure policy on every action.
export function executionRow(snapshot, onAction, { nexusUrl, conversationId } = {}) {
  if (!snapshot?.run_public_id) return null;
  const held = (snapshot.tasks || []).filter(isUnresolvedFailure);
  const active = snapshot.run_status && !isTerminal(snapshot.run_status);
  if (!active && !held.length) return null;
  const failure = alert({ tone: "error" });
  const element = el("section", { class: "execution", "aria-label": t("seat.execution_controls") });
  let busy = false;
  const action = (label, glyph, path, body = {}) => button({ label, icon: glyph, size: "sm", onClick: async () => {
    if (busy) return;
    busy = true;
    failure.hide();
    for (const control of element.querySelectorAll("button")) control.disabled = true;
    try { await onAction(path, { public_id: snapshot.run_public_id, ...body }); }
    catch (error) { failure.show(error.message || t("conversation.request_failed")); }
    finally {
      busy = false;
      for (const control of element.querySelectorAll("button")) control.disabled = false;
    }
  } });
  if (active) {
    const paused = snapshot.run_status === "paused";
    const running = snapshot.run_status === "running";
    element.append(el("div", { class: "execution__row" },
      el("span", { class: "execution__label", text: paused ? t("seat.execution_paused") : running ? t("seat.execution_in_progress") : statusText(snapshot.run_status) }),
      paused ? action(t("seat.resume"), "play", "/runs/resume") : running ? action(t("seat.pause"), "pause", "/runs/pause") : null));
  }
  for (const task of held) {
    element.append(el("div", { class: "execution__row execution__row--warn" },
      el("span", { class: "execution__label", text: t("seat.step", { task_key: task.task_key, status: statusText(task.status) }) }),
      action(t("seat.retry_failed_step"), "retry", "/runs/retry", { task_key: task.task_key }),
      action(t("seat.abandon_failed_step"), "close", "/runs/abandon", { task_key: task.task_key })));
    if (task.error_key === "provider_context_overflow") element.append(el("p", { class: "execution__hint", text: t("errors.provider_context_overflow") }));
  }
  if (held.some((task) => task.error_key === "conversation_cost_limit_reached")) {
    element.append(el("p", { class: "execution__hint", text: t("seat.cost_limit_recovery") }));
    if (nexusUrl && conversationId) element.append(link({
      href: `${nexusUrl.replace(/\/$/, "")}/conversations/${encodeURIComponent(conversationId)}/cost_limit/edit`,
      text: t("seat.edit_cost_limit"),
    }));
  }
  element.append(failure.element);
  return element;
}

function connectionMessage(value) {
  if (value.access === "read-only") return { text: t("conversation.read_only"), refresh: true };
  if (value.access === "unavailable") return { text: t("conversation.unavailable"), refresh: true };
  if (value.detached) return { text: t("conversation.detached"), refresh: true };
  if (value.readError) return { text: value.readError, refresh: true };
  if (value.reconnecting) return { text: t("conversation.reconnecting"), refresh: false };
  if (value.access === "loading" && !value.detail && !value.error) return { text: t("conversation.loading"), refresh: false };
  return { text: "", refresh: false };
}

// The seat under the transcript: execution controls, notices, the queue of
// waiting inputs, and the card the person acts on. An approval or question
// replaces the composer card while it waits; the composer stays mounted,
// hidden, with its draft.
export function createSeat({ conversations, nexusUrl = () => null }) {
  const get = () => conversations.state.get();
  const answers = new Map();
  const execution = el("div", { class: "seat__execution" });
  const ingress = el("p", { class: "notice seat__notice", role: "status", hidden: true });
  const connectionText = el("span", { class: "grow" });
  const connectionRefresh = button({ label: t("common.refresh"), variant: "ghost", size: "sm", icon: "refresh", onClick: () => conversations.refresh() });
  const connection = el("div", { class: "notice seat__notice row", role: "status", hidden: true }, connectionText, connectionRefresh);
  const failure = alert({ tone: "error" });
  const notice = alert({ tone: "warning" });
  const queue = el("ul", { class: "queue", "aria-label": t("seat.pending_inputs"), hidden: true });
  const card = el("div", { class: "seat__card" });
  const composerSlot = el("div", { class: "seat__composer" });
  const element = el("div", { class: "seat" }, execution, ingress, connection, failure.element, notice.element, queue, card, composerSlot);
  const seen = {};
  let currentCard = null;

  function positionLabel(className) {
    const element = el("span", { class: className });
    return { element, update(total) { element.hidden = total <= 1; element.textContent = t("seat.position", { position: 1, total }); } };
  }

  function approvalCard(ask, writable) {
    const heading = uniqueId("ask");
    const position = positionLabel("ask__position");
    const site = ask.tool_name === "web_fetch" && ask.target?.kind !== "mcp";
    let pending = false;
    const act = async (path, body) => {
      if (pending) return;
      pending = true;
      for (const control of node.querySelectorAll("button")) control.disabled = true;
      const done = await conversations.respond(ask, path, body);
      pending = false;
      if (!done && node.isConnected) for (const control of node.querySelectorAll("button")) control.disabled = !writable;
    };
    const approve = button({ label: t("seat.approve"), variant: "primary", size: "sm", disabled: !writable, onClick: () => act("/runs/approve") });
    const deny = button({ label: t("seat.deny"), size: "sm", disabled: !writable, onClick: () => act("/runs/deny") });
    // The daemon derives the site rule from the held input when the person acts.
    const allow = site ? button({ label: t("seat.allow_site"), size: "sm", disabled: !writable, onClick: () => act("/runs/approve", { always: true }) }) : null;
    const node = el("section", { class: "ask ask--approval", tabindex: "-1", "aria-labelledby": heading },
      el("div", { class: "ask__strip" }, el("span", { id: heading, text: t("seat.approval_required") }),
        position.element),
      el("div", { class: "ask__body" },
        el("p", { class: "ask__headline", text: ask.tool_alias || ask.tool_name || t("seat.tool_action") }),
        mcpTarget(ask),
        el("pre", { class: "ask__input", text: JSON.stringify(ask.tool_input, null, 2) }),
        site ? el("p", { class: "ask__policy", text: t("seat.site_policy") }) : null),
      el("div", { class: "ask__actions" }, deny, allow, approve));
    // Keys act only when the card itself has focus; its buttons keep their own Enter.
    node.addEventListener("keydown", (event) => {
      if (event.target !== node) return;
      if (event.key === "Enter") { event.preventDefault(); approve.click(); }
      else if (event.key === "Escape") { event.preventDefault(); deny.click(); }
    });
    return { node, focus: () => approve.focus(), updatePosition: position.update };
  }

  function questionCard(ask, writable) {
    const key = `${ask.run_public_id}:${ask.task_key}`;
    const heading = uniqueId("ask");
    const position = positionLabel("ask__count");
    const answer = textarea({ name: key, rows: 2, disabled: !writable, attrs: { "aria-label": t("seat.answer"), "aria-describedby": heading } });
    answer.value = answers.get(key) || "";
    answer.addEventListener("input", () => answers.set(key, answer.value));
    const submit = button({ label: t("seat.send_answer"), variant: "primary", size: "sm", type: "submit", disabled: !writable });
    const prompt = typeof ask.prompt === "string" ? ask.prompt : JSON.stringify(ask.prompt || "");
    const form = el("form", { class: "ask__form", onsubmit: async (event) => {
      event.preventDefault();
      if (!answer.value.trim() || submit.disabled) return;
      submit.disabled = true; answer.disabled = true;
      if (await conversations.respond(ask, "/answer", { content: answer.value })) answers.delete(key);
      else if (form.isConnected) { submit.disabled = !writable; answer.disabled = !writable; }
    } }, answer, el("div", { class: "ask__actions" }, submit));
    answer.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey && !composing(event)) { event.preventDefault(); form.requestSubmit(); }
    });
    const node = el("section", { class: "ask ask--question", "aria-labelledby": heading },
      el("div", { class: "ask__head" },
        el("p", { class: "ask__eyebrow", id: heading, text: t("seat.needs_answer") }),
        position.element),
      el("div", { class: "ask__prompt markdown" }, markdown(prompt)), form);
    return { node, focus: () => answer.focus(), updatePosition: position.update };
  }

  function paintAsks(value, writable) {
    const ask = value.asks[0];
    const signature = JSON.stringify([ask, writable]);
    if (signature === seen.asks) { currentCard?.updatePosition(value.asks.length); return; }
    seen.asks = signature;
    const hadFocus = element.contains(document.activeElement);
    const inCard = card.contains(document.activeElement);
    const built = ask ? (ask.kind === "approval" ? approvalCard : questionCard)(ask, writable) : null;
    currentCard = built;
    built?.updatePosition(value.asks.length);
    card.replaceChildren(...(built ? [built.node] : []));
    composerSlot.hidden = !!built;
    if (built && hadFocus) built.focus();
    else if (!built && inCard) composerSlot.querySelector("textarea")?.focus();
  }

  function paintQueue(value, gate) {
    const signature = JSON.stringify([value.inputs, gate.controls.send && !value.busy]);
    if (signature === seen.queue) return;
    seen.queue = signature;
    const latest = latestPendingSteer(value.inputs);
    queue.hidden = !value.inputs.length;
    queue.replaceChildren(...value.inputs.map((input) => el("li", { class: "queue__row" },
      el("div", { class: "queue__text" },
        el("span", { class: "queue__label", text: pendingInputLabel(input) }),
        el("div", { class: "markdown markdown--compact" }, markdown(input.text || "")),
        input.blocked_reason ? el("p", { class: "queue__reason", text: input.blocked_reason }) : null),
      input === latest ? button({ label: t("composer.send_now"), variant: "ghost", size: "sm", disabled: !gate.controls.send || value.busy,
        attrs: { title: t("composer.send_now_help") }, onClick: () => conversations.promote() }) : null)));
  }

  function paint(value) {
    if (value.id !== seen.id) { seen.id = value.id; answers.clear(); seen.asks = null; seen.queue = null; seen.execution = null; }
    const gate = composerState(value);
    const { writable } = conversationControls(value.detail, value.access);
    const snapshot = writable ? value.snapshot : null;
    const publicUrl = nexusUrl();
    const executionKey = JSON.stringify([snapshot?.run_public_id, snapshot?.run_status, snapshot?.tasks, snapshot?.attention, publicUrl]);
    if (executionKey !== seen.execution) {
      seen.execution = executionKey;
      execution.replaceChildren(...[executionRow(snapshot, conversations.execute, { nexusUrl: publicUrl, conversationId: value.id })].filter(Boolean));
    }
    const channels = (value.detail?.ingresses || []).map((entry) => entry.label).join(" · ");
    ingress.hidden = !channels && !value.detail?.bot_public_id;
    ingress.textContent = channels ? t("seat.ingress", { channels, stop: gate.stop ? t("seat.stop_remains_available") : "" }) : value.detail?.bot_public_id ? t("seat.bot_history") : "";
    const message = connectionMessage(value);
    connection.hidden = !message.text;
    connectionText.textContent = message.text;
    connectionRefresh.hidden = !message.refresh;
    if (value.error) failure.show(value.error); else failure.hide();
    if (value.notice) notice.show(value.notice, "warning"); else notice.hide();
    paintQueue(value, gate);
    paintAsks(value, writable);
  }

  const stop = conversations.state.subscribe(paint, { immediate: true });
  return { element, composerSlot, dispose() { stop(); } };
}
