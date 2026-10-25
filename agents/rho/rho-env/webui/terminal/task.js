import { terminalPanel } from "./panel.js";

// Attaching to an existing task never creates an independent shell Run.
export function taskTerminal(ui, t, initialProps) {
  let props = initialProps, terminal;
  const actions = ui.el("span");
  props.actions.append(actions);
  const screen = ui.el("div");
  const open = ui.primitives.button({ label: t("terminal.open"), size: "sm", onClick() {
    terminal = terminalPanel(ui, t, { call: ui.call, target: props.target });
    actions.replaceChildren(terminal.stop);
    screen.replaceChildren(terminal.element);
    open.hidden = true;
  } });
  const element = ui.el("section", {}, open, screen);
  function update(next) {
    props = next;
    open.hidden = !!terminal || props.task?.kind !== "tool_task" || !["running", "dispatched"].includes(props.task.status);
    if (terminal && ui.isTerminal(props.task?.status)) terminal.finish();
  }
  update(props);
  return { element, update, dispose() { terminal?.dispose(); actions.remove(); } };
}
