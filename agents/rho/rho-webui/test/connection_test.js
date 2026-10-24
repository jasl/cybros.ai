import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { connectionCard } from "../webui/features/settings/connection.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

function mount(call) {
  let refreshed = 0;
  const card = connectionCard({ call }, { document: { deployment: {} }, refresh: async () => { refreshed += 1; } });
  document.body.append(card.element);
  const fields = card.element.querySelectorAll("input");
  return { card, fields, refreshed: () => refreshed, submit: async () => {
    card.element.querySelector("form").dispatchEvent(new Event("submit"));
    await flush();
  } };
}

test("import sends both application password fields and clears them after installation", async () => {
  const requests = [];
  const writes = [];
  localStorage.setItem = (...args) => writes.push(args);
  sessionStorage.setItem = (...args) => writes.push(args);
  const view = mount(async (...args) => { requests.push(args); });
  view.fields.forEach((field, index) => { field.value = `private-${index}`; expect(field.type).toBe("password"); });
  await view.submit();
  expect(requests).toEqual([["/connection/api_keys", { method: "POST", body: {
    access_token: "private-0", executor_access_token: "private-1",
  } }]]);
  expect(view.fields.map((field) => field.value)).toEqual(["", ""]);
  expect(view.refreshed()).toBe(1);
  expect(view.card.element.textContent).not.toContain("private-0");
  expect(writes).toEqual([]);
});

test("import clears rejected inputs", async () => {
  const requests = [];
  const view = mount(async (...args) => { requests.push(args); throw new Error("Wrong Agent"); });
  view.fields.forEach((field, index) => { field.value = `private-${index}`; });
  await view.submit();
  expect(requests[0][1].body).toEqual({ access_token: "private-0", executor_access_token: "private-1" });
  expect(view.fields.map((field) => field.value)).toEqual(["", ""]);
  expect(view.card.element.textContent).toContain("Wrong Agent");
  expect(view.refreshed()).toBe(0);
});
