import { el } from "../../kernel/dom.js";
import { t, statusText } from "../../kernel/i18n.js";
import { markdown } from "../../kernel/markdown.js";
import { isTerminal, stamp } from "../../kernel/format.js";
import { artifactsIn, artifactKey } from "../../kernel/artifacts.js";
import { disclosure } from "../../primitives/index.js";

const prose = (text, compact = false) => el("div", { class: compact ? "markdown markdown--compact" : "markdown" }, markdown(text || ""));
const speaker = (turn) => turn.speaker?.display_name || turn.speaker?.handle || (turn.role === "assistant" ? t("brand.rho") : t("common.you"));

export function emptyTurnText(turn) {
  if (turn.role !== "assistant") return t("common.message");
  switch (turn.status) {
    case "canceled": return t("transcript.stopped");
    case "failed": return t("transcript.failed");
    case "timed_out": return t("transcript.timed_out");
    case "completed": return t("transcript.no_response");
    default: return t("common.working");
  }
}

function meta(turn, label, status = null) {
  return el("header", { class: "turn__meta" }, el("span", { class: "turn__speaker", text: label }),
    turn.created_at ? el("time", { datetime: turn.created_at, text: stamp(turn.created_at) }) : null,
    status ? el("span", { class: "turn__status", text: status }) : null);
}

const placeholder = (text) => el("p", { class: "turn__placeholder", text });

// A Side conversation's frozen parent context: one readable card, never a
// reply, an artifact result or an execution to control.
function referenceRow(turn, content) {
  return el("article", { class: "turn turn--reference", "data-turn-id": turn.public_id },
    el("header", { class: "turn__reference-head" }, el("span", { class: "turn__reference-title", text: t("transcript.reference_title") }),
      turn.created_at ? el("time", { datetime: turn.created_at, text: stamp(turn.created_at) }) : null),
    el("p", { class: "turn__reference-note", text: t("transcript.reference_note") }),
    content ? prose(content) : placeholder(t("transcript.no_persisted_content")));
}

function summaryRow(turn, content) {
  const box = disclosure({ title: t("transcript.context_summary"), icon: "list", attrs: { "data-disclosure": `summary-${turn.public_id}` } });
  box.body.append(content ? prose(content, true) : placeholder(t("transcript.no_persisted_content")));
  return el("article", { class: "turn turn--summary", "data-turn-id": turn.public_id }, box.element);
}

function callbackRow(turn, content, figures = []) {
  const box = disclosure({ title: t("transcript.background_result"), attrs: { "data-disclosure": `callback-${turn.public_id}` } });
  box.body.append(content ? prose(content, true) : placeholder(t("transcript.no_persisted_content")));
  return el("article", { class: "turn turn--aside", "data-turn-id": turn.public_id }, box.element, figures);
}

function userRow(turn, content, figures) {
  return el("article", { class: "turn turn--user", "data-turn-id": turn.public_id }, meta(turn, speaker(turn)),
    el("div", { class: "turn__bubble" }, content ? prose(content) : placeholder(emptyTurnText(turn))), figures);
}

function assistantRow(turn, variant, content, figures, { active, activity }) {
  const label = turn.role === "system" ? t("transcript.system") : turn.role === "tool" ? t("common.tool") : speaker(turn);
  // The live response below stands for the running turn's empty body.
  const answering = active && !isTerminal(turn.status);
  const node = el("article", { class: `turn turn--assistant${turn.role === "assistant" ? "" : " turn--aside"}`, "data-turn-id": turn.public_id },
    meta(turn, label, turn.status && turn.status !== "completed" ? statusText(turn.status) : null),
    content ? prose(content) : answering ? null : placeholder(emptyTurnText(turn)),
    variant.content === undefined && variant.content_preview ? el("p", { class: "turn__note", text: t("transcript.preview") }) : null,
    figures);
  // Retention removed the execution details: the text stays and no transcript
  // the server marked unavailable is requested.
  if (variant.details_pruned_at) node.append(el("p", { class: "turn__pruned", text: t("transcript.details_pruned") }));
  else if (variant.run_public_id) node.append(activity(variant.run_public_id, turn.public_id));
  return node;
}

// One durable turn. A reply keeps its captured prompt above the answer.
// Kernel receipts are folded separately from the person's words; their
// origin identifies them, never their text or a peer's sender stamp.
export function turnRow(turn, { active = false, artifacts, activity }) {
  const variant = turn.active_variant || {};
  const content = variant.content ?? variant.content_preview ?? "";
  if (turn.reference) return referenceRow(turn, content);
  if (turn.kind === "compaction_summary") return summaryRow(turn, content);
  const published = turn.published_artifacts || [];
  const filenames = new Set(published.map((artifact) => artifact.filename));
  // A published upload is the usable delivery when prose also names its file.
  // This only narrows the path heuristic; distinct upload identities stay distinct.
  const inferred = turn.role === "assistant" ? artifactsIn(content).filter((artifact) => !filenames.has(artifact.filename)) : [];
  const figures = [...(variant.attachments || []), ...published, ...inferred]
    .map((artifact) => artifacts.figure(artifact, artifactKey(turn, artifact)));
  const callback = turn.origin === "child" || turn.origin === "task_result";
  if (turn.kind === "message" && callback) return callbackRow(turn, content, figures);
  const body = turn.role === "user" ? userRow(turn, content, figures) : assistantRow(turn, variant, content, figures, { active, activity });
  if (turn.kind === "direct_reply" && variant.prompt_text) {
    const prompt = { public_id: `${turn.public_id}:prompt`, role: "user" };
    return el("div", { class: "turn-pair" }, callback ? callbackRow(prompt, variant.prompt_text) : userRow(prompt, variant.prompt_text, []), body);
  }
  return body;
}
