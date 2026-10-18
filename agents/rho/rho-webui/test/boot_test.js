import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";
import { createBoot } from "../webui/shell/boot.js";
import { observable } from "../webui/kernel/observable.js";
import { el } from "../webui/kernel/dom.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

test("the boot page grows its arc as modules settle, names the ones still loading or failed, and leaves", () => {
  const element = el("div", { id: "boot" }, el("span", { class: "boot__spinner" }));
  document.body.append(element);
  const boot = createBoot(element);
  const states = observable(new Map([
    ["a", { id: "a", name: "Alpha", status: "loading" }],
    ["b", { id: "b", name: "Beta", status: "loading" }],
  ]));
  boot.watch(states);
  expect(element.style.getPropertyValue("--boot-arc")).toBe("72deg");
  expect(element.querySelectorAll(".boot__line").map((line) => line.textContent)).toEqual(["Alpha: loading", "Beta: loading"]);
  states.set(new Map([["a", { id: "a", name: "Alpha", status: "ready" }], ["b", { id: "b", name: "Beta", status: "failed" }]]));
  expect(element.style.getPropertyValue("--boot-arc")).toBe("288deg");
  expect(element.querySelectorAll(".boot__line").map((line) => line.textContent)).toEqual(["Beta: failed"]);
  expect(element.querySelector(".boot__line--failed")).not.toBeNull();
  boot.hide();
  expect(element.isConnected).toBe(false);
});

test("a failure keeps the page readable instead of blank", () => {
  const element = el("div", { id: "boot" }, el("span", { class: "boot__spinner" }));
  document.body.append(element);
  createBoot(element).fail("This page was built for a different daemon", ["page 4, daemon 5"]);
  expect(element.querySelector(".boot__spinner")).toBeNull();
  expect(element.querySelector(".boot__failure").textContent).toBe("This page was built for a different daemon");
  expect(element.querySelector(".boot__line").textContent).toBe("page 4, daemon 5");
});
