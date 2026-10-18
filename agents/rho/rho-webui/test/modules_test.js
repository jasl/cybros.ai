import { test, expect } from "bun:test";
import { createSlots } from "../webui/kernel/slots.js";
import { createHandle } from "../webui/kernel/handle.js";
import { createModules } from "../webui/kernel/modules.js";
import { translator } from "../webui/kernel/i18n.js";

const component = () => ({ element: { nodeType: 1 } });
const row = (id, entry = `/modules/${id}/abc123def456/index.js`) => ({ id, name: id, entry });

function harness(modules = {}) {
  const slots = createSlots();
  const calls = [];
  const handles = [];
  const loader = createModules({
    makeHandle: (id) => {
      const handle = createHandle({ id, slots, call: async (path, options) => { calls.push([id, path, options]); return {}; },
        toast() {}, navigate() {}, dock: { open() {} }, primitives: {}, el() {}, translator });
      handles.push(handle);
      return handle;
    },
    importer: async (url) => {
      const module = modules[url];
      if (!module) throw new TypeError(`Failed to fetch dynamically imported module: ${url}`);
      return module;
    },
  });
  return { slots, loader, calls, handles, states: () => [...loader.state.get().values()].map(({ id, status, phase, message }) => ({ id, status, phase, message })) };
}

test("sync loads new rows, registers their contributions and disposes rows that leave", async () => {
  const seen = [];
  const { slots, loader, states } = harness({
    "/modules/a/abc123def456/index.js": { register(ui) { seen.push(ui.id); ui.slots.register("plugins.item.config", { key: "a" }, component); } },
    "/modules/b/abc123def456/index.js": { register(ui) { ui.slots.register("plugins.item.config", { key: "b" }, component); } },
  });
  await loader.sync([row("a"), row("b")]);
  expect(seen).toEqual(["a"]);
  expect(slots.entries("plugins.item.config").map((entry) => entry.cell)).toEqual(["a", "b"]);
  expect(states()).toEqual([{ id: "a", status: "ready", phase: null, message: "" }, { id: "b", status: "ready", phase: null, message: "" }]);
  await loader.sync([row("b")]);
  expect(slots.entries("plugins.item.config").map((entry) => entry.cell)).toEqual(["b"]);
  expect(states().map((state) => state.id)).toEqual(["b"]);
});

test("a changed entry URL is a new import and the old handle's contributions go away first", async () => {
  const versions = [];
  const { slots, loader } = harness({
    "/modules/a/v1/index.js": { register(ui) { versions.push("v1"); ui.slots.register("plugins.item.config", { key: "a" }, component); } },
    "/modules/a/v2/index.js": { register(ui) { versions.push("v2"); ui.slots.register("plugins.item.config", { key: "a", order: 1 }, component); } },
  });
  await loader.sync([row("a", "/modules/a/v1/index.js")]);
  await loader.sync([row("a", "/modules/a/v2/index.js")]);
  expect(versions).toEqual(["v1", "v2"]);
  expect(slots.winner("plugins.item.config", "a").order).toBe(1);
});

test("import and register failures roll back partial registrations and are reported by phase", async () => {
  const errors = [];
  const { slots, loader, states } = harness({
    "/modules/throws/abc123def456/index.js": { register(ui) {
      ui.slots.register("plugins.item.config", { key: "throws" }, component);
      throw new Error("register exploded");
    } },
    "/modules/rejects/abc123def456/index.js": { async register() { throw new Error("async failure"); } },
    "/modules/no-register/abc123def456/index.js": { default: {} },
  });
  loader.state.subscribe(() => {});
  await loader.sync([row("throws"), row("rejects"), row("no-register"), row("missing")]);
  expect(slots.entries("plugins.item.config")).toEqual([]);
  expect(states()).toEqual([
    { id: "throws", status: "failed", phase: "register", message: "register exploded" },
    { id: "rejects", status: "failed", phase: "register", message: "async failure" },
    { id: "no-register", status: "failed", phase: "import", message: "does not export register(ui)" },
    { id: "missing", status: "failed", phase: "import", message: "Failed to fetch dynamically imported module: /modules/missing/abc123def456/index.js" },
  ]);
  expect(errors).toEqual([]);
});

test("a failed module is not retried by a later identical sync but a render failure keeps its registrations", async () => {
  let imports = 0;
  const { slots, loader, states } = harness({
    "/modules/flaky/abc123def456/index.js": { register() { imports += 1; throw new Error("no"); } },
    "/modules/ok/abc123def456/index.js": { register(ui) { ui.slots.register("plugins.item.config", { key: "ok" }, component); } },
  });
  await loader.sync([row("flaky"), row("ok")]);
  await loader.sync([row("flaky"), row("ok")]);
  expect(imports).toBe(1);
  loader.report("ok", new Error("render broke"));
  expect(states().find((state) => state.id === "ok")).toEqual({ id: "ok", status: "failed", phase: "render", message: "render broke" });
  expect(slots.entries("plugins.item.config")).toHaveLength(1);
  loader.report("unknown", new Error("ignored"));
  expect(states().some((state) => state.id === "unknown")).toBe(false);
});

test("disposing a module aborts its handle signal and its default request signal", async () => {
  const { loader, calls, handles } = harness({
    "/modules/a/abc123def456/index.js": { async register(ui) { await ui.call("/telegram"); } },
  });
  await loader.sync([row("a")]);
  expect(calls[0][2].signal).toBe(handles[0].ui.signal);
  expect(handles[0].ui.signal.aborted).toBe(false);
  await loader.sync([]);
  expect(handles[0].ui.signal.aborted).toBe(true);
});

test("concurrent syncs are serialized and the latest desired set wins", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const { loader, states } = harness({
    "/modules/slow/abc123def456/index.js": { async register() { await gate; } },
    "/modules/fast/abc123def456/index.js": { register() {} },
  });
  const first = loader.sync([row("slow")]);
  const second = loader.sync([row("fast")]);
  const third = loader.sync([]);
  expect(second).toBe(first);
  expect(third).toBe(first);
  release();
  await first;
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(states()).toEqual([]);
});

test("dispose removes every live module", async () => {
  const { slots, loader, states } = harness({
    "/modules/a/abc123def456/index.js": { register(ui) { ui.slots.register("plugins.item.config", { key: "a" }, component); } },
  });
  await loader.sync([row("a")]);
  loader.dispose();
  expect(states()).toEqual([]);
  expect(slots.entries("plugins.item.config")).toEqual([]);
});
