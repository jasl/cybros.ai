import { test, expect } from "bun:test";
import { configurationEdits, pluginDraft, pluginSaveMessage } from "../webui/plugin_draft.js";
import { enabledDependents, pluginFieldValue } from "../webui/plugin_settings.js";

const schema = { type: "object", properties: {
  port: { type: "integer", minimum: 1, maximum: 65535, default: 3773 },
  enabled: { type: "boolean", default: true },
  note: { type: ["string", "null"] },
  token: { type: "string", writeOnly: true },
  servers: { type: "object", additionalProperties: { type: "object", properties: {
    command: { type: "string" }, args: { type: "array", items: { type: "string" } },
    env: { type: "object", writeOnly: true },
  } } },
} };
const view = (overrides = {}, extra = {}) => ({ id: "example", name: "Example", enabled: false, active: false,
  configuration: { schema, overrides, value: { port: 3773, enabled: true, ...overrides }, diagnostics: [],
    secrets: [{ path: ["token"], set: true }, { path: ["servers", "build.prod", "env"], set: true }] }, ...extra });

test("opening a disabled plugin is read-only and explicit default-valued overrides are preserved", () => {
  const draft = pluginDraft(view());
  expect(draft.dirty()).toBe(false);
  expect(draft.field(["port"])).toEqual({ value: 3773, overridden: false });
  expect(draft.overrides()).toEqual({});
  draft.set(["port"], 3773);
  expect(draft.operations()).toEqual([{ op: "set", path: ["port"], value: 3773 }]);
  draft.acknowledge(draft.operations(), view({ port: 3773 }));
  expect(draft.field(["port"])).toEqual({ value: 3773, overridden: true });
  draft.unset(["port"]);
  expect(draft.field(["port"])).toEqual({ value: 3773, overridden: false });
  expect(draft.operations()).toEqual([{ op: "unset", path: ["port"] }]);
});

test("form and JSON share sparse edits, preserve literal map names and keep unreturned secrets", () => {
  const draft = pluginDraft(view({ servers: { "build.prod": { command: "old", args: ["first"] }, other: { command: "keep" } } }));
  draft.set(["port"], 4373);
  const edited = draft.overrides(); edited.servers["build.prod"].command = "new";
  draft.editJSON(edited);
  expect(draft.operations()).toEqual([
    { op: "set", path: ["port"], value: 4373 },
    { op: "set", path: ["servers", "build.prod", "command"], value: "new" },
  ]);
  draft.set(["servers", "build.prod", "env"], { KEY: "replacement" });
  expect(draft.overrides().servers["build.prod"]).toEqual({ command: "new", args: ["first"] });
  expect(draft.field(["servers"]).value["build.prod"].env).toBeUndefined();
  const remove = draft.overrides(); delete remove.servers["build.prod"];
  draft.editJSON(remove);
  expect(draft.operations()).toEqual([
    { op: "set", path: ["port"], value: 4373 },
    { op: "unset", path: ["servers", "build.prod"] },
  ]);
});

test("secret keep, replace and clear never write a redacted placeholder", () => {
  const draft = pluginDraft(view());
  draft.set(["token"], "new-secret");
  expect(draft.overrides()).toEqual({});
  draft.keep(["token"]);
  expect(draft.operations()).toEqual([]);
  draft.unset(["token"]);
  expect(draft.operations()).toEqual([{ op: "unset", path: ["token"] }]);
  draft.clearSecrets();
  expect(draft.dirty()).toBe(false);
  expect(() => draft.editJSON({ token: "not-allowed-here" })).toThrow("separate secret controls");
});

