import { test, expect } from "bun:test";
import { createCodeMode, createComposer, pendingInputLabel, latestPendingSteer } from "../webui/composer.js";

// The picker uses the same element through refresh and submission. Double only
// that DOM seam to exercise edits while a request or refresh is in flight.
function withDocument(run) {
  const previous = globalThis.document;
  const node = () => ({
    nodeType: 1, children: [], listeners: {}, value: "", hidden: false,
    setAttribute(name, value) { this[name] = value; },
    addEventListener(name, handler) { this.listeners[name] = handler; },
    append(child) { this.children.push(child); },
  });
  globalThis.document = { createElement: node, createTextNode: (text) => ({ nodeType: 3, textContent: text }) };
  try { run(); } finally { globalThis.document = previous; }
}

const policy = (code_mode) => ({ available: true, code_mode, effective: code_mode !== false });
const choose = (picker, value) => { picker.input.value = value; picker.input.listeners.change(); };

test("the composer defaults to steer and lets the sender explicitly queue", () => withDocument(() => {
  let submitted;
  const composer = createComposer({ onMessage() {}, onChange() {}, onStop() {},
    onSubmit: () => { submitted = composer.delivery.value; } });
  composer.composer.listeners.submit();
  expect(submitted).toBe("steer");
  composer.delivery.value = "queue";
  composer.composer.listeners.submit();
  expect(submitted).toBe("queue");
}));

test("pending labels use accepted delivery mode without claiming that the model read it", () => {
  expect(pendingInputLabel({ state: "pending", delivery_mode: "steer" })).toBe("Additional instruction waiting to be read");
  expect(pendingInputLabel({ state: "pending", delivery_mode: "queue" })).toBe("Message queued");
  expect(pendingInputLabel({ state: "held", delivery_mode: "steer" })).toBe("Message waiting");
  expect(pendingInputLabel({ state: "blocked", delivery_mode: "steer", blocked_reason: "run_held" })).toBe("Message waiting");
  expect(pendingInputLabel({ state: "steering", delivery_mode: "steer_now" })).toBe("Send now requested · waiting to be read");
});

test("Send now promotes the latest ordinary steer without replacing queued future work", () => {
  const inputs = [
    { public_id: "first", state: "steering", delivery_mode: "steer", queue_position: 1 },
    { public_id: "queue", state: "pending", delivery_mode: "queue", queue_position: 6 },
    { public_id: "latest", state: "steering", delivery_mode: "steer", queue_position: 3 },
    { public_id: "already", state: "steering", delivery_mode: "steer_now", queue_position: 4 },
  ];
  expect(latestPendingSteer(inputs).public_id).toBe("latest");
  expect(latestPendingSteer(inputs.filter((input) => input.delivery_mode !== "steer"))).toBeUndefined();
});

test("Ctrl+Enter invokes Send now and respects disabled and IME composition", () => withDocument(() => {
  let immediate = 0;
  const composer = createComposer({ onMessage() {}, onChange() {}, onStop() {}, onSubmit() {}, onSendNow: () => { immediate += 1; } });
  const key = (fields = {}) => composer.message.listeners.keydown({ key: "Enter", ctrlKey: true, preventDefault() {}, ...fields });
  key();
  expect(immediate).toBe(1);
  composer.sendNow.disabled = true;
  key();
  expect(immediate).toBe(1);
  composer.sendNow.disabled = false;
  key({ isComposing: true });
  expect(immediate).toBe(1);
}));

test("Code Mode preserves an explicit off and clears the conversation override only for default", () => withDocument(() => {
  const picker = createCodeMode();
  picker.reset();
  expect(picker.value()).toBeNull();
  picker.update(policy(false));
  expect(picker.value()).toBe(false);
  choose(picker, "default");
  picker.update(policy(false));
  expect(picker.value()).toBeNull();
  picker.accepted(null);
  picker.update(policy(null));
  expect(picker.value()).toBeNull();
  picker.update(policy(true));
  expect(picker.value()).toBe(true);
}));

test("a later edit survives acceptance of the previous message and background refresh", () => withDocument(() => {
  const picker = createCodeMode();
  picker.update(policy(true));
  choose(picker, "off");
  const submitted = picker.value();
  choose(picker, "on");
  picker.accepted(submitted);
  picker.update(policy(false));
  expect(picker.value()).toBe(true);
  picker.reset();
  picker.update(policy(false));
  expect(picker.value()).toBe(false);
}));

test("foreign agent conversations omit rho Code Mode without disabling conversation reads", () => withDocument(() => {
  const picker = createCodeMode();
  picker.update({ available: false, code_mode: null, effective: false });
  expect(picker.element.hidden).toBe(true);
  expect(picker.value()).toBeUndefined();
  picker.reset();
  expect(picker.element.hidden).toBe(false);
  expect(picker.value()).toBeNull();
}));
