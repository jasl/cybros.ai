import { locale, t, translator } from "./kernel/i18n.js";
import { bearer, call as request, follow, health, artifactBytes, Refused } from "./kernel/api.js";
import { el } from "./kernel/dom.js";
import { observable } from "./kernel/observable.js";
import { createSlots } from "./kernel/slots.js";
import { createHandle } from "./kernel/handle.js";
import { createModules } from "./kernel/modules.js";
import { createTheme } from "./kernel/theme.js";
import { primitives } from "./primitives/index.js";
import { createToasts } from "./primitives/toast.js";
import { installTooltips } from "./primitives/tooltip.js";
import { createRouter } from "./shell/router.js";
import { createBoot } from "./shell/boot.js";
import { createLogin, startNexusLogin } from "./shell/login.js";
import { createInventory } from "./shell/inventory.js";
import { createSetup } from "./shell/setup.js";
import { createWorkspaces } from "./shell/workspaces.js";
import { createBots } from "./shell/bots.js";
import { createNexus } from "./shell/nexus.js";
import { createFrame } from "./shell/frame.js";
import { register as registerConversation, createConversations } from "./features/conversation/index.js";
import { register as registerPlugins } from "./features/plugins/index.js";
import { register as registerSettings } from "./features/settings/index.js";
import { register as registerSchedules } from "./features/schedules/index.js";
import { register as registerBackground } from "./features/background/index.js";
import { register as registerUsage } from "./features/usage/index.js";
import { register as registerTask } from "./features/task/index.js";
import { register as registerBots } from "./features/bots/index.js";
import { register as registerNexus } from "./features/nexus/index.js";

// The page speaks one control version; a daemon that speaks another gets a
// sentence instead of a half-working console.
const CONTROL_VERSION = 4;
const MODULE_BOOT_DEADLINE = 3000;
const BUILT_INS = [
  ["conversation", registerConversation], ["plugins", registerPlugins], ["settings", registerSettings],
  ["schedules", registerSchedules], ["bots", registerBots], ["nexus", registerNexus], ["background", registerBackground], ["usage", registerUsage],
  ["task", registerTask],
];

const root = document.getElementById("root");
const boot = createBoot(document.getElementById("boot"));
document.title = t("brand.rho");
document.documentElement.lang = locale;
const theme = createTheme();
installTooltips();
let session = null;
let login = null;

function showLogin(message = "") {
  login?.destroy();
  root.hidden = false;
  login = createLogin({ root, call: request, credentials: bearer, onReady: enter, message });
  login.initialize();
}

async function enter() {
  login?.destroy(); login = null;
  session = createSession();
  await session.start();
}

