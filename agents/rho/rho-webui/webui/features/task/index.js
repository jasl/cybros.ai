import { el } from "../../kernel/dom.js";
import { t, statusText } from "../../kernel/i18n.js";
import { markdown } from "../../kernel/markdown.js";
import { isUnresolvedFailure } from "../../kernel/format.js";
import { artifactsIn, createArtifactOpener } from "../../kernel/artifacts.js";
import { alert, iconButton, spinner } from "../../primitives/index.js";

const UPLOADS = "nexus://uploads/";
const query = (path, values) => `${path}?${new URLSearchParams(values)}`;
const block = (title, ...content) => el("section", { class: "task__block" }, el("h3", { class: "task__heading", text: title }), ...content);

// The files a task captured: uploads its result names by `resource_link`.
export function taskCaptures(detail) {
  return (detail.content || []).filter((entry) => entry.type === "resource_link" && entry.uri?.startsWith(UPLOADS))
    .map((entry) => ({ public_id: entry.uri.slice(UPLOADS.length), filename: entry.name }));
}

// One task as `/runs/task` reports it. Provider diagnostics stay literal
// text; an unresolved context overflow adds the catalog's repair guidance.
export function taskDetail(detail, artifacts) {
  const overflow = detail.error?.key === "provider_context_overflow" && isUnresolvedFailure(detail);
  return el("div", { class: "task__detail" },
    el("p", { class: "task__summary", text: `${detail.tool_name || detail.kind || t("common.task")} · ${statusText(detail.status)}` }),
    detail.prompt ? block(t("task.prompt"), el("div", { class: "markdown" }, markdown(detail.prompt))) : null,
    detail.tool_input ? block(t("task.input"), el("pre", { class: "code-block", text: JSON.stringify(detail.tool_input, null, 2) })) : null,
    detail.output ? block(t("task.output"), el("pre", { class: "code-block", text: detail.output }),
      artifactsIn(detail.output).map((artifact) => artifacts.figure(artifact))) : null,
    taskCaptures(detail).map((capture) => artifacts.figure(capture)),
    overflow ? el("p", { class: "notice notice--warn", text: t("errors.provider_context_overflow") }) : null,
    detail.error ? el("pre", { class: "code-block task__error", text: JSON.stringify(detail.error, null, 2) }) : null);
}

function taskPanel(shell, initialProps) {
  let props = initialProps;
  const reads = new AbortController();
  const artifacts = createArtifactOpener({ artifactBytes: shell.artifactBytes, host: () => props.conversation.id, signal: reads.signal });
  const body = el("div", { class: "task__body" });
  const refresh = iconButton({ icon: "refresh", label: t("common.refresh"), onClick: () => load() });
  const element = el("section", { class: "task", "aria-label": t("common.task") },
    el("header", { class: "task__head" }, refresh), body);
  let reading = 0;

  async function load() {
    const version = ++reading;
    const { params, conversation } = props;
    body.replaceChildren(el("p", { class: "task__status" }, spinner(), el("span", { text: t("task.loading") })));
    try {
      const values = { public_id: params.runId, ...(conversation.workspace ? { workspace_public_id: conversation.workspace } : {}), task_key: params.taskKey };
      const { task } = await shell.call(query("/runs/task", values), { signal: reads.signal });
      if (version === reading && !reads.signal.aborted) body.replaceChildren(taskDetail(task, artifacts));
    } catch (error) {
      if (version !== reading || reads.signal.aborted || error.name === "AbortError" || error.status === 401) return;
      body.replaceChildren(alert({ tone: "error", text: error.message || t("task.load_failed") }).element);
    }
  }

  load();
  return {
    element,
    update(next) { props = next; },
    dispose() { reads.abort(); artifacts.dispose(); },
  };
}

// A task's full detail opens as a dock tab beside its conversation; the tab
// is reached from the activity of a turn, so it is not offered in the guide.
export function register(ui, shell) {
  ui.slots.register("dock.tab", { key: "task", title: (params) => params.title || t("common.task"), icon: "terminal" },
    (props) => taskPanel(shell, props));
}
