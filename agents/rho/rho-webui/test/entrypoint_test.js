import { test, expect } from "bun:test";
import { fileURLToPath } from "node:url";

test("the browser entrypoint and every imported module parse and link", async () => {
  const result = await Bun.build({
    entrypoints: [fileURLToPath(new URL("../webui/console.js", import.meta.url))],
    target: "browser",
    write: false,
  });
  expect(result.success).toBe(true);
});
