import { statusText, t } from "./i18n.js";
import { el, isTerminal, isUnresolvedFailure } from "./views.js";

// The daemon derives the site rule from the held input when the person acts.
export function approvalControls(ask, onAction) {
  const site = ask.tool_name === "web_fetch";
  const action = (text, path, body = {}) => el("button", { type: "button", text,
    onclick: () => onAction(path, body) });
  return el("div", { class: "approval-controls" },
    el("p", { text: ask.tool_name || t("controls.tool_action") }),
    el("pre", { text: JSON.stringify(ask.tool_input, null, 2) }),
    action(t("controls.approve"), "/runs/approve"),
    site ? action(t("controls.allow_this_site_until_restart"), "/runs/approve", { always: true }) : null,
    action(t("controls.deny"), "/runs/deny"),
    site ? el("p", { class: "muted", text:
      t("controls.site_policy") }) : null);
}

export function approvalNotice(result) {
  return result.grant?.refused
    ? t("controls.this_request_was_approved_but_permission_for_this")
    : null;
}

// A failed task is actionable only until a resolution or its authored absorb
// policy accounts for it. Nexus rechecks the decision when the person acts.
export function executionControls(snapshot, onAction) {
  if (!snapshot?.run_public_id) return null;
  const held = (snapshot.tasks || []).filter(isUnresolvedFailure);
  const active = snapshot.run_status && !isTerminal(snapshot.run_status);
  if (!active && !held.length) return null;

  const controls = el("section", { class: "execution-controls", "aria-label": t("controls.execution_controls") });
  const error = el("p", { class: "bad", role: "alert", hidden: true });
  let busy = false;
  const action = (label, path, body = {}) => el("button", {
    type: "button", text: label, onclick: async () => {
      if (busy) return;
      busy = true; error.hidden = true;
      for (const button of controls.querySelectorAll("button")) button.disabled = true;
      try { await onAction(path, { public_id: snapshot.run_public_id, ...body }); }
      catch (failure) { error.textContent = failure.message; error.hidden = false; }
      finally {
        busy = false;
        for (const button of controls.querySelectorAll("button")) button.disabled = false;
      }
    },
  });
  if (active) {
    const paused = snapshot.run_status === "paused";
    controls.append(el("div", { class: "execution-row" },
      el("span", { class: "muted", text: paused ? t("controls.execution_paused") : t("controls.execution_in_progress") }),
      paused ? action(t("controls.resume"), "/runs/resume") : action(t("controls.pause"), "/runs/pause")));
  }
  for (const task of held) {
    controls.append(el("div", { class: "execution-row" },
      el("span", { class: "warn", text: t("controls.step", { task_key: task.task_key, value2: statusText(task.status) }) }),
      action(t("controls.retry_failed_step"), "/runs/retry", { task_key: task.task_key }),
      action(t("controls.abandon_failed_step"), "/runs/abandon", { task_key: task.task_key })));
    if (task.error_key === "provider_context_overflow") {
      controls.append(el("p", { class: "warn", text: t("errors.provider_context_overflow") }));
    }
  }
  controls.append(error);
  return controls;
}
