import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";
import { createTheme, CONTENT_SIZE } from "../webui/kernel/theme.js";

let restore;
beforeEach(() => { restore = installDocument({ dark: true }); });
afterEach(() => restore());

test("appearance follows the system until chosen, and the choice is a local display preference", () => {
  const theme = createTheme();
  expect(theme.appearance.get()).toBe("system");
  expect(theme.effective()).toBe("dark");
  expect(document.documentElement.hasAttribute("data-theme")).toBe(false);
  theme.setAppearance("light");
  expect(document.documentElement.getAttribute("data-theme")).toBe("light");
  expect(theme.effective()).toBe("light");
  expect(localStorage.getItem("rho.appearance")).toBe("light");
  theme.setAppearance("system");
  expect(localStorage.getItem("rho.appearance")).toBeNull();
  expect(() => theme.setAppearance("sepia")).toThrow("Unknown appearance");
  expect(createTheme().appearance.get()).toBe("system");
});

test("content size is clamped to 10–22 and written as the --content-size variable", () => {
  const theme = createTheme();
  expect(theme.contentSize.get()).toBe(CONTENT_SIZE.default);
  theme.setContentSize(30);
  expect(theme.contentSize.get()).toBe(22);
  expect(document.documentElement.style.getPropertyValue("--content-size")).toBe("22px");
  theme.setContentSize("abc");
  expect(theme.contentSize.get()).toBe(14);
  expect(localStorage.getItem("rho.content_size")).toBeNull();
  localStorage.setItem("rho.content_size", "11");
  expect(createTheme().contentSize.get()).toBe(11);
});
