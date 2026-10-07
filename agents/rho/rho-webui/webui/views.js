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
export const titleOf = (row) => row.title || "Untitled conversation";
export const stamp = (value) => {
  const date = new Date(value);
  return value && !Number.isNaN(date.valueOf()) ? date.toLocaleString() : "";
};
export const modelRef = (model) => model
  ? (typeof model === "string" ? model : `${model.provider_id}/${model.model_ref}`) : "";
export function emptyTurnText(turn) {
  if (turn.role !== "assistant") return "Message";
  switch (turn.status) {
    case "canceled": return "Stopped";
    case "failed": return "Response failed";
    case "timed_out": return "Response timed out";
    case "completed": return "No response";
    default: return "Working…";
  }
}

export function conversationButton(row, current, onPick) {
  const attention = row.attention;
  const status = row.archived_at ? "Archived" : attention?.reason || (row.active_turn_public_id ? "Working" : "Ready");
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
  const name = artifact.filename || artifact.path || "attachment";
  const result = el("div", { class: "artifact-result" });
  return el("figure", { class: "artifact", "data-artifact-key": key },
    el("button", { type: "button", text: `Open artifact ${name}`,
      onclick: (event) => onArtifact(artifact, result, event.currentTarget) }),
    el("button", { type: "button", text: `Download ${name}`,
      onclick: (event) => onArtifact(artifact, result, event.currentTarget, true) }), result);
}

export function taskDetail(detail, onArtifact) {
  const captures = (detail.content || []).filter((block) => block.type === "resource_link" && block.uri?.startsWith("nexus://uploads/"))
    .map((block) => ({ public_id: block.uri.slice("nexus://uploads/".length), filename: block.name }));
  return el("div", { class: "task-detail" },
    el("p", { class: "muted", text: `${detail.tool_name || detail.kind || "Task"} · ${detail.status || ""}` }),
    detail.prompt ? el("section", {}, el("h4", { text: "Prompt" }), prose(detail.prompt)) : null,
    detail.tool_input ? el("section", {}, el("h4", { text: "Input" }),
      el("pre", { text: JSON.stringify(detail.tool_input, null, 2) })) : null,
    detail.output ? el("section", {}, el("h4", { text: "Output" }),
      el("pre", { text: detail.output }), artifactsIn(detail.output).map((a) => artifactFigure(a, onArtifact))) : null,
    captures.map((capture) => artifactFigure(capture, onArtifact)),
    detail.error ? el("pre", { class: "bad", text: JSON.stringify(detail.error, null, 2) }) : null);
}

export function roundCard(round, runId, onTask, onArtifact) {
  const fan = round.calls || { items: [], count: 0 };
  const calls = fan.items || [];
  const count = fan.count || calls.length;
  const branches = round.branches || [];
  return el("section", { class: "round" },
    el("div", { class: "round-heading" },
      el("span", { class: "muted", text: round.status || "" }),
      el("button", { class: "linkish", text: "Read full round", onclick: () => onTask(runId, round.task_key) })),
    round.text_preview ? prose(round.text_preview) : null,
    round.text_preview ? el("p", { class: "faint", text: "Round preview — open the full round for complete output." }) : null,
    calls.map((call) => el("div", { class: `call ${call.is_error ? "bad" : ""}` },
      el("button", { class: "linkish", text: call.name || "Tool",
        onclick: () => onTask(runId, call.task_key || call.key) }),
      el("span", { class: "muted", text: ` · ${call.status || ""}` }),
      call.output_preview ? el("pre", { text: call.output_preview }) : null,
      artifactsIn(call.output_preview).map((a) => artifactFigure(a, onArtifact)))),
    count > calls.length ? el("p", { class: "faint", text: `${count - calls.length} more calls are outside this preview.` }) : null,
    branches.length ? el("p", { class: "faint", text: `Branches under ${branches.join(", ")}.` }) : null);
}

export function turnCard(turn, { onActivity, onArtifact }) {
  const variant = turn.active_variant || {};
  const assistant = turn.role === "assistant";
  const content = variant.content ?? variant.content_preview ?? "";
  if (turn.reference) {
    return el("article", { class: "message reference", "data-turn-id": turn.public_id },
      el("header", {}, el("strong", { text: "Parent conversation reference snapshot" }),
        el("time", { class: "faint", text: stamp(turn.created_at) })),
      el("p", { class: "muted", text: "Read-only context captured when this side conversation opened." }),
      content ? prose(content) : el("p", { class: "muted", text: "No persisted content was available." }));
  }
  const label = turn.kind === "compaction_summary" ? "Context summary"
    : turn.role === "system" ? "System" : turn.role === "tool" ? "Tool"
    : turn.speaker?.display_name || turn.speaker?.handle || (assistant ? "rho" : "You");
  const body = el("article", { class: `message ${assistant ? "assistant" : "user"}`, "data-turn-id": turn.public_id },
    el("header", {}, el("strong", { text: label }), el("time", { class: "faint", text: stamp(turn.created_at) }),
      turn.status !== "completed" ? el("span", { class: "muted", text: turn.status || "" }) : null),
    content ? prose(content) : el("p", { class: "muted", text: emptyTurnText(turn) }),
    variant.content === undefined && variant.content_preview ? el("p", { class: "faint", text: "Preview" }) : null,
    (variant.attachments || []).map((a) => artifactFigure(a, onArtifact, artifactKey(turn, a))),
    assistant ? artifactsIn(content).map((a) => artifactFigure(a, onArtifact, artifactKey(turn, a))) : null);
  if (variant.details_pruned_at) {
    body.append(el("p", { class: "faint", text: "Execution details removed by the retention policy. Conversation text is retained." }));
  } else if (variant.run_public_id) {
    const activityBody = el("div", { class: "activity-body" });
    const details = el("details", { class: "activity", "data-disclosure": `activity-${turn.public_id}` },
      el("summary", { text: "Tools and activity" }), activityBody);
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
        el("header", {}, el("strong", { text: "You" })), prose(variant.prompt_text)), body);
  }
  return body;
}
