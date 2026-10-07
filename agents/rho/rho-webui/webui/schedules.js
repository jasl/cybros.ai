import { el, stamp } from "./views.js";
import { Submissions } from "./lifecycle.js";

const button = (text, onclick, attrs = {}) => el("button", { type: "button", text, onclick, ...attrs });
const field = (text, control) => el("label", {}, text, control);
const query = (path, values) => `${path}?${new URLSearchParams(values)}`;
const path = "/conversations/schedules";
const pending = new Submissions();

function timestamp(value) {
  if (!/(Z|[+-]\d{2}:\d{2})$/i.test(value) || Number.isNaN(Date.parse(value))) {
    throw new Error("Use an ISO date and time with a time zone, such as 2026-10-02T09:00:00+08:00.");
  }
  return new Date(value).toISOString();
}

export function scheduledRule(kind, { at, seconds, localTime, timeZone }) {
  switch (kind) {
    case "once": return { kind, run_at: timestamp(at.trim()) };
    case "interval": {
      const every_seconds = Number(seconds);
      if (!Number.isSafeInteger(every_seconds) || every_seconds <= 0) throw new Error("The interval must be a positive number of seconds.");
      return { kind, every_seconds, starts_at: timestamp(at.trim()) };
    }
    case "daily":
      if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(localTime)) throw new Error("Use a daily time in HH:MM format.");
      new Intl.DateTimeFormat("en", { timeZone });
      return { kind, local_time: localTime, time_zone: timeZone };
    default: throw new Error("Choose a schedule.");
  }
}

export function scheduledRuleText(rule) {
  switch (rule.kind) {
    case "once": return `Once · ${stamp(rule.run_at)}`;
    case "interval": return `Every ${rule.every_seconds} seconds · first ${stamp(rule.starts_at)}`;
    case "daily": return `Daily · ${rule.local_time} ${rule.time_zone}`;
    default: return rule.kind;
  }
}

export function scheduledJobChanges(observed, edited) {
  return Object.fromEntries(Object.entries(edited).filter(([name, value]) => JSON.stringify(value) !== JSON.stringify(observed[name])));
}

