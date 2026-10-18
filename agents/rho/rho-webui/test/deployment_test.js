import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { deploymentSection } from "../webui/features/settings/deployment.js";
import { uuidv7 } from "../webui/kernel/uuid.js";

let restore;
let views;
let polls;
const originalTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;
beforeEach(() => {
  restore = installDocument(); views = []; polls = new Map();
  globalThis.setTimeout = (callback, delay, ...rest) => {
    if (delay !== 2000) return originalTimeout(callback, delay, ...rest);
    const id = Symbol("poll"); polls.set(id, callback); return id;
  };
  globalThis.clearTimeout = (id) => { if (!polls.delete(id) && typeof id !== "symbol") originalClearTimeout(id); };
});
afterEach(() => {
  for (const view of views) view.dispose(); restore();
  globalThis.setTimeout = originalTimeout; globalThis.clearTimeout = originalClearTimeout;
});

const candidate = { release: "2610111234", images: [{ name: "rho", version: "2610111234", reference: "rho@sha256:abc" }] };
const initial = { supported: true, installed: { release: "2610101234" }, candidate: null, preflight: null, active_operation: null, last_operation: null };
const checked = { ...initial, candidate, preflight: { ready: true, checks: [{ name: "Images", status: "passed", message: "Release is available." }] }, idempotency_key: "key-1" };
const active = { id: "operation-1", status: "running", phase: "preparing", target: candidate, error: null, recovery: null };
const button = (root, label) => root.querySelectorAll("button").find((node) => node.textContent === label);

const denied = async () => { throw Object.assign(new Error("Administrator required"), { status: 403, code: "administrator_required" }); };
async function poll() { const work = [...polls.values()]; polls.clear(); work.forEach((run) => run()); await flush(); await flush(); }
function setup(handler = async () => initial, nexusHandler = denied, props = {}) {
  const calls = [];
  const nexusCalls = [];
  let signs = 0;
  const view = deploymentSection({ call: async (path, options = {}) => { calls.push([path, options]); return handler(path, options); },
    nexus: { request: async (path, options = {}) => { nexusCalls.push([path, options]); return nexusHandler(path, options); } }, signIn: () => signs++ }, props);
  views.push(view);
  document.body.append(view.element);
  return { view, calls, nexusCalls, element: view.element.querySelector('[data-upgrade-target="rho"]'),
    nexus: view.element.querySelector('[data-upgrade-target="nexus"]'), signs: () => signs };
}

test("unmanaged installations show their actual update procedure", async () => {
  for (const [mode, text] of [["checkout", "git pull"], ["installed", "rho update"], ["container", "deployment tools"]]) {
    const page = setup(async () => ({ supported: false, mode }));
    await flush();
    expect(page.element.textContent).toContain(text);
    expect(button(page.element, "Check for updates").hidden).toBe(true);
    expect(button(page.element, "Upgrade rho").hidden).toBe(true);
  }
});

test("upgrade requires a fresh successful check and confirmation of the rho restart", async () => {
  const page = setup(async (path) => path.endsWith("/check") ? checked : path.endsWith("/upgrade") ? active : path.includes("/log?") ? { entries: [], next_cursor: null } : initial);
  await flush();
  expect(button(page.element, "Upgrade rho").disabled).toBe(true);
  button(page.element, "Check for updates").click(); await flush();
  expect(page.element.textContent).toContain("Release is available.");
  expect(button(page.element, "Upgrade rho").disabled).toBe(false);
  button(page.element, "Upgrade rho").click();
  const dialog = document.querySelector("dialog");
  expect(dialog.textContent).toContain("Nexus and its database stay unchanged");
  expect(page.calls.filter(([path]) => path.endsWith("/upgrade"))).toHaveLength(0);
  button(dialog, "Upgrade rho").click(); await flush();
  expect(page.calls.find(([path]) => path.endsWith("/upgrade"))[1].body).toEqual({ candidate: { release: candidate.release, images: candidate.images }, idempotency_key: "key-1" });
});

test("blocked preflight and edited release choices cannot start an upgrade", async () => {
  let blocked = true;
  const page = setup(async (path) => path.endsWith("/check") ? { ...checked, preflight: { ready: !blocked, checks: [{ name: "Disk", status: "blocked", message: "Make room.", next_step: "Free disk space." }] } } : initial);
  await flush(); button(page.element, "Check for updates").click(); await flush();
  expect(button(page.element, "Upgrade rho").disabled).toBe(true);
  expect(page.element.textContent).toContain("Free disk space.");
  blocked = false; button(page.element, "Check for updates").click(); await flush();
  expect(button(page.element, "Upgrade rho").disabled).toBe(false);
  const release = page.element.querySelector("input"); release.value = "2610111300"; release.dispatchEvent(new Event("input"));
  expect(button(page.element, "Upgrade rho").disabled).toBe(true);
});

