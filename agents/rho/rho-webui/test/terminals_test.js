import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { terminalsPanel, register } from "../webui/features/terminals/index.js";

let restore, panels;
beforeEach(() => { restore = installDocument(); panels = []; });
afterEach(() => { panels.forEach((panel) => panel.dispose()); restore(); });
const target = { public_id: "run", task_key: "call_tool", workspace_public_id: "workspace" };
const findButton = (panel, label) => panel.element.querySelectorAll("button").find((node) => node.textContent === label);

function fixture({ status = "needs_approval", failFirst = false } = {}) {
  const creates = [], stops = [];
  const panel = terminalsPanel({ async call(path, options = {}) {
    if (path === "/runners") return { runners: [{ public_id: "runner", tools: ["terminal"], display_name: "Runner" }] };
    if (path === "/terminals" && options.method === "POST") {
      creates.push(options.body);
      if (failFirst && creates.length === 1) throw new Error("Connection interrupted");
      return { terminal: target };
    }
    if (path.startsWith("/terminals?")) return { terminals: [], has_more: false };
    if (path.startsWith("/runs/task?")) return { task: { status, ...(status === "failed" ? { error: { key: "tool_not_served" } } : {}) } };
    if (path === "/stop") { stops.push(options.body); return {}; }
    throw new Error(`Unexpected request ${path}`);
  } }, { conversation: { workspace: "workspace" } });
  panels.push(panel);
  return { panel, creates, stops };
}

test("creation waits for discovery and an uncertain retry preserves the original Runner and key", async () => {
  const f = fixture({ failFirst: true });
  expect(findButton(f.panel, "New terminal").disabled).toBe(true);
  await flush();
  f.panel.element.querySelector("select").value = "runner";
  findButton(f.panel, "New terminal").click();
  await flush();
  expect(findButton(f.panel, "Retry terminal creation")).toBeTruthy();
  expect(f.panel.element.querySelector("select").disabled).toBe(true);
  findButton(f.panel, "Retry terminal creation").click();
  await flush();
  expect(f.creates).toHaveLength(2);
  expect(f.creates[0]).toEqual(f.creates[1]);
  expect(f.creates[0].workspace_public_id).toBe("workspace");
  expect(f.panel.element.textContent).toContain("approval");
  expect(f.panel.element.querySelector(".terminal")).toBeNull();
  findButton(f.panel, "Stop terminal").click();
  await flush();
  expect(f.stops[0]).toMatchObject({ public_id: "run", host_type: "run", force: true });
  expect(f.stops[0].task_key).toBeUndefined();
});

test("a failed task shows its reason and does not leave an endless Connecting terminal", async () => {
  const f = fixture({ status: "failed" });
  await flush();
  f.panel.element.querySelector("select").value = "runner";
  findButton(f.panel, "New terminal").click();
  await flush();
  expect(f.panel.element.textContent).toContain("tool_not_served");
  expect(f.panel.element.querySelector(".terminal")).toBeNull();
  expect(findButton(f.panel, "Stop terminal").disabled).toBe(true);
});


test("switching Workspace replaces the panel reads without stopping the previous terminal", async () => {
  let factory;
  const calls = [];
  const shell = { async call(path) {
    calls.push(path);
    return path === "/runners" ? { runners: [] } : { terminals: [], has_more: false };
  } };
  register({ slots: { register(slot, _meta, component) { if (slot === "dock.tab") factory = component; } } }, shell);
  const panel = factory({ conversation: { workspace: "first" } });
  panels.push(panel);
  await flush();
  panel.update({ conversation: { workspace: "second" } });
  await flush();
  expect(calls).toContain("/terminals?workspace_public_id=first");
  expect(calls).toContain("/terminals?workspace_public_id=second");
  expect(calls).not.toContain("/stop");
});
