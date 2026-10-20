import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { el } from "../webui/kernel/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { createArtifactOpener } from "../webui/kernel/artifacts.js";
import { turnRow } from "../webui/features/conversation/turn.js";
import { activityDisclosure } from "../webui/features/conversation/activity.js";
import { createTranscript } from "../webui/features/conversation/transcript.js";
import { executionIdentity } from "../webui/features/conversation/lifecycle.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const opener = (artifactBytes = async () => new Blob(["x"], { type: "text/plain" })) =>
  createArtifactOpener({ artifactBytes, host: () => "c-1", signal: new AbortController().signal });
const action = (node, label) => node.querySelectorAll("button").find((button) => button.getAttribute("aria-label") === label);
const deps = (overrides = {}) => ({ artifacts: opener(), activity: () => el("details", { class: "activity-stub" }), ...overrides });
const reference = {
  public_id: "turn-reference", kind: "direct_reply", role: "assistant", status: "completed", reference: true,
  published_artifacts: [{ public_id: "up-reference", filename: "parent.pdf" }],
  active_variant: { public_id: "variant-reference", prompt_text: "the parent question",
    content: "User:\nthe parent question\n\nAssistant:\nReading /tmp/ledger.txt. The parent keeps its execution." },
};

test("a parent reference is one readable context card without duplicated prompt or inferred actions", () => {
  const card = turnRow(reference, deps());
  expect(card.localName).toBe("article");
  expect(card.textContent).toContain("Parent conversation reference snapshot");
  expect(card.textContent).toContain("Read-only context captured when this side conversation opened.");
  expect(card.textContent.match(/the parent question/g)).toHaveLength(1);
  expect(card.querySelectorAll("button, details, figure")).toHaveLength(0);
  expect(executionIdentity({ active_turn_public_id: null }, [reference], { turn: reference.public_id })).toBeNull();
});

test("a reply that owns its prompt shows it as the person's message, then the answer with its artifacts and activity", () => {
  const reply = { public_id: "turn-reply", kind: "direct_reply", role: "assistant", status: "completed",
    published_artifacts: [{ public_id: "up-answer", filename: "answer.txt" }],
    active_variant: { public_id: "variant-reply", run_public_id: "run-reply", prompt_text: "the side question", content: "The answer is saved in answer.txt." } };
  const node = turnRow(reply, deps());
  const [prompt, answer] = node.children;
  expect(prompt.className).toBe("turn turn--user");
  expect(prompt.textContent).toContain("the side question");
  expect(answer.className).toBe("turn turn--assistant");
  expect(answer.querySelector(".markdown").textContent).toBe("The answer is saved in answer.txt.");
  expect(answer.querySelectorAll("figure[data-artifact-key]")).toHaveLength(1);
  expect(answer.querySelectorAll(".activity-stub")).toHaveLength(1);
  expect(executionIdentity({}, [reference, reply], { turn: reply.public_id })).toBe("turn-reply:run-reply");
});

test("an acknowledgement's filename mentions do not acquire a later callback's published files", async () => {
  const files = [{ public_id: "up-readme", filename: "README.md" }, { public_id: "up-bundle", filename: "project.zip" }];
  const reads = [];
  const artifacts = opener(async (artifact) => {
    reads.push(artifact);
    return new Blob(["# Published README"]);
  });
  try {
    const ack = turnRow({ public_id: "ack-turn", kind: "direct_reply", role: "assistant", status: "completed", published_artifacts: [],
      active_variant: { public_id: "ack-variant", content: "I will prepare README.md and project.zip. The README.md will explain usage." } }, deps({ artifacts }));
    const result = turnRow({ public_id: "result-turn", kind: "direct_reply", role: "assistant", status: "completed", origin: "child",
      published_artifacts: files, active_variant: { public_id: "result-variant", content: "README.md and project.zip are ready." } }, deps({ artifacts }));
    document.body.append(ack, result);
    expect(ack.querySelectorAll("figure, .artifact__actions button")).toHaveLength(0);
    expect(result.querySelectorAll("figure").map((figure) => figure.querySelector(".artifact__name").textContent)).toEqual(["README.md", "project.zip"]);
    action(result, "Preview README.md").click();
    await flush();
    expect(result.querySelector(".artifact__result h2").textContent).toBe("Published README");
    action(result, "Download project.zip").click();
    await flush();
    expect(reads).toEqual(files);
  } finally { artifacts.dispose(); }
});