test("an ambiguous upgrade can only retry its original checked key and selection", async () => {
  const page = setup(async (path) => {
    if (path.endsWith("/check")) return checked;
    if (path.endsWith("/upgrade")) throw Object.assign(new Error("unavailable"), { status: 0 });
    return initial;
  });
  await flush(); button(page.element, "Check for updates").click(); await flush();
  button(page.element, "Upgrade rho").click(); button(document.querySelector("dialog"), "Upgrade rho").click(); await flush();
  expect(page.element.textContent).toContain("The request may have been accepted");
  expect(button(page.element, "Check for updates").disabled).toBe(true);
  button(page.element, "Retry upgrade request").click(); await flush();
  const submissions = page.calls.filter(([path]) => path.endsWith("/upgrade"));
  expect(submissions).toHaveLength(2);
  expect(submissions[0][1].body).toEqual(submissions[1][1].body);
});

test("a restored failed receipt names host recovery and never offers Resume", async () => {
  const failed = { ...active, status: "interrupted", phase: "activating", recovery: "Inspect ./cybros upgrade-status and recover on the host." };
  const page = setup(async (path) => path.includes("/log?") ? { entries: [{ text: "Restarting rho.\n" }], next_cursor: "cursor" } : { ...initial, last_operation: failed });
  await flush(); await flush();
  expect(page.element.textContent).toContain("Interrupted");
  expect(page.element.textContent).toContain("./cybros upgrade-status");
  expect(page.element.textContent).toContain("Restarting rho.");
  expect(button(page.element, "Resume")).toBeUndefined();
});

test("progress reconnects after a restart without resubmitting and stops when hidden or disposed", async () => {
  let unavailable = false;
  let receipt = active;
  const page = setup(async (path) => {
    if (unavailable) throw Object.assign(new Error("offline"), { status: 0 });
    if (path.includes("/log?")) return { entries: [{ text: "step\n" }], next_cursor: "next", operation: receipt };
    return { ...initial, active_operation: receipt.status === "running" ? receipt : null, last_operation: receipt };
  });
  await flush(); await flush();
  expect(page.element.textContent).toContain("In progress");
  unavailable = true; await poll();
  expect(page.element.textContent).toContain("Waiting for rho to return");
  page.view.update({ visible: false });
  expect(polls.size).toBe(0);
  unavailable = false; receipt = { ...active, status: "succeeded", phase: "completed" };
  page.view.update({ visible: true }); await flush(); await flush();
  expect(page.element.textContent).toContain("Succeeded");
  expect(page.element.querySelector(".upgrade-progress").textContent).not.toContain("null");
  expect(polls.size).toBe(0);
  expect(page.calls.filter(([, options]) => options.method === "POST")).toHaveLength(0);
  page.view.dispose(); expect(polls.size).toBe(0);
});

test("pending requests survive remount and recover by receipt key without a second POST", async () => {
  const first = setup(async (path) => {
    if (path.endsWith("/check")) return checked;
    if (path.endsWith("/upgrade")) throw Object.assign(new Error("offline"), { status: 0 });
    return initial;
  });
  await flush(); button(first.element, "Check for updates").click(); await flush();
  button(first.element, "Upgrade rho").click(); button(document.querySelector("dialog"), "Upgrade rho").click(); await flush();
  expect(sessionStorage.getItem("rho.deployment.pending.rho")).toContain("key-1");
  first.view.dispose(); first.view.element.remove();
  const next = setup(async (path) => path.includes("/log?") ? { entries: [], next_cursor: null } : { ...initial, active_operation: { ...active, idempotency_key: "key-1" } });
  await flush(); await flush();
  expect(sessionStorage.getItem("rho.deployment.pending.rho")).toBeNull();
  expect(next.calls.filter(([, options]) => options.method === "POST")).toHaveLength(0);
  expect(button(next.element, "Retry upgrade request").hidden).toBe(true);
});

test("an ambiguous request retains its retry when account details arrive after the section mounts", async () => {
  const handler = async (path) => {
    if (path.endsWith("/check")) return checked;
    if (path.endsWith("/upgrade")) throw Object.assign(new Error("offline"), { status: 0 });
    return initial;
  };
  const first = setup(handler);
  await flush(); button(first.element, "Check for updates").click(); await flush();
  button(first.element, "Upgrade rho").click(); button(document.querySelector("dialog"), "Upgrade rho").click(); await flush();
  const identity = { human: { public_id: "human-1" } };
  first.view.update({ identity });
  first.view.dispose(); first.view.element.remove();
  const next = setup(handler, denied, { identity });
  await flush();
  expect(button(next.element, "Retry upgrade request").hidden).toBe(false);
  expect(button(next.element, "Check for updates").disabled).toBe(true);
  button(next.element, "Retry upgrade request").click(); await flush();
  const original = first.calls.find(([path]) => path.endsWith("/upgrade"))[1].body;
  expect(next.calls.find(([path]) => path.endsWith("/upgrade"))[1].body).toEqual(original);
});

