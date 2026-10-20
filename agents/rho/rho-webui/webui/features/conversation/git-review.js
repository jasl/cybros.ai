import { el, icon } from "../../kernel/dom.js";
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

// One card owns one immutable reply. It survives transcript repainting, but
// disposal prevents a late read or feedback response from reaching another chat.
export function createGitReview({ conversations, turn }) {
  const variant = turn.active_variant;
  let disposed = false; let reviews = []; let selected = null; let text = ""; let expanded = false; let busy = false;
  const content = el("div", { class: "git-review__body" });
  const notice = el("p", { role: "status" });
  const summary = el("summary");
  const element = el("details", { class: "git-review is-expanded", hidden: true, open: true, "data-disclosure": `review-${variant.public_id}` }, summary, notice, content);
  element.addEventListener("toggle", () => element.classList.toggle("is-expanded", element.open));

  const counts = (files) => el("span", { class: "git-review__counts" },
    el("span", { class: "git-review__added", text: `+${files.reduce((total, file) => total + (file.additions || 0), 0)}` }),
    el("span", { class: "git-review__removed", text: `−${files.reduce((total, file) => total + (file.deletions || 0), 0)}` }));

  function paint() {
    const files = reviews.flatMap((review) => review.files.map((file) => ({ review, file })));
    element.hidden = !files.length;
    summary.replaceChildren(el("span", { text: files.length === 1 ? t("git_review.title_one") : t("git_review.title", { count: files.length }) }),
      counts(files.map(({ file }) => file)), icon("chevron-right"));
    content.replaceChildren();
    if (reviews.some((review) => review.truncated)) content.append(el("p", { text: t("git_review.limited") }));
    const list = el("div", { class: "git-review__files" });
    for (const { review, file } of expanded ? files : files.slice(0, 3)) {
      list.append(el("button", { type: "button", class: "git-review__file", onclick: () => {
        selected = { review, file }; paint(); content.querySelector(".git-review__line")?.focus();
      } }, el("span", { class: "git-review__path", text: file.path }),
      file.additions !== undefined ? counts([file]) : el("span", { text: file.status })));
    }
    content.append(list);
    if (files.length > 3) content.append(el("button", { type: "button", class: "btn btn--sm btn--ghost",
      text: expanded ? t("git_review.show_less") : t("git_review.show_more", { count: files.length - 3 }),
      onclick: () => { expanded = !expanded; paint(); } }));
    if (!selected) return;
    const { review, file, row } = selected;
    content.append(el("p", { class: "git-review__scope", text: t("git_review.scope", { root: review.root, runner: review.runner }) }), el("h3", { text: file.path }));
    if (file.state !== "text") {
      content.append(el("p", { text: ({ binary: t("git_review.binary"), too_large: t("git_review.too_large"),
        omitted: t("git_review.omitted"), unavailable: t("git_review.unavailable") })[file.state] })); return;
    }
    const lines = el("div", { class: "git-review__patch", role: "group", "aria-label": t("git_review.lines") });
    for (const line of patchLines(file.patch)) {
      if (!line.side) { lines.append(el("pre", { text: line.text })); continue; }
      lines.append(el("button", { type: "button", class: `git-review__line git-review__line--${line.text.startsWith(" ") ? "context" : line.side}`,
        "aria-label": t("git_review.line", { side: line.side, line: line.line, text: line.excerpt }),
        "aria-pressed": row?.line === line.line && row?.side === line.side ? "true" : "false",
        text: `${line.line} ${line.text}`, onclick: () => { selected.row = line; paint(); content.querySelector("textarea")?.focus(); } }));
    }
    content.append(lines);
    if (!row) return;
    content.append(el("p", { text: t("git_review.selected", { side: row.side, line: row.line }) }));
    const input = el("textarea", { class: "control", rows: 3, "aria-label": t("git_review.comment"), maxlength: 8000 });
    input.value = text;
    input.addEventListener("input", () => { text = input.value; });
    content.append(input, el("button", { type: "button", class: "btn btn--sm btn--primary", text: t("git_review.add"),
      disabled: busy, onclick: () => addComment() }));
  }

  async function addComment() {
    if (busy || !text.trim()) return;
    const { review, file, row } = selected;
    const comment = { runner: review.runner, root: review.root, base: review.base, path: file.path,
      side: row.side, line: row.line, excerpt: row.excerpt, turn: turn.public_id, variant: variant.public_id,
      run: review.run, text: text.trim() };
    busy = true; paint();
    try {
      const feedback = await conversations.reviewFeedback(comment);
      if (disposed) return;
      const draft = conversations.state.get().draft;
      conversations.setDraft([draft, feedback].filter(Boolean).join("\n\n"));
      text = ""; notice.textContent = t("git_review.added");
    } catch (error) { if (!disposed) notice.textContent = error.message; }
    finally { if (!disposed) { busy = false; paint(); } }
  }

  conversations.readReview({ turn: turn.public_id, variant: variant.public_id }).then((value) => {
    if (!disposed) { reviews = value; paint(); }
  }).catch((error) => {
    if (!disposed && error.name !== "AbortError") {
      element.hidden = false; summary.textContent = t("git_review.unavailable"); notice.textContent = error.message;
    }
  });
  return { element, dispose() { disposed = true; } };
}