test("JSON removes only visible overrides, while arrays replace as a complete field", () => {
  expect(configurationEdits({ port: 10, servers: { local: { args: ["one", "two"] } } },
    { servers: { local: { args: [] } }, enabled: false, note: null }, schema)).toEqual([
    { op: "unset", path: ["port"] },
    { op: "set", path: ["servers", "local", "args"], value: [] },
    { op: "set", path: ["enabled"], value: false },
    { op: "set", path: ["note"], value: null },
  ]);
  const secretList = { type: "array", items: { type: "object", properties: { token: { type: "string", writeOnly: true } } } };
  expect(() => configurationEdits([], [{}], secretList, ["accounts"])).toThrow("contains secrets");
});

test("status refresh and failed writes preserve drafts, a confirmed save clears only its submitted edits", () => {
  const draft = pluginDraft(view({ port: 10 }));
  draft.set(["port"], 20);
  const submitted = draft.operations();
  draft.update(view({ port: 30 }, { active: true }));
  expect(draft.field(["port"]).value).toBe(20);
  expect(draft.dirty()).toBe(true);
  draft.set(["port"], 20);
  draft.set(["enabled"], false);
  draft.acknowledge(submitted, view({ port: 20 }));
  expect(draft.operations()).toEqual([
    { op: "set", path: ["port"], value: 20 },
    { op: "set", path: ["enabled"], value: false },
  ]);
  draft.acknowledge(draft.operations(), view({ port: 20, enabled: false }));
  expect(draft.dirty()).toBe(false);
});

test("a new descendant edit survives acknowledgement of its parent and newer parent resets remove old child drafts", () => {
  const draft = pluginDraft(view());
  draft.set(["servers", "local"], { command: "old" });
  const submitted = draft.operations();
  draft.set(["servers", "local", "command"], "new");
  draft.acknowledge(submitted, view({ servers: { local: { command: "old" } } }));
  expect(draft.overrides().servers.local.command).toBe("new");
  draft.unset(["servers"]);
  expect(draft.operations()).toEqual([{ op: "unset", path: ["servers"] }]);
});

test("save feedback distinguishes validation, saved-but-unapplied, restart and uncertain durability", () => {
  expect(pluginSaveMessage({ saved: false })).toContain("not saved");
  expect(pluginSaveMessage({ saved: true, applied: false })).toContain("Saved, but not applied");
  expect(pluginSaveMessage({ saved: true, applied: false, restart_required: true })).toContain("Restart rho");
  expect(pluginSaveMessage({ code: "settings_durability_uncertain", saved: true, published: true, applied: false })).toContain("Do not retry");
  expect(pluginSaveMessage({ saved: true, applied: true })).toBe("Saved and applied.");
});

test("schema controls retain false, zero, empty values and nullable values", () => {
  expect(pluginFieldValue({ type: "boolean" }, "false")).toBe(false);
  expect(pluginFieldValue({ type: "integer", minimum: 0 }, "0")).toBe(0);
  expect(pluginFieldValue({ type: "string" }, "")).toBe("");
  expect(pluginFieldValue({ type: ["string", "null"], writeOnly: true }, "bot:token")).toBe("bot:token");
  expect(pluginFieldValue({ type: ["string", "null"] }, "null")).toBeNull();
  expect(pluginFieldValue({ type: ["string", "null"] }, '""')).toBe("");
  expect(() => pluginFieldValue(schema.properties.port, "70000")).toThrow("65535");
  expect(() => pluginFieldValue(schema.properties.port, "1.5")).toThrow("whole number");
});

test("disable choices contain enabled direct and transitive dependents without unrelated plugins or cycles", () => {
  const inventory = [
    { id: "base", enabled: true, requires: ["second"] },
    { id: "second", enabled: true, requires: ["first"] },
    { id: "first", enabled: true, requires: ["base"] },
    { id: "disabled", enabled: false, requires: ["base"] },
    { id: "unrelated", enabled: true, requires: [] },
  ];
  expect(enabledDependents(inventory, "base").map((plugin) => plugin.id)).toEqual(["second", "first"]);
  expect(enabledDependents(inventory, "unrelated")).toEqual([]);
});