test("explicit file paths and owned attachments remain actionable without guessing bare filenames", () => {
  const attachment = { path: "attached.md", filename: "attached.md" };
  const shown = [];
  turnRow({ public_id: "paths-turn", role: "assistant", status: "completed", active_variant: { public_id: "paths-variant",
    content: "README.md, notes.txt and image.png are names. Read /tmp/report.MD, ./notes.md, ../logs.txt and output/data.json. [README](./README.md)",
    attachments: [attachment] } },
  deps({ artifacts: { figure: (artifact) => { shown.push(artifact); return el("figure"); } } }));
  expect(shown).toEqual([attachment, ...["/tmp/report.MD", "./notes.md", "../logs.txt", "output/data.json", "./README.md"]
    .map((path) => ({ path, filename: path.split("/").pop() }))]);
});

const receipt = '<task_result source="worker">The requested report is ready.</task_result>';
for (const origin of ["child", "task_result"]) {
  test(`${origin} reply folds its receipt while the parent's answer and published files stay visible`, () => {
    const node = turnRow({ public_id: "result-turn", kind: "direct_reply", role: "assistant", status: "completed", origin,
      callback_sources: [], published_artifacts: [{ public_id: "up-report", filename: "report.md" }],
      active_variant: { public_id: "result-variant", prompt_text: receipt, content: "Your report is ready.", run_public_id: "result-run" } }, deps());
    const [prompt, answer] = node.children;
    expect(prompt.querySelector(".turn__speaker")?.textContent).not.toBe("You");
    const details = prompt.querySelector("details");
    expect(details).not.toBeNull();
    expect(details.open).toBe(false);
    expect(details.querySelector("summary").textContent).toContain("Background task result");
    details.open = true;
    expect(details.open).toBe(true);
    expect(details.querySelector(".markdown").textContent).toBe(receipt);
    expect(answer.querySelector(".markdown").textContent).toBe("Your report is ready.");
    expect(answer.querySelectorAll("figure[data-artifact-key]")).toHaveLength(1);
    expect(answer.querySelectorAll(".activity-stub")).toHaveLength(1);
  });

  test(`${origin} message from a callback batch keeps its receipt folded and readable`, () => {
    const node = turnRow({ public_id: "receipt-turn", kind: "message", role: "user", status: "completed", origin,
      callback_sources: [], active_variant: { public_id: "receipt-variant", content: receipt,
        attachments: [{ public_id: "up-receipt", filename: "worker.md" }] } }, deps());
    expect(node.querySelector(".turn__speaker")?.textContent).not.toBe("You");
    const details = node.querySelector("details");
    expect(details).not.toBeNull();
    expect(details.open).toBe(false);
    details.open = true;
    expect(details.open).toBe(true);
    expect(details.querySelector(".markdown").textContent).toBe(receipt);
    expect(node.querySelectorAll("figure[data-artifact-key]")).toHaveLength(1);
    expect(details.querySelectorAll("figure")).toHaveLength(0);
  });
}

test("person and ingress-authored agent inputs keep callback-looking text as ordinary user content", () => {
  for (const origin of ["person", "agent"]) {
    for (const kind of ["message", "direct_reply"]) {
      const node = turnRow({ public_id: "person-turn", kind, role: kind === "message" ? "user" : "assistant", status: "completed", origin,
        sender_conversation_public_id: "sender", callback_sources: [], active_variant: { public_id: "person-variant",
          content: kind === "message" ? receipt : "An ordinary answer.", prompt_text: kind === "direct_reply" ? receipt : undefined } }, deps());
      const prompt = kind === "message" ? node : node.firstElementChild;
      expect(prompt.className).toBe("turn turn--user");
      expect(prompt.querySelector(".turn__speaker").textContent).toBe("You");
      expect(prompt.querySelector(".markdown").textContent).toBe(receipt);
      expect(prompt.querySelector("details")).toBeNull();
    }
  }
});

