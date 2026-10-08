import { t } from "./i18n.js";
import { el } from "./views.js";

export function codeModeValue(choice) {
  return { default: null, on: true, off: false }[choice];
}

export function createComposer({ onMessage, onChange, onSubmit, onSendNow, onStop }) {
  const message = el("textarea", { id: "message", name: "message", rows: "3", required: true,
    placeholder: t("composer.ask_rho_to_work_on_something"), oninput: () => onMessage(message.value),
    onkeydown: (event) => {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing && event.keyCode !== 229) {
        event.preventDefault();
        if (event.ctrlKey || event.metaKey) {
          if (!sendNow.disabled) onSendNow(event);
        } else if (!send.disabled) composer.requestSubmit();
      }
    } });
  const model = el("select", { id: "model", required: true, onchange: onChange },
    el("option", { value: "", text: t("composer.loading_models") }));
  const approval = el("select", { id: "approval" },
    el("option", { value: "ask", text: t("common.ask_before_effects") }),
    el("option", { value: "bypass", text: t("common.allow_effects") }),
    el("option", { value: "rules", text: t("common.use_approval_rules") }));
  const codeMode = createCodeMode();
  const delivery = el("select", { id: "delivery-mode", onchange: onChange },
    el("option", { value: "steer", text: t("composer.steer_current_work") }),
    el("option", { value: "queue", text: t("composer.after_current_reply") }));
  delivery.value = "steer";
  const send = el("button", { type: "submit", class: "primary", text: t("common.send") });
  const sendNow = el("button", { type: "button", text: t("composer.send_now"),
    title: t("composer.send_now_help"), onclick: onSendNow, hidden: true });
  const stop = el("button", { type: "button", text: t("common.stop"), onclick: onStop, class: "danger", hidden: true });
  const composer = el("form", { class: "composer", onsubmit: onSubmit },
    el("label", { for: "message", class: "sr-only", text: t("common.message") }), message,
    el("div", { class: "composer-options" },
      el("label", { for: "model", text: t("common.model") }, model),
      el("label", { for: "approval", text: t("common.approval_mode") }, approval), codeMode.element,
      el("label", { for: "delivery-mode", text: t("composer.send_behavior") }, delivery)),
    el("div", { class: "composer-footer" },
      el("span", { class: "faint", text: t("composer.enter_to_send_shift_enter_for_a_new") }),
      el("span", { class: "spacer" }), stop, sendNow, send));
  return { message, model, approval, codeMode, delivery, send, sendNow, stop, composer };
}

export function pendingInputLabel(input) {
  if (input.blocked_reason || input.state === "held") return t("console.message_waiting");
  if (input.delivery_mode === "steer_now") return t("console.message_steering_now");
  return t(input.delivery_mode === "steer" ? "console.message_steering" : "console.message_queued");
}

export function latestPendingSteer(inputs) {
  return inputs.filter((input) => input.state === "steering" && input.delivery_mode === "steer")
    .sort((left, right) => left.queue_position - right.queue_position).at(-1);
}

// Background refreshes must not discard a choice made for the next message.
export function createCodeMode() {
  let edited = false;
  let available = true;
  const input = el("select", { id: "code-mode", onchange: () => { edited = true; } },
    el("option", { value: "default", text: t("composer.rho_default") }),
    el("option", { value: "on", text: t("composer.on") }),
    el("option", { value: "off", text: t("composer.off") }));
  const element = el("label", { for: "code-mode", title: t("composer.applies_when_you_send_and_becomes_this_conversation") }, t("composer.code_mode"), input);
  return { element, input,
    value: () => available ? codeModeValue(input.value) : undefined,
    reset: () => { edited = false; available = true; element.hidden = false; input.value = "default"; },
    accepted: (value) => { if (value === codeModeValue(input.value)) edited = false; },
    update: (policy) => {
      available = policy.available;
      element.hidden = !available;
      if (!edited) input.value = policy.code_mode === null ? "default" : policy.code_mode ? "on" : "off";
    },
  };
}
