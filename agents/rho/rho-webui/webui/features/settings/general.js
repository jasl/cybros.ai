import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { CONTENT_SIZE } from "../../kernel/theme.js";
import { button, disclosure, section, segmented, stepper } from "../../primitives/index.js";
import { accessCard } from "./access.js";
import { connectionCard } from "./connection.js";

const row = (label, description, control) => el("div", { class: "settings-row" },
  el("div", { class: "settings-row__text" }, el("p", { class: "settings-row__label", text: label }),
    description ? el("p", { class: "settings-row__description", text: description }) : null), control);

function factValue(key, value) {
  if (key === "mode") return ({
    full: t("settings_editor.deployment.modes.full"), agent: t("settings_editor.deployment.modes.agent"),
    runner: t("settings_editor.deployment.modes.runner"),
  })[value] || value;
  if (value === true) return t("common.boolean_true");
  if (value === false) return t("common.boolean_false");
  if (value === null || value === undefined) return t("settings_editor.deployment.not_configured");
  return typeof value === "object" ? JSON.stringify(value) : String(value);
}

const deploymentLabel = (key) => ({
  api_only: t("settings_editor.deployment.api_only"), bind: t("settings_editor.deployment.bind"),
  executor_socket: t("settings_editor.deployment.executor_socket"), mode: t("settings_editor.deployment.mode"),
  public_url: t("settings_editor.deployment.public_url"), webui_root: t("settings_editor.deployment.webui_root"),
})[key] || key;

// General settings keep account, display and page access first. Explicit
// connection and deployment controls follow; model choices live in Defaults
// and Agent Presets. Display choices stay in this browser.
export function generalSection(shell, initialProps) {
  let props = initialProps;
  const account = el("p", { class: "settings-row__description" });
  const accountLabel = el("p", { class: "settings-row__label", text: t("settings.signed_in_label") });
  const signOut = button({ label: t("shell.sign_out"), size: "sm", icon: "logout", onClick: () => shell.signOut() });
  // A page an unlock admitted holds no Nexus account; it may sign in for one.
  const signIn = button({ label: t("settings.sign_in_with_nexus"), size: "sm", icon: "key", attrs: { hidden: true }, onClick: () => shell.signIn() });
  const accountCard = section({ title: t("common.nexus_account") });
  accountCard.body.append(el("div", { class: "settings-row" },
    el("div", { class: "settings-row__text" }, accountLabel, account), el("div", { class: "row" }, signIn, signOut)));
  const access = accessCard(shell, initialProps);
  const connection = connectionCard(shell, initialProps);

  const appearance = segmented({ name: "appearance", label: t("settings.appearance"), value: shell.theme.appearance.get(),
    options: [{ value: "system", label: t("settings.appearance_system"), icon: "monitor" },
      { value: "light", label: t("settings.appearance_light"), icon: "sun" }, { value: "dark", label: t("settings.appearance_dark"), icon: "moon" }],
    onChange: (value) => shell.theme.setAppearance(value) });
  const size = stepper({ label: t("settings.content_size"), value: shell.theme.contentSize.get(), min: CONTENT_SIZE.min, max: CONTENT_SIZE.max,
    format: (value) => t("settings.content_size_value", { size: value }), onChange: (value) => shell.theme.setContentSize(value) });
  const displayCard = section({ title: t("settings.display") });
  displayCard.body.append(row(t("settings.appearance"), t("settings.appearance_help"), appearance.element),
    row(t("settings.content_size"), t("settings.content_size_help"), size.element));

  const readiness = el("p", { class: "settings-row__description" });
  const deployment = el("dl", { class: "settings-facts" });
  const aboutCard = disclosure({ title: t("settings_editor.deployment_information") });
  aboutCard.body.append(el("p", { class: "field__hint", text: t("settings_editor.process_role_listening_address_and_installed_runtime_paths") }), readiness, deployment);
  const element = el("div", { class: "settings-section" }, accountCard.element, displayCard.element, access.element, connection.element, aboutCard.element);

  function paint() {
    const identity = props.identity;
    const human = identity?.human;
    const unlocked = identity?.session === "unlock";
    accountLabel.textContent = unlocked ? t("settings.this_page") : t("settings.signed_in_label");
    account.textContent = human
      ? t("settings.signed_in_to_nexus_as", { value1: human.display_name || human.public_id, role: t(`roles.${human.role}`, {}, human.role) })
      : unlocked && identity.access?.mode === "password" ? t("settings.unlocked_with_the_password")
        : unlocked ? t("settings.open_on_this_machine")
          : t("settings.your_nexus_session_is_unavailable_sign_out_and");
    signIn.hidden = !unlocked;
    // Signing out of an open gate would only open it again.
    signOut.hidden = unlocked && identity.access?.mode !== "password";
    signOut.querySelector(".btn__label").textContent = unlocked ? t("settings.lock") : t("shell.sign_out");
    const defaults = props.status?.defaults;
    readiness.textContent = defaults?.tools_ready && defaults?.runner_executor_public_id
      ? t("settings.agent_tools_and_the_default_runner_are_ready") : t("settings.agent_and_tool_defaults_are_installed_runner_readiness");
    const version = shell.setup.state.get().daemon?.version;
    deployment.replaceChildren(
      ...(version ? [el("dt", { text: t("settings.version") }), el("dd", { class: "mono", text: version })] : []),
      ...Object.entries(props.document?.deployment || {}).flatMap(([key, value]) => [el("dt", { text: deploymentLabel(key) }), el("dd", { text: factValue(key, value) })]));
  }

  const stops = [
    shell.theme.appearance.subscribe((value) => appearance.set(value)),
    shell.theme.contentSize.subscribe((value) => size.set(value)),
  ];
  paint();
  return {
    element,
    update(next) { props = next; paint(); access.update(next); connection.update(next); },
    dispose() { for (const stop of stops) stop(); },
  };
}
