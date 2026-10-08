import { pluginText, statusText, t } from "./i18n.js";
import { el } from "./views.js";
import { jsonSetting } from "./settings_state.js";

const button = (text, onclick, attrs = {}) => el("button", { type: "button", text, onclick, ...attrs });
const shortVersion = (version) => version ? version.slice(0, 12) : t("common.none");

export function packageCheckMessage(answer) {
  if (answer.timed_out) return t("package_settings.check_timed_out_this_version_has_not_passed");
  if (!answer.passed) return answer.exit_status == null ? t("package_settings.checks_failed")
    : t("package_settings.checks_failed_with_exit", { status: answer.exit_status });
  if (answer.tests === 0) return t("package_settings.structure_and_dependencies_checked_no_test_files_were");
  return t(answer.tests === 1 ? "package_settings.checks_passed_one" : "package_settings.checks_passed_many", { tests: answer.tests });
}

export function packageActionMessage(answer) {
  if (answer.installed) return answer.active ? t("package_settings.this_version_is_installed_and_already_running") : t("package_settings.candidate_installed_check_it_then_activate_it_when");
  const messages = [];
  if (answer.persistence === "published_durability_uncertain") {
    messages.push(t("package_settings.the_selection_was_written_but_its_durability_is"));
  } else {
    messages.push(answer.saved ? (answer.applied ? t("package_settings.selection_saved_and_applied") : t("package_settings.selection_saved_but_not_applied")) : t("package_settings.selection_was_not_saved"));
  }
  if (answer.restart_required) messages.push(t("package_settings.restart_rho_to_load_the_saved_selection"));
  if (answer.published === false) messages.push(t("package_settings.platform_announcement_was_not_completed"));
  if (answer.cleanup_pending?.length) messages.push(t("package_settings.cleanup_pending", { value1: answer.cleanup_pending.join(", ") }));
  if (answer.failures?.length) messages.push(t("package_settings.cleanup_failures", { value1: answer.failures.map((row) => `${row.extension} (${row.error_class})`).join(", ") }));
  if (answer.warning) messages.push(answer.warning);
  return messages.join(" ");
}

export function packageActivation(name, version, configuration) {
  const body = { action: "activate", name, version };
  if (configuration.trim()) body.configuration = jsonSetting(configuration, t("common.configuration_overrides"));
  return body;
}