test("files without a renderer offer only Download beside direct and callback answers", async () => {
  const files = ["report.pdf", "notes.docx", "budget.xlsx", "sources.ZIP", "trace.log", "notes.txt", "data.json", "unknown.bin"]
    .map((filename, index) => ({ public_id: `up-${index}`, filename, content_type: "image/png" }));
  const reads = [];
  const artifacts = opener(async (artifact, host, _signal, download) => {
    reads.push({ artifact, host, download });
    return new Blob(["published bytes"], { type: "image/png" });
  });
  try {
    for (const origin of ["person", "child"]) {
      const node = turnRow({ public_id: `turn-${origin}`, kind: "direct_reply", role: "assistant", status: "completed", origin,
        callback_sources: origin === "child" ? [{ result: { variant_public_id: "worker-variant" } }] : [],
        published_artifacts: files, active_variant: { public_id: `variant-${origin}`, content: "The requested files are ready." } }, deps({ artifacts }));
      document.body.append(node);
      const figures = node.querySelectorAll("figure[data-artifact-key]");
      expect(figures.map((figure) => figure.querySelector(".artifact__name").textContent)).toEqual(files.map((file) => file.filename));
      for (const figure of figures) {
        const name = figure.querySelector(".artifact__name").textContent;
        expect(figure.querySelectorAll("button").map((button) => button.getAttribute("aria-label"))).toEqual([`Download ${name}`]);
        action(figure, `Download ${name}`).click();
        await flush();
        expect(figure.querySelector("a").getAttribute("href")).toStartWith("blob:");
      }
    }
    expect(reads).toEqual([...files, ...files].map((artifact) => ({ artifact, host: "c-1", download: true })));
  } finally { artifacts.dispose(); }
});

test("Markdown Preview renders authenticated file contents with the existing safe Markdown vocabulary", async () => {
  const reads = [];
  const source = "# Usage\n\nRun **tally** with `--help`.\n\n<script>alert(1)</script>\n\n[unsafe](javascript:alert)";
  const artifacts = opener(async (artifact, host, _signal, download) => {
    reads.push({ artifact, host, download });
    return new Blob([source], { type: "application/octet-stream" });
  });
  try {
    for (const filename of ["notes.Md", "README.MARKDOWN"]) {
      const artifact = { public_id: `upload-${filename}`, filename };
      const figure = artifacts.figure(artifact);
      document.body.append(figure);
      const preview = action(figure, `Preview ${filename}`);
      expect(preview?.textContent).toBe("Preview");
      preview.click();
      expect(preview.disabled).toBe(true);
      await flush();
      expect(preview.disabled).toBe(false);
      const body = figure.querySelector(".markdown");
      expect(body.querySelector("h2").textContent).toBe("Usage");
      expect(body.querySelector("strong").textContent).toBe("tally");
      expect(body.querySelector("code").textContent).toBe("--help");
      expect(body.textContent).toContain("<script>alert(1)</script>");
      expect(body.querySelectorAll("script, a")).toHaveLength(0);
      expect(figure.querySelector(".artifact__result > a").getAttribute("download")).toBe(filename);
      expect(reads.at(-1)).toEqual({ artifact, host: "c-1", download: false });
    }
    const inferred = turnRow({ public_id: "markdown-path", role: "assistant", status: "completed",
      active_variant: { content: "Read /tmp/notes.MARKDOWN." } }, deps({ artifacts }));
    expect(action(inferred, "Preview notes.MARKDOWN")).toBeDefined();
  } finally { artifacts.dispose(); }
});

test("Preview keeps supported image extensions even when upload bytes have a generic MIME type", async () => {
  const artifacts = opener(async () => new Blob(["image bytes"], { type: "application/octet-stream" }));
  try {
    for (const filename of ["shot.PNG", "photo.jpg", "photo.JpEg", "motion.gif", "picture.webp", "picture.avif", "drawing.svg", "icon.ico"]) {
      const figure = artifacts.figure({ public_id: `upload-${filename}`, filename });
      document.body.append(figure);
      const preview = action(figure, `Preview ${filename}`);
      expect(preview?.textContent).toBe("Preview");
      preview.click();
      await flush();
      const image = figure.querySelector("img");
      expect(image.getAttribute("alt")).toBe(filename);
      expect(image.getAttribute("src")).toStartWith("blob:");
      expect(figure.querySelector(".artifact__result > a").getAttribute("download")).toBe(filename);
    }
  } finally { artifacts.dispose(); }
});

