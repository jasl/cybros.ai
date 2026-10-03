import { el, isTerminal } from "./views.js";

// A failed task is actionable only until a resolution or its authored absorb
// policy accounts for it. Nexus rechecks the decision when the person acts.
export function executionControls(snapshot, onAction) {
  if (!snapshot?.loop) return null;
  const held = (snapshot.tasks || []).filter((task) =>
    ["failed", "timed_out", "uncertain"].includes(task.status) &&
    !task.failure_resolution && task.on_failure !== "absorb");
  const active = snapshot.loop_status && !isTerminal(snapshot.loop_status);
  if (!active && !held.length) return null;

  const controls = el("section", { class: "execution-controls", "aria-label": "Execution controls" });
  const error = el("p", { class: "bad", role: "alert", hidden: true });
  let busy = false;
  const action = (label, path, body = {}) => el("button", {
    type: "button", text: label, onclick: async () => {
      if (busy) return;
      busy = true; error.hidden = true;
      for (const button of controls.querySelectorAll("button")) button.disabled = true;
      try { await onAction(path, { public_id: snapshot.loop, ...body }); }
      catch (failure) { error.textContent = failure.message; error.hidden = false; }
      finally {
        busy = false;
        for (const button of controls.querySelectorAll("button")) button.disabled = false;
      }
    },
  });
  if (active) {
    const paused = snapshot.loop_status === "paused";
    controls.append(el("div", { class: "execution-row" },
      el("span", { class: "muted", text: paused ? "Execution paused" : "Execution in progress" }),
      paused ? action("Resume", "/loops/resume") : action("Pause", "/loops/pause")));
  }
  for (const task of held) {
    controls.append(el("div", { class: "execution-row" },
      el("span", { class: "warn", text: `Step ${task.task_key} · ${task.status.replaceAll("_", " ")}` }),
      action("Retry failed step", "/loops/retry", { task_key: task.task_key }),
      action("Abandon failed step", "/loops/abandon", { task_key: task.task_key })));
  }
  controls.append(error);
  return controls;
}
