import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { fakeBots } from "./support/bots.js";
import { createHero, runnerChoice } from "../webui/features/conversation/hero.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

test("the resolved default runner fills a fresh conversation while a manual choice survives refresh", () => {
  const own = { public_id: "own", own: true, selected: false };
  const remote = { public_id: "remote", own: false, selected: false };
  const runners = [remote, own];
  expect(runnerChoice(runners, { current: "", defaultRunner: "own", edited: false })).toBe(own);
  expect(runnerChoice(runners, { current: "own", defaultRunner: "remote", edited: false })).toBe(remote);
  expect(runnerChoice(runners, { current: "remote", defaultRunner: "own", edited: true })).toBe(remote);
  expect(runnerChoice(runners, { current: "", defaultRunner: null, edited: false })).toBeNull();
  expect(runnerChoice(runners, { current: "own", defaultRunner: "unavailable", edited: false })).toBeNull();
  expect(runnerChoice([remote, { ...own, selected: true }], { current: "", defaultRunner: null, edited: false })?.public_id).toBe("own");
});

function hero({ progress = { step: "ready", title: "rho is ready to use", ready: true }, ...overrides } = {}) {
  const state = observable({ id: null, error: "", runner: "own", choicesError: null,
    runners: [{ public_id: "own", display_name: "Laptop", own: true, root: "/home/me", presence: "online" }, { public_id: "remote", display_name: "Build box" }], ...overrides });
  const calls = [];
  const conversations = {
    state,
    setRunner: (id) => { calls.push(["setRunner", id]); state.update((value) => ({ ...value, runner: id })); },
  };
  const setupState = observable({ status: { connected: true } });
  const bots = fakeBots({ bots: [{ public_id: "u-reviewer", name: "reviewer", display_name: "Reviewer" }] });
  const shell = { setup: { state: setupState, progress: () => progress }, inventory: { state: observable({ plugins: [] }) }, bots,
    settings: { open: (...target) => calls.push(["settings", ...target]) }, openPlugin: (id) => calls.push(["plugin", id]) };
  const view = createHero({ conversations, shell });
  document.body.append(view.element);
  return { view, state, calls, bots, element: view.element };
}

test("the runner chip lists runners with this machine and presence, and choosing one is a deliberate edit", () => {
  const h = hero();
  const chip = h.element.querySelector(".hero__location .chip");
  expect(chip.getAttribute("aria-label")).toBe("Runner: Laptop");
  chip.click();
  const items = document.body.querySelectorAll("[role=menuitemradio]");
  expect(items.map((item) => item.textContent)).toEqual(["Laptop · This machine · online", "Build box"]);
  items[1].click();
  expect(h.calls).toEqual([["setRunner", "remote"]]);
  expect(chip.querySelector(".chip__label").textContent).toBe("Build box");
});

test("a new conversation offers only Runner selection without a directory control", () => {
  const h = hero();
  const location = h.element.querySelector(".hero__location");
  expect(location.querySelectorAll("button")).toHaveLength(1);
  expect(location.getAttribute("aria-label")).toBe("Runner");
  expect(location.querySelector("button").getAttribute("aria-label")).toBe("Runner: Laptop");
  expect(h.element.querySelectorAll('input, [aria-haspopup="dialog"]')).toHaveLength(0);
  expect(h.element.textContent).not.toContain("/home/me");
});

test("an incomplete setup shows its step above the composer with the way to finish it", () => {
  const model = hero({ progress: { step: "model", title: "Choose your default model", ready: false } });
  const notice = model.element.querySelector(".hero__notice");
  expect(notice.hidden).toBe(false);
  expect(notice.textContent).toContain("Choose your default model");
  expect(notice.querySelector(".hero__notice-text").textContent).toBe("Finish setup to start a conversation.");
  expect(notice.querySelector("button").textContent).toBe("Agent Presets");
  notice.querySelector("button").click();
  expect(model.calls).toEqual([["settings", "presets", "main"]]);
  restore(); restore = installDocument();
  const connection = hero({ progress: { step: "connection", title: "Connect rho to Nexus", ready: false } });
  expect(connection.element.querySelector(".hero__notice-text").textContent).toBe("Finish setup to start a conversation.");
  expect(connection.element.querySelector(".hero__notice button").textContent).toBe("Open Settings");
  connection.element.querySelector(".hero__notice button").click();
  expect(connection.calls).toEqual([["settings", "general"]]);
  restore(); restore = installDocument();
  const plugin = hero({ progress: { step: "plugin", plugin: "rho.ingress_telegram", title: "Finish setting up Telegram", ready: false } });
  const action = plugin.element.querySelector(".hero__notice button");
  expect(action.textContent).toBe("Open plugin");
  action.click();
  expect(plugin.calls).toEqual([["plugin", "rho.ingress_telegram"]]);
  restore(); restore = installDocument();
  expect(hero().element.querySelector(".hero__notice").hidden).toBe(true);
});

test("a failed create is said in the hero, and unavailable runners are named", () => {
  const h = hero({ error: "Choose an available workspace", runners: [], choicesError: new Error("down") });
  expect(h.element.querySelector(".alert--error").textContent).toBe("Choose an available workspace");
  expect(h.element.querySelector(".hero__location .chip").getAttribute("aria-label")).toBe("Runner: Runners unavailable");
});

test("a new conversation with a bot wears the bot's mark and name; rho's own keeps the brand", () => {
  const h = hero();
  expect(h.element.querySelector(".hero__title").textContent).toBe("What should rho work on?");
  expect(h.element.querySelector('.hero__mark .icon[data-icon="rho"]')).not.toBeNull();
  h.state.update((value) => ({ ...value, agent: "u-reviewer" }));
  expect(h.element.querySelector(".hero__title").textContent).toBe("What should Reviewer work on?");
  const mark = h.element.querySelector(".hero__mark .mark--glyph");
  expect(mark.querySelector('.icon[data-icon="bot"]')).not.toBeNull();
  expect(mark.className).toContain("mark--lg");
  // A bot the page does not know yet reads as rho until the bots load.
  h.state.update((value) => ({ ...value, agent: "u-later" }));
  expect(h.element.querySelector(".hero__title").textContent).toBe("What should rho work on?");
  h.bots.set({ bots: [...h.bots.state.get().bots, { public_id: "u-later", name: "later", display_name: "Later" }] });
  expect(h.element.querySelector(".hero__title").textContent).toBe("What should Later work on?");
  h.state.update((value) => ({ ...value, agent: null }));
  expect(h.element.querySelector(".hero__title").textContent).toBe("What should rho work on?");
});
