import { el, isTerminal } from "./views.js";

// The daemon derives the site rule from the held input when the person acts.
export function approvalControls(ask, onAction) {
  const site = ask.tool_name === "web_fetch";
  const action = (text, path, body = {}) => el("button", { type: "button", text,
    onclick: () => onAction(path, body) });
  return el("div", { class: "approval-controls" },
    el("p", { text: ask.tool_name || "Tool action" }),
    el("pre", { text: JSON.stringify(ask.tool_input, null, 2) }),
    action("Approve", "/runs/approve"),
    site ? action("Allow this site until restart", "/runs/approve", { always: true }) : null,
    action("Deny", "/runs/deny"),
    site ? el("p", { class: "muted", text:
      "Initial URLs must begin with the exact scheme, host and written port shown above, followed by /. " +
      "No subdomains, www variants, or added/removed default ports. " +
      "Redirects keep web_fetch’s same-site policy, including www." }) : null);
}

export function approvalNotice(result) {
  return result.grant?.refused
    ? "This request was approved, but permission for this site could not be saved. Future requests may ask again."
    : null;
}

// A failed task is actionable only until a resolution or its authored absorb
// policy accounts for it. Nexus rechecks the decision when the person acts.
export function executionControls(snapshot, onAction) {
  if (!snapshot?.run_public_id) return null;
  const held = (snapshot.tasks || []).filter((task) =>
    ["failed", "timed_out", "uncertain"].includes(task.status) &&
    !task.failure_resolution && task.on_failure !== "absorb");
  const active = snapshot.run_status && !isTerminal(snapshot.run_status);
  if (!active && !held.length) return null;

  const controls = el("section", { class: "execution-controls", "aria-label": "Execution controls" });
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
      el("span", { class: "muted", text: paused ? "Execution paused" : "Execution in progress" }),
      paused ? action("Resume", "/runs/resume") : action("Pause", "/runs/pause")));
  }
  for (const task of held) {
    controls.append(el("div", { class: "execution-row" },
      el("span", { class: "warn", text: `Step ${task.task_key} · ${task.status.replaceAll("_", " ")}` }),
      action("Retry failed step", "/runs/retry", { task_key: task.task_key }),
      action("Abandon failed step", "/runs/abandon", { task_key: task.task_key })));
  }
  controls.append(error);
  return controls;
}
