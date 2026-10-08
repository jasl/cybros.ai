import { locale, statusText, t } from "./i18n.js";
import { markdown } from "./markdown.js";

// All content enters through DOM text or the Markdown renderer. No model or
// tool output is interpreted as HTML.
export const el = (tag, attrs = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (name === "class") node.className = value;
    else if (name === "text") node.textContent = value;
    else if (name.startsWith("on")) node.addEventListener(name.slice(2), value);
    else node.setAttribute(name, value === true ? "" : String(value));
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child.nodeType ? child : document.createTextNode(String(child)));
  }
  return node;
};

export const state = (title, ...children) =>
  el("div", { class: "state" }, el("h2", { text: title }), ...children);
export const prose = (text) => el("div", { class: "markdown" }, markdown(text || ""));
export const isTerminal = (status) =>
  ["completed", "failed", "canceled", "cancelled", "timed_out", "skipped", "stopped"].includes(status);
export const isUnresolvedFailure = (task) =>
  ["failed", "timed_out", "uncertain"].includes(task.status) && !task.failure_resolution && task.on_failure !== "absorb";
export const titleOf = (row) => row.title || t("views.untitled_conversation");
export const stamp = (value) => {
  const date = new Date(value);
  return value && !Number.isNaN(date.valueOf()) ? date.toLocaleString(locale) : "";
};
export const modelRef = (model) => model
  ? (typeof model === "string" ? model : `${model.provider_id}/${model.model_ref}`) : "";
export function emptyTurnText(turn) {
  if (turn.role !== "assistant") return t("common.message");
  switch (turn.status) {
    case "canceled": return t("views.stopped");
    case "failed": return t("views.response_failed");
    case "timed_out": return t("views.response_timed_out");
    case "completed": return t("views.no_response");
    default: return t("common.working");
  }
}

export function conversationButton(row, current, onPick) {
  const attention = row.attention;
  const status = row.archived_at ? t("views.archived") : statusText(attention?.reason) || (row.active_turn_public_id ? t("views.working") : t("common.ready"));
  return el("button", { class: "conversation", "aria-current": current ? "true" : "false",
    "data-conversation-id": row.public_id, onclick: () => onPick(row.public_id) },
    el("span", { class: "conversation-title", text: titleOf(row) }),
    el("span", { class: "meta" },
      el("span", { class: attention ? "attention" : "muted", text: status }),
      el("time", { class: "faint", datetime: row.last_activity_at || row.updated_at,
        text: stamp(row.last_activity_at || row.updated_at) })));
}

