import { test, expect } from "bun:test";
import { turnCard } from "../webui/views.js";
import { executionIdentity } from "../webui/lifecycle.js";

// Only the DOM is doubled; the ordinary turn and Markdown renderers build the
// tree whose visible text, controls and execution identity the page consumes.
function withDocument(run) {
  const previous = globalThis.document;
  const node = (tag, nodeType = 1) => ({
    tag, nodeType, children: [], textContent: "", listeners: {},
    setAttribute(name, value) { this[name] = value; },
    addEventListener(name, handler) { this.listeners[name] = handler; },
    append(...children) { this.children.push(...children); },
  });
  globalThis.document = {
    createElement: (tag) => node(tag),
    createTextNode: (text) => ({ nodeType: 3, textContent: text }),
    createDocumentFragment: () => node(null, 11),
  };
  try { run(); } finally { globalThis.document = previous; }
}

const descendants = (node) => typeof node === "string" ? [] : [node, ...(node.children || []).flatMap(descendants)];
const textOf = (node) => typeof node === "string" ? node : node.textContent + (node.children || []).map(textOf).join("");
const controls = { onActivity: () => {}, onArtifact: () => {} };
const reference = {
  public_id: "turn-reference", kind: "direct_reply", role: "assistant", status: "completed", reference: true,
  active_variant: { public_id: "variant-reference", prompt_text: "the parent question",
    content: "User:\nthe parent question\n\nAssistant:\nReading ledger.txt; the parent keeps its execution." },
};

test("a parent reference is one readable context card without duplicated prompt or inferred actions", () => withDocument(() => {
  const card = turnCard(reference, controls);
  const text = textOf(card);
  expect(card.tag).toBe("article");
  expect(text).toContain("Parent conversation reference snapshot");
  expect(text).toContain("Read-only context captured when this side conversation opened.");
  expect(text.match(/the parent question/g)).toHaveLength(1);
  expect(text).toContain("Reading ledger.txt; the parent keeps its execution.");
  expect(descendants(card).filter((node) => ["button", "details", "figure"].includes(node.tag))).toHaveLength(0);
}));

test("a reference variant never supplies an execution identity", () => {
  expect(executionIdentity({ active_turn_public_id: null }, [reference], { turn: reference.public_id })).toBeNull();
});

test("a later owned reply retains its prompt, result artifacts and own execution", () => withDocument(() => {
  const reply = { public_id: "turn-reply", kind: "direct_reply", role: "assistant", status: "completed",
    active_variant: { public_id: "variant-reply", run_public_id: "run-reply",
      prompt_text: "the side question", content: "The answer is saved in answer.txt." } };
  const cards = [reference, reply].map((turn) => turnCard(turn, controls));
  expect(textOf(cards[0])).toContain("Parent conversation reference snapshot");
  expect(textOf(cards[1])).toContain("the side question");
  expect(textOf(cards[1])).toContain("The answer is saved in answer.txt.");
  expect(descendants(cards[1]).filter((node) => node.tag === "button")).toHaveLength(2);
  expect(descendants(cards[1]).filter((node) => node.tag === "details")).toHaveLength(1);
  expect(executionIdentity({}, [reference, reply], { turn: reply.public_id })).toBe("turn-reply:run-reply");
}));
