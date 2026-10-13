import { el, icon } from "../../kernel/dom.js";
import { t, pluginText, statusText } from "../../kernel/i18n.js";
import { jsonObject } from "../../kernel/forms.js";
import { button, field, formGroup, group, input, select, textarea } from "../../primitives/index.js";

const shortVersion = (version) => (version ? version.slice(0, 12) : t("common.none"));

export function packageCheckMessage(answer) {
  if (answer.timed_out) return t("package_settings.check_timed_out_this_version_has_not_passed");
  if (!answer.passed) return answer.exit_status == null ? t("package_settings.checks_failed")
    : t("package_settings.checks_failed_with_exit", { status: answer.exit_status });
  if (answer.tests === 0) return t("package_settings.structure_and_dependencies_checked_no_test_files_were");
  return answer.tests === 1 ? t("package_settings.checks_passed_one", { tests: answer.tests }) : t("package_settings.checks_passed_many", { tests: answer.tests });
}

export function packageActionMessage(answer) {
  if (answer.installed) return answer.active ? t("package_settings.this_version_is_installed_and_already_running") : t("package_settings.candidate_installed_check_it_then_activate_it_when");
  const messages = [];
  if (answer.persistence === "published_durability_uncertain") messages.push(t("package_settings.the_selection_was_written_but_its_durability_is"));
  else messages.push(answer.saved ? (answer.applied ? t("package_settings.selection_saved_and_applied") : t("package_settings.selection_saved_but_not_applied")) : t("package_settings.selection_was_not_saved"));
  if (answer.restart_required) messages.push(t("package_settings.restart_rho_to_load_the_saved_selection"));
  if (answer.published === false) messages.push(t("package_settings.platform_announcement_was_not_completed"));
  if (answer.cleanup_pending?.length) messages.push(t("package_settings.cleanup_pending", { names: answer.cleanup_pending.join(", ") }));
  if (answer.failures?.length) messages.push(t("package_settings.cleanup_failures", { failures: answer.failures.map((row) => `${row.extension} (${row.error_class})`).join(", ") }));
  if (answer.warning) messages.push(answer.warning);
  return messages.join(" ");
}

// Blank keeps and migrates the saved configuration; JSON replaces it whole.
export function packageActivation(name, version, configuration) {
  const body = { action: "activate", name, version };
  if (configuration.trim()) body.configuration = jsonObject(configuration, t("common.configuration_overrides"));
  return body;
}

