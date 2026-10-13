import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";

let restore;
let restoreFetch;
beforeEach(() => { restore = installDocument(); restoreFetch = globalThis.fetch; });
afterEach(() => { globalThis.fetch = restoreFetch; restore(); });

test("a request the browser could not send is refused in words; an abort stays an abort; a refusal keeps the daemon's words", async () => {
  const { call, Refused } = await import("../webui/kernel/api.js");
  globalThis.fetch = async () => { throw new TypeError("Failed to fetch"); };
  const down = await call("/agents").catch((error) => error);
  expect(down).toBeInstanceOf(Refused);
  expect([down.status, down.code, down.message]).toEqual([0, "unreachable", "rho could not be reached. Check that it is running, then refresh."]);

  globalThis.fetch = async () => { throw Object.assign(new Error("aborted"), { name: "AbortError" }); };
  const aborted = await call("/agents").catch((error) => error);
  expect(aborted.name).toBe("AbortError");

  globalThis.fetch = async () => new Response(JSON.stringify({ error: { code: "not_found", message: "no bot named x" } }), { status: 404, headers: { "content-type": "application/json" } });
  const refused = await call("/agents").catch((error) => error);
  expect([refused.status, refused.code, refused.message]).toEqual([404, "not_found", "no bot named x"]);
});
