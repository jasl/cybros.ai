import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { createSetup, setupProgress, automaticModel } from "../webui/shell/setup.js";
import { observable } from "../webui/kernel/observable.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const ready = { connected: true, model: { ready: true, default_model: "p/m", eligible: [{ ref: "p/m" }] } };

test("setup progress is a projection: connection, then model, then any running plugin that needs setup", () => {
  expect(setupProgress(null)).toMatchObject({ step: "connection", ready: false });
  expect(setupProgress({ connected: true, model: { ready: false, eligible: [] } })).toMatchObject({ step: "provider", title: "To do: configure a model in Nexus" });
  expect(setupProgress({ connected: true, model: { ready: false, eligible: [{ ref: "a" }, { ref: "b" }] } }).title).toBe("Choose your default model");
  const plugins = [
    { id: "rho.webui", name: "Web interface", enabled: true, active: true, readiness: { ready: true } },
    { id: "rho.ingress_telegram", name: "Telegram", enabled: true, active: true, readiness: { ready: false, issues: ["A Telegram bot owner is not configured"] } },
    { id: "rho.disabled", name: "Off", enabled: false, active: false, readiness: { ready: false } },
  ];
  expect(setupProgress(ready, plugins)).toEqual({ step: "plugin", plugin: "rho.ingress_telegram", title: "Finish setting up Telegram", ready: false });
  expect(setupProgress(ready, plugins.slice(0, 1))).toEqual({ step: "ready", title: "rho is ready to use", ready: true });
});

test("a sole eligible model is adopted automatically once, and an existing choice always wins", async () => {
  expect(automaticModel({ default_model: null, eligible: [{ ref: "only" }] })).toBe("only");
  expect(automaticModel({ default_model: "chosen", eligible: [{ ref: "only" }] })).toBeNull();
  expect(automaticModel({ default_model: null, eligible: [{ ref: "a" }, { ref: "b" }] })).toBeNull();
  const writes = [];
  let statusReads = 0;
  const call = async (path, options) => {
    if (path === "/settings" && options?.method === "PATCH") { writes.push(options.body); return { settings: { default_model: options.body.default_model } }; }
    if (path === "/settings") return { settings: { default_model: null }, nexus: {} };
    if (path === "/settings/status") { statusReads += 1; return { connected: true, model: { ready: statusReads > 1, default_model: statusReads > 1 ? "only" : null, eligible: [{ ref: "only" }] } }; }
    if (path === "/auth/status") return { authenticated: true, human: { display_name: "Ada" } };
    if (path === "/status") return { workspace: { state: "adopted" } };
    throw new Error(path);
  };
  const controller = new AbortController();
  const setup = createSetup({ call, signal: controller.signal, inventory: { state: observable({ plugins: [] }) } });
  await setup.refresh();
  expect(writes).toEqual([{ default_model: "only" }]);
  expect(setup.state.get().status.model.ready).toBe(true);
  expect(setup.state.get().identity.human.display_name).toBe("Ada");
  expect(setup.progress().ready).toBe(true);
  await setup.refresh();
  expect(writes).toHaveLength(1);
});

test("save writes once at a time, keeps the returned document and surfaces refusals to the caller", async () => {
  let release;
  const patches = [];
  let current = { settings: {} };
  const call = async (path, options) => {
    if (options?.method === "PATCH") {
      patches.push(options.body);
      if (options.body.default_model === "slow") return new Promise((resolve) => { release = () => { current = { settings: { default_model: "slow" } }; resolve(current); }; });
      if (options.body.default_model === "second") { current = { settings: { default_model: "second" } }; return current; }
      const error = new Error("settings_invalid"); error.status = 422; throw error;
    }
    if (path === "/settings") return current;
    if (path === "/settings/status") return { connected: true, model: { ready: true } };
    if (path === "/auth/status") return {};
    return {};
  };
  const controller = new AbortController();
  const setup = createSetup({ call, signal: controller.signal, inventory: { state: observable({ plugins: [] }) } });
  const first = setup.save({ default_model: "slow" }, { refresh: false });
  let secondDone = false;
  const second = setup.save({ default_model: "second" }).then((answer) => { secondDone = true; return answer; });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(patches).toEqual([{ default_model: "slow" }]);
  expect(secondDone).toBe(false);
  release();
  expect(await first).toEqual({ settings: { default_model: "slow" } });
  expect(await second).toEqual({ settings: { default_model: "second" } }, "a save made while another applies waits its turn");
  expect(patches).toEqual([{ default_model: "slow" }, { default_model: "second" }]);
  expect(setup.state.get().document).toEqual({ settings: { default_model: "second" } });
  await expect(setup.save({ default_model: "bad" }, { refresh: false })).rejects.toThrow("settings_invalid");
  expect(await setup.save({ default_model: "second" }, { refresh: false })).toEqual({ settings: { default_model: "second" } }, "a failed write does not block the next");
});


test("returning from Nexus in another tab refreshes model availability and coalesces the focus event", async () => {
  const controller = new AbortController();
  let current = ready;
  let reads = 0;
  const setup = createSetup({ signal: controller.signal, inventory: { state: observable({ plugins: [] }) },
    call: async (path) => {
      if (path === "/settings/status") { reads += 1; return current; }
      return {};
    } });
  await setup.refresh();
  setup.watchFocus();
  current = { ...ready, model: { ...ready.model, eligible: [{ ref: "p/m" }, { ref: "p/new" }] } };
  document.visibilityState = "hidden";
  document.dispatchEvent(new Event("visibilitychange"));
  expect(reads).toBe(1);
  document.visibilityState = "visible";
  document.dispatchEvent(new Event("visibilitychange"));
  window.dispatchEvent(new Event("focus"));
  await flush();
  expect(reads).toBe(2);
  expect(setup.state.get().status.model.eligible.map((row) => row.ref)).toEqual(["p/m", "p/new"]);
  controller.abort();
  setup.dispose();
  document.dispatchEvent(new Event("visibilitychange"));
  await flush();
  expect(reads).toBe(2);
});
