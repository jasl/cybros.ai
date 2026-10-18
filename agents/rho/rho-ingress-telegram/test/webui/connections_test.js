import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, type, flush } from "../../../rho-webui/test/support/dom.js";
import { connectionPatch } from "../../webui/connections.js";
import { mount, CONNECTION, field, button, deferred, shown } from "./support.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

test("connection credentials have one owner and omit, replace or clear tokens deliberately", async () => {
  expect(connectionPatch({ name: " Shared ", enabled: true, token: " ", clearToken: false })).toEqual({ name: "Shared", enabled: true });
  expect(connectionPatch({ name: "Shared", enabled: true, token: " 123:fixture ", clearToken: false })).toEqual({ name: "Shared", enabled: true, token: "123:fixture" });
  expect(connectionPatch({ name: "Shared", enabled: false, token: "ignored", clearToken: true })).toEqual({ name: "Shared", enabled: false, token: null });
  const page = mount({ connections: true }); await flush();
  expect(field(page.container, "token").value).toBe("");
  expect(shown(page.container)).toContain("A token is saved");
  expect(shown(page.container)).toContain("Telegram account @shared_bot");
  expect(field(page.container, "owner_id")).toBeNull();
  type(field(page.container, "connection_name"), "Renamed"); field(page.container, "connection_name").form.requestSubmit(); await flush();
  expect(page.writes()[0]).toMatchObject({ path: "/telegram/connection", body: { connection_public_id: CONNECTION.public_id, name: "Renamed", enabled: true } });
  field(page.container, "clear_token").click(); expect(field(page.container, "token").disabled).toBe(true);
  field(page.container, "clear_token").form.requestSubmit(); await flush();
  expect(page.writes().at(-1).body.token).toBeNull();
  expect(field(page.container, "clear_token").checked).toBe(false);
  page.outlet.dispose();
});

test("a new connection saves once without an existing id and the returned id owns later updates", async () => {
  let rows = [];
  const page = mount({ connections: true, routes: { "/telegram/connections": () => ({ connections: rows }), "/telegram/connection": ({ body }) => {
    const connection = { ...CONNECTION, name: body.name }; rows = [connection]; return { connection, saved: true };
  } } }); await flush();
  expect(shown(page.container)).toContain("No Telegram connections yet");
  button(page.container, "New connection").click();
  type(field(page.container, "connection_name"), "Shared account"); type(field(page.container, "token"), "123:fixture");
  field(page.container, "token").form.requestSubmit(); await flush();
  expect(page.writes()[0].body).toEqual({ name: "Shared account", enabled: true, token: "123:fixture" });
  expect(field(page.container, "connection_public_id").value).toBe(CONNECTION.public_id);
  expect(field(page.container, "token").value).toBe("");
  type(field(page.container, "connection_name"), "Later name"); field(page.container, "connection_name").form.requestSubmit(); await flush();
  expect(page.writes().at(-1).body.connection_public_id).toBe(CONNECTION.public_id);
  page.outlet.dispose();
});

test("switching or hiding connections clears unsaved secrets and preserves ordinary drafts", async () => {
  const other = { ...CONNECTION, public_id: "connection-b", name: "Other" };
  const page = mount({ connections: true, routes: { "/telegram/connections": () => ({ connections: [CONNECTION, other] }),
    "/telegram/connection": ({ query }) => ({ connection: query.get("connection_public_id") === other.public_id ? other : CONNECTION }) } }); await flush();
  type(field(page.container, "connection_name"), "My draft"); type(field(page.container, "token"), "secret-a");
  type(field(page.container, "connection_public_id"), other.public_id); await flush();
  expect(field(page.container, "connection_name").value).toBe("Other"); expect(field(page.container, "token").value).toBe("");
  type(field(page.container, "token"), "secret-b"); type(field(page.container, "connection_public_id"), CONNECTION.public_id); await flush();
  expect(field(page.container, "connection_name").value).toBe("My draft"); expect(field(page.container, "token").value).toBe("");
  type(field(page.container, "token"), "secret-c"); page.outlet.update({ ...page.props, visible: false });
  expect(field(page.container, "token").value).toBe("");
  page.outlet.update(page.props); await flush(); expect(field(page.container, "connection_name").value).toBe("My draft");
  type(field(page.container, "token"), "secret-d"); document.hidden = true; document.dispatchEvent(new Event("visibilitychange"));
  expect(field(page.container, "token").value).toBe("");
  page.outlet.dispose();
});

test("late saves stay with their originating connection while another draft remains unchanged", async () => {
  const pending = deferred(); const other = { ...CONNECTION, public_id: "connection-b", name: "Other" };
  const page = mount({ connections: true, routes: { "/telegram/connections": () => ({ connections: [CONNECTION, other] }),
    "/telegram/connection": ({ body, query }) => body ? pending.promise : { connection: query.get("connection_public_id") === other.public_id ? other : CONNECTION } } }); await flush();
  type(field(page.container, "connection_name"), "Saved first"); field(page.container, "connection_name").form.requestSubmit();
  type(field(page.container, "connection_public_id"), other.public_id); await flush(); type(field(page.container, "connection_name"), "Second draft");
  pending.resolve({ connection: { ...CONNECTION, name: "Saved first" } }); await flush();
  expect(field(page.container, "connection_name").value).toBe("Second draft");
  expect(page.writes()[0].body.connection_public_id).toBe(CONNECTION.public_id);
  page.outlet.dispose();
});

test("failed verification keeps a draft, and refreshing does not discard its ordinary fields", async () => {
  const page = mount({ connections: true, routes: { "/telegram/connection": ({ body }) => {
    if (body) throw new Error("Telegram refused the token"); return { connection: CONNECTION };
  } } }); await flush();
  type(field(page.container, "connection_name"), "My draft"); type(field(page.container, "token"), "bad-fixture");
  field(page.container, "token").form.requestSubmit(); await flush();
  expect(shown(page.container)).toContain("Telegram refused the token");
  expect(field(page.container, "connection_name").value).toBe("My draft");
  expect(field(page.container, "token").closest("fieldset").disabled).toBe(false);
  button(page.container, "Refresh").click(); await flush();
  expect(field(page.container, "connection_name").value).toBe("My draft");
  page.outlet.dispose();
});