// One authenticated page session: every registry, request and subscription
// hangs off its signal, so sign-out or a lost grant tears all of it down and
// a fresh login starts clean.
function createSession() {
  const controller = new AbortController();
  const { signal } = controller;
  const toasts = createToasts();
  const router = createRouter();
  const slots = createSlots();
  let frame = null;

  function dispose() {
    if (signal.aborted) return false;
    controller.abort();
    frame?.dispose(); modules.dispose(); conversations?.dispose(); bots.dispose();
    inventory.dispose(); setup.dispose(); toasts.dispose(); router.dispose();
    root.replaceChildren();
    session = null;
    return true;
  }
  function leave(message = "") {
    if (dispose()) showLogin(message);
  }

  // Every request and stream of the session: a 401 anywhere means the grant
  // is gone, and the page says so once instead of each caller handling it.
  const authorityLost = (error) => {
    if (error instanceof Refused && error.status === 401) leave(t("shell.authorization_lost"));
    throw error;
  };
  const call = (path, options = {}) => request(path, { signal, ...options }).catch(authorityLost);
  const followStream = (id, options) => follow(id, options).catch(authorityLost);
  const readArtifact = (...args) => artifactBytes(...args).catch(authorityLost);

  const toast = (text, options) => toasts.toast(text, options);
  const navigation = observable(router.read().panel || "conversation");
  // Each open is a fresh request, so naming the same section twice still lands on it.
  const settingsRequest = observable(null);
  // The conversation panel's address is the open conversation's, or the
  // current workspace's hero; a panel's address names only the panel.
  // Retained panels read the address when shown, so publish it first.
  const navigate = (key) => {
    if (key === "conversation") {
      const { id, workspace } = shell.conversations.selection.get();
      router.push({ panel: null, plugin: null, conversation: id, workspace: id ? workspace : workspaces.addressed() });
    } else {
      const address = router.read();
      router.push({ panel: key, plugin: key === "plugins" ? address.plugin : null, item: key === address.panel ? address.item : null, conversation: null, workspace: null });
    }
    navigation.set(key);
  };
  const dock = {
    open: (key, options) => frame?.dock.open(key, options),
    close: () => frame?.dock.close(),
    toggle: () => frame?.dock.toggle(),
    state: () => frame?.dock.state,
  };

  // The inventory is created after the modules it syncs, so handles reach it late.
  const inventoryLate = { refresh: () => inventory.refresh() };
  const handleParts = { slots, call, toast, navigate, dock, primitives, el, translator, inventory: inventoryLate };
  const modules = createModules({
    makeHandle: (id) => createHandle({ id, ...handleParts }),
    onError: (error, facts) => console.error(`webui module ${facts.id} failed while ${facts.phase}`, error),
  });
  // A contribution that throws is reported on its module's row; a built-in
  // failure is the page's own bug and is said once.
  const renderError = (error, { registration }) => {
    console.error(`${registration.name} contribution by ${registration.owner} failed`, error);
    if (registration.owner.startsWith("rho.webui")) toast(t("shell.part_of_the_page_failed"), { tone: "error" });
    else modules.report(registration.owner, error);
  };
  const openPlugin = (id) => { router.push({ panel: "plugins", plugin: id }, { notify: true }); navigation.set("plugins"); };
  const inventory = createInventory({ call, signal, modules, toast, openPlugin });
  const setup = createSetup({ call, signal, inventory, toast });
  const workspaces = createWorkspaces({ call, signal, router });
  const bots = createBots({ call, signal, setup });
  const nexus = createNexus({ call });
  const shell = {
    signal, slots, call, follow: followStream, artifactBytes: readArtifact, router, navigation, navigate, openPlugin, inventory, modules, setup, theme,
    workspaces, bots, nexus, toast, dock, renderError, leave,
    // Settings is a main page; an opener may name the section it lands on.
    settings: { request: settingsRequest, open: (section, item = null) => { if (section) settingsRequest.set({ section, item }); navigate("settings"); } },
    signOut: async () => {
      try { await request("/auth/logout", { method: "POST", body: {} }); } catch { /* the grant may already be gone */ }
      bearer.clear();
      leave();
    },
    // A page an unlock admitted asks for its Nexus account; the sign-in
    // leaves for Nexus and the login page finishes it on return.
    signIn: async () => {
      try { await startNexusLogin({ call: request, credentials: bearer }); }
      catch (error) { toast(error.message || t("login.could_not_connect_to_nexus_try_again"), { tone: "error" }); }
    },
    conversations: null,
  };
  const conversations = createConversations({ call, follow: followStream, artifactBytes: readArtifact, signal, toast, router, setup, workspaces,
    openDock: dock.open, openSettings: shell.settings.open, renderError });
  shell.conversations = conversations;

  async function start() {
    for (const [name, register] of BUILT_INS) {
      const handle = createHandle({ id: `rho.webui/${name}`, ...handleParts });
      try { await register(handle.ui, shell); }
      catch (error) { console.error(`built-in ${name} failed to register`, error); toast(t("shell.part_of_the_page_failed"), { tone: "error" }); }
    }
    const shellHandle = createHandle({ id: "rho.webui/shell", ...handleParts });
    frame = createFrame({ root, slots, shell, ui: shellHandle.ui });
    boot.watch(modules.state);
    // Modules load behind the boot page, but never hold it hostage: after the
    // deadline the frame mounts and late modules render as they register.
    await Promise.race([
      Promise.all([setup.refresh().then(() => inventory.refresh()), workspaces.refresh()]).catch((error) => console.error("boot refresh failed", error)),
      new Promise((resolve) => setTimeout(resolve, MODULE_BOOT_DEADLINE)),
    ]);
    if (signal.aborted) return;
    frame.mount();
    root.hidden = false;
    boot.hide();
    await conversations.start();
    inventory.watchFocus();
    setup.watchFocus();
  }

  return { start, leave, dispose };
}

// The page a browser with this tab's bearer gets, else the login page.
async function resume() {
  if (!location.pathname.endsWith("/auth/callback") && bearer.get()) { await enter(); return; }
  boot.hide();
  showLogin();
}

async function main() {
  let facts = {};
  try { facts = await health(); } catch { /* the login screen remains usable */ }
  if (facts.control_version && facts.control_version !== CONTROL_VERSION) {
    boot.fail(t("boot.different_daemon"),
      [t("boot.control_version_mismatch", { page: CONTROL_VERSION, daemon: facts.control_version })]);
    return;
  }
  await resume();
}

// Leaving tears the page down — streams close and the daemon's followers are
// released — whether the tab is closing or the document is going into the
// back/forward cache. A document that comes back from that cache is the
// torn-down one (a login whose controller is aborted, a session whose frame
// is gone), so it is rebuilt as a fresh load would be. The first show of a
// new document has `persisted` false and is `main`'s.
window.addEventListener("pagehide", () => { login?.destroy(); session?.dispose(); });
window.addEventListener("pageshow", (event) => { if (event.persisted) resume(); });
main();