test("published files take precedence over prose paths with the same filename without merging distinct uploads", () => {
  const published = [{ public_id: "up-a", filename: "report.md" }, { public_id: "up-b", filename: "report.md" }];
  const shown = [];
  turnRow({ public_id: "turn-files", role: "assistant", status: "completed", published_artifacts: published,
    active_variant: { public_id: "variant-files", content: "Read report.md or /home/runner/report.md. Also see /tmp/logs.txt." } },
  deps({ artifacts: { figure: (artifact) => { shown.push(artifact); return el("figure"); } } }));
  expect(shown).toEqual([...published, { path: "/tmp/logs.txt", filename: "logs.txt" }]);
});

test("turn bodies say what is there: the person's bubble, summaries folded, previews and pruned details labelled", () => {
  const user = turnRow({ public_id: "u", role: "user", status: "completed", active_variant: { content: "**hello**" } }, deps());
  expect(user.querySelector(".turn__bubble strong").textContent).toBe("hello");
  expect(user.querySelector(".turn__speaker").textContent).toBe("You");
  const summary = turnRow({ public_id: "s", kind: "compaction_summary", role: "system", active_variant: { content: "Earlier work." } }, deps());
  expect(summary.querySelector("details summary").textContent).toContain("Context summary");
  const preview = turnRow({ public_id: "p", role: "assistant", status: "completed", active_variant: { content_preview: "Short…", run_public_id: "r" } }, deps());
  expect(preview.textContent).toContain("Preview");
  const pruned = turnRow({ public_id: "x", role: "assistant", status: "completed", active_variant: { content: "Kept text", details_pruned_at: "2026-01-01", run_public_id: "r" } }, deps());
  expect(pruned.textContent).toContain("Execution details removed by the retention policy");
  expect(pruned.querySelectorAll(".activity-stub")).toHaveLength(0);
  const failed = turnRow({ public_id: "f", role: "assistant", status: "failed", active_variant: {} }, deps());
  expect(failed.querySelector(".turn__placeholder").textContent).toBe("Response failed");
  const answering = turnRow({ public_id: "a", role: "assistant", status: "running", active_variant: {} }, deps({ active: true }));
  expect(answering.querySelector(".turn__placeholder")).toBeNull();
});

test("activity reads its rounds once when opened and links calls and rounds to the task tab", async () => {
  const reads = [];
  const opened = [];
  const rounds = async (runId, before) => {
    reads.push([runId, before]);
    if (before) return { rounds: [{ task_key: "r0", status: "completed", calls: { items: [], count: 0 } }], has_older: false };
    return { has_older: true, next_before: "cursor-1", rounds: [{ task_key: "r1", status: "completed", text_preview: "Checked *files*",
      calls: { count: 3, items: [{ name: "bash", status: "completed", task_key: "c1", output_preview: "wrote /tmp/report.txt. report.txt is ready.", is_error: false },
        { name: "read", status: "failed", key: "c2", is_error: true }] }, branches: ["c1"] }] };
  };
  const box = activityDisclosure("run-1", "turn-1", { rounds, openTask: (...args) => opened.push(args), artifacts: opener() });
  document.body.append(box);
  expect(box.querySelector("summary").textContent).toContain("Tools and activity");
  box.open = true;
  await flush();
  expect(reads).toEqual([["run-1", null]]);
  expect(box.textContent).toContain("1 more calls are outside this preview.");
  expect(box.textContent).toContain("Branches under c1.");
  expect(box.textContent).toContain("Round preview — open the full round for complete output.");
  const calls = box.querySelectorAll(".round details");
  expect(calls.map((call) => call.querySelector(".disclosure__title").textContent)).toEqual(["bash", "read"]);
  expect(calls[1].className).toContain("disclosure--bad");
  expect(calls[0].querySelector("pre").textContent).toBe("wrote /tmp/report.txt. report.txt is ready.");
  expect(calls[0].querySelectorAll("figure")).toHaveLength(1);
  calls[1].querySelector(".link-button").click();
  box.querySelector(".round__heading .link-button").click();
  expect(opened).toEqual([["run-1", "c2", "read"], ["run-1", "r1", "Model round"]]);
  box.open = false; box.open = true;
  expect(reads).toHaveLength(1);
  box.querySelector(".disclosure__body > button").click();
  await flush();
  expect(reads.at(-1)).toEqual(["run-1", "cursor-1"]);
  expect(box.querySelectorAll(".round")).toHaveLength(2);
});

