import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, type, flush } from "../../../rho-webui/test/support/dom.js";
import { mount, BOT, CONNECTION, telegram, field, button, deferred, shown } from "./support.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

test("Bot settings offer a shared connection and one target without a token, identity picker or Home editor", async () => {
  const page = mount(); await flush();
  expect(field(page.container, "connection_public_id").value).toBe(CONNECTION.public_id);
  expect(field(page.container, "chat_id").value).toBe("42");
  for (const name of ["token", "clear_token", "agent_public_id", "home_workspace_public_id"]) expect(field(page.container, name)).toBeNull();
  expect(field(page.container, "list")).toBeNull();
  expect(shown(page.container)).toContain("Only the bot owner can use this bot in a private Telegram chat.");
  expect(page.writes()).toEqual([]);
  page.outlet.dispose();
});

test("saving a fixed group topic addresses the Bot and never writes Connection credentials", async () => {
  const page = mount(); await flush();
  type(field(page.container, "chat_id"), "-10042"); type(field(page.container, "topic_id"), "7"); type(field(page.container, "owner_id"), " 55 ");
  field(page.container, "chat_id").form.requestSubmit(); await flush();
  expect(page.writes()).toHaveLength(1);
  expect(page.writes()[0]).toMatchObject({ path: "/telegram/configuration", method: "POST", body: {
    agent_public_id: BOT.public_id, enabled: true, connection_public_id: CONNECTION.public_id,
    target: { chat_id: "-10042", topic_id: 7 }, owner_id: "55",
  } });
  expect(page.toasts).toContainEqual(["Alpha: Telegram settings saved.", "success"]);
  expect(page.refreshes()).toBe(1);
  expect(page.inventoryRefreshes()).toBe(1);
  page.outlet.dispose();
});

test("target validation and a duplicate-target refusal retain the draft for correction", async () => {
  const page = mount({ routes: { "/telegram/configuration": () => { throw new Error("This destination already belongs to another Bot."); } } }); await flush();
  type(field(page.container, "topic_id"), "7"); field(page.container, "chat_id").form.requestSubmit(); await flush();
  expect(page.writes()).toEqual([]);
  expect(shown(page.container)).toContain("A topic needs a negative group chat ID");
  type(field(page.container, "chat_id"), "-10042"); field(page.container, "chat_id").form.requestSubmit(); await flush();
  expect(shown(page.container)).toContain("This destination already belongs to another Bot.");
  expect(field(page.container, "chat_id").value).toBe("-10042");
  expect(field(page.container, "topic_id").value).toBe("7");
  expect(field(page.container, "chat_id").closest("fieldset").disabled).toBe(false);
  page.outlet.dispose();
});

test("disabled Bot drafts can clear the connection and target explicitly", async () => {
  const page = mount(); await flush();
  field(page.container, "enabled").click(); type(field(page.container, "connection_public_id"), ""); type(field(page.container, "chat_id"), "");
  field(page.container, "enabled").form.requestSubmit(); await flush();
  expect(page.writes()[0].body).toEqual({ agent_public_id: BOT.public_id, enabled: false, connection_public_id: null, target: null, owner_id: "42" });
  page.outlet.dispose();
});

test("target and message drafts survive a status refresh and connection-list failure blocks only target saves", async () => {
  const page = mount(); await flush();
  type(field(page.container, "owner_id"), "77"); type(field(page.container, "input_debounce_seconds"), "8");
  const list = page.routes["/telegram/connections"];
  page.routes["/telegram/connections"] = () => { throw new Error("Connections unavailable"); };
  button(page.container, "Refresh").click(); await flush();
  expect(field(page.container, "owner_id").value).toBe("77");
  expect(field(page.container, "input_debounce_seconds").value).toBe("8");
  expect(field(page.container, "owner_id").closest("fieldset").disabled).toBe(true);
  expect(field(page.container, "input_debounce_seconds").closest("fieldset").disabled).toBe(false);
  field(page.container, "owner_id").form.requestSubmit(); await flush(); expect(page.writes()).toEqual([]);
  page.routes["/telegram/connections"] = list; button(page.container, "Refresh").click(); await flush();
  expect(field(page.container, "owner_id").closest("fieldset").disabled).toBe(false);
  expect(field(page.container, "owner_id").value).toBe("77");
  page.outlet.dispose();
});

test("late target saves and reads cannot update a newly opened Bot page", async () => {
  const saved = deferred();
  const first = mount({ routes: { "/telegram/configuration": () => saved.promise } }); await flush();
  type(field(first.container, "owner_id"), "77"); field(first.container, "owner_id").form.requestSubmit();
  first.outlet.dispose();
  const second = mount({ bot: { public_id: "bot-b", name: "beta", display_name: "Beta" }, routes: {
    "/telegram": () => telegram({ agent_public_id: "bot-b", configuration: { ...telegram().configuration, owner_id: "88" } }),
  } }); await flush();
  type(field(second.container, "owner_id"), "99"); saved.resolve({ saved: true }); await flush();
  expect(first.writes()[0].body.agent_public_id).toBe("bot-a");
  expect(first.writes()[0].signal.aborted).toBe(true);
  expect(first.toasts).toEqual([]);
  expect(field(second.container, "owner_id").value).toBe("99");
  second.outlet.dispose();
});

test("external access writes remain scoped to the Bot and personal Bots expose no Access form", async () => {
  let current = telegram({ owner_only: false, access: { allowed_users: [], allowed_chats: [], ignored_users: [] } });
  const page = mount({ routes: { "/telegram": () => current, "/telegram/access": ({ body }) => {
    current = { ...current, access: { ...current.access, [body.list]: [body.id] } }; return current;
  } } }); await flush();
  type(field(page.container, "id"), "66"); field(page.container, "id").form.requestSubmit(); await flush();
  expect(page.writes()[0]).toMatchObject({ path: "/telegram/access", body: { agent_public_id: BOT.public_id, list: "allowed_users", action: "add", id: "66" } });
  expect(shown(page.container)).toContain("66");
  expect(shown(page.container)).not.toContain("Only the bot owner can use this bot");
  page.outlet.dispose();
});
