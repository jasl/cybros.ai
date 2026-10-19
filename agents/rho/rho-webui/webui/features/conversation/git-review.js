import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";

// Only hunk lines have source coordinates. Headers and metadata remain text.
export function patchLines(patch) {
  let left = null; let right = null;
  return patch.split("\n").map((text) => {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(text);
    if (hunk) { left = Number(hunk[1]); right = Number(hunk[2]); return { text }; }
    if (left === null || !/^[ +\-]/.test(text)) return { text };
    if (text.startsWith("-")) return { text, side: "left", line: left++, excerpt: text.slice(1) };
    if (text.startsWith("+")) return { text, side: "right", line: right++, excerpt: text.slice(1) };
    left++; return { text, side: "right", line: right++, excerpt: text.slice(1) };
  });
}

export function createGitReview({ conversations }) {
  const drafts = new Map();
  let scope = null; let state = {}; let generation = 0;
  const scopeOf = (value) => JSON.stringify([value.id, value.detail?.default_runner?.executor_public_id]);
  const content = el("div", { class: "git-review__body" });
  const notice = el("p", { role: "status" });
  const refresh = el("button", { type: "button", class: "btn btn--sm btn--secondary", text: t("git_review.refresh"), onclick: () => load() });
  const summary = el("summary", { text: t("git_review.title") });
  const element = el("details", { class: "git-review" }, summary, refresh, notice, content);
  element.addEventListener("toggle", () => { if (element.open && !state.review && !state.busy) load(); });

  function paint() {
    refresh.disabled = !!state.busy;
    notice.textContent = state.error || state.notice || (state.busy ? t("git_review.loading") : "");
    content.replaceChildren();
    if (!state.review) return;
    const review = state.review;
    content.append(el("p", { class: "git-review__scope", text: t("git_review.scope", { root: review.root, base: review.base, runner: review.runner }) }));
    if (review.truncated) content.append(el("p", { text: t("git_review.limited") }));
    const files = el("div", { class: "git-review__files" });
    for (const row of review.files) files.append(el("button", { type: "button", class: "btn btn--sm btn--secondary", text: `${row.status} ${row.path}`,
      disabled: !!state.busy, onclick: () => load(row.path) }));
    content.append(files);
    if (!review.files.length) content.append(el("p", { text: t("git_review.empty") }));
    const file = review.file;
    if (!file) return;
    content.append(el("h3", { text: file.path }));
    if (file.state !== "text") { content.append(el("p", { text: ({ too_large: t("git_review.too_large"), binary: t("git_review.binary"), unavailable: t("git_review.unavailable") })[file.state] })); return; }
    const lines = el("div", { class: "git-review__patch", role: "group", "aria-label": t("git_review.lines") });
    for (const row of patchLines(file.patch)) {
      if (!row.side) { lines.append(el("pre", { text: row.text })); continue; }
      lines.append(el("button", { type: "button", class: `git-review__line git-review__line--${row.text.startsWith(" ") ? "context" : row.side}`,
        "aria-label": t("git_review.line", { side: row.side, line: row.line, text: row.excerpt }),
        "aria-pressed": state.selected?.line === row.line && state.selected?.side === row.side ? "true" : "false",
        text: `${row.line} ${row.text}`, onclick: () => { state.selected = row; paint(); content.querySelector("textarea")?.focus(); } }));
    }
    content.append(lines);
    if (!state.selected) return;
    content.append(el("p", { text: t("git_review.selected", { side: state.selected.side, line: state.selected.line }) }));
    const input = el("textarea", { class: "control", rows: 3, "aria-label": t("git_review.comment"), maxlength: 8000 });
    input.value = state.text || "";
    input.addEventListener("input", () => { state.text = input.value; });
    const add = el("button", { type: "button", class: "btn btn--sm btn--primary", text: t("git_review.add"), disabled: !!state.busy, onclick: () => addComment() });
    content.append(input, add);
  }

  async function load(path) {
    const current = ++generation;
    const previous = state.review;
    state.busy = true; state.error = ""; paint();
    try {
      const review = await conversations.readReview(path ? { path, base: previous.base, runner: previous.runner } : {});
      if (current !== generation) return;
      state.review = review; state.selected = null; state.notice = "";
    } catch (error) { if (current === generation) state.error = error.message; }
    finally { if (current === generation) { state.busy = false; paint(); if (path) content.querySelector(".git-review__line")?.focus(); } }
  }

  async function addComment() {
    if (state.busy || !state.text?.trim()) return;
    const current = ++generation;
    const review = state.review; const file = review.file; const selected = state.selected;
    const comment = { runner: review.runner, root: review.root, base: review.base, path: file.path,
      side: selected.side, line: selected.line, excerpt: selected.excerpt, fingerprint: file.fingerprint, text: state.text.trim() };
    state.busy = true; state.error = ""; paint();
    try {
      let changed = false;
      try {
        const fresh = await conversations.readReview({ path: file.path, base: review.base, runner: review.runner });
        changed = fresh.file.fingerprint !== file.fingerprint || fresh.root !== review.root;
      } catch { changed = true; }
      if (current !== generation) return;
      const text = await conversations.reviewFeedback(comment);
      if (current !== generation) return;
      const draft = conversations.state.get().draft;
      conversations.setDraft([draft, text].filter(Boolean).join("\n\n"));
      state.text = "";
      state.notice = changed ? t("git_review.changed") : t("git_review.added");
    } catch (error) { if (current === generation) state.error = error.message; }
    finally { if (current === generation) { state.busy = false; paint(); } }
  }

  const stop = conversations.state.subscribe((value) => {
    element.hidden = !value.id || value.access !== "ready";
    const next = scopeOf(value);
    if (next === scope) return;
    generation++;
    if (scope) drafts.set(scope, { ...state, busy: false });
    scope = next; state = drafts.get(scope) || {}; paint();
    if (element.open && !element.hidden && !state.review) load();
  }, { immediate: true });
  return { element, dispose() { generation++; stop(); } };
}
