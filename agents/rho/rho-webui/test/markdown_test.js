import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";
import { markdown } from "../webui/kernel/markdown.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());
const render = (text) => {
  const host = document.createElement("div");
  host.append(markdown(text));
  return host;
};

test("pipe tables render semantic headers, inline values and column alignment", () => {
  const host = render("Answers:\n| Field | Value | Type |\n| :--- | :---: | ---: |\n| enabled | `false` | **boolean** |\n| count | `0` | integer |\n\nDone.");
  expect(host.querySelectorAll("thead th").map((cell) => cell.textContent)).toEqual(["Field", "Value", "Type"]);
  expect(host.querySelectorAll("tbody tr")).toHaveLength(2);
  expect(host.querySelector("td code").textContent).toBe("false");
  expect(host.querySelector("td strong").textContent).toBe("boolean");
  expect(host.querySelectorAll("th").map((cell) => cell.style.textAlign)).toEqual(["left", "center", "right"]);
  expect(host.querySelectorAll("p").map((node) => node.textContent)).toEqual(["Answers:", "Done."]);
  expect(host.querySelector("table").parentNode.getAttribute("tabindex")).toBe("0");
});

test("tables handle optional outer pipes, escaped pipes, and missing or excess cells", () => {
  const host = render("Name | Value\n--- | ---\n`a\\|b` | x\\|y\nshort\none | two | ignored");
  expect(host.querySelectorAll("tbody tr").map((row) => row.children.map((cell) => cell.textContent)))
    .toEqual([["a|b", "x|y"], ["short", ""], ["one", "two"]]);
});

test("table cells keep raw HTML and unsafe links inert", () => {
  const host = render("| Name | Value |\n| --- | --- |\n| <img src=x onerror=alert(1)> | [bad](javascript:alert) |\n| safe | [docs](https://example.com) |");
  expect(host.querySelector("img")).toBeNull();
  expect(host.querySelectorAll("a")).toHaveLength(1);
  expect(host.querySelector("a").href).toBe("https://example.com/");
  expect(host.querySelector("td").textContent).toContain("<img");
});

test("incomplete table headers remain readable and fenced tables stay code", () => {
  for (const text of ["a | b\n---", "a | b\n--- |", "a | b\n--- | --- | ---", "a | b\n--- | nope"]) {
    expect(render(text).querySelector("table")).toBeNull();
  }
  const host = render("```text\n| a | b |\n| --- | --- |\n```\n\n| a | b |\n| --- | --- |\n\n# Next");
  expect(host.querySelector("pre code").textContent).toContain("| --- | --- |");
  expect(host.querySelectorAll("table")).toHaveLength(1);
  expect(host.querySelector("h2").textContent).toBe("Next");
});
