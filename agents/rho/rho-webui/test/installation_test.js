import { test, expect } from "bun:test";
import { installationStage, installationSnapshot, saveInstallationPassword } from "../webui/installation.js";

const installation = { enabled: true, password_required: false, nexus_ready: false, setup_url: "https://nexus.example/setup#secret=private", error: null };
const paired = {
  authority: { signed: "signed_in", planes: { member: "live", executor_transport: "live", runner_transport: "live" } },
  identity: { executor_public_id: "agent-address", runner_executor_public_id: "runner-address" },
};

test("only the bundled installation asks for a password before account setup", () => {
  expect(installationStage({ enabled: false }, null)).toBe("ready");
  expect(installationStage({ ...installation, password_required: true }, paired)).toBe("password");
  expect(installationStage(installation, null)).toBe("account");
  expect(installationStage({ ...installation, nexus_ready: null }, null)).toBe("waiting");
  expect(installationStage({ ...installation, nexus_ready: true, setup_url: null }, null)).toBe("pairing");
});

test("an existing paired installation bypasses stale helper status but partial authority waits", () => {
  expect(installationStage({ ...installation, nexus_ready: null, error: "Helper unavailable" }, paired)).toBe("ready");
  for (const plane of ["member", "executor_transport", "runner_transport"]) {
    const partial = { ...paired, authority: { ...paired.authority, planes: { ...paired.authority.planes, [plane]: "unknown" } } };
    expect(installationStage({ ...installation, nexus_ready: true }, partial)).toBe("pairing");
  }
  for (const address of ["executor_public_id", "runner_executor_public_id"]) {
    expect(installationStage({ ...installation, nexus_ready: true }, { ...paired, identity: { ...paired.identity, [address]: null } })).toBe("pairing");
  }
  expect(installationStage({ ...installation, error: "Helper unavailable" }, null)).toBe("error");
});

test("installation polling reads authority only after password setup and never initiates a pairing", async () => {
  const paths = [];
  let document = { ...installation, password_required: true };
  const call = async (path) => {
    paths.push(path);
    if (path === "/installation") return document;
    if (path === "/status") return paired;
    throw new Error(`Unexpected request ${path}`);
  };
  expect(await installationSnapshot(call)).toEqual([document, null]);
  expect(paths).toEqual(["/installation"]);
  document = { ...installation, nexus_ready: true };
  expect(await installationSnapshot(call)).toEqual([document, paired]);
  expect(paths).toEqual(["/installation", "/installation", "/status"]);
});

test("setting a password preserves spaces and uses the shared settings owner without retrying failure", async () => {
  const calls = [];
  const secret = " a new passphrase ";
  const call = async (...args) => { calls.push(args); return { configured: { access_passphrase: true } }; };
  await expect(saveInstallationPassword(call, secret, "different")).rejects.toThrow("match");
  await expect(saveInstallationPassword(call, "short", "short")).rejects.toThrow("8 characters");
  expect(calls).toHaveLength(0);
  await saveInstallationPassword(call, secret, secret);
  expect(calls).toEqual([["/settings", { method: "PATCH", body: { access_passphrase: secret }, signal: undefined }]]);
  let attempts = 0;
  await expect(saveInstallationPassword(async () => { attempts++; throw new Error("Save failed"); }, secret, secret)).rejects.toThrow("Save failed");
  expect(attempts).toBe(1);
});

test("installation failures propagate to the view instead of treating unknown state as completed", async () => {
  await expect(installationSnapshot(async () => { throw new Error("offline"); })).rejects.toThrow("offline");
  await expect(installationSnapshot(async (path) => {
    if (path === "/installation") return installation;
    throw Object.assign(new Error("Session expired"), { status: 401 });
  })).rejects.toMatchObject({ status: 401 });
});
