import { test, expect } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const WEBUI = fileURLToPath(new URL("../webui", import.meta.url));

function files(directory) {
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    return statSync(path).isDirectory() ? files(path) : path.endsWith(".js") ? [path] : [];
  });
}

test("the browser entrypoint and every imported module parse and link", async () => {
  const result = await Bun.build({ entrypoints: [join(WEBUI, "app.js")], target: "browser", write: false });
  expect(result.logs.map((log) => log.message)).toEqual([]);
  expect(result.success).toBe(true);
});

// Features never import each other: shared code lives in kernel/ and
// primitives/, and modules see only the `ui` handle. The one exception is the
// shell mounting the conversation browser into the sidebar.
test("imports respect the layer boundaries", () => {
  const violations = [];
  for (const path of files(WEBUI)) {
    const relative = path.slice(WEBUI.length + 1);
    const layer = relative.split("/")[0];
    for (const match of readFileSync(path, "utf8").matchAll(/^(?:import|export)[^"']*from\s+["']([^"']+)["']/gm)) {
      const target = resolve(dirname(path), match[1]).slice(WEBUI.length + 1);
      const targetLayer = target.split("/")[0];
      if (!match[1].startsWith(".")) violations.push(`${relative} imports a bare specifier ${match[1]}`);
      if (layer === "kernel" && targetLayer !== "kernel" && targetLayer !== "locales") violations.push(`${relative} → ${target}`);
      if (layer === "primitives" && !["primitives", "kernel"].includes(targetLayer)) violations.push(`${relative} → ${target}`);
      if (layer === "features" && targetLayer === "features" && relative.split("/")[1] !== target.split("/")[1]) violations.push(`${relative} → ${target}`);
      if (layer === "features" && targetLayer === "shell") violations.push(`${relative} → ${target}`);
      if (layer === "shell" && targetLayer === "features" && target !== "features/conversation/browser.js") violations.push(`${relative} → ${target}`);
    }
  }
  expect(violations).toEqual([]);
});

test("no shipped file is longer than the review ceiling", () => {
  const long = files(WEBUI).map((path) => [path.slice(WEBUI.length + 1), readFileSync(path, "utf8").split("\n").length]).filter(([, lines]) => lines > 800);
  expect(long).toEqual([]);
});
