import { el } from "./views.js";

export function codeModeValue(choice) {
  return { default: null, on: true, off: false }[choice];
}

export function createComposer({ onMessage, onChange, onSubmit, onStop }) {
  const message = el("textarea", { id: "message", name: "message", rows: "3", required: true,
    placeholder: "Ask rho to work on something…", oninput: () => onMessage(message.value),
    onkeydown: (event) => {
      if (event.key === "Enter" && !event.shiftKey && !event.isComposing && event.keyCode !== 229) {
        event.preventDefault();
        if (!send.disabled) composer.requestSubmit();
      }
    } });
  const model = el("select", { id: "model", required: true, onchange: onChange },
    el("option", { value: "", text: "Loading models…" }));
  const approval = el("select", { id: "approval" },
    el("option", { value: "ask", text: "Ask before effects" }),
    el("option", { value: "bypass", text: "Allow effects" }),
    el("option", { value: "rules", text: "Use approval rules" }));
  const codeMode = createCodeMode();
  const send = el("button", { type: "submit", class: "primary", text: "Send" });
  const stop = el("button", { type: "button", text: "Stop", onclick: onStop, class: "danger", hidden: true });
  const composer = el("form", { class: "composer", onsubmit: onSubmit },
    el("label", { for: "message", class: "sr-only", text: "Message" }), message,
    el("div", { class: "composer-options" },
      el("label", { for: "model", text: "Model" }, model),
      el("label", { for: "approval", text: "Approval mode" }, approval), codeMode.element),
    el("div", { class: "composer-footer" },
      el("span", { class: "faint", text: "Enter to send · Shift+Enter for a new line" }),
      el("span", { class: "spacer" }), stop, send));
  return { message, model, approval, codeMode, send, stop, composer };
}

// Background refreshes must not discard a choice made for the next message.
export function createCodeMode() {
  let edited = false;
  let available = true;
  const input = el("select", { id: "code-mode", onchange: () => { edited = true; } },
    el("option", { value: "default", text: "rho default" }),
    el("option", { value: "on", text: "On" }),
    el("option", { value: "off", text: "Off" }));
  const element = el("label", { for: "code-mode", title: "Applies when you send, and becomes this conversation's choice for future requests." }, "Code Mode", input);
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
