import { test, expect } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { createTranslator, pluginText, statusText, t } from "../webui/kernel/i18n.js";
import shell from "../webui/locales/en/shell.js";
import conversation from "../webui/locales/en/conversation.js";
import settings from "../webui/locales/en/settings.js";
import nexus from "../webui/locales/en/nexus.js";
import english from "../webui/locales/en.js";

const WEBUI = join(import.meta.dir, "../webui");
// Keys looked up with a computed suffix: their prefix is the contract.
const DYNAMIC_PREFIXES = ["status.", "roles.", "plugins.", "kernel_tools.", "nexus.workload_", "nexus.protocol_", "nexus.rate_", "nexus.limit_", "nexus.capability_", "nexus.fact_", "nexus.media_",
  "deployment.check_", "deployment.status_", "deployment.phase_"];

function files(directory) {
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    return statSync(path).isDirectory() ? files(path) : path.endsWith(".js") ? [path] : [];
  });
}

test("catalog translations own product branding and interpolate runtime values without interpreting them", () => {
  const translated = createTranslator({ "brand.rho": "Assistant", "brand.nexus": "Platform",
    "setup.connect_rho_to_nexus": "{value1} connects {rho} to {nexus}." });
  expect(translated("login.sign_in_with_your_nexus_account_to_use")).toContain("to use Assistant.");
  expect(translated("login.allow_session_storage_in_this_browser_to_sign")).toContain("sign in to Assistant.");
  expect(translated("errors.provider_context_overflow")).toContain("Platform Settings > Model providers");
  expect(translated("setup.connect_rho_to_nexus", { value1: "<script>{rho}</script>" }))
    .toBe("<script>{rho}</script> connects Assistant to Platform.");
  expect(t("brand.rho")).toBe("rho");
  expect(t("common.close")).toBe("Close");
});

test("plugin-owned metadata remains a literal fallback and supports locale overrides by plugin id", () => {
  const plugin = { id: "personal.notes", name: "Notes", description: "Read {topic} notes <safely>." };
  expect(pluginText(plugin, "description")).toBe(plugin.description);
  expect(pluginText(plugin, "name")).toBe("Notes");
  const translated = createTranslator({ "plugins.personal.notes.description": "Manage personal notes." });
  expect(translated("plugins.personal.notes.description", {}, plugin.description)).toBe("Manage personal notes.");
  expect(statusText("timed_out")).toBe("timed out");
  expect(statusText("future_status")).toBe("future_status");
});

test("missing application copy or interpolation fails visibly instead of printing a translation key", () => {
  expect(() => t("missing.copy")).toThrow("Missing translation");
  expect(() => t("common.unavailable_item")).toThrow("Missing interpolation");
  expect(t("common.unavailable_item", { name: "model-a" })).toBe("model-a · unavailable");
});

test("the catalog parts define every key once", () => {
  const seen = new Map();
  for (const [part, catalog] of Object.entries({ shell, conversation, settings, nexus })) {
    for (const key of Object.keys(catalog)) {
      expect(seen.has(key) ? `${key} defined in ${seen.get(key)} and ${part}` : "").toBe("");
      seen.set(key, part);
    }
  }
  expect(Object.keys(english)).toHaveLength(seen.size);
});

test("every literal key the page looks up exists, and every catalog key is looked up somewhere", () => {
  const used = new Set();
  for (const path of files(WEBUI)) {
    if (path.includes("/locales/")) continue;
    for (const match of readFileSync(path, "utf8").matchAll(/\bt\(\s*["'`]([a-z0-9_.-]+)["'`]/g)) used.add(match[1]);
  }
  const missing = [...used].filter((key) => !Object.hasOwn(english, key) && !DYNAMIC_PREFIXES.some((prefix) => key.startsWith(prefix)));
  expect(missing).toEqual([]);
  const unused = Object.keys(english).filter((key) => !used.has(key) && !DYNAMIC_PREFIXES.some((prefix) => key.startsWith(prefix)) && !key.startsWith("brand."));
  expect(unused).toEqual([]);
});
