import { el, icon } from "../../kernel/dom.js";
import { t, statusText } from "../../kernel/i18n.js";
import { isTerminal } from "../../kernel/format.js";
import { alert, button, emptyState, iconButton } from "../../primitives/index.js";

const query = (path, values) => `${path}?${new URLSearchParams(values)}`;
// Authored, and nothing spent on it yet: the task waits on a dependency or
// on a person's approval.
const PRE_START = ["waiting", "needs_approval"];
// What the conversation has in flight, read off the follower snapshot: the
// current run's live tasks and the subagents (child conversations) it
// spawned, busy or idle.
export function backgroundWork(state) {
  const snapshot = state?.snapshot || null;
  const tasks = (snapshot?.tasks || []).filter((task) => !isTerminal(task.status));
  const children = snapshot?.children || [];
  return {
    runId: snapshot?.run_public_id || null,
    running: tasks.filter((task) => !PRE_START.includes(task.status)),
    waiting: tasks.filter((task) => PRE_START.includes(task.status)),
    busy: children.filter((child) => child.busy),
    idle: children.filter((child) => !child.busy),
  };
}

export const workCount = (work) => work.running.length + work.busy.length;

// A task's name: the tool it calls once the task read answered, else the
// kernel's node kind (`contracts/nexus/v1/runs.json`) in a person's words.
export function kindText(task, detail) {
  if (detail?.tool_name) return detail.tool_name;
  switch (task.kind) {
    case "model_task": return t("background.kind_model");
    case "tool_task": return t("background.kind_tool");
    case "delegation_task": return t("background.kind_delegation");
    case "await_task": return t("background.kind_await");
    case "join_task": return t("background.kind_join");
    default: return task.kind || t("common.task");
  }
}

// A spawned child carries the label its parent gave it; a scheduled
// execution has none and goes by its title.
const childName = (child) => child.label || child.title || child.public_id;

