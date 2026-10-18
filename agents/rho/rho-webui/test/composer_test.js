import { test, expect, beforeEach, afterEach, jest } from "bun:test";
import { installDocument, key, type } from "./support/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { createComposer } from "../webui/features/conversation/composer.js";
import { latestPendingSteer } from "../webui/features/conversation/lifecycle.js";
import { pendingInputLabel } from "../webui/features/conversation/seat.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => { jest.useRealTimers(); restore(); });

function conversations(overrides = {}) {
  const state = observable({ id: "c-1", access: "ready", detail: { public_id: "c-1", active_turn_public_id: null }, inputs: [],
    busy: false, stopping: false, draft: "", focus: 0, modes: { available: true, code_mode_available: true, code_mode: true, subagent: true }, modesBusy: false, models: [{ ref: "local/model", display_name: "Local" }],
    choicesError: null, model: "local/model", approval: "ask", delivery: "steer", runner: "", ...overrides });
  const calls = [];
  const record = (name) => (...args) => { calls.push([name, ...args]); };
  const patch = (changes) => state.update((value) => ({ ...value, ...changes }));
  return {
    state, calls, patch,
    send: record("send"), sendNow: record("sendNow"), stop: record("stop"),
    setDraft: (text) => { calls.push(["setDraft", text]); patch({ draft: text }); },
    setApproval: (mode) => { calls.push(["setApproval", mode]); patch({ approval: mode }); },
    setDelivery: (mode) => { calls.push(["setDelivery", mode]); patch({ delivery: mode }); },
    setMode: (name, enabled) => { calls.push(["setMode", name, enabled]); patch({ modes: { ...state.get().modes, [name]: enabled } }); },
    setModel: (ref) => { calls.push(["setModel", ref]); patch({ model: ref }); },
  };
}

function mounted(overrides) {
  const fake = conversations(overrides);
  const composer = createComposer({ conversations: fake });
  document.body.append(composer.element);
  const draft = composer.element.querySelector("textarea");
  const send = composer.element.querySelector(".send");
  const chips = composer.element.querySelectorAll(".chip");
  return { fake, composer, draft, send, chips, names: () => fake.calls.map(([name]) => name).filter((name) => name !== "setDraft") };
}
const running = { detail: { public_id: "c-1", active_turn_public_id: "turn-1" } };

test("Enter sends, Shift+Enter keeps a newline, Mod+Enter sends now, and composition never sends", () => {
  const { draft, names } = mounted();
  type(draft, "hello");
  expect(key(draft, "Enter").defaultPrevented).toBe(true);
  expect(key(draft, "Enter", { shiftKey: true }).defaultPrevented).toBe(false);
  key(draft, "Enter", { isComposing: true });
  key(draft, "Enter", { keyCode: 229 });
  key(draft, "Enter", { ctrlKey: true });
  key(draft, "Enter", { metaKey: true });
  expect(names()).toEqual(["send", "sendNow", "sendNow"]);
});

test("typing writes the controller's draft and the field grows to at most fourteen lines", () => {
  const { draft, fake } = mounted();
  draft.scrollHeight = 120;
  type(draft, "two\nlines");
  expect(fake.state.get().draft).toBe("two\nlines");
  expect(draft.style.height).toBe("120px");
  draft.scrollHeight = 900;
  fake.patch({ draft: "a very long draft from another conversation" });
  expect(draft.value).toBe("a very long draft from another conversation");
  expect(draft.style.height).toBe("336px");
});

test("Escape twice within a second stops a running conversation; slower presses and idle ones do not", () => {
  jest.useFakeTimers();
  const { draft, names, fake } = mounted(running);
  key(draft, "Escape");
  jest.advanceTimersByTime(1500);
  key(draft, "Escape");
  expect(names()).toEqual([]);
  jest.advanceTimersByTime(400);
  key(draft, "Escape");
  expect(names()).toEqual(["stop"]);
  fake.patch({ detail: { public_id: "c-1", active_turn_public_id: null } });
  key(draft, "Escape"); key(draft, "Escape");
  expect(names()).toEqual(["stop"]);
});

