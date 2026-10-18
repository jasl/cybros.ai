import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush, type } from "./support/dom.js";
import { el } from "../webui/kernel/dom.js";
import { createLogin } from "../webui/shell/login.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const refusal = (status, code, message) => Object.assign(new Error(message), { status, code });

// The login page against a fake daemon: `access` and `paired` are what
// `/auth/status` says, `unlock` answers the gate.
function page({ access = { mode: "nexus", configured: null, password_set: false }, paired = true, unlock = async () => ({ phase: "active", bearer: "rho-browser-v1-x" }),
  start = null, device = null } = {}) {
  const requests = [];
  const bearers = [];
  let ready = 0;
  const call = async (path, options = {}) => {
    requests.push([options.method || "GET", path, options.body]);
    if (path === "/auth/status") return { nexus_url: "http://10.0.0.115:3300", flows: ["authorization_code", "device_code"], paired, access, authenticated: false };
    if (path === "/auth/unlock") return unlock(options.body);
    if (path === "/auth/start" && start) return start;
    if (path === "/auth/device/start" && device) return device;
    throw new Error(`unexpected ${path}`);
  };
  const root = el("div");
  document.body.append(root);
  const login = createLogin({ root, call, credentials: { set: (value) => bearers.push(value) }, onReady: async () => { ready += 1; } });
  const button = (label) => root.querySelectorAll("button").find((node) => node.textContent === label);
  const visible = (node) => !!node && !node.hidden && !node.closest("[hidden]");
  return { login, root, requests, bearers, ready: () => ready, button, visible, field: () => root.querySelector('input[name="unlock_password"]') };
}

test("an open gate on a paired rho admits the page by itself, without a sign-in screen", async () => {
  const p = page({ access: { mode: "open", configured: null, password_set: false } });
  await p.login.initialize();
  await flush();
  expect(p.requests.map(([method, path]) => `${method} ${path}`)).toEqual(["GET /auth/status", "POST /auth/unlock"]);
  expect(p.requests[1][2]).toEqual({});
  expect(p.bearers).toEqual(["rho-browser-v1-x"]);
  expect(p.ready()).toBe(1);
});

test("before pairing the Nexus buttons stand whatever the gate says, and nexus mode keeps them", async () => {
  const unpaired = page({ access: { mode: "open" }, paired: false });
  await unpaired.login.initialize();
  await flush();
  expect(unpaired.requests).toHaveLength(1);
  expect(unpaired.visible(unpaired.button("Connect to Nexus"))).toBe(true);
  expect(unpaired.visible(unpaired.button("Use a device code"))).toBe(true);
  expect(unpaired.visible(unpaired.field())).toBe(false);

  const nexus = page();
  await nexus.login.initialize();
  await flush();
  expect(nexus.requests).toHaveLength(1);
  expect(nexus.visible(nexus.button("Connect to Nexus"))).toBe(true);
  expect(nexus.root.querySelector("h1").textContent).toBe("Connect to Nexus");
});

test("Connect to Nexus leaves for Nexus with the buttons off; a device code shows its code and keeps them usable", async () => {
  const assigned = [];
  location.assign = (url) => assigned.push(url);
  const leaving = page({ paired: false, start: { authorization_url: "http://10.0.0.115:3300/oauth/authorize?state=one", state: "one", login_secret: "s" } });
  await leaving.login.initialize();
  await flush();
  leaving.button("Connect to Nexus").click();
  await flush();
  expect(assigned).toEqual(["http://10.0.0.115:3300/oauth/authorize?state=one"]);
  expect([leaving.button("Connect to Nexus").disabled, leaving.button("Use a device code").disabled]).toEqual([true, true]);
  expect(JSON.parse(sessionStorage.getItem(`rho.login.${location.origin}`))).toMatchObject({ flow: "authorization_code", state: "one" });

  const device = page({ paired: false, device: { phase: "pending", state: "d", login_secret: "s", user_code: "ABCD-EFGH",
    verification_uri_complete: "http://10.0.0.115:3300/oauth/device?user_code=ABCD-EFGH", interval: 5 } });
  await device.login.initialize();
  await flush();
  device.button("Use a device code").click();
  await flush();
  expect(device.root.querySelector(".login__code").textContent).toBe("ABCD-EFGH");
  expect([device.button("Connect to Nexus").disabled, device.button("Use a device code").disabled]).toEqual([false, false]);
  expect(assigned).toHaveLength(1);
  device.login.destroy();
});

test("a password gate asks for the password, says why a wrong one failed, and admits the right one", async () => {
  const attempts = [];
  const p = page({ access: { mode: "password", configured: "password", password_set: true }, unlock: async (body) => {
    attempts.push(body.password);
    if (body.password !== "correct horse") throw refusal(401, "unlock_refused", "That is not the unlock password");
    return { phase: "active", bearer: "rho-browser-v1-y" };
  } });
  await p.login.initialize();
  await flush();
  expect(p.root.querySelector("h1").textContent).toBe("Unlock rho");
  expect(p.visible(p.field())).toBe(true);
  expect(p.visible(p.button("Connect to Nexus"))).toBe(false);
  type(p.field(), "wrong one");
  p.field().form.requestSubmit();
  await flush();
  expect(attempts).toEqual(["wrong one"]);
  expect(p.root.querySelector('[role="alert"]:not([hidden])').textContent).toBe("That is not the unlock password");
  expect(p.field().value).toBe("");
  expect(p.ready()).toBe(0);
  type(p.field(), "correct horse");
  p.field().form.requestSubmit();
  await flush();
  expect(p.bearers).toEqual(["rho-browser-v1-y"]);
  expect(p.ready()).toBe(1);
});

test("Sign in with Nexus instead brings the Nexus buttons back under the password gate", async () => {
  const p = page({ access: { mode: "password", configured: "password", password_set: true } });
  await p.login.initialize();
  await flush();
  p.button("Sign in with Nexus instead").click();
  expect(p.visible(p.button("Connect to Nexus"))).toBe(true);
  expect(p.visible(p.field())).toBe(false);
  expect(p.root.querySelector("h1").textContent).toBe("Connect to Nexus");
});
