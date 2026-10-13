import { agentChoices, projectChoices } from "./choices.js";
import { connectionOptions } from "./options.js";
import { statusCard } from "./status.js";

// The T3 settings body, shown on the plugin's own page and in place of the
// generic form on its Plugins entry. It reads `GET /t3` itself: the project
// and agent are chosen from the service's own lists, a choice the person is
// editing survives every later read, and the forms stay closed until a read
// succeeds. `level` is the heading level of its cards.
export function t3Settings(ui, t, { level = 3 } = {}) {
  const { el, primitives: p } = ui;
  const reads = new AbortController();
  const configurationPath = `/extensions/${encodeURIComponent(ui.id)}/configuration`;
  let current = null;
  let projectDirty = false;
  let agentDirty = false;

  const alert = p.alert({ tone: "error" });
  const status = statusCard(ui, t, { level, refresh });
  const options = connectionOptions(ui, t, { save: saveOptions, issue: issueToken, level });

  const projectSelect = p.select({ name: "project_id" });
  const useProject = p.button({ label: t("project.use"), variant: "primary", type: "submit" });
  const projectNotice = el("p", { class: "notice", text: t("project.directory_unavailable"), hidden: true });
  const projectFields = el("fieldset", { class: "stack", disabled: true },
    p.field({ label: t("project.label"), control: projectSelect }).element, el("div", { class: "row row--end" }, useProject));
  const path = p.input({ name: "path", required: true, spellcheck: "false", autocomplete: "off", mono: true });
  const pathField = p.field({ label: t("create.label"), control: path, hint: t("create.hint") });
  const create = p.button({ label: t("create.submit"), icon: "plus", type: "submit" });
  const createFields = el("fieldset", { class: "stack", disabled: true }, pathField.element, el("div", { class: "row row--end" }, create));
  const project = p.section({ title: t("project.title"), description: t("project.description"), level });
  project.body.append(projectNotice,
    el("form", { oninput: editProject, onchange: editProject, onsubmit: saveProject }, projectFields),
    el("form", { oninput: () => pathField.setError(null), onsubmit: createProject }, createFields));

  const agentSelect = p.select({ name: "default_agent" });
  const saveAgent = p.button({ label: t("agent.save"), variant: "primary", type: "submit" });
  const agentNotice = el("p", { class: "notice", text: t("agent.directory_unavailable"), hidden: true });
  const agentFields = el("fieldset", { class: "stack", disabled: true },
    p.field({ label: t("agent.label"), control: agentSelect, hint: t("agent.hint") }).element, el("div", { class: "row row--end" }, saveAgent));
  const agent = p.section({ title: t("agent.title"), description: t("agent.description"), level });
  agent.body.append(agentNotice, el("form", { oninput: editAgent, onchange: editAgent, onsubmit: submitAgent }, agentFields));

  const element = el("div", { class: "stack" }, alert.element, status.element, options.element, project.element, agent.element);

  async function read() {
    try {
      paint(await ui.call("/t3", { signal: reads.signal }));
    } catch (error) {
      if (error.name === "AbortError") return;
      alert.show(error.message);
      if (current === null) status.failed();
    }
  }

  function refresh() {
    alert.hide();
    return read();
  }

  function paint(document) {
    const first = current === null;
    current = document;
    const saved = document.configuration;
    status.paint(document);
    options.paint(saved, document.status);
    paintChoices(projectSelect, (kept) => projectChoices(document.projects, kept, t), saved.project_id, projectDirty);
    paintChoices(agentSelect, (kept) => agentChoices(document.providers, kept, t), saved.default_agent, agentDirty);
    projectNotice.hidden = document.projects !== null;
    create.disabled = document.projects === null;
    agentNotice.hidden = document.providers !== null;
    paintActions();
    if (first) for (const fields of [projectFields, createFields, agentFields, options.fields]) fields.disabled = false;
  }

  function paintChoices(select, build, saved, dirty) {
    const value = dirty ? select.value : saved;
    select.replaceChildren(...build([saved, value]).map((option) =>
      el("option", { value: option.value, text: option.label, disabled: option.disabled })));
    select.value = value;
  }

  // Each choice saves only when it differs from the saved one.
  function paintActions() {
    useProject.disabled = projectSelect.value === current.configuration.project_id;
    saveAgent.disabled = agentSelect.value === current.configuration.default_agent;
  }

  function editProject() {
    projectDirty = true;
    paintActions();
  }

  function editAgent() {
    agentDirty = true;
    paintActions();
  }

  const patch = (operations) => ui.call(configurationPath, { method: "PATCH", body: { operations }, signal: reads.signal });

  // A listed project goes through T3's own route, which checks it against the
  // service's list; Not set needs no check and clears the saved one.
  function saveProject(event) {
    event.preventDefault();
    const id = projectSelect.value;
    const send = id
      ? () => ui.call("/t3/project", { method: "POST", body: { id }, signal: reads.signal })
      : () => patch([{ op: "unset", path: ["project_id"] }]);
    return write(projectFields, send, () => { projectDirty = false; },
      (answer) => (id ? t("project.saved", { title: answer.project.title }) : t("project.cleared")));
  }

  function createProject(event) {
    event.preventDefault();
    const folder = path.value.trim();
    if (!folder.startsWith("/")) {
      pathField.setError(t("create.absolute"));
      path.focus();
      return;
    }
    return write(createFields, () => ui.call("/t3/project", { method: "POST", body: { path: folder }, signal: reads.signal }),
      () => { path.value = ""; projectDirty = false; }, (answer) => t("project.saved", { title: answer.project.title }));
  }

  function submitAgent(event) {
    event.preventDefault();
    const value = agentSelect.value;
    return write(agentFields, () => patch([value ? { op: "set", path: ["default_agent"], value } : { op: "unset", path: ["default_agent"] }]),
      () => { agentDirty = false; }, () => t("agent.saved"));
  }

  function saveOptions(fields, operations, done) {
    return write(fields, () => patch(operations), done, () => t("options.saved"));
  }

  // A local service's bearer: rho issues one natively and saves it. The
  // answer never carries the bearer.
  function issueToken(fields) {
    return write(fields, () => ui.call("/t3/token", { method: "POST", body: {}, signal: reads.signal }), () => {}, () => t("options.token_issued"));
  }

  // Every save reads the document again and asks the shell to re-read the
  // plugin inventory, whose readiness follows the project and connection. A
  // save the daemon kept but could not apply is still a save: the edit is
  // done and the warning says what is pending.
  async function write(fields, send, done, success) {
    alert.hide();
    fields.disabled = true;
    try {
      const answer = await send();
      done();
      announce(answer, success(answer));
      await Promise.all([read(), ui.inventory.refresh()]);
    } catch (error) {
      if (error.name === "AbortError") return;
      if (error.details?.saved) {
        done();
        alert.show(error.message, "warning");
        await Promise.all([read(), ui.inventory.refresh()]);
      } else {
        alert.show(error.message);
      }
    } finally {
      fields.disabled = false;
    }
  }

  // A restart-only local service keeps its settings until rho restarts, so
  // that outcome stays on the page instead of passing as a toast.
  function announce(answer, text) {
    if (answer.restart_required) alert.show(t("save.restart"), "warning");
    else ui.toast(text, { tone: "success" });
  }

  read();
  return { element, refresh, update() {}, dispose() { reads.abort(); } };
}