test("the round button is Stop while a turn runs with an empty draft, and Send otherwise", () => {
  const { send, fake, names } = mounted(running);
  expect(send.getAttribute("aria-label")).toBe("Stop");
  expect(send.querySelector(".icon").dataset.icon).toBe("stop");
  send.click();
  expect(names()).toEqual(["stop"]);
  fake.patch({ draft: "more context" });
  expect(send.getAttribute("aria-label")).toBe("Add this instruction to the current work");
  expect(send.querySelector(".icon").dataset.icon).toBe("send");
  send.click();
  expect(names()).toEqual(["stop", "send"]);
  fake.patch({ delivery: "queue" });
  expect(send.getAttribute("aria-label")).toBe("Queue this message after the current response");
  fake.patch({ detail: { public_id: "c-1", active_turn_public_id: null }, draft: "" });
  expect(send.getAttribute("aria-label")).toBe("Send");
  expect(send.disabled).toBe(true);
});

test("Code mode and Subagent keep stable labels while their highlight and accessible state toggle independently", () => {
  const { chips, fake } = mounted();
  const [approval, code, subagent, delivery, model] = chips;
  expect(approval.getAttribute("aria-label")).toBe("Permissions: Ask before changes");
  expect(code.textContent).toBe("Code mode");
  expect(subagent.textContent).toBe("Subagent");
  expect(code.classList.contains("is-on")).toBe(true);
  expect(subagent.classList.contains("is-on")).toBe(true);
  expect(code.getAttribute("aria-pressed")).toBe("true");
  expect(subagent.getAttribute("aria-pressed")).toBe("true");
  expect(code.hasAttribute("aria-haspopup")).toBe(false);
  code.click();
  expect(fake.calls.at(-1)).toEqual(["setMode", "code_mode", false]);
  expect(code.getAttribute("aria-pressed")).toBe("false");
  expect(code.textContent).toBe("Code mode");
  expect(code.classList.contains("is-on")).toBe(false);
  expect(code.getAttribute("aria-label")).toBe("Code mode · Off");
  expect(subagent.getAttribute("aria-pressed")).toBe("true");
  expect(subagent.classList.contains("is-on")).toBe(true);
  subagent.click();
  expect(fake.calls.at(-1)).toEqual(["setMode", "subagent", false]);
  expect(subagent.textContent).toBe("Subagent");
  expect(subagent.getAttribute("aria-pressed")).toBe("false");
  expect(subagent.classList.contains("is-on")).toBe(false);
  subagent.click();
  expect(fake.calls.at(-1)).toEqual(["setMode", "subagent", true]);
  expect(subagent.getAttribute("aria-pressed")).toBe("true");
  expect(subagent.classList.contains("is-on")).toBe(true);
  expect(document.querySelector('[role="menu"]')).toBeNull();
  expect(delivery.hidden).toBe(true);
  expect(model.querySelector(".chip__label").textContent).toBe("Local");
  approval.click();
  const items = document.querySelectorAll('[role="menu"] [role="menuitemradio"]');
  expect(items.map((node) => node.querySelector(".menu__label").textContent)).toEqual(["Ask before changes", "Rules only", "Bypass permissions"]);
  expect(items[1].querySelector(".menu__detail").textContent).toContain("everything else is refused");
  document.querySelector('[role="menu"]').remove();
  fake.patch({ ...running, approval: "bypass" });
  expect(delivery.hidden).toBe(false);
  expect(approval.querySelector(".chip__label").textContent).toBe("Bypass permissions");
});

