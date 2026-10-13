import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";
import { createSlots } from "../webui/kernel/slots.js";
import { listOutlet, keyedOutlet } from "../webui/kernel/outlets.js";
import { el } from "../webui/kernel/dom.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const labelled = (text) => (props) => ({ element: el("span", { text: `${text}:${props.value}` }) });
const texts = (container) => container.children.map((node) => node.textContent);

test("a list outlet mounts winners in order, keeps existing nodes in place and disposes removed ones", () => {
  const slots = createSlots();
  const container = el("div");
  const disposed = [];
  slots.register("sidebar.panellist", { id: "b", order: 20 }, (props) => ({
    element: el("span", { text: `b:${props.value}` }), dispose: () => disposed.push("b"),
  }));
  const outlet = listOutlet(slots, "sidebar.panellist", container, { value: 1 });
  const first = container.firstChild;
  const disposeA = slots.register("sidebar.panellist", { id: "a", order: 10 }, labelled("a"));
  expect(texts(container)).toEqual(["a:1", "b:1"]);
  expect(container.children[1]).toBe(first);
  disposeA();
  expect(texts(container)).toEqual(["b:1"]);
  outlet.dispose();
  expect(disposed).toEqual(["b"]);
  expect(container.childNodes).toHaveLength(0);
});

test("update calls a component's update when it has one and re-creates it otherwise", () => {
  const slots = createSlots();
  const container = el("div");
  const seen = [];
  slots.register("sidebar.panellist", { id: "stateful", order: 1 }, (props) => {
    const element = el("input");
    element.value = `draft ${props.value}`;
    return { element, update: (next) => seen.push(next.value) };
  });
  slots.register("sidebar.panellist", { id: "stateless", order: 2 }, labelled("s"));
  const outlet = listOutlet(slots, "sidebar.panellist", container, { value: 1 });
  const field = container.children[0];
  field.value = "typed by the person";
  outlet.update({ value: 2 });
  expect(container.children[0]).toBe(field);
  expect(field.value).toBe("typed by the person");
  expect(seen).toEqual([2]);
  expect(container.children[1].textContent).toBe("s:2");
});

test("a throwing contribution is omitted and reported without taking the owner down", () => {
  const slots = createSlots();
  const container = el("div");
  const failures = [];
  slots.register("sidebar.panellist", { id: "broken", order: 1 }, () => { throw new Error("boom"); }, "bad.plugin");
  slots.register("sidebar.panellist", { id: "fine", order: 2 }, labelled("fine"));
  listOutlet(slots, "sidebar.panellist", container, { value: 1 }, { onError: (error, facts) => failures.push([error.message, facts.registration.owner, facts.phase]) });
  expect(texts(container)).toEqual(["fine:1"]);
  expect(failures).toEqual([["boom", "bad.plugin", "render"]]);
});

test("a keyed outlet shows the cell's winner, falls back when empty or broken, and follows winner changes", () => {
  const slots = createSlots();
  const container = el("div");
  const fallback = (props) => ({ element: el("p", { text: `generic:${props.plugin}` }) });
  const outlet = keyedOutlet(slots, "plugins.item.config", container, { fallback });
  outlet.show("rho.ingress_telegram", { plugin: "rho.ingress_telegram" });
  expect(texts(container)).toEqual(["generic:rho.ingress_telegram"]);
  const dispose = slots.register("plugins.item.config", { key: "rho.ingress_telegram" }, (props) => ({
    element: el("form", { text: `telegram:${props.plugin}` }),
  }), "rho.ingress_telegram");
  expect(texts(container)).toEqual(["telegram:rho.ingress_telegram"]);
  dispose();
  expect(texts(container)).toEqual(["generic:rho.ingress_telegram"]);
  slots.register("plugins.item.config", { key: "rho.ingress_telegram" }, () => { throw new Error("nope"); }, "rho.ingress_telegram");
  outlet.show("rho.ingress_telegram", { plugin: "rho.ingress_telegram" });
  expect(texts(container)).toEqual(["generic:rho.ingress_telegram"]);
  outlet.show("other", { plugin: "other" });
  expect(texts(container)).toEqual(["generic:other"]);
  outlet.dispose();
  expect(container.childNodes).toHaveLength(0);
});

test("a retaining keyed outlet hides previous panels and tells them they are not visible", () => {
  const slots = createSlots();
  const container = el("div");
  const visibility = [];
  slots.register("main", { key: "conversation" }, (props) => ({
    element: el("section", { text: "conversation" }), update: (next) => visibility.push(["conversation", next.visible]),
  }));
  slots.register("main", { key: "plugins" }, () => ({ element: el("section", { text: "plugins" }) }));
  const outlet = keyedOutlet(slots, "main", container, { retain: true });
  outlet.show("conversation", {});
  const conversation = container.firstChild;
  outlet.show("plugins", {});
  expect(container.children).toHaveLength(2);
  expect(conversation.hidden).toBe(true);
  expect(container.children[1].hidden).toBe(false);
  outlet.show("conversation", {});
  expect(container.children[0]).toBe(conversation);
  expect(conversation.hidden).toBe(false);
  expect(visibility).toEqual([["conversation", false], ["conversation", true]]);
  // A page without `update` is re-instantiated when another is shown; the fresh element stays hidden.
  expect(container.children[1].hidden).toBe(true);
  expect(container.children[1].textContent).toBe("plugins");
});

test("a kept hidden page leaves as soon as its registration goes away, not when it is next shown", () => {
  const slots = createSlots();
  const container = el("div");
  const disposed = [];
  slots.register("main", { key: "conversation" }, () => ({ element: el("section", { text: "conversation" }) }));
  const remove = slots.register("main", { key: "t3" }, () => ({ element: el("section", { text: "t3" }), update() {}, dispose: () => disposed.push("t3") }), "rho.t3");
  const outlet = keyedOutlet(slots, "main", container, { retain: true, fallback: () => ({ element: el("p", { text: "nothing here" }) }) });
  outlet.show("t3", {});
  outlet.show("conversation", {});
  expect(texts(container)).toEqual(["t3", "conversation"]);
  remove();
  expect(disposed).toEqual(["t3"]);
  expect(texts(container)).toEqual(["conversation"]);
  outlet.show("t3", {});
  expect(texts(container)).toEqual(["conversation", "nothing here"]);
});