// The side-panel tab: everything the conversation is doing in the
// background, each with its own Stop, and Stop all work above them. Tool
// names arrive from the task read once per key; the snapshot carries keys,
// kinds and statuses, never tool names.
function backgroundPanel(shell, initialProps) {
  let props = initialProps;
  const reads = new AbortController();
  const names = new Map();
  const failure = alert({ tone: "error" });
  const stopAll = button({ label: t("conversation.stop_all"), variant: "danger", size: "sm", icon: "stop", onClick: () => shell.conversations.stop() });
  const body = el("div", { class: "background__body" });
  const element = el("section", { class: "background", "aria-label": t("background.title") },
    el("header", { class: "background__head" }, stopAll),
    failure.element, body);
  let busy = null;

  const alive = () => !reads.signal.aborted;
  const state = () => shell.conversations.state.get();
  const target = (id) => ({ public_id: id, host_type: "conversation", ...(state().workspace ? { workspace_public_id: state().workspace } : {}) });

  function error(problem) {
    if (!alive() || problem.name === "AbortError" || problem.status === 401) return;
    failure.show(problem.code === "not_a_branch" ? t("background.not_a_branch") : problem.message || t("conversation.request_failed"));
  }

  async function stop(key, body) {
    if (busy || !alive()) return;
    busy = key;
    paint();
    try {
      await shell.call("/stop", { method: "POST", body, signal: reads.signal, conversation: state().id });
      if (!alive()) return;
      failure.hide();
    } catch (problem) { error(problem); }
    finally { busy = null; }
    shell.conversations.refresh();
  }

  // One read per task key: the name is stable for the task's lifetime.
  function resolveName(task) {
    const { id, workspace } = state();
    const work = backgroundWork(state());
    if (!work.runId || names.has(task.task_key)) return;
    names.set(task.task_key, null);
    const values = { public_id: work.runId, task_key: task.task_key, ...(workspace ? { workspace_public_id: workspace } : {}) };
    shell.call(query("/runs/task", values), { signal: reads.signal, conversation: id })
      .then(({ task: detail }) => { if (alive()) { names.set(task.task_key, detail); paint(); } })
      .catch(() => { if (alive()) names.delete(task.task_key); });
  }

  const stopButton = (key, label, body) => {
    const control = iconButton({ icon: "stop", label, onClick: () => stop(key, body) });
    control.disabled = !!busy || !props.conversation.writable;
    return control;
  };

  function taskRow(task, { stoppable }) {
    resolveName(task);
    const name = kindText(task, names.get(task.task_key));
    return el("div", { class: "background__row", "data-task-key": task.task_key },
      el("span", { class: "background__glyph" }, icon(task.kind === "model_task" ? "spark" : "tool")),
      el("span", { class: "background__text" }, el("span", { class: "background__name", text: name }),
        el("span", { class: "background__meta", text: `${task.task_key} · ${statusText(task.status)}` })),
      stoppable ? stopButton(task.task_key, t("background.stop_task", { name }), { ...target(state().id), task_key: task.task_key }) : null);
  }

  function childRow(child, { stoppable }) {
    const open = el("button", { type: "button", class: "background__name background__name--link", text: childName(child),
      onclick: () => props.conversation.open(child.public_id, { workspace: state().workspace }) });
    return el("div", { class: "background__row", "data-child-id": child.public_id },
      el("span", { class: "background__glyph" }, icon("user")),
      el("span", { class: "background__text" }, open,
        el("span", { class: "background__meta", text: stoppable ? t("background.subagent_working") : t("background.subagent_idle") })),
      stoppable ? stopButton(child.public_id, t("background.stop_subagent", { name: childName(child) }), { ...target(child.public_id), force: true }) : null);
  }

  const group = (title, rows) => (rows.length ? el("section", { class: "background__group" }, el("h3", { class: "background__group-title", text: title }), ...rows) : null);

  function paint() {
    const current = state();
    const work = backgroundWork(current);
    stopAll.hidden = !current.id || !current.detail?.active_turn_public_id;
    stopAll.disabled = !!current.stopping || !props.conversation.writable;
    if (!current.id) { body.replaceChildren(emptyState({ icon: "list", title: t("background.title"), description: t("shell.dock_guide_needs_conversation") })); return; }
    const sections = [
      group(t("background.running"), [...work.busy.map((child) => childRow(child, { stoppable: true })), ...work.running.map((task) => taskRow(task, { stoppable: true }))]),
      group(t("background.waiting"), work.waiting.map((task) => taskRow(task, { stoppable: true }))),
      group(t("background.idle_subagents"), work.idle.map((child) => childRow(child, { stoppable: false }))),
    ].filter(Boolean);
    body.replaceChildren(...(sections.length ? sections : [emptyState({ icon: "list", title: t("background.nothing_running"), description: t("background.guide") })]));
  }

  const stops = [shell.conversations.state.subscribe(paint)];
  paint();
  return {
    element,
    update(next) { props = next; paint(); },
    dispose() { reads.abort(); for (const stop of stops) stop(); },
  };
}

// The header button: a count of what runs in the background, when anything does.
function backgroundButton(shell, initialProps) {
  const count = el("span", { class: "background-chip__count" });
  const element = el("button", { type: "button", class: "chip background-chip", onclick: () => shell.dock.open("background") }, icon("list"), count);
  let conversation = initialProps.conversation;
  const paint = () => {
    const work = backgroundWork(shell.conversations.state.get());
    const total = workCount(work);
    element.hidden = !conversation.id || conversation.access === "unavailable";
    count.textContent = String(total);
    count.hidden = !total;
    element.setAttribute("aria-label", t("background.chip_label", { count: total }));
    element.dataset.tip = t("background.title");
  };
  const stop = shell.conversations.state.subscribe(paint);
  paint();
  return { element, update(next) { conversation = next.conversation; paint(); }, dispose: stop };
}

export function register(ui, shell) {
  ui.slots.register("dock.tab", { key: "background", title: () => t("background.title"), description: () => t("background.guide"), icon: "list" },
    (props) => backgroundPanel(shell, props));
  ui.slots.register("conversation.header.utilities", { id: "background", order: 10 }, (props) => backgroundButton(shell, props));
}
