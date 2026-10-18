import { el } from "../../kernel/dom.js";
import { t, statusText } from "../../kernel/i18n.js";
import { markdown } from "../../kernel/markdown.js";
import { artifactsIn } from "../../kernel/artifacts.js";
import { button, disclosure } from "../../primitives/index.js";

// One tool call of a round: its name and status, the output preview and an
// entry into the task tab for the complete output.
function callRow(call, runId, { openTask, artifacts }) {
  const name = call.name || t("common.tool");
  const row = disclosure({ title: name, summary: `· ${statusText(call.status)}`, icon: "terminal", tone: call.is_error ? "bad" : undefined });
  row.body.append(...[
    call.output_preview ? el("pre", { class: "code-block activity__output", text: call.output_preview }) : null,
    ...artifactsIn(call.output_preview).map((artifact) => artifacts.figure(artifact)),
    el("button", { type: "button", class: "link-button", text: t("activity.open_output"),
      onclick: () => openTask(runId, call.task_key || call.key, name) }),
  ].filter(Boolean));
  return row.element;
}

// A round's `calls` is `{ count, items }` (a preview of its fan-out) and its
// `branches` the keys of calls that opened their own branch.
function roundRow(round, runId, deps) {
  const fan = round.calls || { items: [], count: 0 };
  const calls = fan.items || [];
  const count = fan.count || calls.length;
  const branches = round.branches || [];
  return el("section", { class: "round" },
    el("div", { class: "round__heading" }, el("span", { text: statusText(round.status) }),
      el("button", { type: "button", class: "link-button", text: t("activity.read_full_round"),
        onclick: () => deps.openTask(runId, round.task_key, t("activity.round")) })),
    round.text_preview ? el("div", { class: "markdown markdown--compact" }, markdown(round.text_preview)) : null,
    round.text_preview ? el("p", { class: "round__note", text: t("activity.round_preview") }) : null,
    calls.map((call) => callRow(call, runId, deps)),
    count > calls.length ? el("p", { class: "round__note", text: t("activity.more_calls", { count: count - calls.length }) }) : null,
    branches.length ? el("p", { class: "round__note", text: t("activity.branches", { keys: branches.join(", ") }) }) : null);
}

// "Tools and activity" of one run, read from `/runs/transcript` the first
// time it opens (and again when a repaint reopens it), newest page first.
export function activityDisclosure(runId, turnId, { rounds, openTask, artifacts }) {
  const box = disclosure({ title: t("activity.title"), icon: "tool", attrs: { "data-disclosure": `activity-${turnId}` } });
  const deps = { openTask, artifacts };
  async function load(before = null) {
    const status = el("p", { class: "activity__status", text: t("activity.loading") });
    if (before) box.body.prepend(status); else box.body.append(status);
    try {
      const transcript = await rounds(runId, before);
      if (!box.body.isConnected) return;
      status.replaceWith(...transcript.rounds.map((round) => roundRow(round, runId, deps)));
      if (!before && !transcript.rounds.length) box.body.append(el("p", { class: "activity__status", text: t("activity.empty") }));
      if (transcript.has_older) {
        const earlier = button({ label: t("activity.earlier"), variant: "ghost", size: "sm",
          onClick: () => { earlier.remove(); load(transcript.next_before); } });
        box.body.prepend(earlier);
      }
    } catch (error) {
      if (error.name !== "AbortError") status.textContent = error.message || t("conversation.request_failed");
    }
  }
  box.element.addEventListener("toggle", () => {
    if (box.element.open && !box.body.childElementCount) load();
  });
  return box.element;
}
