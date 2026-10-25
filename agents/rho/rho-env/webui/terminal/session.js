import { terminalPanel } from "./panel.js";

// One Dock instance keeps one accepted target, including across remounts.
export function terminalSession(ui, t, props) {
  const { el, isTerminal } = ui;
  const { button, alert } = ui.primitives;
  const reads = new AbortController();
  const failure = alert({ tone: "error" });
  const status = el("p", { role: "status", text: t("terminals.starting") });
  const host = el("div", { class: "terminal-session__host" });
  const retry = button({ label: t("terminals.retry"), size: "sm", onClick: () => { creation = start(); } });
  retry.hidden = true;
  const element = el("section", { class: "terminal-session" }, status, failure.element, retry, host);
  let target = props.params.target, terminal, timer, starting = false, ended = false, closeFailed = false;
  const call = (path, options = {}) => ui.call(path, { ...options,
    signal: options.signal ? AbortSignal.any([reads.signal, options.signal]) : reads.signal });
  function showError(problem) { if (!reads.signal.aborted && problem.name !== "AbortError") failure.show(problem.message); }
  async function poll() {
    try {
      const { task } = await call(`/runs/task?${new URLSearchParams(target)}`);
      if (reads.signal.aborted) return;
      if (!closeFailed || isTerminal(task.status)) failure.hide();
      if (isTerminal(task.status)) {
        const stopped = ["canceled", "cancelled", "stopped"].includes(task.status);
        const message = t(stopped ? "terminal.stopped" : task.status === "failed" ? "terminals.failed" : "terminal.ended");
        ended = true;
        terminal?.finish();
        status.hidden = true;
        props.updateParams({ ...props.params, target, status: message });
        if (task.error && !stopped) failure.show(task.error.message || task.error.key);
        return;
      }
      status.textContent = task.status === "needs_approval" ? t("terminals.approval") : t("terminals.starting");
      if (["running", "dispatched"].includes(task.status) && !terminal) {
        terminal = terminalPanel(ui, t, { call, target, stopRun: true });
        host.replaceChildren(terminal.element);
        status.hidden = true;
      }
    } catch (problem) { showError(problem); }
    if (!reads.signal.aborted) timer = setTimeout(poll, 1000);
  }
  async function start() {
    if (starting) return;
    starting = true; retry.hidden = true; failure.hide();
    try {
      if (!target) {
        const result = await call("/terminals", { method: "POST", body: props.params.intent });
        target = result.terminal;
        // Retain the accepted identity even if the conversation changed during IO.
        props.updateParams({ ...props.params, target });
      }
      if (reads.signal.aborted) return;
      element.dataset.terminalId = target.public_id;
      poll();
    } catch (problem) { showError(problem); retry.hidden = false; }
    finally { starting = false; }
  }
  let creation = start();
  props.beforeClose(async () => {
    await creation;
    // Resolve an uncertain create with its original idempotency key before Stop.
    if (!target) { creation = start(); await creation; }
    if (!target) return false;
    if (ended) return true;
    closeFailed = false; failure.hide();
    try {
      await call("/stop", { method: "POST", body: { ...target, task_key: undefined, host_type: "run", force: true } });
      return true;
    } catch (problem) { closeFailed = true; showError(problem); return false; }
  });
  return { element, update() {}, dispose() { reads.abort(); clearTimeout(timer); terminal?.dispose(); } };
}
