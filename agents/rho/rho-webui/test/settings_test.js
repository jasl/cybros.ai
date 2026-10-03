import { test, expect } from "bun:test";
import { automaticModel, runnerChoice, setupProgress, telegramConfiguration, settingsChanges, jsonSetting, verificationLink, webLink } from "../webui/settings_state.js";
import { editedSetting } from "../webui/settings_editor.js";
import { settingsSnapshot } from "../webui/settings.js";

const eligible = [{ ref: "local/model" }];
const connected = { connected: true, model: { default_model: null, ready: false, eligible: [] } };
const paired = { enabled: true, connection: "running", token: { present: true }, configuration: { owner_id: "12345" } };

test("a missing Telegram extension leaves model and agent settings usable without calling its route", async () => {
  const calls = [];
  const documents = {
    "/settings": { settings: { compose: "auto" }, extensions: [{ name: "rho.webui" }] },
    "/settings/status": { ...connected, model: { default_model: null, ready: false, eligible } },
    "/status": { connection: null },
  };
  const [configuration, status, telegram] = await settingsSnapshot(async (path) => {
    calls.push(path);
    if (!(path in documents)) throw new Error(`Unexpected route ${path}`);
    return documents[path];
  });
  expect(calls).not.toContain("/telegram");
  expect(calls).not.toContain("/runner");
  expect(configuration.settings.compose).toBe("auto");
  expect(automaticModel(status.model)).toBe("local/model");
  expect(telegram).toBeNull();
  expect(setupProgress(status, telegram).step).toBe("model");
  expect(setupProgress({ ...status, model: { ready: true } }, telegram).ready).toBe(true);
});

test("a loaded Telegram extension keeps real route failures visible", async () => {
  for (const failure of [Object.assign(new Error("missing route"), { status: 404 }),
    Object.assign(new Error("unauthorized"), { status: 401 }), new Error("connection failed")]) {
    const call = async (path) => {
      if (path === "/settings") return { extensions: [{ name: "rho.ingress_telegram" }] };
      if (path === "/telegram") throw failure;
      return {};
    };
    await expect(settingsSnapshot(call)).rejects.toBe(failure);
  }
  await expect(settingsSnapshot(async () => ({}))).rejects.toThrow();
});

test("setup follows actual connection and Telegram state before missing models", () => {
  expect(setupProgress({ connected: false }, paired).step).toBe("connection");
  expect(setupProgress(connected, { ...paired, enabled: false }).title).toBe("Connect your Telegram bot");
  expect(setupProgress(connected, { ...paired, token: { present: false } }).step).toBe("telegram");
  expect(setupProgress(connected, { ...paired, configuration: { owner_id: null } }).title).toBe("Bind your Telegram account");
  expect(setupProgress(connected, { ...paired, connection: "error" }).title).toBe("Check your Telegram connection");
  expect(setupProgress(connected, paired)).toEqual({ step: "model", title: "To do: configure a model in Nexus", ready: false });
});

test("a Nexus settings link visit cannot mark setup ready without observed model readiness", () => {
  const awaitingChoice = { ...connected, model: { default_model: null, ready: false, eligible } };
  expect(setupProgress(awaitingChoice, paired).title).toBe("Choose your default model");
  expect(setupProgress({ ...awaitingChoice, model: { default_model: "local/model", eligible, ready: true } }, paired))
    .toEqual({ step: "ready", title: "rho is ready to use", ready: true });
  expect(setupProgress({ ...awaitingChoice, model: { default_model: "gone/model", eligible, ready: false } }, paired).ready).toBe(false);
});

test("only one eligible model and no saved choice permit automatic selection", () => {
  expect(automaticModel({ default_model: null, eligible })).toBe("local/model");
  expect(automaticModel({ default_model: "saved/model", eligible })).toBeNull();
  expect(automaticModel({ default_model: null, eligible: [...eligible, { ref: "other/model" }] })).toBeNull();
  expect(automaticModel({ default_model: null, eligible: [] })).toBeNull();
  expect(automaticModel(null)).toBeNull();
});

