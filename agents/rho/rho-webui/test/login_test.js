import { test, expect } from "bun:test";
import { loginSession } from "../webui/login.js";

function harness(respond = () => ({})) {
  const saved = new Map();
  const storage = { getItem: (key) => saved.get(key) || null, setItem: (key, value) => saved.set(key, value), removeItem: (key) => saved.delete(key) };
  const requests = [];
  const events = [];
  let url = "http://10.0.0.115:7777/?conversation=existing";
  let bearer = null;
  const options = {
    storage, credentials: { set: (value) => { bearer = value; } }, currentUrl: () => url,
    navigate: (address) => { events.push(["navigate", address]); },
    replace: (path) => { url = new URL(path, url).href; events.push(["replace", path]); },
    call: async (path, options) => { requests.push([path, options]); events.push(["request", path]); return respond(path, options); },
  };
  return { session: loginSession(options), requests, events, saved, storage,
    reload: () => loginSession(options), callback: (query) => { url = `http://10.0.0.115:7777/auth/callback?${query}`; },
    url: () => url, bearer: () => bearer };
}

const codeStart = { authorization_url: "http://10.0.0.115:3300/oauth/authorize?state=one", state: "one", login_secret: "tab-secret" };
const deviceStart = { phase: "pending", state: "device", login_secret: "device-secret", user_code: "ABCD-EFGH",
  verification_uri_complete: "http://10.0.0.115:3300/oauth/device?user_code=ABCD-EFGH", interval: 5 };

test("Code login keeps its transaction in the initiating tab and restores its destination after callback", async () => {
  const browser = harness((path) => path === "/auth/start" ? codeStart : { phase: "active", bearer: "browser-only" });
  await browser.session.start("authorization_code");
  expect(browser.session.pending()).toEqual({ ...codeStart, flow: "authorization_code", return_to: "/?conversation=existing" });
  expect(browser.events.at(-1)).toEqual(["navigate", codeStart.authorization_url]);
  browser.callback("code=single-use&state=one");
  await browser.reload().complete();
  expect(browser.requests.at(-1)).toEqual(["/auth/complete", { method: "POST", signal: undefined,
    body: { code: "single-use", state: "one", login_secret: "tab-secret" } }]);
  expect(browser.events.slice(-2)).toEqual([["replace", "/?conversation=existing"], ["request", "/auth/complete"]]);
  expect(browser.url()).not.toContain("single-use");
  expect(browser.bearer()).toBe("browser-only");
  expect(browser.saved.size).toBe(0);
});

test("a callback from another tab or another login cannot exchange a code", async () => {
  for (const state of [null, "different"]) {
    const browser = harness(() => codeStart);
    if (state) await browser.session.start("authorization_code");
    browser.callback(`code=unrelated&state=${state || "one"}`);
    await expect(browser.session.complete()).rejects.toThrow("does not match");
    expect(browser.requests.filter(([path]) => path === "/auth/complete")).toHaveLength(0);
    expect(browser.url()).not.toContain("unrelated");
    expect(browser.bearer()).toBeNull();
  }
});

test("denial and ambiguous code exchange consume local state without retrying on reload", async () => {
  const denied = harness(() => codeStart);
  await denied.session.start("authorization_code");
  denied.callback("error=access_denied&state=one");
  await expect(denied.session.complete()).rejects.toThrow("not approved");
  expect(denied.requests).toHaveLength(1);
  const uncertain = harness((path) => {
    if (path === "/auth/start") return codeStart;
    throw new Error("Connection interrupted");
  });
  await uncertain.session.start("authorization_code");
  uncertain.callback("code=spent&state=one");
  await expect(uncertain.session.complete()).rejects.toThrow("interrupted");
  uncertain.callback("code=spent&state=one");
  await expect(uncertain.reload().complete()).rejects.toThrow("does not match");
  expect(uncertain.requests.filter(([path]) => path === "/auth/complete")).toHaveLength(1);
});

test("device login resumes in the same tab and accepts only the completed browser credential", async () => {
  let polls = 0;
  const browser = harness((path) => path === "/auth/device/start" ? deviceStart
    : ++polls === 1 ? { phase: "pending", interval: 10 } : { phase: "active", bearer: "device-browser" });
  await browser.session.start("device_code");
  expect(browser.events.some(([name]) => name === "navigate")).toBe(false);
  const resumed = browser.reload();
  expect(await resumed.poll()).toEqual({ phase: "pending", interval: 10 });
  expect(browser.bearer()).toBeNull();
  await resumed.poll();
  expect(browser.bearer()).toBe("device-browser");
  expect(resumed.pending()).toBeNull();
  expect(browser.requests.at(-1)[1].body).toEqual({ state: "device", login_secret: "device-secret" });
});

test("uninitialized Nexus does not create or poll a device transaction before explicit continuation", async () => {
  let initialized = false;
  const error = Object.assign(new Error("Initialize Nexus first"), { code: "initialization_required",
    details: { initialization_uri: "http://10.0.0.115:3300/setup" } });
  const browser = harness(() => {
    if (!initialized) throw error;
    return deviceStart;
  });
  await expect(browser.session.start("device_code")).rejects.toBe(error);
  expect(browser.session.pending()).toBeNull();
  expect(browser.requests).toHaveLength(1);
  initialized = true;
  await browser.session.start("device_code");
  expect(browser.requests.map(([path]) => path)).toEqual(["/auth/device/start", "/auth/device/start"]);
  expect(browser.session.pending().user_code).toBe("ABCD-EFGH");
});

test("concurrent device polls share one request and a failed poll requires a new login", async () => {
  let reject;
  const browser = harness((path) => path === "/auth/device/start" ? deviceStart
    : new Promise((_resolve, refusal) => { reject = refusal; }));
  await browser.session.start("device_code");
  const first = browser.session.poll();
  const second = browser.session.poll();
  expect(first).toBe(second);
  reject(new Error("Login expired"));
  await expect(first).rejects.toThrow("expired");
  expect(browser.session.pending()).toBeNull();
  expect(browser.requests.filter(([path]) => path === "/auth/device/poll")).toHaveLength(1);
});

test("a replaced device login cannot overwrite or erase the new login when its poll returns late", async () => {
  for (const succeeded of [true, false]) {
    let settle;
    const browser = harness((path) => {
      if (path === "/auth/device/start") return deviceStart;
      if (path === "/auth/start") return codeStart;
      return new Promise((resolve, reject) => { settle = succeeded ? resolve : reject; });
    });
    await browser.session.start("device_code");
    const oldPoll = browser.session.poll();
    await browser.session.start("authorization_code");
    settle(succeeded ? { phase: "active", bearer: "old-browser" } : new Error("Old login expired"));
    expect(await oldPoll).toEqual({ phase: "superseded" });
    expect(browser.bearer()).toBeNull();
    expect(browser.session.pending().state).toBe(codeStart.state);
  }
});
