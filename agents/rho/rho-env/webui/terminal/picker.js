export function terminalsPanel(ui, t, props) {
  const { el, uuidv7, isTerminal } = ui;
  const { button, alert, select, field } = ui.primitives;
  const reads = new AbortController();
  const workspace = props.conversation.workspace;
  const scope = workspace ? { workspace_public_id: workspace } : {};
  const failure = alert({ tone: "error" });
  const runner = select({ disabled: true, options: [{ value: "", label: t("terminals.loading") }] });
  const runnerField = field({ label: t("terminals.runner"), control: runner });
  const unavailable = alert({ tone: "info", text: t("terminals.unavailable"), hidden: true });
  const heading = el("h3", { text: t("terminals.existing"), hidden: true });
  const history = el("div", { class: "terminals__history" });
  const create = button({ label: t("terminals.new"), size: "sm", onClick: start });
  create.disabled = true;
  const refresh = button({ label: t("refresh"), size: "sm", onClick: () => load() });
  const older = button({ label: t("terminals.older"), size: "sm", onClick: () => load(after) });
  older.hidden = true;
  const element = el("section", { class: "terminals", "aria-label": t("terminals.title") },
    el("header", { class: "terminals__head" }, runnerField.element,
      el("div", { class: "terminals__actions" }, create, refresh)),
    el("p", { class: "terminals__guide", text: t("terminals.guide") }), unavailable.element, failure.element,
    heading, history, older);
  let after;
  const alive = () => !reads.signal.aborted;
  const query = (path, values) => `${path}?${new URLSearchParams(values)}`;
  const call = (path, options = {}) => ui.call(path, { ...options, signal: reads.signal });
  function error(problem) { if (alive() && problem.name !== "AbortError") failure.show(problem.message); }
  const tabs = () => ui.dock.state().get().tabs;
  const nextNumber = () => Math.max(0, ...tabs().filter((tab) => tab.key === "terminal").map((tab) => tab.params.number || 0)) + 1;
  function start() {
    if (!runner.value) return;
    const id = uuidv7();
    const number = nextNumber();
    const name = runner.selectedOptions?.[0]?.textContent || t("terminal.title");
    ui.dock.open("terminal", { id: `terminal:${id}`, params: {
      number, title: t("terminals.named", { number, runner: name }),
      intent: { ...scope, runner_executor_public_id: runner.value, idempotency_key: id },
    } });
    props.close?.();
  }
  function open(row) {
    const existing = tabs().find((tab) => tab.key === "terminal" && tab.params.target?.public_id === row.public_id);
    if (existing) { ui.dock.open("terminal", { id: existing.id }); props.close?.(); return; }
    const number = nextNumber();
    ui.dock.open("terminal", { id: `terminal:${row.public_id}`, params: {
      number, title: t("terminals.number", { number }),
      target: { public_id: row.public_id, task_key: row.task_key, workspace_public_id: row.workspace_public_id },
    } });
    props.close?.();
  }

  async function load(cursor) {
    try {
      const [catalog, page] = await Promise.all([
        call("/runners"), call(query("/terminals", { ...scope, ...(cursor ? { after: cursor } : {}) })),
      ]);
      if (!alive()) return;
      const selected = runner.value;
      const choices = catalog.runners.filter((row) => row.tools.includes("terminal"));
      runner.replaceChildren(...choices.map((row) => el("option", { value: row.public_id, text: row.display_name || row.public_id })));
      if (!choices.length) runner.append(el("option", { value: "", text: t("terminals.none") }));
      if (choices.some((row) => row.public_id === selected)) runner.value = selected;
      runner.disabled = !choices.length;
      create.disabled = !choices.length;
      unavailable.element.hidden = choices.length > 0;
      failure.hide();
      const rows = page.terminals.filter((row) => !isTerminal(row.status)).map((row) => {
        const openButton = button({
          label: t("terminals.created", { time: new Date(row.created_at).toLocaleString() }), size: "sm",
          onClick: () => open(row),
        });
        openButton.dataset.terminalId = row.public_id;
        return openButton;
      });
      cursor ? history.append(...rows) : history.replaceChildren(...rows);
      heading.hidden = history.childNodes.length === 0;
      after = page.after;
      older.hidden = !page.has_more;
    } catch (problem) { error(problem); }
  }
  load();
  return { element, dispose() { reads.abort(); } };
}
