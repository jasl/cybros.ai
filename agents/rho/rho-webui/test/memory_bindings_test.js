import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { openMemoryBindings } from "../webui/features/conversation/memory_bindings.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());
const settle = async () => { for (let n = 0; n < 8; n++) await Promise.resolve(); await flush(); };
const binding = (name = "project") => ({ name, source: { collection_public_id: "collection-one" }, access: "read" });
const button = (root, text) => root.querySelectorAll("button").find((node) => node.textContent === text);
const change = (node, value) => { node.value = value; node.dispatchEvent(new Event("change")); };
const field = (root, label) => {
  const node = root.querySelectorAll("label").find((candidate) => candidate.textContent === label);
  return root.querySelector(`[id="${node.getAttribute("for")}"]`);
};
function open({ selection = { bindings: [binding()] }, writable = true, save, collections } = {}) {
  const writes = [];
  const editor = {
    read: async () => ({ memory_context: selection, effective_memory_context: { bindings: [{ ...binding(), scope: "workspace", state: "archived", collection_public_id: "collection-one" }] } }),
    collections: collections || (async () => ({ memory_collections: [], pagination: { next_after: null } })),
    save: async (value) => { writes.push(value); if (save) return save(value); },
  };
  return { ...openMemoryBindings({ editor, writable, id: "original" }), writes };
}

test("automatic and off remain distinct selections; custom defaults keep Speaker relative", async () => {
  const view = open({ selection: null });
  await settle();
  change(field(view.element, "Memory selection"), "custom");
  button(view.element, "Save").click();
  await settle();
  expect(view.writes[0].bindings.find((row) => row.name === "speaker").source).toEqual({ scope: "speaker" });
  for (const [mode, expected] of [["disabled", { bindings: [] }], ["automatic", null]]) {
    const next = open(); await settle();
    change(field(next.element, "Memory selection"), mode);
    button(next.element, "Save").click(); await settle();
    expect(next.writes).toEqual([expected]);
  }
});

test("paginated collection choices preserve the selection and save an exact UUID with its access", async () => {
  const cursors = [];
  const view = open({ collections: async (after) => {
    cursors.push(after);
    return { memory_collections: [{ public_id: after ? "collection-three" : "collection-two", name: "Shared notes", scope: "workspace" }],
      pagination: { next_after: after ? null : "opaque-next" } };
  } });
  await settle();
  const source = field(view.element, "Source");
  change(source, "collection:collection-two");
  button(view.element, "Load more collections").click(); await settle();
  expect(source.value).toBe("collection:collection-two");
  expect(cursors).toEqual([null, "opaque-next"]);
  expect(view.element.textContent).toContain("Archived · read only");
  button(view.element, "Save").click(); await settle();
  expect(view.writes).toEqual([{ bindings: [{ name: "project", source: { collection_public_id: "collection-two" }, access: "read" }] }]);
});

test("a refused save keeps the draft and never retries on its own", async () => {
  const view = open({ save: async () => { throw new Error("memory_scope_unavailable"); } });
  await settle();
  field(view.element, "Binding name").value = "research";
  button(view.element, "Save").click(); await settle();
  expect(view.writes).toHaveLength(1);
  expect(view.element.open).toBe(true);
  expect(view.element.textContent).toContain("memory_scope_unavailable");
  expect(field(view.element, "Binding name").value).toBe("research");
  expect(button(view.element, "Save").disabled).toBe(false);
  view.dispose();
});

test("read-only bindings expose no save and disposing ignores a late read", async () => {
  const view = open({ writable: false }); await settle();
  expect(button(view.element, "Save")).toBeUndefined();
  expect(view.element.querySelector(".memory-bindings__fields").disabled).toBe(true);
  view.dispose();
  let resolve;
  const late = openMemoryBindings({ editor: { read: () => new Promise((r) => { resolve = r; }) }, writable: true, id: "old" });
  late.dispose();
  resolve({ memory_context: null, effective_memory_context: { bindings: [] } }); await settle();
  expect(late.element.isConnected).toBe(false);
});