const ARTIFACT = /(?:^|[\s"'(])((?:\/|\.\.?\/)?[\w./@+-]*\.(?:png|jpe?g|gif|webp|avif|svg|log|txt|json|md))(?=$|[\s"'),.])/ig;
export function artifactsIn(text) {
  const found = new Set();
  for (const match of String(text || "").matchAll(ARTIFACT)) found.add(match[1]);
  return [...found].map((path) => ({ path, filename: path.split("/").pop() }));
}

export const artifactKey = (turn, artifact) => JSON.stringify([
  turn.public_id, turn.active_variant?.public_id, artifact.public_id, artifact.path, artifact.filename,
]);

// A status refresh can arrive while remote bytes are loading. Keep that
// request's result node and button alive only for the same turn and variant.
export function preserveTurnArtifacts(previous, next) {
  const figures = new Map();
  for (const figure of previous.querySelectorAll("[data-artifact-key]")) {
    const key = figure.dataset.artifactKey;
    if (!figures.has(key)) figures.set(key, []);
    figures.get(key).push(figure);
  }
  for (const figure of next.querySelectorAll("[data-artifact-key]")) {
    const existing = figures.get(figure.dataset.artifactKey)?.shift();
    if (existing) figure.replaceWith(existing);
  }
}

export function artifactFigure(artifact, onArtifact, key = null) {
  const name = artifact.filename || artifact.path || t("views.attachment");
  const result = el("div", { class: "artifact-result" });
  return el("figure", { class: "artifact", "data-artifact-key": key },
    el("button", { type: "button", text: t("views.open_artifact", { name: name }),
      onclick: (event) => onArtifact(artifact, result, event.currentTarget) }),
    el("button", { type: "button", text: t("views.download", { name: name }),
      onclick: (event) => onArtifact(artifact, result, event.currentTarget, true) }), result);
}

export function taskDetail(detail, onArtifact) {
  const captures = (detail.content || []).filter((block) => block.type === "resource_link" && block.uri?.startsWith("nexus://uploads/"))
    .map((block) => ({ public_id: block.uri.slice("nexus://uploads/".length), filename: block.name }));
  const overflow = detail.error?.key === "provider_context_overflow";
  return el("div", { class: "task-detail" },
    el("p", { class: "muted", text: `${detail.tool_name || detail.kind || t("common.task")} · ${statusText(detail.status)}` }),
    detail.prompt ? el("section", {}, el("h4", { text: t("views.prompt") }), prose(detail.prompt)) : null,
    detail.tool_input ? el("section", {}, el("h4", { text: t("views.input") }),
      el("pre", { text: JSON.stringify(detail.tool_input, null, 2) })) : null,
    detail.output ? el("section", {}, el("h4", { text: t("views.output") }),
      el("pre", { text: detail.output }), artifactsIn(detail.output).map((a) => artifactFigure(a, onArtifact))) : null,
    captures.map((capture) => artifactFigure(capture, onArtifact)),
    overflow && isUnresolvedFailure(detail) ? el("p", { class: "warn", text: t("errors.provider_context_overflow") }) : null,
    detail.error ? el("pre", { class: "bad", text: JSON.stringify(detail.error, null, 2) }) : null);
}

export function roundCard(round, runId, onTask, onArtifact) {
  const fan = round.calls || { items: [], count: 0 };
  const calls = fan.items || [];
  const count = fan.count || calls.length;
  const branches = round.branches || [];
  return el("section", { class: "round" },
    el("div", { class: "round-heading" },
      el("span", { class: "muted", text: statusText(round.status) }),
      el("button", { class: "linkish", text: t("views.read_full_round"), onclick: () => onTask(runId, round.task_key) })),
    round.text_preview ? prose(round.text_preview) : null,
    round.text_preview ? el("p", { class: "faint", text: t("views.round_preview_open_the_full_round_for_complete") }) : null,
    calls.map((call) => el("div", { class: `call ${call.is_error ? "bad" : ""}` },
      el("button", { class: "linkish", text: call.name || t("common.tool"),
        onclick: () => onTask(runId, call.task_key || call.key) }),
      el("span", { class: "muted", text: ` · ${statusText(call.status)}` }),
      call.output_preview ? el("pre", { text: call.output_preview }) : null,
      artifactsIn(call.output_preview).map((a) => artifactFigure(a, onArtifact)))),
    count > calls.length ? el("p", { class: "faint", text: t("views.more_calls_are_outside_this_preview", { value1: count - calls.length }) }) : null,
    branches.length ? el("p", { class: "faint", text: t("views.branches_under", { value1: branches.join(", ") }) }) : null);
}

export function turnCard(turn, { onActivity, onArtifact }) {
  const variant = turn.active_variant || {};
  const assistant = turn.role === "assistant";
  const content = variant.content ?? variant.content_preview ?? "";
  if (turn.reference) {
    return el("article", { class: "message reference", "data-turn-id": turn.public_id },
      el("header", {}, el("strong", { text: t("views.parent_conversation_reference_snapshot") }),
        el("time", { class: "faint", text: stamp(turn.created_at) })),
      el("p", { class: "muted", text: t("views.read_only_context_captured_when_this_side_conversation") }),
      content ? prose(content) : el("p", { class: "muted", text: t("views.no_persisted_content_was_available") }));
  }
  const label = turn.kind === "compaction_summary" ? t("views.context_summary")
    : turn.role === "system" ? t("views.system") : turn.role === "tool" ? t("common.tool")
    : turn.speaker?.display_name || turn.speaker?.handle || (assistant ? t("brand.rho") : t("common.you"));
  const body = el("article", { class: `message ${assistant ? "assistant" : "user"}`, "data-turn-id": turn.public_id },
    el("header", {}, el("strong", { text: label }), el("time", { class: "faint", text: stamp(turn.created_at) }),
      turn.status !== "completed" ? el("span", { class: "muted", text: statusText(turn.status) }) : null),
    content ? prose(content) : el("p", { class: "muted", text: emptyTurnText(turn) }),
    variant.content === undefined && variant.content_preview ? el("p", { class: "faint", text: t("views.preview") }) : null,
    (variant.attachments || []).map((a) => artifactFigure(a, onArtifact, artifactKey(turn, a))),
    assistant ? artifactsIn(content).map((a) => artifactFigure(a, onArtifact, artifactKey(turn, a))) : null);
  if (variant.details_pruned_at) {
    body.append(el("p", { class: "faint", text: t("views.execution_details_removed_by_the_retention_policy_conversation") }));
  } else if (variant.run_public_id) {
    const activityBody = el("div", { class: "activity-body" });
    const details = el("details", { class: "activity", "data-disclosure": `activity-${turn.public_id}` },
      el("summary", { text: t("views.tools_and_activity") }), activityBody);
    details.addEventListener("toggle", () => {
      if (details.open && !activityBody.childElementCount) onActivity(variant.run_public_id, activityBody);
    });
    body.append(details);
  }
  // A reply turn owns both its captured prompt and its answer. Message turns
  // already carry their role, and never grow a second invented prompt.
  if (turn.kind === "direct_reply" && variant.prompt_text) {
    return el("div", { class: "turn" },
      el("article", { class: "message user", "data-turn-id": `${turn.public_id}:prompt` },
        el("header", {}, el("strong", { text: t("common.you") })), prose(variant.prompt_text)), body);
  }
  return body;
}
