import { test, expect } from "bun:test";
import { artifactKey, preserveTurnArtifacts } from "../webui/views.js";

const turn = { public_id: "turn-a", active_variant: { public_id: "variant-a" } };
const artifact = { path: "preview.svg", filename: "preview.svg" };

// Only the DOM replacement seam is doubled. The pending reader holds the old
// figure, just as a real fetch holds the original result element and button.
function card(keys) {
  const figures = keys.map((key) => ({ dataset: { artifactKey: key }, result: null, disabled: false }));
  for (const [index, figure] of figures.entries()) figure.replaceWith = (other) => { figures[index] = other; };
  return { figures, querySelectorAll: () => figures };
}

test("a status redraw preserves a pending artifact request and its rendered result", async () => {
  const original = card([artifactKey(turn, artifact)]);
  const target = original.figures[0]; target.disabled = true;
  let complete;
  const fetch = new Promise((resolve) => { complete = resolve; }).then((bytes) => {
    target.result = bytes; target.disabled = false;
  });
  const settled = card([artifactKey({ ...turn, status: "completed" }, artifact)]);
  preserveTurnArtifacts(original, settled);
  expect(settled.figures[0]).toBe(target);
  expect(settled.figures[0].disabled).toBe(true);
  complete("decoded image"); await fetch;
  expect(settled.figures[0].result).toBe("decoded image");
  expect(settled.figures[0].disabled).toBe(false);
  const refreshed = card([artifactKey(turn, artifact)]);
  preserveTurnArtifacts(settled, refreshed);
  expect(refreshed.figures[0].result).toBe("decoded image");
});

test("another turn, variant or artifact never inherits the old preview target", () => {
  const original = card([artifactKey(turn, artifact)]);
  for (const [nextTurn, nextArtifact] of [
    [{ ...turn, public_id: "turn-b" }, artifact],
    [{ ...turn, active_variant: { public_id: "variant-b" } }, artifact],
    [turn, { ...artifact, path: "other/preview.svg" }],
    [turn, { public_id: "upload-a", filename: "preview.svg" }],
  ]) {
    const next = card([artifactKey(nextTurn, nextArtifact)]);
    const fresh = next.figures[0];
    preserveTurnArtifacts(original, next);
    expect(next.figures[0]).toBe(fresh);
    expect(next.figures[0]).not.toBe(original.figures[0]);
  }
});

test("repeated appearances retain their own figures without sharing a target", () => {
  const key = artifactKey(turn, artifact);
  const previous = card([key, key]);
  const next = card([key, key]);
  preserveTurnArtifacts(previous, next);
  expect(next.figures[0]).toBe(previous.figures[0]);
  expect(next.figures[1]).toBe(previous.figures[1]);
  expect(next.figures[0]).not.toBe(next.figures[1]);
});