test("a repaint while an artifact is loading keeps that read's figure; another variant gets a fresh one", async () => {
  let deliver;
  const state = observable({ id: "c-1", access: "ready", detail: { public_id: "c-1" }, turns: [], older: false, snapshot: null, live: "", reasoning: "" });
  const conversations = { state, rounds: async () => ({ rounds: [] }), openTask: () => {}, loadOlder: async () => {},
    artifactOpener: () => opener(() => new Promise((resolve) => { deliver = resolve; })) };
  const scroller = el("div");
  const transcript = createTranscript({ conversations, scroller });
  scroller.append(transcript.element);
  document.body.append(scroller);
  const turn = { public_id: "t-1", position: 1, role: "assistant", status: "running", published_artifacts: [{ public_id: "up-notes", filename: "notes.md" }],
    active_variant: { public_id: "v-1", content: "See notes.md" } };
  state.update((value) => ({ ...value, turns: [turn] }));
  const figure = transcript.element.querySelector("figure");
  figure.querySelector("button").click();
  expect(figure.querySelector("button").disabled).toBe(true);
  state.update((value) => ({ ...value, turns: [{ ...turn, status: "completed" }] }));
  expect(transcript.element.querySelector("figure")).toBe(figure);
  deliver(new Blob(["# File contents"], { type: "application/octet-stream" }));
  await flush();
  expect(figure.querySelector(".artifact__result h2").textContent).toBe("File contents");
  expect(figure.querySelector(".artifact__result a").getAttribute("href")).toStartWith("blob:");
  state.update((value) => ({ ...value, turns: [{ ...turn, active_variant: { public_id: "v-2", content: "See notes.md" } }] }));
  expect(transcript.element.querySelector("figure")).not.toBe(figure);
  const loading = transcript.element.querySelector("figure");
  action(loading, "Preview notes.md").click();
  let finishText;
  const blob = new Blob(["# Old variant"]);
  blob.text = () => new Promise((resolve) => { finishText = resolve; });
  deliver(blob);
  await flush();
  state.update((value) => ({ ...value, turns: [{ ...turn, active_variant: { public_id: "v-3", content: "See notes.md" } }] }));
  finishText("# Old variant");
  await flush();
  expect(loading.querySelector(".artifact__result").textContent).toBe("");
  expect(transcript.element.querySelector(".artifact__result").textContent).toBe("");
  transcript.dispose();
});

test("recorded change cards follow their reply, survive repaint, and never fill a new conversation", async () => {
  const reply = (id) => ({ public_id: id, kind: "direct_reply", role: "assistant", status: "completed",
    active_variant: { public_id: `v-${id}`, run_public_id: `run-${id}`, content: `Answer ${id}`,
      prompt_text: `Question ${id}`, runner_effects: { status: "touched" } } });
  const state = observable({ id: "c-1", access: "ready", detail: {}, turns: [reply("one"), reply("empty"), reply("late")],
    older: false, snapshot: null, live: "", reasoning: "" });
  const reads = []; let finish;
  const recorded = [{ runner: "original", root: "/project", base: "before", run: "run-one",
    files: [{ path: "one.txt", status: "A", state: "text", patch: "@@ -0,0 +1 @@\n+one\n", additions: 1, deletions: 0 }] }];
  const conversations = { state, rounds: async () => ({ rounds: [] }), openTask: () => {}, loadOlder: async () => {},
    artifactOpener: () => opener(), readReview: async ({ turn }) => {
      reads.push(turn);
      return turn === "one" ? recorded : turn === "late" ? new Promise((resolve) => { finish = resolve; }) : [];
    } };
  const scroller = el("div");
  const transcript = createTranscript({ conversations, scroller });
  scroller.append(transcript.element); document.body.append(scroller);
  await flush();
  const first = transcript.element.querySelector('[data-turn-id="one"] .git-review');
  expect(first.hidden).toBe(false);
  expect(transcript.element.querySelector('[data-turn-id="empty"] .git-review').hidden).toBe(true);
  state.update((value) => ({ ...value, turns: value.turns.map((turn) => ({ ...turn, published_artifacts: [] })) }));
  expect(transcript.element.querySelector('[data-turn-id="one"] .git-review')).toBe(first);
  expect(reads).toEqual(["one", "empty", "late"]);
  state.update((value) => ({ ...value, id: "c-2", turns: [] }));
  finish(recorded); await flush();
  expect(transcript.element.querySelector(".git-review")).toBeNull();
  transcript.dispose();
});
