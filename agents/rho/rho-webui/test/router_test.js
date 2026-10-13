import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";
import { createRouter } from "../webui/shell/router.js";

let restore;
beforeEach(() => { restore = installDocument({ url: "http://localhost/workspaces/w-1/conversations/c-1?debug=1" }); });
afterEach(() => restore());

test("the address is read from the path and written back as a path, with the query string left alone", () => {
  const router = createRouter();
  expect(router.read()).toEqual({ panel: null, conversation: "c-1", workspace: "w-1", plugin: null, item: null });
  router.push({ panel: "plugins", plugin: "rho.ingress_telegram" });
  expect(location.pathname + location.search).toBe("/plugins/rho.ingress_telegram?debug=1");
  expect(router.read()).toEqual({ panel: "plugins", conversation: null, workspace: null, plugin: "rho.ingress_telegram", item: null });
  router.replace({ plugin: null });
  expect(location.pathname).toBe("/plugins");
  router.push({ panel: "telegram", plugin: null });
  expect(location.pathname).toBe("/panels/telegram");
  router.push({ panel: null, conversation: null, workspace: "w-2" });
  expect(location.pathname).toBe("/workspaces/w-2");
  router.replace({ workspace: null });
  expect(location.pathname + location.search).toBe("/?debug=1");
  router.dispose();
});

test("popstate notifies subscribers with the current address and dispose stops it", () => {
  const router = createRouter();
  const seen = [];
  const unsubscribe = router.subscribe((address) => seen.push(address.conversation));
  globalThis.location = new URL("http://localhost/conversations/c-2");
  window.dispatchEvent(new Event("popstate"));
  expect(seen).toEqual(["c-2"]);
  unsubscribe();
  window.dispatchEvent(new Event("popstate"));
  expect(seen).toEqual(["c-2"]);
  router.dispose();
});
