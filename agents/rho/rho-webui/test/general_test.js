import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { createTheme } from "../webui/kernel/theme.js";
import { generalSection } from "../webui/features/settings/general.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const eligible = [{ ref: "local/a", display_name: "Model A" }, { ref: "local/b" }];
function general({ document = {}, status = {}, identity = { human: { display_name: "Ada", role: "owner" } }, save = async () => null } = {}) {
  const calls = [];
  const theme = createTheme({ storage: localStorage, root: globalThis.document.documentElement, media: { matches: false } });
  const shell = { theme, signOut: () => calls.push("signOut"), setup: { state: observable({ daemon: { version: "0.9.1" } }) } };
  let props = { document: { settings: { default_model: null }, nexus: {}, deployment: {}, ...document },
    status: { connected: true, model: { ready: false, default_model: null, eligible }, defaults: {}, ...status }, identity, save, refresh: async () => {} };
  const view = generalSection(shell, props);
  globalThis.document.body.append(view.element);
  return { view, calls, theme, element: view.element, update: (changes) => { props = { ...props, ...changes }; view.update(props); } };
}
const byLabel = (root, text) => globalThis.document.getElementById(root.querySelectorAll("label").find((node) => node.textContent === text).getAttribute("for"));

test("the account names the signed-in Human and role, and Sign out ends this browser's session", () => {
  const g = general();
  expect(g.element.textContent).toContain("Signed in to Nexus as Ada (owner).");
  g.element.querySelectorAll("button").find((node) => node.textContent === "Sign out").click();
  expect(g.calls).toEqual(["signOut"]);
  g.update({ identity: {} });
  expect(g.element.textContent).toContain("Your Nexus session is unavailable. Sign out and connect again.");
});

test("the model card is rho's bot's now: General carries the account, access, display and deployment alone", () => {
  const g = general();
  expect(g.element.querySelectorAll(".card__title").map((node) => node.textContent)).toEqual(["Nexus account", "Display", "Opening this page", "Runtime API keys"]);
  expect(g.element.querySelector('[name="default_model"]')).toBeNull();
  const deployment = g.element.querySelectorAll("details").find((node) => node.textContent.includes("Deployment information"));
  expect(deployment.open).toBe(false);
});

test("appearance and content size drive this browser's theme and follow changes made elsewhere", () => {
  const g = general();
  const dark = g.element.querySelectorAll("input[type=radio]").find((input) => input.value === "dark");
  dark.checked = true;
  dark.dispatchEvent(new Event("change"));
  expect(g.theme.appearance.get()).toBe("dark");
  expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
  expect(localStorage.getItem("rho.appearance")).toBe("dark");
  g.theme.setAppearance("light");
  expect(g.element.querySelectorAll("input[type=radio]").find((input) => input.value === "light").checked).toBe(true);
  const larger = g.element.querySelectorAll(".stepper button")[1];
  expect(larger.getAttribute("aria-label")).toBe("Content size +");
  larger.click();
  expect(g.theme.contentSize.get()).toBe(15);
  expect(document.documentElement.style.getPropertyValue("--content-size")).toBe("15px");
  expect(g.element.querySelector(".stepper output").textContent).toBe("15 px");
  g.theme.setContentSize(22);
  expect(g.element.querySelector(".stepper output").textContent).toBe("22 px");
  expect(g.element.querySelectorAll(".stepper button")[1].disabled).toBe(true);
});

test("readiness, deployment facts and the daemon version are listed as the deployment states them", () => {
  const g = general({ document: { deployment: { mode: "full", api_only: false, bind: "127.0.0.1:7000", webui_root: null, extra: { a: 1 } } },
    status: { defaults: { tools_ready: true, runner_executor_public_id: "r-1" } } });
  const facts = g.element.querySelectorAll(".settings-facts dt").map((term) => [term.textContent, term.nextElementSibling.textContent]);
  expect(facts).toEqual([["Version", "0.9.1"], ["Operating mode", "Agent and Runner"], ["API only", "No"], ["Configured listening address", "127.0.0.1:7000"],
    ["Web interface directory", "Not set in settings"], ["extra", '{"a":1}']]);
  expect(g.element.textContent).toContain("A tool list has been received and a default Runner is selected.");
});

