import { el } from "../../kernel/dom.js";
import { t, statusText } from "../../kernel/i18n.js";
import { isTerminal } from "../../kernel/format.js";
import { button, alert } from "../../primitives/index.js";
import { terminalPanel } from "../../primitives/terminal.js";

export function terminalsPanel(shell, props) {
  const reads = new AbortController();
  const workspace = props.conversation.workspace;
  const scope = workspace ? { workspace_public_id: workspace } : {};
  const failure = alert({ tone: "error" });
  const runner = el("select", { "aria-label": t("terminals.runner") });
  const current = el("div");
  const history = el("div");
  const create = button({ label: t("terminals.new"), onClick: start });
  create.disabled = true;
  const refresh = button({ label: t("common.refresh"), size: "sm", onClick: () => load() });
  const older = button({ label: t("terminals.older"), size: "sm", onClick: () => load(after) });
  older.hidden = true;
  const element = el("section", { class: "task", "aria-label": t("terminals.title") },
    el("header", { class: "task__head" }, runner, create, refresh),
    el("p", { text: t("terminals.guide") }), failure.element, current, history, older);
  let terminal, timer, generation = 0, pending, busy = false, after;
  const alive = () => !reads.signal.aborted;
  const query = (path, values) => `${path}?${new URLSearchParams(values)}`;
  const call = (path, options = {}) => shell.call(path, { ...options,
    signal: options.signal ? AbortSignal.any([reads.signal, options.signal]) : reads.signal });
  function error(problem) { if (alive() && problem.name !== "AbortError") failure.show(problem.message); }

  async function start() {
    if (busy || !runner.value) return;
    busy = true;
    create.disabled = runner.disabled = true;
    pending ||= { ...scope, runner_executor_public_id: runner.value, idempotency_key: crypto.randomUUID() };
    try {
      const { terminal: target } = await call("/terminals", { method: "POST", body: pending });
      if (!alive()) return;
      pending = null;
      failure.hide();
      open(target);
      load();
    } catch (problem) { error(problem); }
    finally {
      busy = false;
      create.disabled = false;
      // An uncertain response retries the same accepted intent, including its Runner.
      runner.disabled = !!pending;
      create.textContent = pending ? t("terminals.retry") : t("terminals.new");
    }
  }

  function open(target) {
    const version = ++generation;
    clearTimeout(timer);
    terminal?.dispose(); terminal = null;
    const status = el("p", { role: "status" });
    const host = el("div");
    const stop = button({ label: t("terminal.stop"), variant: "danger", size: "sm", async onClick() {
      stop.disabled = true;
      try { await call("/stop", { method: "POST", body: { ...target, task_key: undefined, host_type: "run", force: true } }); }
      catch (problem) { error(problem); stop.disabled = false; }
    } });
    current.replaceChildren(status, stop, host);
    async function poll() {
      try {
        const { task } = await call(query("/runs/task", target));
        if (!alive() || version !== generation) return;
        status.textContent = `${statusText(task.status)}${task.error ? ` · ${task.error.message || task.error.key}` : ""}`;
        if (isTerminal(task.status)) {
          terminal?.finish();
          stop.disabled = true;
          return;
        }
        if (["running", "dispatched"].includes(task.status) && !terminal) {
          terminal = terminalPanel({ call, target, stopRun: true });
          host.replaceChildren(terminal.element);
          stop.hidden = true;
        }
      } catch (problem) { error(problem); }
      if (alive() && version === generation) timer = setTimeout(poll, 1000);
    }
    poll();
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
      if (choices.some((row) => row.public_id === selected)) runner.value = selected;
      create.disabled = busy || !choices.length;
      if (!choices.length) failure.show(t("terminals.unavailable"));
      const rows = page.terminals.map((row) => {
        const openButton = button({
          label: `${row.created_at} · ${statusText(row.status)}`, size: "sm",
          onClick: () => open({ public_id: row.public_id, task_key: row.task_key, workspace_public_id: row.workspace_public_id }),
        });
        openButton.dataset.terminalId = row.public_id;
        return openButton;
      });
      cursor ? history.append(...rows) : history.replaceChildren(...rows);
      after = page.after;
      older.hidden = !page.has_more;
    } catch (problem) { error(problem); }
  }
  load();
  return { element, dispose() { reads.abort(); clearTimeout(timer); terminal?.dispose(); } };
}

export function register(ui, shell) {
  ui.slots.register("dock.tab", { key: "terminals", title: () => t("terminals.title"), description: () => t("terminals.guide"), icon: "tool" },
    (props) => {
      let workspace = props.conversation.workspace;
      let panel = terminalsPanel(shell, props);
      const element = el("div", {}, panel.element);
      return { element,
        update(next) {
          if (next.conversation.workspace === workspace) return;
          workspace = next.conversation.workspace;
          panel.dispose();
          panel = terminalsPanel(shell, next);
          element.replaceChildren(panel.element);
        },
        dispose() { panel.dispose(); },
      };
    });
  ui.slots.register("conversation.header.utilities", { id: "terminals", order: 15 }, () => ({
    element: button({ label: t("terminals.title"), size: "sm", onClick: () => shell.dock.open("terminals") }),
  }));
}