test("the resolved default runner fills a fresh conversation while manual choices survive refresh", () => {
  const own = { public_id: "own", own: true, selected: false };
  const remote = { public_id: "remote", own: false, selected: false };
  const runners = [remote, own];
  expect(runnerChoice(runners, { current: "", defaultRunner: "own", edited: false })).toBe(own);
  expect(runnerChoice(runners, { current: "own", defaultRunner: "remote", edited: false })).toBe(remote);
  expect(runnerChoice(runners, { current: "remote", defaultRunner: "own", edited: true })).toBe(remote);
  expect(runnerChoice(runners, { current: "", defaultRunner: null, edited: false })).toBeNull();
  expect(runnerChoice(runners, { current: "own", defaultRunner: "unavailable", edited: false })).toBeNull();
  expect(runnerChoice([remote, { ...own, selected: true }], { current: "", defaultRunner: null, edited: false })?.public_id).toBe("own");
});

test("Telegram can verify a token without any model or owner, and blank tokens do not replace saved credentials", () => {
  expect(telegramConfiguration({ token: " bot-token ", ownerId: "", enabled: true }))
    .toEqual({ token: "bot-token", owner_id: null, enabled: true });
  expect(telegramConfiguration({ token: "  ", ownerId: " 12345 ", enabled: true }))
    .toEqual({ owner_id: "12345", enabled: true });
  expect(telegramConfiguration({ token: "", ownerId: "12345", enabled: false }))
    .toEqual({ owner_id: "12345", enabled: false });
  expect(telegramConfiguration({ token: "", ownerId: "12345", enabled: false, clearToken: true }))
    .toEqual({ owner_id: "12345", enabled: false, token: null });
});

test("partial settings edits retain unrelated policy and distinguish clearing a value", () => {
  const saved = { fallback_model: "local/fallback", compose: "auto", compaction: { mode: "kernel" }, checkpoints: { enabled: true } };
  expect(settingsChanges(saved, { compose: "auto", fallback_model: null, compaction: { mode: "kernel" } }))
    .toEqual({ fallback_model: null });
  expect(settingsChanges(saved, { checkpoints: {} })).toEqual({ checkpoints: {} });
});

test("advanced settings reject non-object configuration and malformed positive timeouts", () => {
  expect(jsonSetting('{"example":{"command":"local-tool","env":{"KEY":"new-secret"}}}', "MCP"))
    .toEqual({ example: { command: "local-tool", env: { KEY: "new-secret" } } });
  for (const value of ["[]", "null", '"text"', "1", "{"]) expect(() => jsonSetting(value, "MCP")).toThrow("MCP");
  for (const value of ["0", "-2", "1.5", "no"]) expect(() => editedSetting("number", value, "Timeout")).toThrow("positive whole");
  expect(editedSetting("number", "90", "Timeout")).toBe(90);
  expect(editedSetting("lines", " rho/browser\n\n rho/custom ", "Extensions")).toEqual(["rho/browser", "rho/custom"]);
  expect(editedSetting("text", "   ", "Fallback")).toBeNull();
  expect(editedSetting("secret-text", " passphrase with spaces ", "Passphrase")).toBe(" passphrase with spaces ");
});

test("device approval replaces an internal origin while retaining the route and authorization code", () => {
  const link = verificationLink({ verification_uri: "http://nexus:3000/device/verify?source=rho", user_code: "ABCD EFGH" }, "https://nexus.example.test");
  const url = new URL(link);
  expect(url.origin).toBe("https://nexus.example.test");
  expect(url.pathname).toBe("/device/verify");
  expect(url.searchParams.get("source")).toBe("rho");
  expect(url.searchParams.get("user_code")).toBe("ABCD EFGH");
  expect(verificationLink({ verification_uri: "http://nexus/internal/oauth/device", user_code: "ABCD" },
    "https://public.test/nexus", "http://nexus/internal")).toBe("https://public.test/nexus/oauth/device?user_code=ABCD");
  expect(verificationLink({ verification_uri: "http://nexus/base/oauth/device", user_code: "ABCD" },
    "https://public.test/base", "http://nexus/base")).toBe("https://public.test/base/oauth/device?user_code=ABCD");
  expect(verificationLink({ verification_uri: "javascript:alert(1)" }, "https://nexus.example.test")).toBeNull();
  expect(webLink("data:text/html,hello")).toBeNull();
  expect(webLink("https://nexus.example.test/admin/model_providers")).toBe("https://nexus.example.test/admin/model_providers");
});
