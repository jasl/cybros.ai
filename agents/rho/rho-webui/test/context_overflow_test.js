import { test, expect } from "bun:test";
import { executionControls } from "../webui/controls.js";
import { taskDetail } from "../webui/views.js";

const descendants = (node) => [node, ...(node.children || []).flatMap(descendants)];
const textOf = (node) => node ? node.textContent + (node.children || []).map(textOf).join("") : "";
async function withDocument(run) {
  const previous = globalThis.document;
  const node = (tag, nodeType = 1) => ({
    tag, nodeType, children: [], textContent: "", listeners: {},
    setAttribute(name, value) { this[name] = value; },
    addEventListener(name, handler) { this.listeners[name] = handler; },
    append(...children) { this.children.push(...children); },
    querySelectorAll(tagName) { return descendants(this).filter((child) => child.tag === tagName); },
  });
  globalThis.document = {
    createElement: (tag) => node(tag),
    createTextNode: (text) => ({ nodeType: 3, textContent: text }),
  };
  try { await run(); } finally { globalThis.document = previous; }
}

const failed = { task_key: "r1", kind: "model_task", status: "failed", on_failure: "halt",
  error_key: "provider_context_overflow" };
const snapshot = (task) => ({ run_public_id: "run-overflow", run_status: "needs_attention", tasks: [task] });

test("unresolved context overflow explains server limits beside the existing scoped retry control", () => withDocument(async () => {
  const actions = [];
  const panel = executionControls(snapshot(failed), (...args) => actions.push(args));
  const text = textOf(panel);
  expect(text).toContain("Nexus Settings > Model providers > Edit model > Context and capabilities");
  expect(text).toContain("Combined context window");
  expect(text).toContain("Input token limit or Combined context window");
  expect(text).toContain("server's actual limit (use only one)");
  expect(text).toContain("Output token limit");
  expect(text).toContain("lower the requested output budget");
  await panel.querySelectorAll("button").find((button) => button.textContent === "Retry failed step").listeners.click();
  expect(actions).toEqual([["/runs/retry", { public_id: "run-overflow", task_key: "r1" }]]);
}));

test("automatic recovery and settled failures do not show model-limit instructions", () => withDocument(() => {
  for (const fields of [{ status: "waiting" }, { status: "running" }, { status: "completed" },
    { failure_resolution: "abandoned" }, { on_failure: "absorb" }, { error_key: "other_failure" }]) {
    const task = { ...failed, ...fields };
    expect(textOf(executionControls(snapshot(task), () => {}))).not.toContain("Context and capabilities");
    const detail = taskDetail({ ...task, error: { key: task.error_key, detail: "Requested 9000 tokens; maximum 8192." } }, () => {});
    expect(textOf(detail)).not.toContain("Context and capabilities");
    expect(textOf(detail)).toContain("Requested 9000 tokens; maximum 8192.");
  }
}));

test("task detail adds recovery guidance beside the existing literal provider diagnostics", () => withDocument(() => {
  const detail = taskDetail({ ...failed, error: { key: failed.error_key, detail: "Requested 9000 tokens; maximum 8192. <div>" } }, () => {});
  expect(textOf(detail)).toContain("Context and capabilities");
  const diagnostic = descendants(detail).find((node) => node.tag === "pre");
  expect(diagnostic.textContent).toContain("Requested 9000 tokens; maximum 8192. <div>");
  expect(diagnostic.children).toEqual([]);
}));
