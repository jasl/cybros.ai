import { el } from "../../kernel/dom.js";
import { t, statusText, locale } from "../../kernel/i18n.js";
import { paintModels } from "../../primitives/model_choices.js";
import { stamp } from "../../kernel/format.js";
import { changedFields } from "../../kernel/forms.js";
import { iconButton, alert, button, emptyState, field, input, select, textarea } from "../../primitives/index.js";

const PATH = "/conversations/schedules";
const PAGE = 20;
const query = (path, values) => `${path}?${new URLSearchParams(values)}`;

function timestamp(value) {
  if (!/(Z|[+-]\d{2}:\d{2})$/i.test(value) || Number.isNaN(Date.parse(value))) throw new Error(t("schedules.use_an_iso_date_and_time_with_a"));
  return new Date(value).toISOString();
}

// One-time and interval instants carry an explicit zone; a daily rule keeps
// its local civil time and the named IANA zone.
export function scheduledRule(kind, { at, seconds, localTime, timeZone }) {
  switch (kind) {
    case "once": return { kind, run_at: timestamp(at.trim()) };
    case "interval": {
      const every_seconds = Number(seconds);
      if (!Number.isSafeInteger(every_seconds) || every_seconds <= 0) throw new Error(t("schedules.the_interval_must_be_a_positive_number_of"));
      return { kind, every_seconds, starts_at: timestamp(at.trim()) };
    }
    case "daily":
      if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(localTime)) throw new Error(t("schedules.use_a_daily_time_in_hh_mm_format"));
      new Intl.DateTimeFormat(locale, { timeZone });
      return { kind, local_time: localTime, time_zone: timeZone };
    default: throw new Error(t("schedules.choose_a_schedule"));
  }
}

export function scheduledRuleText(rule) {
  switch (rule.kind) {
    case "once": return t("schedules.once_2", { stamp: stamp(rule.run_at) });
    case "interval": return t("schedules.every_seconds_first", { every_seconds: rule.every_seconds, stamp: stamp(rule.starts_at) });
    case "daily": return t("schedules.daily_2", { local_time: rule.local_time, time_zone: rule.time_zone });
    default: return rule.kind;
  }
}

export const operationLabel = (operation) => ({ run: t("schedules.action_run"), pause: t("schedules.action_pause"), resume: t("schedules.action_resume"), cancel: t("schedules.action_cancel") })[operation];
// Each command's glyph, distinct from the others': run plays, resume puts the clock back, pause and cancel are themselves.
export const operationIcon = (operation) => ({ run: "play", pause: "pause", resume: "restore", cancel: "close" })[operation];
// The lifecycle commands a job in `status` offers, in display order. Run
// starts one execution now and leaves the clock alone.
export const operationsFor = (status) => (status === "active" ? ["run", "pause", "cancel"] : status === "paused" ? ["run", "resume", "cancel"] : []);
const approvals = () => [{ value: "ask", label: t("common.ask_before_changes") }, { value: "rules", label: t("common.rules_only") },
  { value: "bypass", label: t("common.bypass_permissions") }];

