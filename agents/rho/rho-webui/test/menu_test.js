import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, key } from "./support/dom.js";
import { menuButton } from "../webui/primitives/menu.js";
import { createToasts } from "../webui/primitives/toast.js";
import { field, input, switchControl, segmented } from "../webui/primitives/field.js";
import { alert } from "../webui/primitives/feedback.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

test("a menu is built when opened, is keyboard navigable, runs the chosen item and returns focus", () => {
  const picked = [];
  const trigger = menuButton({ label: "Model", variant: "chip", items: () => [
    { type: "title", label: "Models" },
    { type: "radio", label: "A", checked: true, onSelect: () => picked.push("a") },
    { type: "radio", label: "B", onSelect: () => picked.push("b") },
    { type: "separator" },
    { type: "item", label: "Disabled", disabled: true },
  ] });
  document.body.append(trigger.element);
  trigger.element.click();
  const menu = document.body.querySelector(".menu");
  expect(trigger.element.getAttribute("aria-expanded")).toBe("true");
  const items = menu.querySelectorAll("[role^=menuitem]");
  expect(items).toHaveLength(3);
  expect(items[0].getAttribute("aria-checked")).toBe("true");
  expect(document.activeElement).toBe(items[0]);
  key(menu, "ArrowDown");
  expect(document.activeElement).toBe(items[1]);
  key(menu, "ArrowDown");
  expect(document.activeElement).toBe(items[0]);
  key(menu, "End");
  expect(document.activeElement).toBe(items[1]);
  items[1].click();
  expect(picked).toEqual(["b"]);
  expect(document.body.querySelector(".menu")).toBeNull();
  expect(trigger.element.getAttribute("aria-expanded")).toBe("false");
  expect(document.activeElement).toBe(trigger.element);
  trigger.update({ label: "Model B" });
  expect(trigger.element.textContent).toBe("Model B");
});

test("toasts stack to three, announce errors and run their action", () => {
  const toasts = createToasts({ hold: 1000, fade: 10 });
  const acted = [];
  toasts.toast("one");
  toasts.toast("two", { tone: "success" });
  toasts.toast("three", { tone: "error", action: { label: "View", onClick: () => acted.push("viewed") } });
  toasts.toast("four");
  const nodes = toasts.element.querySelectorAll(".toast");
  expect(nodes.map((node) => node.textContent)).toEqual(["two", "threeView", "four"]);
  expect(nodes[1].getAttribute("role")).toBe("alert");
  nodes[1].querySelector(".toast__action").click();
  expect(acted).toEqual(["viewed"]);
  expect(toasts.element.querySelectorAll(".toast")).toHaveLength(2);
  toasts.dispose();
  expect(toasts.element.querySelectorAll(".toast")).toHaveLength(0);
});

test("fields wire labels, hints and errors for assistive technology; switches and segments report changes", () => {
  const control = input({ name: "owner" });
  const wrapped = field({ label: "Owner", control, hint: "Numeric id" });
  expect(wrapped.element.querySelector("label").getAttribute("for")).toBe(control.id);
  expect(control.getAttribute("aria-describedby")).toBe(`${control.id}-hint`);
  wrapped.setError("Required");
  expect(control.getAttribute("aria-describedby")).toBe(`${control.id}-hint ${control.id}-error`);
  expect(control.hasAttribute("aria-invalid")).toBe(true);
  wrapped.setError(null);
  expect(control.hasAttribute("aria-invalid")).toBe(false);

  const changes = [];
  const toggle = switchControl({ label: "Enabled", onChange: (event) => changes.push(event.target.checked) });
  toggle.input.click();
  expect(changes).toEqual([true]);
  expect(toggle.input.getAttribute("role")).toBe("switch");
  toggle.set(false, { disabled: true });
  expect(toggle.input.checked).toBe(false);
  expect(toggle.input.disabled).toBe(true);

  const picks = [];
  const group = segmented({ label: "Appearance", value: "system", onChange: (value) => picks.push(value),
    options: [{ value: "system", label: "System" }, { value: "light", label: "Light" }, { value: "dark", label: "Dark" }] });
  group.element.querySelectorAll("input")[2].click();
  expect(picks).toEqual(["dark"]);
  group.set("light");
  expect(group.element.querySelectorAll("input")[1].checked).toBe(true);

  const box = alert({ tone: "info" });
  expect(box.element.hidden).toBe(true);
  box.show("Saved", "success");
  expect(box.element.className).toBe("alert alert--success");
  expect(box.element.getAttribute("role")).toBe("status");
  box.show("Broken");
  expect(box.element.getAttribute("role")).toBe("status");
  box.show("Broken", "error");
  expect(box.element.getAttribute("role")).toBe("alert");
});