test("an unlocked page names how it got in, offers a Nexus sign-in, and locks only when a password admitted it", () => {
  const g = general({ identity: { authenticated: true, session: "unlock", human: null, access: { mode: "open", configured: null, password_set: false } } });
  const button = (label) => g.element.querySelectorAll("button").find((node) => node.textContent === label);
  expect(g.element.textContent).toContain("rho's gate is open here");
  expect(button("Sign in with Nexus").hidden).toBe(false);
  expect(button("Lock").hidden).toBe(true);
  g.update({ identity: { authenticated: true, session: "unlock", human: null, access: { mode: "password", configured: "password", password_set: true } } });
  expect(g.element.textContent).toContain("Unlocked with rho's password");
  expect(button("Lock").hidden).toBe(false);
  button("Lock").click();
  expect(g.calls).toEqual(["signOut"]);
  g.update({ identity: { authenticated: true, session: "human", human: { display_name: "Ada", role: "owner" }, access: { mode: "password", configured: "password", password_set: true } } });
  expect(g.element.textContent).toContain("Signed in to Nexus as Ada (owner).");
  expect(button("Sign out").hidden).toBe(false);
  expect(button("Sign in with Nexus").hidden).toBe(true);
});

test("the access card saves the password before asking for it, then the mode, and reads the gate again", async () => {
  const requests = [];
  const saves = [];
  let identity = { authenticated: true, session: "human", human: { display_name: "Ada", role: "owner" }, access: { mode: "open", configured: null, password_set: false } };
  const theme = createTheme({ storage: localStorage, root: globalThis.document.documentElement, media: { matches: false } });
  const shell = { theme, signOut() {}, signIn() {}, setup: { state: observable({ daemon: {} }) },
    call: async (path, options) => { requests.push([path, options.body]); identity = { ...identity, access: { ...identity.access, password_set: options.body.password !== null } }; return { password_set: true }; } };
  let refreshes = 0;
  let props = { document: { settings: { default_model: null, webui_access: null }, nexus: {}, deployment: {} }, status: { connected: true, model: { eligible: [] }, defaults: {} },
    identity, save: async (changes) => { saves.push(changes); props = { ...props, document: { ...props.document, settings: { ...props.document.settings, ...changes } } }; return props.document; },
    refresh: async () => { refreshes += 1; props = { ...props, identity }; view.update(props); } };
  const view = generalSection(shell, props);
  globalThis.document.body.append(view.element);
  const mode = byLabel(view.element, "Who can open this page");
  expect(mode.options.map((option) => option.textContent)).toEqual(["Automatic", "Open · anyone who reaches this page", "Nexus sign-in", "Unlock password"]);
  expect(view.element.textContent).toContain("Right now: Open · anyone who reaches this page.");
  const password = byLabel(view.element, "Unlock password");
  expect(password.closest(".field").hidden).toBe(true);
  mode.value = "password";
  mode.dispatchEvent(new Event("change"));
  expect(password.closest(".field").hidden).toBe(false);
  mode.closest("form").dispatchEvent(new Event("submit"));
  await flush();
  expect(view.element.textContent).toContain("Type an unlock password to ask for one.");
  expect(saves).toEqual([]);
  password.value = "correct horse battery";
  password.dispatchEvent(new Event("input"));
  mode.closest("form").dispatchEvent(new Event("submit"));
  await flush();
  expect(requests).toEqual([["/auth/password", { password: "correct horse battery" }]]);
  expect(saves).toEqual([{ webui_access: "password" }]);
  expect(refreshes).toBe(1);
  expect(password.value).toBe("");
  expect(mode.closest(".card").querySelector(".alert--success").textContent).toBe("Settings saved and active.");
  // Back to automatic, dropping the password: the mode changes before the password goes.
  mode.value = "";
  mode.dispatchEvent(new Event("change"));
  const remove = view.element.querySelector('input[name="remove_password"]');
  expect(remove.closest("label").hidden).toBe(false);
  remove.checked = true;
  remove.dispatchEvent(new Event("change"));
  mode.closest("form").dispatchEvent(new Event("submit"));
  await flush();
  expect(saves.at(-1)).toEqual({ webui_access: null });
  expect(requests.at(-1)).toEqual(["/auth/password", { password: null }]);
});