// The scheduled jobs of the shown conversation, as a dock tab. The tab owns
// its draft and the job version it observed; conversation refreshes never
// replace its form, and leaving the conversation disposes it.
export function schedulesPanel(shell, initialProps, { creates }) {
  let props = initialProps;
  let selectedJob = props.params?.job || null;
  const reads = new AbortController();
  const conversation = () => props.conversation;
  const target = () => ({ public_id: conversation().id, ...(conversation().workspace ? { workspace_public_id: conversation().workspace } : {}) });
  const writable = () => conversation().writable;
  const failure = alert({ tone: "error" });
  failure.element.setAttribute("tabindex", "-1");
  const editor = el("div", { class: "schedules__editor" });
  const list = el("div", { class: "schedules__list" });
  const history = el("div", { class: "schedules__history" });
  const more = button({ label: t("schedules.more_jobs"), variant: "ghost", size: "sm", onClick: () => load(nextAfter) });
  more.hidden = true;
  const create = button({ label: t("common.new_scheduled_job"), variant: "primary", size: "sm", icon: "plus", onClick: () => edit() });
  const all = button({ label: t("schedules.all_jobs"), variant: "ghost", size: "sm", icon: "chevron-left", onClick: () => {
    selectedJob = null;
    historyRead += 1;
    history.replaceChildren();
    load();
  } });
  all.hidden = !selectedJob;
  create.dataset.mutation = "true";
  const element = el("section", { class: "schedules", "aria-label": t("common.scheduled_jobs") },
    el("header", { class: "schedules__head" },
      el("div", { class: "schedules__toolbar" }, iconButton({ icon: "refresh", label: t("common.refresh"), onClick: () => load() }), create)),
    el("p", { class: "schedules__intro", text: t("schedules.each_execution_works_in_a_fresh_conversation_and") }),
    failure.element, all, editor, list, more, history);
  let nextAfter = null;
  let busy = false;
  let listRead = 0;
  let historyRead = 0;
  let openedCreateRequest = null;

  const alive = () => !reads.signal.aborted;
  const lock = () => { for (const control of element.querySelectorAll("button,input,select,textarea")) control.disabled = busy || (control.dataset.mutation === "true" && !writable()); };
  const mutation = (node) => { node.dataset.mutation = "true"; node.disabled = busy || !writable(); return node; };

  // A refusal of the conversation itself is the controller's to show.
  function error(problem) {
    if (!alive() || problem.name === "AbortError" || problem.status === 401) return;
    failure.show(problem.code === "stale_object" ? t("schedules.this_job_changed_your_draft_is_kept_refresh")
      : problem.message || t("schedules.the_request_failed_retry_to_use_the_same"));
    failure.element.focus();
    if ([403, 404].includes(problem.status) || problem.code === "ingress_bound") conversation().refresh();
  }
  const read = (suffix, values = {}) => shell.call(query(`${PATH}${suffix}`, { ...target(), ...values }), { signal: reads.signal, conversation: conversation().id });

  async function write(operation, body) {
    if (busy || !alive() || !writable()) return null;
    busy = true; lock();
    try {
      const answer = await shell.call(`${PATH}/${operation}`, { method: "POST", body, signal: reads.signal, conversation: conversation().id });
      if (!alive()) return null;
      failure.hide();
      return answer;
    } catch (problem) { error(problem); return null; }
    finally { busy = false; if (alive()) lock(); }
  }

  // A job's commands as icons, labelled: edit, its executions, then the
  // lifecycle commands, a cancel last.
  function row(job) {
    const name = job.name || job.prompt.split("\n")[0];
    const actions = el("div", { class: "schedule__actions" },
      ["active", "paused"].includes(job.status) ? mutation(iconButton({ icon: "rename", label: t("schedules.edit"), onClick: () => edit(job) })) : null,
      iconButton({ icon: "list", label: t("schedules.executions_2"), onClick: () => executions(job) }));
    for (const operation of operationsFor(job.status)) {
      const control = mutation(iconButton({ icon: operationIcon(operation), label: operationLabel(operation), onClick: async () => {
        if (await write(operation, { ...target(), job_public_id: job.public_id })) await load();
      } }));
      if (operation === "cancel") control.classList.add("btn--danger");
      actions.append(control);
    }
    return el("article", { class: "schedule" },
      el("h3", { class: "schedule__name", text: name }),
      el("p", { class: "schedule__meta", text: t("schedules.schedule_next", { status: statusText(job.status), next: stamp(job.next_run_at) || t("schedules.none") }) }),
      el("p", { class: "schedule__rule", text: scheduledRuleText(job.rule) }),
      el("p", { class: "schedule__prompt", text: job.prompt }),
      job.last_execution ? el("p", { class: "schedule__meta", text: t("schedules.latest_execution", { status: statusText(job.last_execution.status) }) }) : null,
      job.last_error_code ? el("p", { class: "schedule__error", text: t("schedules.last_error", { last_error_code: job.last_error_code }) }) : null,
      actions);
  }

  async function load(after) {
    const reading = ++listRead;
    const jobId = selectedJob;
    all.hidden = !jobId;
    try {
      if (jobId) {
        more.hidden = true;
        const answer = await read("/detail", { job_public_id: jobId });
        if (!alive() || reading !== listRead) return;
        list.replaceChildren(row(answer.schedule));
        await executions(answer.schedule);
        return;
      }
      const answer = await read("", { limit: PAGE, ...(after ? { after } : {}) });
      if (!alive() || reading !== listRead) return;
      if (!after) list.replaceChildren();
      list.append(...answer.schedules.map(row));
      if (!after && !answer.schedules.length) list.append(el("p", { class: "schedules__empty", text: t("schedules.no_scheduled_jobs_yet") }));
      nextAfter = answer.pagination.next_after;
      more.hidden = !nextAfter;
    } catch (problem) { if (reading === listRead) error(problem); }
  }

  // Each occurrence works in a fresh child conversation in this workspace.
  async function executions(job, after) {
    const reading = ++historyRead;
    try {
      const answer = await read("/executions", { job_public_id: job.public_id, limit: PAGE, ...(after ? { after } : {}) });
      if (!alive() || reading !== historyRead) return;
      if (!after) history.replaceChildren(el("h3", { class: "schedules__subtitle", text: t("schedules.executions", { name: job.name || job.prompt.split("\n")[0] }) }));
      history.querySelector(".schedules__more-executions")?.remove();
      if (!after && !answer.executions.length) history.append(el("p", { class: "schedules__empty", text: t("schedules.no_executions_yet") }));
      for (const execution of answer.executions) {
        history.append(el("div", { class: "schedules__execution" },
          el("span", { text: `${stamp(execution.scheduled_for)} · ${statusText(execution.status)}` }),
          button({ label: t("schedules.open_execution"), variant: "ghost", size: "sm",
            onClick: () => conversation().open(execution.child_conversation_public_id, { workspace: conversation().workspace }) })));
      }
      if (answer.pagination.next_after) {
        const next = button({ label: t("schedules.more_executions"), variant: "ghost", size: "sm", onClick: () => executions(job, answer.pagination.next_after) });
        next.classList.add("schedules__more-executions");
        history.append(next);
      }
    } catch (problem) { if (reading === historyRead) error(problem); }
  }

  function edit(job = null) {
    if (!writable() || busy) return;
    const rule = job?.rule || { kind: "once" };
    const name = input({ name: "name", value: job?.name || "" });
    const prompt = textarea({ name: "prompt", rows: 4, required: true, value: job?.prompt || "" });
    const kind = select({ name: "schedule", value: rule.kind, options: [{ value: "once", label: t("schedules.once") },
      { value: "interval", label: t("schedules.every_interval") }, { value: "daily", label: t("schedules.daily") }] });
    const instant = new Date(rule.run_at || rule.starts_at || Date.now() + 1_800_000);
    const localInstant = new Date(instant.getTime() - instant.getTimezoneOffset() * 60_000).toISOString().slice(0, 19);
    const at = input({ name: "at", type: "datetime-local", step: "1", value: localInstant });
    const seconds = input({ name: "seconds", type: "number", min: 1, step: 1, value: String(rule.every_seconds || 3600) });
    const localTime = input({ name: "local_time", type: "time", value: rule.local_time || "09:00" });
    const timeZone = input({ name: "time_zone", value: rule.time_zone || Intl.DateTimeFormat().resolvedOptions().timeZone });
    const model = select({ name: "model", required: true });
    paintModels(model, shell.setup.state.get().status?.model?.eligible || [], job?.model?.model || conversation().defaults.model, null);
    const approval = select({ name: "approval", options: approvals(), value: job?.approval_mode || conversation().defaults.approval_mode });
    const atField = field({ label: t("schedules.first_run"), control: at,
      hint: t("schedules.local_time_hint", { zone: Intl.DateTimeFormat().resolvedOptions().timeZone }) });
    const secondsField = field({ label: t("schedules.interval_in_seconds"), control: seconds });
    const daily = el("div", { class: "schedules__pair" }, field({ label: t("schedules.daily_time"), control: localTime }).element,
      field({ label: t("schedules.time_zone_iana"), control: timeZone }).element);
    const showRule = () => {
      atField.element.hidden = kind.value === "daily"; at.required = kind.value !== "daily";
      secondsField.element.hidden = kind.value !== "interval"; seconds.required = kind.value === "interval";
      daily.hidden = kind.value !== "daily"; localTime.required = timeZone.required = kind.value === "daily";
    };
    kind.addEventListener("change", showRule);
    const fields = () => {
      const chosenModel = model.value.trim();
      return { name: name.value.trim() || null, prompt: prompt.value,
        rule: scheduledRule(kind.value, { at: kind.value === "daily" ? "" : new Date(at.value).toISOString(),
          seconds: seconds.value, localTime: localTime.value, timeZone: timeZone.value.trim() }),
        model: chosenModel, approval_mode: approval.value,
        ...(job?.model?.model === chosenModel && job.model.reasoning_effort ? { reasoning_effort: job.model.reasoning_effort } : {}) };
    };
    // Compare what the form displayed, so formatting an unchanged instant or
    // displaying an inherited approval choice cannot silently revise policy.
    const observed = job ? fields() : null;
    const form = el("form", { class: "schedules__form", onsubmit: async (event) => {
      event.preventDefault();
      if (busy || !writable()) return;
      try {
        const edited = fields();
        const body = { ...target(), ...(job ? changedFields(observed, edited) : edited) };
        const submission = job ? null : creates.prepare(`${PATH}/create`, body);
        const result = await write(job ? "update" : "create", job
          ? { ...body, job_public_id: job.public_id, expected_lock_version: job.lock_version } : submission.body);
        if (result) { if (submission) creates.accepted(submission); editor.replaceChildren(); await load(); }
      } catch (problem) { error(problem); }
    } }, el("h3", { class: "schedules__subtitle", text: job ? t("schedules.edit_scheduled_job") : t("common.new_scheduled_job") }),
    field({ label: t("schedules.name_optional"), control: name }).element, field({ label: t("common.task"), control: prompt }).element,
    field({ label: t("schedules.schedule"), control: kind }).element, atField.element, secondsField.element, daily,
    field({ label: t("common.model"), control: model }).element, field({ label: t("common.permissions"), control: approval }).element,
    el("div", { class: "schedules__form-actions" },
      button({ label: job ? t("schedules.save_changes") : t("schedules.create_job"), variant: "primary", size: "sm", type: "submit" }),
      button({ label: t("schedules.discard_draft"), variant: "ghost", size: "sm", onClick: () => editor.replaceChildren() })));
    for (const control of form.querySelectorAll("button,input,select,textarea")) control.dataset.mutation = "true";
    showRule();
    editor.replaceChildren(form);
    prompt.focus();
  }

  const empty = emptyState({ icon: "clock", title: t("common.scheduled_jobs"), description: t("shell.dock_guide_needs_conversation") });
  if (conversation().id) load(); else element.replaceChildren(empty);
  lock();
  // Navigation can mount this panel before the conversation finishes loading.
  // Keep the request until its model and write permissions are available.
  function openRequestedDraft() {
    if (!props.params?.create || props.params === openedCreateRequest || !writable() || busy) return;
    openedCreateRequest = props.params;
    edit();
  }
  openRequestedDraft();
  const stopModels = shell.setup.state.subscribe(({ status }) => {
    const model = editor.querySelector("select[name=model]");
    if (model) paintModels(model, status?.model?.eligible || [], model.value || conversation().defaults.model, null);
  });
  return {
    element,
    update(next) {
      const changed = props.conversation.detail?.updated_at !== next.conversation.detail?.updated_at;
      const requested = props.params !== next.params && next.params?.job;
      const creating = props.params !== next.params && next.params?.create && selectedJob;
      props = next;
      if (!alive()) return;
      if (requested) {
        selectedJob = requested;
        editor.replaceChildren();
        historyRead += 1;
        history.replaceChildren();
        list.replaceChildren();
      }
      if (creating) {
        selectedJob = null;
        historyRead += 1;
        history.replaceChildren();
      }
      lock(); openRequestedDraft();
      // Result delivery changes the owning conversation. Re-read the jobs so
      // their execution status catches up without replacing an open draft.
      if ((changed || requested || creating) && conversation().id && !busy) load();
    },
    dispose() { stopModels(); reads.abort(); },
  };
}
