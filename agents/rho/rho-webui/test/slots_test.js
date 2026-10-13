import { test, expect } from "bun:test";
import { SLOTS, createSlots } from "../webui/kernel/slots.js";

const component = () => ({ element: { nodeType: 1 } });
const names = (rows) => rows.map((row) => row.cell);

test("the catalog is closed and every slot is a list or keyed cell set", () => {
  expect(Object.keys(SLOTS).sort()).toEqual([
    "bots.item.config", "conversation.header.utilities", "dock.tab", "main", "plugins.item.config", "settings.section", "sidebar.panellist",
  ]);
  for (const spec of Object.values(SLOTS)) expect(["list", "keyed"]).toContain(spec.kind);
  const slots = createSlots();
  expect(() => slots.register("sidebar.panelist", { id: "x" }, component)).toThrow("Unknown slot sidebar.panelist");
  expect(() => slots.entries("nope")).toThrow("Unknown slot nope");
});

test("registrations name their cell and required meta, and components are functions", () => {
  const slots = createSlots();
  expect(() => slots.register("sidebar.panellist", {}, component)).toThrow("id is required");
  expect(() => slots.register("main", {}, component)).toThrow("key is required");
  expect(() => slots.register("settings.section", { key: "general" }, component)).toThrow("label is required");
  expect(() => slots.register("dock.tab", { key: "task" }, component)).toThrow("title is required");
  expect(() => slots.register("main", { key: "plugins" }, "not a function")).toThrow("component must be a function");
  expect(() => slots.register("settings.section", { key: "general", label: () => "General" }, component)).not.toThrow();
});

test("list entries follow order then registration sequence, and dispose removes them", () => {
  const slots = createSlots();
  const changes = [];
  slots.subscribe("sidebar.panellist", () => changes.push(names(slots.entries("sidebar.panellist"))));
  const disposeB = slots.register("sidebar.panellist", { id: "b", order: 20 }, component);
  slots.register("sidebar.panellist", { id: "a", order: 10 }, component);
  slots.register("sidebar.panellist", { id: "c", order: 10 }, component);
  expect(names(slots.entries("sidebar.panellist"))).toEqual(["a", "c", "b"]);
  disposeB();
  disposeB();
  expect(names(slots.entries("sidebar.panellist"))).toEqual(["a", "c"]);
  expect(changes).toEqual([["b"], ["a", "b"], ["a", "c", "b"], ["a", "c"]]);
});

test("a cell refuses a second occupant at the same priority and names the current one", () => {
  const slots = createSlots();
  slots.register("plugins.item.config", { key: "rho.ingress_telegram" }, component, "rho.ingress_telegram");
  expect(() => slots.register("plugins.item.config", { key: "rho.ingress_telegram" }, component, "other.plugin"))
    .toThrow("plugins.item.config: rho.ingress_telegram is already registered by rho.ingress_telegram");
});

test("a lower priority shadows a cell and disposing it restores the previous winner", () => {
  const slots = createSlots();
  const builtin = () => ({ element: { nodeType: 1 } });
  const replacement = () => ({ element: { nodeType: 1 } });
  slots.register("dock.tab", { key: "task", title: () => "Task" }, builtin);
  expect(slots.winner("dock.tab", "task").component).toBe(builtin);
  const dispose = slots.register("dock.tab", { key: "task", title: () => "Task", priority: -10 }, replacement, "custom.task");
  expect(slots.winner("dock.tab", "task").component).toBe(replacement);
  expect(slots.winner("dock.tab", "task").owner).toBe("custom.task");
  expect(slots.entries("dock.tab")).toHaveLength(1);
  dispose();
  expect(slots.winner("dock.tab", "task").component).toBe(builtin);
  expect(slots.winner("dock.tab", "missing")).toBeNull();
});

test("registration meta is kept verbatim for owners that list cells", () => {
  const slots = createSlots();
  const label = () => "General";
  slots.register("settings.section", { key: "general", order: 0, label }, component);
  slots.register("settings.section", { key: "advanced", order: 20, label: () => "More" }, component);
  const [general] = slots.entries("settings.section");
  expect(general.meta.label).toBe(label);
  expect(general.owner).toBe("rho.webui");
  expect(Object.isFrozen(general)).toBe(true);
});