test("mode controls show loading, preserve saved values during writes, and respect unavailable and read-only conversations", () => {
  const { chips, fake, send, draft } = mounted({ modes: null, draft: "continue" });
  const [approval, code, subagent, , model] = chips;
  for (const toggle of [code, subagent]) {
    expect(toggle.disabled).toBe(true);
    expect(toggle.classList.contains("is-unavailable")).toBe(true);
    expect(toggle.hasAttribute("aria-pressed")).toBe(false);
    expect(toggle.getAttribute("aria-label")).toContain("Loading");
  }
  expect(send.disabled).toBe(true);
  const modes = { available: true, code_mode_available: true, code_mode: false, subagent: true };
  fake.patch({ modes, modesBusy: true });
  expect(code.getAttribute("aria-pressed")).toBe("false");
  expect(code.getAttribute("aria-busy")).toBe("true");
  expect(code.disabled).toBe(true);
  expect(subagent.disabled).toBe(true);
  expect(code.classList.contains("is-unavailable")).toBe(false);
  expect(subagent.classList.contains("is-unavailable")).toBe(false);
  expect(send.disabled).toBe(true);
  fake.patch({ modesBusy: false, modes: { ...modes, code_mode_available: false } });
  expect(code.disabled).toBe(true);
  expect(subagent.disabled).toBe(false);
  expect(code.classList.contains("is-unavailable")).toBe(true);
  expect(subagent.classList.contains("is-unavailable")).toBe(false);
  fake.patch({ modes: { ...modes, available: false } });
  expect(code.disabled).toBe(true);
  expect(subagent.disabled).toBe(true);
  expect(code.classList.contains("is-unavailable")).toBe(true);
  expect(subagent.classList.contains("is-unavailable")).toBe(true);
  for (const detail of [{ public_id: "c-1", ingresses: [{ label: "Telegram" }] },
    { public_id: "c-1", bot_public_id: "bot-1", ingresses: [] }]) {
    fake.patch({ detail, modes });
    for (const control of [approval, code, subagent, model, draft]) expect(control.disabled).toBe(true);
    for (const toggle of [code, subagent]) expect(toggle.classList.contains("is-unavailable")).toBe(true);
  }
});

test("the model menu keeps an unavailable saved model visible but not selectable", () => {
  const { chips, fake } = mounted({ model: "gone/model" });
  const model = chips[4];
  expect(model.querySelector(".chip__label").textContent).toBe("gone/model · unavailable");
  model.click();
  const items = document.body.querySelectorAll("[role=menuitemradio]");
  expect(items.map((item) => [item.textContent, item.disabled, item.getAttribute("aria-checked")]))
    .toEqual([["AutomaticUse the Preset's model. Choose this to clear a model override.", false, "false"],
      ["Locallocal/model", false, "false"], ["gone/model · unavailable", true, "true"]]);
  items[1].click();
  expect(fake.state.get().model).toBe("local/model");
});

test("Automatic stays selected after fallback and the actual response route is shown separately", () => {
  const { chips, fake, send } = mounted({ model: "", actualModel: "backup/model", draft: "continue" });
  const model = chips[4];
  expect(model.querySelector(".chip__label").textContent).toBe("Automatic");
  expect(send.disabled).toBe(false);
  model.click();
  expect(document.querySelector(".menu__title").textContent).toBe("Last response: backup/model");
  let items = document.body.querySelectorAll("[role=menuitemradio]");
  expect(items.map((item) => item.getAttribute("aria-checked"))).toEqual(["true", "false"]);
  items[1].click();
  expect(fake.calls.at(-1)).toEqual(["setModel", "local/model"]);
  model.click();
  items = document.body.querySelectorAll("[role=menuitemradio]");
  items[0].click();
  expect(fake.calls.at(-1)).toEqual(["setModel", ""]);
  expect(model.querySelector(".chip__label").textContent).toBe("Automatic");
});

test("the delivery menu switches between steer and queue and offers Send now", () => {
  const { chips, fake } = mounted({ ...running, inputs: [{ public_id: "s", state: "steering", delivery_mode: "steer", queue_position: 1 }] });
  chips[3].click();
  const [steer, queue] = document.body.querySelectorAll("[role=menuitemradio]");
  expect(steer.getAttribute("aria-checked")).toBe("true");
  queue.click();
  expect(fake.state.get().delivery).toBe("queue");
  chips[3].click();
  const sendNow = document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent.startsWith("Send now"));
  expect(sendNow.disabled).toBe(false);
  sendNow.click();
  expect(fake.calls.at(-1)).toEqual(["sendNow"]);
});

test("the delivery menu waits for a send to finish before capturing Send now availability", () => {
  const { chips, fake, draft } = mounted({ ...running, busy: true, delivery: "queue",
    inputs: [{ public_id: "q", state: "pending", delivery_mode: "queue", queue_position: 1 }] });
  type(draft, "Read this instruction now");
  expect(chips[3].disabled).toBe(true);
  fake.patch({ busy: false });
  expect(chips[3].disabled).toBe(false);
  chips[3].click();
  const sendNow = document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent.startsWith("Send now"));
  expect(sendNow.disabled).toBe(false);
});

test("pending labels follow the accepted delivery mode without claiming the model read it", () => {
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
