import { el, icon } from "../../kernel/dom.js";
import { t, statusText } from "../../kernel/i18n.js";
import { stamp } from "../../kernel/format.js";
import { alert, emptyState, group, iconButton, menuButton, page, skeleton, tag } from "../../primitives/index.js";
import { operationIcon, operationLabel, operationsFor, scheduledRuleText } from "./schedules.js";

const PATH = "/conversations/schedules";
const OVERVIEW = "/workspaces/schedules";
const PAGE = 100;
// The overview reads at most this many pages; a workspace with more jobs
// than that shows the newest it read and says so.
const PAGES = 5;
const RECENT_CONVERSATIONS = 8;
const query = (path, values) => `${path}?${new URLSearchParams(values)}`;

export const jobName = (job) => job.name || job.prompt.split("\n")[0];

// The three groups of the overview: what will run, what is held, what is
// over. Finished jobs stay readable.
export function shelve(jobs) {
  const shelves = { active: [], paused: [], finished: [] };
  for (const job of jobs) shelves[job.status === "active" || job.status === "paused" ? job.status : "finished"].push(job);
  const byNext = (a, b) => (a.next_run_at || "").localeCompare(b.next_run_at || "");
  shelves.active.sort(byNext);
  return shelves;
}

// A job's one-line clock: the rule, then when it next fires, or why not.
export function clockText(job) {
  if (job.status === "active" && job.next_run_at) return t("jobs_page.rule_next", { rule: scheduledRuleText(job.rule), next: stamp(job.next_run_at) });
  return scheduledRuleText(job.rule);
}

function doneText(operation, name) {
  switch (operation) {
    case "run": return t("jobs_page.done_run", { name });
    case "pause": return t("jobs_page.done_pause", { name });
    case "resume": return t("jobs_page.done_resume", { name });
    case "cancel": return t("jobs_page.done_cancel", { name });
    default: throw new Error(`Unknown schedule command ${operation}`);
  }
}

// A group of the page; one that is always shown says when it is empty.
function shelf(title, { actions = [], always = false } = {}) {
  const shelfGroup = group({ title, actions });
  const rows = el("div", { class: "jobs-page__rows" });
  shelfGroup.body.append(rows);
  shelfGroup.element.hidden = !always;
  return { element: shelfGroup.element, paint(jobs, row, empty = null) {
    shelfGroup.element.hidden = !always && !jobs.length;
    shelfGroup.setCount(jobs.length);
    rows.replaceChildren(...(jobs.length ? jobs.map(row) : empty ? [empty] : []));
  } };
}