// The panel owns its draft and observed version. Conversation refreshes never
// replace its form; navigating away aborts reads and removes the panel.
export function openSchedules({ shell, call, target, signal, active, writable, model, approvalMode, onError, openConversation }) {
  const drafts = new Map();
  const alert = el("p", { class: "bad", role: "alert", tabindex: "-1", hidden: true });
  const list = el("div", { class: "scheduled-list" });
  const editor = el("div");
  const history = el("div", { class: "scheduled-history" });
  const more = button("More jobs", () => load(nextAfter), { hidden: true });
  let nextAfter = null;
  let closed = false;
  let busy = false;
  let listRead = 0;
  let historyRead = 0;
  const dialog = el("dialog", { class: "task-dialog scheduled-dialog", "aria-label": "Scheduled jobs" },
    el("div", { class: "execution-row" }, el("h2", { text: "Scheduled jobs" }),
      button("Close", () => dialog.close())),
    el("p", { class: "muted", text: "Each execution works in a fresh conversation and reports back here. Pause or cancel prevents future executions; use Stop in an execution to stop its current work." }),
    alert, el("div", { class: "execution-row" },
      button("New scheduled job", () => edit(), { disabled: !writable() }), button("Refresh jobs", () => load())), editor, list, more, history);
  const alive = () => !closed && active();
  const error = (failure) => {
    if (!alive() || failure.name === "AbortError") return;
    alert.hidden = false;
    alert.textContent = failure.code === "stale_object"
      ? "This job changed. Your draft is kept. Refresh jobs, then open Edit again to use its current version."
      : failure.message || "The request failed. Retry to use the same creation key.";
    alert.focus();
    if ([401, 403, 404].includes(failure.status) || failure.code === "ingress_bound") onError(failure);
  };
  const read = (suffix, values = {}) => call(query(`${path}${suffix}`, { ...target, ...values }), { signal, conversation: target.public_id });
  async function write(operation, body) {
    if (busy || !alive() || !writable()) return null;
    busy = true;
    for (const control of dialog.querySelectorAll("button,input,select,textarea")) control.disabled = true;
    try {
      const answer = await call(`${path}/${operation}`, { method: "POST", body, signal, conversation: target.public_id });
      if (!alive()) return null;
      alert.hidden = true;
      return answer;
    } catch (failure) { error(failure); return null; }
    finally {
      busy = false;
      for (const control of dialog.querySelectorAll("button,input,select,textarea")) {
        control.disabled = control.dataset.mutation === "true" && !writable();
      }
    }
  }
  function row(job) {
    const editable = ["active", "paused"].includes(job.status);
    const controls = el("div", { class: "execution-row" },
      editable && button("Edit", () => edit(job), { disabled: !writable(), "data-mutation": "true" }),
      button("Executions", () => executions(job)));
    for (const operation of job.status === "active" ? ["pause", "cancel"] : job.status === "paused" ? ["resume", "cancel"] : []) {
      controls.append(button(operation[0].toUpperCase() + operation.slice(1), async () => {
        if (await write(operation, { ...target, job_public_id: job.public_id })) await load();
      }, { disabled: !writable(), "data-mutation": "true" }));
    }
    return el("article", { class: "scheduled-job" },
      el("h3", { text: job.name || job.prompt.split("\n")[0] }),
      el("p", { class: "muted", text: `Schedule: ${job.status} · Next: ${stamp(job.next_run_at) || "none"}` }),
      el("p", { text: scheduledRuleText(job.rule) }), el("p", { class: "scheduled-prompt", text: job.prompt }),
      job.last_execution && el("p", { text: `Latest execution: ${job.last_execution.status}` }),
      job.last_error_code && el("p", { class: "bad", text: `Last error: ${job.last_error_code}` }), controls);
  }
  async function load(after) {
    const reading = ++listRead;
    try {
      const answer = await read("", { limit: 20, ...(after ? { after } : {}) });
      if (!alive() || reading !== listRead) return;
      if (!after) list.replaceChildren();
      for (const job of answer.schedules) list.append(row(job));
      if (!after && !answer.schedules.length) list.append(el("p", { class: "muted", text: "No scheduled jobs yet." }));
      nextAfter = answer.pagination.next_after; more.hidden = !nextAfter;
    } catch (failure) { error(failure); }
  }
  async function executions(job, after) {
    const reading = ++historyRead;
    try {
      const answer = await read("/executions", { job_public_id: job.public_id, limit: 20, ...(after ? { after } : {}) });
      if (!alive() || reading !== historyRead) return;
      if (!after) history.replaceChildren(el("h3", { text: `Executions · ${job.name || job.prompt.split("\n")[0]}` }));
      history.querySelector(".more-executions")?.remove();
      if (!after && !answer.executions.length) history.append(el("p", { text: "No executions yet." }));
      for (const execution of answer.executions) {
        history.append(el("div", { class: "execution-row" },
          el("span", { text: `${stamp(execution.scheduled_for)} · ${execution.status}` }),
          button("Open execution", () => openConversation(execution.child_conversation_public_id))));
      }
      if (answer.pagination.next_after) history.append(button("More executions", () => executions(job, answer.pagination.next_after), { class: "more-executions" }));
    } catch (failure) { error(failure); }
  }
  function edit(job = null) {
    if (!writable() || busy) return;
    const rule = job?.rule || { kind: "once" };
    const name = el("input", { name: "name", value: job?.name || "" });
    const prompt = el("textarea", { name: "prompt", rows: 4, required: true }); prompt.value = job?.prompt || "";
    const kind = el("select", { name: "schedule", onchange: () => showRule() },
      ...[["once", "Once"], ["interval", "Every interval"], ["daily", "Daily"]].map(([value, text]) => el("option", { value, text, selected: rule.kind === value })));
    const at = el("input", { name: "at", value: rule.run_at || rule.starts_at || new Date(Date.now() + 1_800_000).toISOString() });
    const seconds = el("input", { name: "seconds", type: "number", min: 1, step: 1, value: rule.every_seconds || 3600 });
    const localTime = el("input", { name: "local_time", type: "time", value: rule.local_time || "09:00" });
    const timeZone = el("input", { name: "time_zone", value: rule.time_zone || Intl.DateTimeFormat().resolvedOptions().timeZone });
    const selectedModel = el("input", { name: "model", required: true, value: job?.model?.model || model() });
    const approval = el("select", { name: "approval" }, ...[["ask", "Ask before effects"], ["bypass", "Allow effects"], ["rules", "Use approval rules"]]
      .map(([value, text]) => el("option", { value, text, selected: value === (job?.approval_mode || approvalMode()) })));
    const atField = field("First run (ISO date, time and zone)", at);
    const secondsField = field("Interval in seconds", seconds);
    const dailyFields = el("div", { class: "scheduled-fields" }, field("Daily time", localTime), field("Time zone (IANA)", timeZone));
    function showRule() { atField.hidden = kind.value === "daily"; secondsField.hidden = kind.value !== "interval"; dailyFields.hidden = kind.value !== "daily"; }
    function fields() {
      const chosenModel = selectedModel.value.trim();
      return { name: name.value.trim() || null, prompt: prompt.value,
        rule: scheduledRule(kind.value, { at: at.value, seconds: seconds.value, localTime: localTime.value, timeZone: timeZone.value.trim() }),
        model: chosenModel, approval_mode: approval.value,
        ...(job?.model?.model === chosenModel && job.model.reasoning_effort ? { reasoning_effort: job.model.reasoning_effort } : {}) };
    }
    // Compare what the form displayed, so formatting an unchanged instant or
    // displaying an inherited approval choice cannot silently revise policy.
    const observed = job ? fields() : null;
    const form = el("form", { class: "scheduled-editor", onsubmit: async (event) => {
      event.preventDefault();
      if (busy || !writable()) return;
      try {
        const edited = fields();
        const body = { ...target, ...(job ? scheduledJobChanges(observed, edited) : edited) };
        const submission = job ? null : pending.prepare(`${path}/create`, body);
        const result = await write(job ? "update" : "create", job
          ? { ...body, job_public_id: job.public_id, expected_lock_version: job.lock_version } : submission.body);
        if (result) { if (submission) pending.accepted(submission, drafts); editor.replaceChildren(); await load(); }
      } catch (failure) { error(failure); }
    } }, el("h3", { text: job ? "Edit scheduled job" : "New scheduled job" }),
      field("Name (optional)", name), field("Task", prompt), field("Schedule", kind), atField, secondsField, dailyFields,
      field("Model", selectedModel), field("Approval mode", approval),
      el("div", { class: "execution-row" }, el("button", { type: "submit", class: "primary", text: job ? "Save changes" : "Create job" }),
        button("Discard draft", () => editor.replaceChildren())));
    for (const control of form.querySelectorAll("button,input,select,textarea")) control.dataset.mutation = "true";
    showRule(); editor.replaceChildren(form); prompt.focus();
  }
  const abort = () => dialog.close();
  dialog.addEventListener("close", () => { closed = true; signal.removeEventListener("abort", abort); dialog.remove(); }, { once: true });
  signal.addEventListener("abort", abort, { once: true });
  dialog.querySelectorAll("button")[1].dataset.mutation = "true";
  shell.append(dialog); dialog.showModal(); load();
  return dialog;
}
