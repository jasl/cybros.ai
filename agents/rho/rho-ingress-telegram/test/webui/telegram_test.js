import { test, expect, beforeEach, afterEach } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { installDocument, type, flush } from "../../../rho-webui/test/support/dom.js";
import { translator } from "../../../rho-webui/webui/kernel/i18n.js";
import english from "../../webui/locales/en.js";
import { setupPrompt } from "../../webui/setup.js";
import { mount, ID, BOT, telegram, field, button, shown } from "./support.js";

const WEBUI = fileURLToPath(new URL("../../webui/", import.meta.url));
const t = translator({ en: english });
let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());
const contributions = (slots) => Object.keys(slots.catalog).flatMap((name) => slots.entries(name).map((entry) => [name, entry.cell, entry.owner]));

test("Telegram contributes shared Connections and Bot target forms without a Main or sidebar identity", async () => {
  const page = mount(); await flush();
  expect(contributions(page.slots)).toEqual([["settings.section", "connections", ID], ["bots.item.config", "telegram", ID], ["plugins.item.config", ID, ID]]);
  page.handle.dispose();
  expect(contributions(page.slots)).toEqual([]);
  expect(page.container.childNodes).toHaveLength(0);
});

test("setup guidance distinguishes missing connection, target, owner, enablement and transport", async () => {
  const current = telegram();
  expect(setupPrompt(current, t)).toBeNull();
  expect(setupPrompt({ ...current, configuration: {} }, t)).toBe("Choose a shared Telegram connection.");
  expect(setupPrompt({ ...current, configuration: { ...current.configuration, target: null } }, t)).toBe("Set the private chat, group or topic this Bot answers.");
  expect(setupPrompt({ ...current, configuration: { ...current.configuration, owner_id: null } }, t)).toBe("Bind your Telegram account");
  expect(setupPrompt({ ...current, enabled: false }, t)).toContain("Enable this Bot");
  expect(setupPrompt({ ...current, connection: "retrying" }, t)).toBe("Check your Telegram connection");
  const page = mount({ routes: { "/telegram": () => telegram({ connection: "future_state", plugin_enabled: false }) } }); await flush();
  expect(shown(page.container)).toContain("Telegram: future state");
  expect(shown(page.container)).toContain("Enable the Telegram plugin in Plugins");
  page.outlet.dispose();
});

test("message options use workload catalogs, numeric delays, and the selected Bot", async () => {
  const page = mount({ routes: {
    "/telegram": () => telegram({ configuration: { ...telegram().configuration, transcription_model: "old/transcribe" } }),
    "/models?workload=transcription": () => ({ models: [{ ref: "fixture/transcribe", display_name: "Transcribe" }] }),
    "/models?workload=speech_generation": () => { throw new Error("No speech catalog"); },
  } }); await flush();
  const grouping = field(page.container, "input_debounce_seconds");
  expect(["min", "max", "step"].map((name) => grouping.getAttribute(name))).toEqual(["0", "10", "1"]);
  expect(grouping.value).toBe("2");
  expect(field(page.container, "transcription_model").options.map((row) => row.textContent)).toEqual(["Not set", "Transcribe · fixture/transcribe", "old/transcribe · unavailable"]);
  type(grouping, "10"); type(field(page.container, "stale_after"), "900"); type(field(page.container, "transcription_model"), "fixture/transcribe");
  grouping.form.requestSubmit(); await flush();
  expect(page.writes()[0].body).toEqual({ agent_public_id: BOT.public_id, stale_after: 900, input_debounce_seconds: 10,
    transcription_model: "fixture/transcribe", speech_model: "" });
  expect(page.toasts).toEqual([["Alpha: Telegram message settings saved.", "success"]]);
  page.outlet.dispose();
});

test("a failed status read leaves forms disabled and Refresh recovers without losing an edited options choice", async () => {
  let reads = 0;
  const page = mount({ routes: { "/telegram": () => { if (++reads === 1) throw new Error("Status unavailable"); return telegram(); } } }); await flush();
  expect(shown(page.container)).toContain("Status unavailable");
  expect(field(page.container, "owner_id").closest("fieldset").disabled).toBe(true);
  button(page.container, "Refresh").click(); await flush();
  expect(field(page.container, "owner_id").closest("fieldset").disabled).toBe(false);
  type(field(page.container, "input_debounce_seconds"), "9"); button(page.container, "Refresh").click(); await flush();
  expect(field(page.container, "input_debounce_seconds").value).toBe("9");
  page.outlet.dispose();
});

test("disposing a Bot form aborts pending reads and prevents later rendering", async () => {
  let resolve;
  const page = mount({ routes: { "/telegram": () => new Promise((done) => { resolve = done; }) } });
  const read = page.requests.find((row) => row.path.startsWith("/telegram?"));
  page.outlet.dispose(); expect(read.signal.aborted).toBe(true);
  resolve(telegram()); await flush(); expect(page.container.childNodes).toHaveLength(0);
});

const modules = readdirSync(WEBUI, { recursive: true }).filter((name) => name.endsWith(".js")).sort();
const source = (name) => readFileSync(join(WEBUI, name), "utf8");

test("every import in webui/ is relative and stays inside webui/", () => {
  expect(modules).toContain("index.js");
  for (const name of modules) {
    const specifiers = [...source(name).matchAll(/\bfrom\s*["']([^"']+)["']|\bimport\s*\(?\s*["']([^"']+)["']/g)]
      .map((match) => match[1] ?? match[2]);
    for (const specifier of specifiers) {
      expect(specifier, `${name} imports ${specifier}`).toMatch(/^\.\.?\//);
      const target = relative(WEBUI, resolve(dirname(join(WEBUI, name)), specifier));
      expect(target.startsWith(".."), `${name} imports ${specifier} from outside webui/`).toBe(false);
      expect(modules, `${name} imports a missing ${specifier}`).toContain(target);
    }
  }
});

test("every literal t() key exists in the catalog and every catalog key is used", () => {
  const code = modules.filter((name) => !name.startsWith("locales")).map(source).join("\n");
  const used = new Set([...code.matchAll(/\bt\(\s*"([^"]+)"/g)].map((match) => match[1]));
  expect(used.size).toBeGreaterThan(40);
  expect([...used].filter((key) => !Object.hasOwn(english, key))).toEqual([]);
  // Connection states are looked up by the document's value, with a readable fallback.
  const dynamic = ["connection."];
  expect(Object.keys(english).filter((key) => !used.has(key) && !dynamic.some((prefix) => key.startsWith(prefix)))).toEqual([]);
});