// The Scheduled jobs page: every job of the current workspace across its
// conversations, grouped by what it will do next. Lifecycle commands act
// here; authoring stays in the job's conversation, where the model, tools
// and approval policy it inherits are visible.
export function jobsPage(shell) {
  const reads = new AbortController();
  const failure = alert({ tone: "error" });
  const loading = el("div", { class: "jobs-page__loading", "aria-hidden": "true" }, skeleton({ lines: 3 }), skeleton({ lines: 3 }));
  const empty = emptyState({ icon: "clock", title: t("jobs_page.empty_title"), description: t("jobs_page.empty_description") });
  const none = el("p", { class: "jobs-page__note text-tertiary", text: t("jobs_page.none_active") });
  const truncated = el("p", { class: "jobs-page__note text-tertiary", text: t("jobs_page.truncated", { count: PAGE * PAGES }), hidden: true });
  const refresh = iconButton({ icon: "refresh", label: t("common.refresh"), onClick: () => load() });
  // A new job is created into the Active group: its action sits on that group's head.
  const create = menuButton({ label: t("common.new_scheduled_job"), icon: "plus", variant: "button", items: () => createItems() });
  const active = shelf(t("jobs_page.active"), { actions: [create.element], always: true });
  const paused = shelf(t("jobs_page.paused"));
  const finished = shelf(t("jobs_page.finished"));
  const scaffold = page({ title: t("common.scheduled_jobs"), description: t("jobs_page.description"), actions: [refresh] });
  scaffold.body.append(failure.element, loading, active.element, paused.element, finished.element, truncated);
  let reading = 0;
  let busy = null;
  let visible = true;
  let jobs = null;

  const alive = () => !reads.signal.aborted;
  const workspace = () => shell.workspaces.current();
  const target = (job) => ({ public_id: job.conversation_public_id, ...(workspace() ? { workspace_public_id: workspace() } : {}) });
  const openConversation = (id) => shell.conversations.select(id, { workspace: workspace() });

  function error(problem) {
    if (!alive() || problem.name === "AbortError" || problem.status === 401) return;
    failure.show(problem.code === "execution_in_progress" ? t("jobs_page.execution_in_progress") : problem.message || t("jobs_page.load_failed"));
  }

  // A job is authored inside the conversation it reports to: pick one of
  // the workspace's recent conversations and the dock opens its editor.
  function createItems() {
    const rows = shell.conversations.list.get().rows
      .filter((row) => !workspace() || !row.workspace_public_id || row.workspace_public_id === workspace())
      .slice(0, RECENT_CONVERSATIONS);
    if (!rows.length) return [{ type: "title", label: t("jobs_page.create_needs_conversation") }];
    return [{ type: "title", label: t("jobs_page.create_in") }, ...rows.map((row) => ({ type: "item", label: row.title || t("conversation.untitled"),
      onSelect: () => { openConversation(row.public_id); shell.dock.open("schedules", { params: { create: true } }); } }))];
  }

  async function write(job, operation) {
    if (busy || !alive()) return;
    busy = job.public_id;
    paint();
    try {
      await shell.call(`${PATH}/${operation}`, { method: "POST", body: { ...target(job), job_public_id: job.public_id }, signal: reads.signal });
      if (!alive()) return;
      failure.hide();
      shell.toast(doneText(operation, jobName(job)), { tone: "success" });
    } catch (problem) { error(problem); }
    finally { busy = null; }
    await load();
  }

  function row(job) {
    const name = el("button", { type: "button", class: "jobs-page__name", text: jobName(job), onclick: () => {
      openConversation(job.conversation_public_id);
      shell.dock.open("schedules", { params: { job: job.public_id } });
    } });
    const where = el("button", { type: "button", class: "jobs-page__where", text: job.conversation_title || t("jobs_page.open_conversation"),
      onclick: () => openConversation(job.conversation_public_id) });
    // The group says active or paused; a finished job's row says how it ended.
    const marks = el("span", { class: "jobs-page__marks" },
      job.status !== "active" && job.status !== "paused" ? tag({ tone: "neutral", text: statusText(job.status) }) : null,
      job.last_error_code ? tag({ tone: "danger", text: t("schedules.last_error", { last_error_code: job.last_error_code }) }) : null);
    const execution = job.last_execution
      ? el("button", { type: "button", class: "jobs-page__execution", text: t("schedules.latest_execution", { status: statusText(job.last_execution.status) }),
        onclick: () => openConversation(job.last_execution.child_conversation_public_id) })
      : null;
    // The row's commands as icons, labelled; a cancel is the row's last.
    const actions = el("div", { class: "jobs-page__actions" });
    for (const operation of operationsFor(job.status)) {
      const control = iconButton({ label: operationLabel(operation), icon: operationIcon(operation),
        disabled: !!busy, onClick: () => write(job, operation) });
      control.dataset.operation = operation;
      if (operation === "cancel") control.classList.add("btn--danger");
      actions.append(control);
    }
    return el("article", { class: "jobs-page__job", "data-job-id": job.public_id },
      el("span", { class: "jobs-page__glyph", "aria-hidden": "true" }, icon(job.status === "paused" ? "pause" : "clock")),
      el("div", { class: "jobs-page__text" },
        el("div", { class: "jobs-page__head" }, name, marks),
        el("p", { class: "jobs-page__prompt", text: job.prompt }),
        el("p", { class: "jobs-page__clock" }, icon("clock"), el("span", { text: clockText(job) })),
        el("p", { class: "jobs-page__meta" }, where, execution)),
      actions);
  }

  function paint() {
    if (!jobs) return;
    const shelves = shelve(jobs);
    loading.hidden = true;
    active.paint(shelves.active, row, jobs.length ? none : empty);
    paused.paint(shelves.paused, row);
    finished.paint(shelves.finished, row);
  }

  // Every page of the overview, newest-first is not promised: the kernel
  // orders by job id, so the page sorts its shelves itself.
  async function load() {
    const version = ++reading;
    try {
      await shell.workspaces.ready?.();
      if (!alive() || version !== reading) return;
      const read = [];
      let after = null;
      for (let count = 0; count < PAGES; count += 1) {
        const values = { limit: PAGE, ...(workspace() ? { workspace_public_id: workspace() } : {}), ...(after ? { after } : {}) };
        const answer = await shell.call(query(OVERVIEW, values), { signal: reads.signal });
        if (!alive() || version !== reading) return;
        read.push(...answer.schedules);
        after = answer.pagination.next_after;
        if (!after) break;
      }
      truncated.hidden = !after;
      jobs = read;
      failure.hide();
      paint();
    } catch (problem) {
      if (version !== reading) return;
      loading.hidden = true;
      error(problem);
    }
  }

  let shownWorkspace = workspace();
  const stops = [
    shell.workspaces.state.subscribe((value) => {
      if (value.current === shownWorkspace) return;
      shownWorkspace = value.current;
      jobs = null;
      loading.hidden = false;
      if (visible) load();
    }),
  ];
  load();
  return {
    element: scaffold.element,
    update({ visible: shown }) { if (shown && (!visible || !jobs)) load(); visible = !!shown; },
    dispose() { reads.abort(); create.dispose(); for (const stop of stops) stop(); },
  };
}