// Managed packages: install a candidate from a source directory, then check,
// activate, roll back or disable an installed version. Saved, running and
// previous versions stay distinct, no write is ever retried, and after an
// uncertain answer the state is read before another change.
export function packagesCard(shell) {
  const cards = new Map();
  const aborted = () => shell.signal.aborted;
  let reading = 0;
  let busy = false;
  let uncertain = false;
  let loaded = false;
  const source = input({ name: "package_source", required: true, autocomplete: "off", spellcheck: "false", placeholder: "/home/runner/my-package" });
  const install = button({ label: t("common.install_candidate"), variant: "primary", size: "sm", type: "submit" });
  // The install: the source field and its button on one row, what an
  // install does under them.
  const sourceField = field({ label: t("package_settings.source_directory"), control: source });
  const installFields = el("fieldset", { class: "packages__install" },
    el("div", { class: "packages__install-row" }, sourceField.element, install),
    el("p", { class: "field__hint", text: t("package_settings.install_a_candidate_from_a_source_directory_on") }));
  const feedback = el("p", { class: "packages__feedback", role: "status", hidden: true });
  const status = el("p", { class: "packages__status", text: t("package_settings.loading_managed_packages") });
  const list = el("div", { class: "packages__list" });
  const form = el("form", { class: "packages__form", onsubmit: async (event) => {
    event.preventDefault();
    const submitted = source.value.trim();
    if (!submitted) return;
    await operation({ action: "install", path: submitted }, feedback, (answer) => {
      if (source.value.trim() === submitted) source.value = "";
      return { name: answer.name, version: answer.version };
    });
  } }, installFields);
  // The page's Refresh reads the packages again with the plugins.
  const shelf = group({ title: t("common.managed_packages"), attrs: { class: "group packages" } });
  shelf.body.append(form, feedback, status, list);
  const element = shelf.element;

  function paintActions() {
    installFields.disabled = busy || uncertain;
    install.querySelector(".btn__label").textContent = busy ? t("common.working") : t("common.install_candidate");
    for (const card of cards.values()) card.paintActions();
  }

  async function read({ force = false, selected } = {}) {
    if (aborted() || (busy && !force)) return;
    const request = ++reading;
    const answer = await shell.call("/extensions/packages");
    if (aborted() || request !== reading) return;
    loaded = true;
    uncertain = false;
    const grouped = Map.groupBy(answer.packages, (row) => row.name);
    shelf.setCount(grouped.size);
    for (const [name, rows] of grouped) {
      if (!cards.has(name)) cards.set(name, packageCard(name));
      cards.get(name).update(rows, selected?.name === name ? selected.version : null);
    }
    for (const [name, card] of cards) if (!grouped.has(name)) { card.element.remove(); cards.delete(name); }
    list.replaceChildren(...[...cards.values()].map((card) => card.element));
    status.textContent = grouped.size ? "" : t("package_settings.no_managed_packages_are_installed");
    status.hidden = grouped.size > 0;
    paintActions();
  }

  async function refresh() {
    try { await read(); } catch (error) { if (!aborted() && error.name !== "AbortError") status.textContent = error.message; }
  }

  async function operation(body, result, accepted = () => null) {
    if (busy || uncertain || aborted()) return;
    busy = true; ++reading; paintActions();
    result.textContent = body.action === "check" ? t("package_settings.checking_this_version") : t("common.working");
    result.hidden = false;
    let answer = null;
    try {
      answer = await shell.call("/extensions/packages", { method: "POST", body });
      if (aborted()) return;
      const selected = accepted(answer);
      result.textContent = body.action === "check" ? packageCheckMessage(answer) : packageActionMessage(answer);
      await read({ force: true, selected });
      if (body.action !== "check") shell.inventory.refresh();
    } catch (error) {
      if (aborted() || error.name === "AbortError") return;
      uncertain = body.action !== "check" && (answer !== null || !error.status || error.status >= 500);
      result.textContent = answer !== null ? t("package_settings.current_state_could_not_be_refreshed_refresh_packages", { message: result.textContent })
        : uncertain ? t("package_settings.the_operation_s_outcome_is_unknown_refresh_packages") : error.message;
    } finally {
      busy = false;
      if (!aborted()) paintActions();
    }
  }

  function packageCard(name) {
    let versions = [];
    const checks = new Map();
    const description = el("p", { class: "package__description" });
    const summary = el("p", { class: "package__summary" });
    const version = select({ name: "version" });
    version.addEventListener("change", () => paint());
    const fullVersion = el("p", { class: "mono package__version" });
    const details = el("p", { class: "package__details" });
    const configuration = textarea({ rows: 5, mono: true, attrs: { autocomplete: "off" } });
    const result = el("p", { class: "package__feedback", role: "status", hidden: true });
    const checkSummary = el("p", { role: "status" });
    const checkOutput = el("pre", { class: "code-block package__output" });
    const checkResult = el("div", { class: "package__check", hidden: true }, checkSummary, checkOutput);
    const overrides = formGroup({ title: t("package_settings.activation_configuration"), description: t("package_settings.leave_blank_to_keep_and_migrate_saved_configuration") });
    overrides.append(field({ label: t("common.configuration_overrides"), control: configuration }).element);
    const check = button({ label: t("package_settings.check_version"), size: "sm", onClick: () => operation({ action: "check", name, version: version.value }, result,
      (answer) => { checks.set(answer.version, answer); paint(); }) });
    const activate = button({ label: t("package_settings.activate_version"), variant: "primary", size: "sm", onClick: async () => {
      const submitted = configuration.value;
      let body;
      try { body = packageActivation(name, version.value, submitted); }
      catch (error) { result.textContent = error.message; result.hidden = false; return; }
      await operation(body, result, () => { if (configuration.value === submitted) configuration.value = ""; });
    } });
    const rollback = button({ label: t("package_settings.roll_back"), size: "sm", onClick: () => operation({ action: "rollback", name }, result) });
    const disable = button({ label: t("package_settings.disable_package"), variant: "danger", size: "sm", onClick: () => operation({ action: "disable", name }, result) });
    const fields = el("fieldset", { class: "package__fields" },
      field({ label: t("package_settings.installed_version"), control: version }).element, fullVersion, details, overrides.element,
      el("div", { class: "package__actions" }, check, activate, rollback, disable));
    const element = el("details", { class: "package", "data-package-name": name },
      el("summary", { class: "package__name" }, el("span", { class: "mono", text: name }), icon("chevron-down")), description, summary, fields,
      el("p", { class: "field__hint", text: t("package_settings.check_runs_this_installed_version_s_tests_and") }), result, checkResult);

    function paintActions() {
      fields.disabled = busy || uncertain;
      rollback.disabled = !versions.some((row) => row.previous);
      disable.disabled = !versions.some((row) => row.selected && row.enabled);
    }

    function paint() {
      const selected = versions.find((row) => row.selected);
      const running = versions.find((row) => row.active);
      const previous = versions.find((row) => row.previous);
      const viewing = versions.find((row) => row.version === version.value);
      description.textContent = viewing ? `${pluginText(viewing, "description")} · ${viewing.id}` : "";
      summary.textContent = t("package_settings.saved_running_previous", { saved: shortVersion(selected?.version),
        state: selected ? ` (${statusText(selected.enabled ? "enabled" : "disabled")})` : "", running: shortVersion(running?.version), previous: shortVersion(previous?.version) });
      fullVersion.textContent = viewing?.version || "";
      details.textContent = viewing ? t("package_settings.configuration_version_business_state", { configuration_version: viewing.configuration_version, state_schema: viewing.state_schema }) : "";
      const answer = checks.get(version.value);
      checkResult.hidden = !answer;
      checkSummary.textContent = answer ? t("package_settings.this_page_s_check", { message: packageCheckMessage(answer) }) : "";
      checkOutput.textContent = answer?.output || t("package_settings.no_output");
      paintActions();
    }

    return {
      element, paintActions,
      clearSecrets() { configuration.value = ""; },
      update(rows, chosen) {
        versions = rows;
        const wanted = chosen || version.value || rows.find((row) => row.selected)?.version || rows[0].version;
        version.replaceChildren(...rows.map((row) => el("option", { value: row.version, text: [shortVersion(row.version),
          row.selected ? statusText("saved") : "", row.active ? statusText("running") : "", row.previous ? statusText("previous") : ""].filter(Boolean).join(" · ") })));
        version.value = rows.some((row) => row.version === wanted) ? wanted : rows[0].version;
        if (chosen) element.open = true;
        paint();
      },
    };
  }

  return {
    element, refresh,
    // Activation overrides may hold credentials; leaving the page drops them.
    clearSecrets() { for (const card of cards.values()) card.clearSecrets(); },
  };
}