test("Nexus administration handles member, sign-in and unsupported states independently from rho", async () => {
  const member = setup(); await flush();
  expect(member.nexus.textContent).toContain("A Nexus owner or administrator manages Nexus upgrades");
  expect(button(member.nexus, "Check for updates").hidden).toBe(true);
  const signedOut = setup(undefined, async () => { throw Object.assign(new Error("Sign in"), { status: 403, code: "human_login_required" }); });
  await flush(); button(signedOut.nexus, "Sign in with Nexus").click();
  expect(signedOut.signs()).toBe(1);
  const unmanaged = setup(undefined, async () => ({ deployment: { supported: false } })); await flush();
  expect(unmanaged.nexus.textContent).toContain("This Nexus has no installation updater configured");
  expect(button(unmanaged.nexus, "Upgrade Nexus").hidden).toBe(true);
});

test("Nexus check and upgrade use the Human proxy, freeze backup choice and send UUIDv7 idempotency", async () => {
  const nexusCandidate = { ...candidate, images: [{ name: "nexus", reference: "nexus@sha256:abc" }] };
  const page = setup(undefined, async (path, options) => {
    if (path.endsWith("/release_check")) return { deployment: { ...checked, candidate: nexusCandidate, idempotency_key: undefined, preflight: { ...checked.preflight, backup: options.body.release_check.backup } } };
    if (path.endsWith("/upgrades")) return { upgrade: { ...active, target: nexusCandidate, backup: options.body.backup } };
    return { deployment: initial };
  });
  await flush();
  const backup = page.nexus.querySelector('input[type="checkbox"]');
  expect(backup.checked).toBe(true);
  button(page.nexus, "Check for updates").click(); await flush();
  expect(page.nexusCalls.at(-1)[1].body).toEqual({ release_check: { tag: "latest", backup: true } });
  expect(page.nexusCalls.at(-1)[1].timeout).toBe(120);
  backup.click(); expect(button(page.nexus, "Upgrade Nexus").disabled).toBe(true);
  button(page.nexus, "Check for updates").click(); await flush();
  button(page.nexus, "Upgrade Nexus").click(); button(document.querySelector("dialog"), "Upgrade Nexus").click(); await flush();
  const [path, options] = page.nexusCalls.find(([path]) => path.endsWith("/upgrades"));
  expect(path).toBe("/api/v1/admin/deployment/upgrades");
  expect(options.body).toEqual({ candidate: nexusCandidate, backup: false });
  expect(options.headers["Idempotency-Key"]).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  expect(page.calls.some(([path]) => path.endsWith("/upgrade"))).toBe(false);
});

test("Nexus progress keeps its proxy route and opaque cursor across an outage", async () => {
  let unavailable = false;
  let complete = false;
  const page = setup(undefined, async (path) => {
    if (unavailable) throw Object.assign(new Error("Nexus unavailable"), { status: 503 });
    const operation = { ...active, status: complete ? "succeeded" : "running", phase: complete ? "completed" : "migrating" };
    if (path.includes("/log?")) return { log: { entries: [{ text: complete ? "Healthy.\n" : "Migrating.\n" }], next_cursor: "opaque+cursor=", operation } };
    return { deployment: { ...initial, active_operation: complete ? null : operation, last_operation: operation } };
  });
  await flush(); await flush();
  expect(page.nexus.textContent).toContain("Migrating the database");
  unavailable = true; await poll();
  expect(page.nexus.textContent).toContain("Waiting for Nexus to return");
  unavailable = false; complete = true; await poll();
  expect(page.nexus.textContent).toContain("Succeeded");
  expect(page.nexus.querySelector(".upgrade-progress").textContent).not.toContain("null");
  expect(page.nexus.textContent).toContain("Healthy.");
  expect(page.nexusCalls.at(-1)[0]).toBe("/api/v1/admin/deployment/upgrades/operation-1/log?cursor=opaque%2Bcursor%3D");
  expect(page.nexusCalls.filter(([, options]) => options.method === "POST")).toHaveLength(0);
  expect(polls.size).toBe(0);
});

test("UUIDv7 preserves current milliseconds and works on LAN HTTP without randomUUID", () => {
  const original = globalThis.crypto;
  globalThis.crypto = { getRandomValues: original.getRandomValues.bind(original) };
  try {
    const before = Date.now(); const first = uuidv7(); const after = Date.now();
    const milliseconds = parseInt(first.slice(0, 13).replaceAll("-", ""), 16);
    expect(milliseconds).toBeGreaterThanOrEqual(before); expect(milliseconds).toBeLessThanOrEqual(after);
    expect(uuidv7()).not.toBe(first);
  } finally { globalThis.crypto = original; }
});
