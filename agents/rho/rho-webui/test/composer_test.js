import { test, expect } from "bun:test";
import { createCodeMode } from "../webui/composer.js";

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