export function packageSettings({ call, signal, showError, changed = async () => {} }) {
  const cards = new Map();
  let reading = 0;
  let busy = false;
  let uncertain = false;
  const path = el("input", { type: "text", required: true, autocomplete: "off", spellcheck: "false",
    placeholder: "/home/runner/my-package" });
  const install = el("button", { type: "submit", text: t("common.install_candidate") });
  const installFields = el("fieldset", { class: "settings-fields" }, el("label", {}, t("package_settings.source_directory"), path), install);
  const feedback = el("p", { class: "package-feedback", role: "status", hidden: true });
  const inventoryStatus = el("p", { class: "muted", text: t("package_settings.loading_managed_packages") });
  const list = el("div", { class: "package-list" });
  const refreshButton = button(t("package_settings.refresh_packages"), () => refresh().catch(showError));
  const element = el("section", { class: "settings-section", "aria-label": t("common.managed_packages") },
    el("h3", { text: t("common.managed_packages") }),
    el("p", { class: "faint", text: t("package_settings.install_a_candidate_from_a_source_directory_on") }),
    el("form", { class: "settings-form", onsubmit: async (event) => {
      event.preventDefault();
      const submitted = path.value.trim();
      if (!submitted) return;
      await operation({ action: "install", path: submitted }, feedback, (answer) => {
        if (path.value.trim() === submitted) path.value = "";
        return { name: answer.name, version: answer.version };
      });
    } }, installFields), feedback, refreshButton, inventoryStatus, list);

  function paintActions() {
    installFields.disabled = busy || uncertain;
    install.textContent = busy ? t("common.working") : t("common.install_candidate");
    refreshButton.disabled = busy;
    for (const card of cards.values()) card.paintActions();
  }

  async function refresh({ force = false, selected } = {}) {
    if (signal?.aborted || (busy && !force)) return;
    const request = ++reading;
    refreshButton.disabled = true;
    try {
      const answer = await call("/extensions/packages", { signal });
      if (signal?.aborted || request !== reading) return;
      uncertain = false;
      const grouped = Map.groupBy(answer.packages, (row) => row.name);
      for (const [name, rows] of grouped) {
        if (!cards.has(name)) cards.set(name, packageCard(name));
        cards.get(name).update(rows, selected?.name === name ? selected.version : null);
      }
      for (const [name, card] of cards) if (!grouped.has(name)) { card.element.remove(); cards.delete(name); }
      list.replaceChildren(...[...cards.values()].map((card) => card.element));
      inventoryStatus.textContent = grouped.size ? t("package_settings.saved_selections_and_running_versions_are_shown_separately") : t("package_settings.no_managed_packages_are_installed");
      paintActions();
    } finally {
      if (!signal?.aborted && request === reading) refreshButton.disabled = busy;
    }
  }

  async function operation(body, result, accepted = () => null) {
    if (busy || uncertain || signal?.aborted) return;
    busy = true; ++reading; paintActions();
    result.textContent = body.action === "check" ? t("package_settings.checking_this_version") : t("common.working");
    result.hidden = false;
    let answer = null;
    try {
      answer = await call("/extensions/packages", { method: "POST", body, signal });
      if (signal?.aborted) return;
      const selected = accepted(answer);
      result.textContent = body.action === "check" ? packageCheckMessage(answer) : packageActionMessage(answer);
      await refresh({ force: true, selected });
      if (body.action !== "check") await changed(answer);
    } catch (error) {
      if (signal?.aborted) return;
      uncertain = body.action !== "check" && (answer !== null || !error.status || error.status >= 500);
      result.textContent = answer !== null ? t("package_settings.current_state_could_not_be_refreshed_refresh_packages", { textContent: result.textContent })
        : uncertain ? t("package_settings.the_operation_s_outcome_is_unknown_refresh_packages")
          : error.message;
      showError(error);
    } finally {
      busy = false;
      if (!signal?.aborted) paintActions();
    }
  }

  function packageCard(name) {
    let versions = [];
    const checks = new Map();
    const summary = el("p", { class: "package-status muted" });
    const description = el("p", { class: "faint" });
    const version = el("select", { onchange: () => paint() });
    const fullVersion = el("p", { class: "mono package-version" });
    const details = el("p", { class: "faint" });
    const configuration = el("textarea", { rows: 5, class: "mono", autocomplete: "off", spellcheck: "false" });
    const overrides = el("details", { class: "settings-details" }, el("summary", { text: t("package_settings.activation_configuration_optional") }),
      el("p", { class: "faint", text: t("package_settings.leave_blank_to_keep_and_migrate_saved_configuration") }),
      el("label", {}, t("common.configuration_overrides"), configuration));
    const result = el("p", { class: "package-feedback", role: "status", hidden: true });
    const checkSummary = el("p", { role: "status" });
    const checkOutput = el("pre", { class: "package-output" });
    const checkResult = el("div", { class: "package-check", hidden: true }, checkSummary,
      el("details", {}, el("summary", { text: t("package_settings.check_output") }), checkOutput));
    const check = button(t("package_settings.check_version"), () => operation({ action: "check", name, version: version.value }, result, (answer) => {
      checks.set(answer.version, answer); paint();
    }));
    const activate = button(t("package_settings.activate_version"), async () => {
      try {
        const submitted = configuration.value;
        const body = packageActivation(name, version.value, submitted);
        await operation(body, result, () => { if (configuration.value === submitted) configuration.value = ""; });
      } catch (error) { result.textContent = error.message; result.hidden = false; showError(error); }
    });
    const rollback = button(t("package_settings.roll_back"), () => operation({ action: "rollback", name }, result));
    const disable = button(t("package_settings.disable_package"), () => operation({ action: "disable", name }, result));
    const actions = el("fieldset", { class: "settings-fields" }, el("label", {}, t("package_settings.installed_version"), version), fullVersion, details,
      overrides, el("div", { class: "settings-actions" }, check, activate, rollback, disable));
    const element = el("details", { class: "settings-details package-card", "data-package-name": name },
      el("summary", {}, el("strong", { text: name })), description, summary, actions,
      el("p", { class: "faint", text: t("package_settings.check_runs_this_installed_version_s_tests_and") }), result, checkResult);

    function paintActions() {
      actions.disabled = busy || uncertain;
      rollback.disabled = !versions.some((row) => row.previous);
      disable.disabled = !versions.some((row) => row.selected && row.enabled);
    }

    function paint() {
      const selected = versions.find((row) => row.selected);
      const running = versions.find((row) => row.active);
      const previous = versions.find((row) => row.previous);
      const viewing = versions.find((row) => row.version === version.value);
      description.textContent = viewing ? `${pluginText(viewing, "description")} · ${viewing.id}` : "";
      summary.textContent = t("package_settings.saved_running_previous", { shortVersion: shortVersion(selected?.version), value2: selected ? ` (${statusText(selected.enabled ? "enabled" : "disabled")})` : "", shortVersion3: shortVersion(running?.version), shortVersion4: shortVersion(previous?.version) });
      fullVersion.textContent = viewing?.version || "";
      details.textContent = viewing ? t("package_settings.configuration_version_business_state", { configuration_version: viewing.configuration_version, state_schema: viewing.state_schema }) : "";
      const answer = checks.get(version.value);
      checkResult.hidden = !answer;
      checkSummary.textContent = answer ? t("package_settings.this_page_s_check", { packageCheckMessage: packageCheckMessage(answer) }) : "";
      checkOutput.textContent = answer?.output || t("package_settings.no_output");
      paintActions();
    }

    return { element, paintActions, clearSecrets: () => { configuration.value = ""; }, update: (rows, chosen) => {
      versions = rows;
      const wanted = chosen || version.value || rows.find((row) => row.selected)?.version || rows[0].version;
      version.replaceChildren(...rows.map((row) => el("option", { value: row.version, text: [shortVersion(row.version),
        row.selected ? statusText("saved") : "", row.active ? statusText("running") : "", row.previous ? statusText("previous") : ""].filter(Boolean).join(" · ") })));
      version.value = rows.some((row) => row.version === wanted) ? wanted : rows[0].version;
      if (chosen) element.open = true;
      paint();
    } };
  }

  return { element, refresh, clearSecrets: () => { for (const card of cards.values()) card.clearSecrets(); } };
}
