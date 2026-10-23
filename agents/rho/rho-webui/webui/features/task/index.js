import { el } from "../../kernel/dom.js";
import { t, statusText } from "../../kernel/i18n.js";
import { markdown } from "../../kernel/markdown.js";
import { isUnresolvedFailure } from "../../kernel/format.js";
import { artifactsIn, createArtifactOpener } from "../../kernel/artifacts.js";
import { alert, button, iconButton, spinner } from "../../primitives/index.js";
import { mcpTarget } from "../../primitives/mcp_target.js";
import { terminalPanel } from "../../primitives/terminal.js";

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
    el("p", { class: "task__summary", text: `${detail.tool_alias || detail.tool_name || detail.kind || t("common.task")} · ${statusText(detail.status)}` }),
    mcpTarget(detail),
    detail.prompt ? block(t("task.prompt"), el("div", { class: "markdown" }, markdown(detail.prompt))) : null,
    detail.tool_input ? block(t("task.input"), el("pre", { class: "code-block", text: JSON.stringify(detail.tool_input, null, 2) })) : null,
    detail.output ? block(t("task.output"), el("pre", { class: "code-block", text: detail.output }),
      artifactsIn(detail.output).map((artifact) => artifacts.figure(artifact))) : null,
    detail.kind === "model_task" && detail.status === "completed" && !detail.output
      ? el("p", { class: "task__status", text: t("task.no_text") }) : null,
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
  let terminal;
  const terminalHost = el("div");
  element.append(terminalHost);

  async function load() {
    const version = ++reading;
    const { params, conversation } = props;
    body.replaceChildren(el("p", { class: "task__status" }, spinner(), el("span", { text: t("task.loading") })));
    try {
      const values = { public_id: params.runId, ...(conversation.workspace ? { workspace_public_id: conversation.workspace } : {}), task_key: params.taskKey };
      const { task } = await shell.call(query("/runs/task", values), { signal: reads.signal });
      if (version === reading && !reads.signal.aborted) {
        body.replaceChildren(taskDetail(task, artifacts));
        if (task.kind === "model_task") {
          const content = el("div", { class: "task__request" });
          const read = button({ label: t("task.read_request"), size: "sm", async onClick() {
            read.disabled = true;
            content.replaceChildren(spinner());
            try {
              const { request } = await shell.call(query("/runs/request", values), { signal: reads.signal });
              if (version !== reading || reads.signal.aborted) return;
              content.replaceChildren(el("pre", { class: "code-block", text: JSON.stringify(request, null, 2) }));
            } catch (error) {
              if (version !== reading || reads.signal.aborted || error.name === "AbortError" || error.status === 401) return;
              content.replaceChildren(alert({ tone: "error", text: error.message || t("task.request_failed") }).element);
              read.disabled = false;
            }
          } });
          body.append(block(t("task.sealed_request"), read, content));
        }
        if (task.kind === "tool_task" && ["running", "dispatched"].includes(task.status) && !terminal) {
          body.prepend(button({ label: t("terminal.open"), size: "sm", onClick(event) {
            event.currentTarget.disabled = true;
            terminal = terminalPanel({ call: shell.call, target: values });
            terminalHost.replaceChildren(terminal.element);
          } }));
        }
      }
    } catch (error) {
      if (version !== reading || reads.signal.aborted || error.name === "AbortError" || error.status === 401) return;
      body.replaceChildren(alert({ tone: "error", text: error.message || t("task.load_failed") }).element);
    }
  }

  load();
  return {
    element,
    update(next) { props = next; },
    dispose() { reads.abort(); terminal?.dispose(); artifacts.dispose(); },
  };
}

// A task's full detail opens as a dock tab beside its conversation; the tab
// is reached from the activity of a turn, so it is not offered in the guide.
export function register(ui, shell) {
  ui.slots.register("dock.tab", { key: "task", title: (params) => params.title || t("common.task"), icon: "terminal" },
    (props) => taskPanel(shell, props));
}
