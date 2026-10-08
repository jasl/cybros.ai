import { test, expect } from "bun:test";
import { createTranslator, pluginText, statusText, t } from "../webui/i18n.js";

test("catalog translations own product branding and interpolate runtime values without interpreting them", () => {
  const translated = createTranslator({ "brand.rho": "Assistant", "brand.nexus": "Platform",
    "settings.signed_in_to_nexus_as": "{value1} uses {nexus} as {role}." });
  expect(translated("composer.ask_rho_to_work_on_something")).toBe("Ask Assistant to work on something…");
  expect(translated("login.sign_in_with_your_nexus_account_to_use")).toContain("to use Assistant.");
  expect(translated("login.allow_session_storage_in_this_browser_to_sign")).toContain("sign in to Assistant.");
  expect(translated("package_settings.install_a_candidate_from_a_source_directory_on")).toContain("machine running Assistant.");
  expect(translated("errors.provider_context_overflow")).toContain("Platform Settings > Model providers");
  expect(translated("prompt_settings.working_style")).toBe("Working style");
  expect(translated("settings.signed_in_to_nexus_as", { value1: "<script>{rho}</script>", role: "owner" }))
    .toBe("<script>{rho}</script> uses Platform as owner.");
  expect(t("brand.rho")).toBe("rho");
  expect(t("common.close")).toBe("Close");
});

test("prompt controls translate labels while using catalog fallbacks for other controls", () => {
  const translated = createTranslator({ "prompt_settings.preset_compact": "精简",
    "prompt_settings.replace_base_prompt": "替换基础提示" });
  expect(translated("prompt_settings.preset_compact")).toBe("精简");
  expect(translated("prompt_settings.replace_base_prompt")).toBe("替换基础提示");
  expect(translated("prompt_settings.preset_standard")).toBe("Standard");
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
