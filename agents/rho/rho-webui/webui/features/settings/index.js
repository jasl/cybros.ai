import { t } from "../../kernel/i18n.js";
import { settingsPage } from "./page.js";
import { generalSection } from "./general.js";
import { advancedSection } from "./advanced.js";
import { presetsSection } from "./presets.js";
import { rolesSection } from "./roles.js";
import { deploymentSection } from "./deployment.js";

// Settings separates reusable behavior from its delegation directory.
export function register(ui, shell) {
  ui.slots.register("main", { key: "settings" }, () => settingsPage(shell));
  ui.slots.register("settings.section", { key: "general", order: 0, label: () => t("settings.general") },
    (props) => generalSection(shell, props));
  ui.slots.register("settings.section", { key: "presets", order: 10, label: () => t("presets.title") },
    (props) => presetsSection(shell, props));
  ui.slots.register("settings.section", { key: "roles", order: 15, label: () => t("roles.title") },
    (props) => rolesSection(shell, props));
  ui.slots.register("settings.section", { key: "advanced", order: 20, label: () => t("settings_editor.defaults") },
    (props) => advancedSection(shell, props));
  ui.slots.register("settings.section", { key: "deployment", order: 30, label: () => t("deployment.title") },
    (props) => deploymentSection(shell, props));
}
