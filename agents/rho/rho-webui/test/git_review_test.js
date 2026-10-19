import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, type } from "./support/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { createGitReview, patchLines } from "../webui/features/conversation/git-review.js";
let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());
const click = (node) => node.click();
const tick = async () => { for (let n = 0; n < 8; n++) await Promise.resolve(); };
const review = { runner: "runner-1", root: "/project", base: "a".repeat(40), files: [{ path: "a.rb", status: "M" }],
  file: { path: "a.rb", state: "text", fingerprint: "original", patch: "--- a/a.rb\n+++ b/a.rb\n@@ -2 +2 @@\n-old\n+<script>new</script>\n" } };
function mount(readReview = async () => structuredClone(review)) {
  const state = observable({ id: "c-1", access: "ready", detail: { default_runner: { executor_public_id: "runner-1" } }, draft: "" });
  const comments = [];
  const conversations = { state, readReview, reviewFeedback: async (comment) => { comments.push(comment); return JSON.stringify(comment); },
    setDraft: (draft) => state.update((value) => ({ ...value, draft })) };
  const panel = createGitReview({ conversations }); document.body.append(panel.element);
  return { state, panel, comments };
}
test("patch coordinates distinguish removed and added lines", () => {
  expect(patchLines(review.file.patch).filter((row) => row.side).map(({ side, line, excerpt }) => ({ side, line, excerpt })))
    .toEqual([{ side: "left", line: 2, excerpt: "old" }, { side: "right", line: 2, excerpt: "<script>new</script>" }]);
});
test("feedback preserves both sides and the original excerpt after worktree changes", async () => {
  let reads = 0;
  const { panel, comments, state } = mount(async () => { const result = structuredClone(review); if (++reads > 1) result.file.fingerprint = "changed"; return result; });
  click(panel.element.querySelector("button")); await tick();
  expect(panel.element.querySelector("script")).toBeNull();
  click(panel.element.querySelector(".git-review__line--left"));
  type(panel.element.querySelector("textarea"), "Keep this");
  click([...panel.element.querySelectorAll("button")].find((button) => button.textContent === "Add feedback to message")); await tick();
  expect(comments[0]).toMatchObject({ side: "left", line: 2, excerpt: "old", fingerprint: "original", root: "/project", runner: "runner-1" });
  expect(panel.element.textContent).toContain("working directory changed");
  expect(state.get().draft).toContain("Keep this");
  click(panel.element.querySelector(".git-review__line--right"));
  type(panel.element.querySelector("textarea"), "Replace this");
  click([...panel.element.querySelectorAll("button")].find((button) => button.textContent === "Add feedback to message")); await tick();
  expect(comments[1]).toMatchObject({ side: "right", line: 2, excerpt: "<script>new</script>" });
});
test("late reads and comment drafts stay in their conversation and Runner", async () => {
  let resolve;
  const { panel, state } = mount(() => new Promise((done) => { resolve = done; }));
  click(panel.element.querySelector("button"));
  state.update((value) => ({ ...value, id: "c-2" }));
  resolve(structuredClone(review)); await tick();
  expect(panel.element.textContent).not.toContain("/project");
  panel.dispose();
});

test("switching Runner preserves each Runner's draft without carrying it to the other", async () => {
  const { panel, state } = mount();
  click(panel.element.querySelector("button")); await tick();
  click(panel.element.querySelector(".git-review__line--left"));
  type(panel.element.querySelector("textarea"), "Runner one comment");
  state.update((value) => ({ ...value, detail: { default_runner: { executor_public_id: "runner-2" } } }));
  expect(panel.element.querySelector("textarea")).toBeNull();
  state.update((value) => ({ ...value, detail: { default_runner: { executor_public_id: "runner-1" } } }));
  expect(panel.element.querySelector("textarea").value).toBe("Runner one comment");
  panel.dispose();
});
