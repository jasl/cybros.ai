import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, type } from "./support/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { createGitReview, patchLines } from "../webui/features/conversation/git-review.js";
let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());
const tick = async () => { for (let n = 0; n < 8; n++) await Promise.resolve(); };
const turn = { public_id: "turn-1", active_variant: { public_id: "variant-1" } };
const file = { path: "a.rb", status: "M", state: "text", additions: 1, deletions: 1,
  patch: "--- a/a.rb\n+++ b/a.rb\n@@ -2 +2 @@\n-old\n+<script>new</script>\n" };
const review = { runner: "runner-1", root: "/project", base: "a".repeat(64), run: "run-1", files: [file] };
function mount(readReview = async () => [structuredClone(review)], reply = turn) {
  const state = observable({ id: "c-1", draft: "" });
  const comments = []; const reads = [];
  const conversations = { state, readReview: (fields) => { reads.push(fields); return readReview(fields); },
    reviewFeedback: async (comment) => { comments.push(comment); return JSON.stringify(comment); },
    setDraft: (draft) => state.update((value) => ({ ...value, draft })) };
  const panel = createGitReview({ conversations, turn: reply }); document.body.append(panel.element);
  return { state, panel, comments, reads };
}
test("patch coordinates distinguish removed and added lines", () => {
  expect(patchLines(file.patch).filter((row) => row.side).map(({ side, line, excerpt }) => ({ side, line, excerpt })))
    .toEqual([{ side: "left", line: 2, excerpt: "old" }, { side: "right", line: 2, excerpt: "<script>new</script>" }]);
});
test("only recorded edits show a card and feedback quotes the historical reply without rereading Git", async () => {
  const { panel, comments, state, reads } = mount();
  expect(panel.element.hidden).toBe(true);
  await tick();
  expect(panel.element.hidden).toBe(false);
  expect(panel.element.querySelector("summary").textContent).toContain("Edited 1 file");
  expect(reads).toEqual([{ turn: "turn-1", variant: "variant-1" }]);
  panel.element.querySelector(".git-review__file").click();
  expect(panel.element.querySelector("script")).toBeNull();
  panel.element.querySelector(".git-review__line--left").click();
  type(panel.element.querySelector("textarea"), "Keep this");
  [...panel.element.querySelectorAll("button")].find((button) => button.textContent === "Add feedback to message").click();
  await tick();
  expect(comments[0]).toMatchObject({ side: "left", line: 2, excerpt: "old", turn: "turn-1", variant: "variant-1", run: "run-1" });
  expect(state.get().draft).toContain("Keep this");
  expect(reads).toHaveLength(1);
  panel.dispose();
});
test("empty and absent recorded diffs stay hidden", async () => {
  for (const reviews of [[], [{ ...review, files: [] }]]) {
    const { panel } = mount(async () => reviews);
    await tick();
    expect(panel.element.hidden).toBe(true);
    panel.dispose();
  }
});
test("late reads after navigation cannot populate a disposed card", async () => {
  let resolve;
  const { panel } = mount(() => new Promise((done) => { resolve = done; }));
  panel.dispose();
  resolve([structuredClone(review)]); await tick();
  expect(panel.element.hidden).toBe(true);
  expect(panel.element.textContent).not.toContain("a.rb");
});
test("cards keep independent reply snapshots and compact their file lists", async () => {
  const first = mount(async () => [{ ...review, files: Array.from({ length: 5 }, (_, index) => ({ ...file, path: `${index}.rb` })) }]);
  const second = mount(async () => [{ ...review, run: "run-2", files: [{ ...file, path: "later.rb" }] }],
    { public_id: "turn-2", active_variant: { public_id: "variant-2" } });
  await tick();
  expect(first.panel.element.querySelectorAll(".git-review__file")).toHaveLength(3);
  [...first.panel.element.querySelectorAll("button")].find((button) => button.textContent === "Show 2 more files").click();
  expect(first.panel.element.querySelectorAll(".git-review__file")).toHaveLength(5);
  expect(first.panel.element.textContent).not.toContain("later.rb");
  expect(second.reads).toEqual([{ turn: "turn-2", variant: "variant-2" }]);
  first.panel.dispose(); second.panel.dispose();
});
