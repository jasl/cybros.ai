// The workspace's fields depend on its type, so it is compared and saved as
// one whole object holding only the fields that type uses.
function workspaceValue({ type, worktreePath = "", baseRef = "", branch = "" }) {
  if (type === "existing_worktree") return { type, worktreePath: worktreePath.trim() };
  if (type === "worktree") return branch.trim() ? { type, baseRef: baseRef.trim(), branch: branch.trim() } : { type, baseRef: baseRef.trim() };
  return { type: "root" };
}

// The configuration edit from the saved settings to the form: one operation
// per field that differs, where an emptied text field returns to its default.
// The bearer is write-only: a typed one is set, Clear unsets the saved one,
// and an empty field keeps it.
export function connectionOperations(saved, form) {
  const operations = [];
  const text = (key, value) => {
    if (value !== saved[key]) operations.push(value ? { op: "set", path: [key], value } : { op: "unset", path: [key] });
  };
  if (form.server !== saved.server) operations.push({ op: "set", path: ["server"], value: form.server });
  text("url", form.url.trim());
  const port = form.listenPort.trim();
  if (port !== "" && Number(port) !== saved.listen_port) operations.push({ op: "set", path: ["listen_port"], value: Number(port) });
  if (form.clearToken) operations.push({ op: "unset", path: ["token"] });
  else if ((form.token ?? "").trim()) operations.push({ op: "set", path: ["token"], value: form.token.trim() });
  const workspace = workspaceValue(form.workspace);
  if (JSON.stringify(workspace) !== JSON.stringify(workspaceValue(saved.workspace))) {
    operations.push({ op: "set", path: ["workspace"], value: workspace });
  }
  return operations;
}

// What the bearer field says: a bearer is saved, or none is.
export const bearerHint = (status, t) => (status.bearer === "saved" ? t("options.token_saved") : t("options.token_hint"));

// THE CONNECTION CARD: where T3 runs, how rho reaches it and its bearer —
// the service — and where its coding work happens — the workspace — as two
// groups of one form with one Save. A field that does not apply to the
// current choice is hidden and disabled, so it neither shows nor blocks
// validation. A host service's bearer is typed here; a local service's is
// issued by rho itself (`issue`).
export function connectionOptions(ui, t, { save, issue, level = 3 }) {
  const { el, primitives: p } = ui;
  let saved = null;
  let status = null;
  let edited = false;

  const server = p.select({ name: "server", options: [
    { value: "host", label: t("server.host") }, { value: "local", label: t("server.local") }] });
  const url = p.input({ name: "url", type: "url", spellcheck: "false", mono: true });
  const urlField = p.field({ label: t("options.url"), control: url, hint: t("options.url_hint") });
  const port = p.input({ name: "listen_port", type: "number", min: 1, max: 65535, step: 1, required: true });
  const portField = p.field({ label: t("options.port"), control: port, hint: t("options.port_hint") });
  const token = p.input({ name: "token", type: "password", autocomplete: "new-password", spellcheck: "false" });
  const tokenField = p.field({ label: t("options.token"), control: token, hint: t("options.token_hint") });
  const clear = p.checkbox({ name: "clear_token", label: t("options.token_clear") });
  const clearField = el("div", { class: "stack stack--tight", hidden: true }, clear.element,
    el("p", { class: "text-xxs text-tertiary", text: t("options.token_clear_hint") }));
  const issueButton = p.button({ label: t("options.token_issue"), size: "sm", icon: "retry", onClick: () => issue(fields) });
  const issueField = el("div", { class: "stack stack--tight", hidden: true },
    el("div", { class: "row row--wrap" }, issueButton), el("p", { class: "text-xxs text-tertiary", text: t("options.token_issue_hint") }));
  const workspaceType = p.select({ name: "workspace", options: [
    { value: "root", label: t("options.workspace_root") }, { value: "existing_worktree", label: t("options.workspace_existing") },
    { value: "worktree", label: t("options.workspace_new") }] });
  const worktreePath = p.input({ name: "worktree_path", spellcheck: "false", mono: true, required: true });
  const worktreeField = p.field({ label: t("options.worktree_path"), control: worktreePath });
  const baseRef = p.input({ name: "base_ref", spellcheck: "false", mono: true, required: true });
  const baseField = p.field({ label: t("options.base_ref"), control: baseRef });
  const branch = p.input({ name: "branch", spellcheck: "false", mono: true });
  const branchField = p.field({ label: t("options.branch"), control: branch });
  const submit = p.button({ label: t("options.save"), variant: "primary", type: "submit" });
  const service = p.formGroup({ title: t("options.service") });
  service.append(p.field({ label: t("options.server"), control: server }).element, urlField.element, portField.element,
    tokenField.element, clearField, issueField);
  const workspace = p.formGroup({ title: t("options.workspace_group") });
  workspace.append(p.field({ label: t("options.workspace"), control: workspaceType }).element, worktreeField.element, baseField.element, branchField.element);
  const fields = el("fieldset", { class: "stack", disabled: true }, service.element, workspace.element, el("div", { class: "row row--end" }, submit));
  const card = p.section({ title: t("options.title"), description: t("options.description"), level });
  card.body.append(el("form", { oninput: edit, onchange: edit, onsubmit: submitOptions }, fields));

  const values = () => ({ server: server.value, url: url.value, listenPort: port.value,
    token: token.value, clearToken: clear.input.checked,
    workspace: { type: workspaceType.value, worktreePath: worktreePath.value, baseRef: baseRef.value, branch: branch.value } });

  function show(field, control, visible) {
    field.element.hidden = !visible;
    control.disabled = !visible;
  }

  function arrange() {
    const local = server.value === "local";
    show(urlField, url, !local);
    show(portField, port, local);
    // A host service's bearer is typed; a local one is issued here, and a
    // saved one of either kind can be cleared.
    show(tokenField, token, !local);
    token.disabled = local || clear.input.checked;
    clearField.hidden = status?.bearer !== "saved";
    issueField.hidden = !local;
    issueButton.querySelector(".btn__label").textContent = status?.bearer === "saved" ? t("options.token_reissue") : t("options.token_issue");
    show(worktreeField, worktreePath, workspaceType.value === "existing_worktree");
    show(baseField, baseRef, workspaceType.value === "worktree");
    show(branchField, branch, workspaceType.value === "worktree");
  }

  function paintSave() {
    submit.disabled = connectionOperations(saved, values()).length === 0;
  }

  function edit() {
    edited = true;
    arrange();
    paintSave();
  }

  // A typed bearer is sent once and never kept in the form.
  function submitOptions(event) {
    event.preventDefault();
    const operations = connectionOperations(saved, values());
    if (operations.length) return save(fields, operations, () => { edited = false; token.value = ""; clear.input.checked = false; });
  }

  // A field the person is editing survives every later read.
  function paint(configuration, next) {
    saved = configuration;
    status = next;
    if (!edited) {
      server.value = configuration.server;
      url.value = configuration.url;
      port.value = String(configuration.listen_port);
      workspaceType.value = configuration.workspace.type;
      worktreePath.value = configuration.workspace.worktreePath ?? "";
      baseRef.value = configuration.workspace.baseRef ?? "";
      branch.value = configuration.workspace.branch ?? "";
    }
    tokenField.setHint(bearerHint(next, t));
    arrange();
    paintSave();
  }

  arrange();
  return { element: card.element, fields, paint };
}
