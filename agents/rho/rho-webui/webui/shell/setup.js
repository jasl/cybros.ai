import { observable } from "../kernel/observable.js";
import { t, pluginText } from "../kernel/i18n.js";

const FOCUS_INTERVAL = 1000;

// Setup is a projection of the connected services, never a saved wizard
// step: connection, then a usable default model, then any running plugin
// that still reports it needs setup.
export function setupProgress(status, plugins = []) {
  if (!status?.connected) return { step: "connection", title: t("setup.connect_rho_to_nexus"), ready: false };
  if (!status.model?.ready) {
    if (!status.model?.eligible?.length) return { step: "provider", ready: false, title: t("setup.to_do_configure_a_model_in_nexus") };
    return { step: "model", ready: false, title: t("setup.choose_your_default_model") };
  }
  const plugin = plugins.find((row) => row.enabled && row.active && row.readiness && !row.readiness.ready);
  if (plugin) return { step: "plugin", plugin: plugin.id, title: t("setup.finish_setting_up_plugin", { name: pluginText(plugin, "name") }), ready: false };
  return { step: "ready", title: t("common.rho_is_ready_to_use"), ready: true };
}

// An existing choice always wins. An unavailable choice needs a deliberate
// replacement; catalog order never chooses among several usable models.
export function automaticModel(model) {
  return !model?.default_model && model?.eligible?.length === 1 ? model.eligible[0].ref : null;
}

// Owns `/settings`, `/settings/status`, `/auth/status` and `/status`: the
// documents every settings section and the setup notice read.
export function createSetup({ call, signal, inventory, toast = () => {} }) {
  const state = observable({ document: null, status: null, identity: null, daemon: null, loading: false, error: null });
  let reading = 0;
  let lastFocus = 0;
  let writes = Promise.resolve();
  const automaticAttempts = new Set();

  const progress = () => setupProgress(state.get().status, inventory.state.get().plugins);

  async function refresh() {
    const version = ++reading;
    state.update((previous) => ({ ...previous, loading: true }));
    try {
      const [document, status, identity, daemon] = await Promise.all([
        call("/settings"), call("/settings/status"), call("/auth/status"), call("/status").catch(() => null),
      ]);
      if (signal.aborted || version !== reading) return;
      state.set({ document, status, identity, daemon, loading: false, error: null });
      const automatic = automaticModel(status.model);
      if (status.connected && automatic && !automaticAttempts.has(automatic)) {
        automaticAttempts.add(automatic);
        const saved = await write({ default_model: automatic }, false);
        if (saved && !signal.aborted && version === reading) {
          toast(t("setup.default_model_selected", { automatic }), { tone: "success" });
          const readiness = await call("/settings/status");
          if (!signal.aborted && version === reading) state.update((previous) => ({ ...previous, status: readiness }));
        }
      }
    } catch (error) {
      if (signal.aborted || error.name === "AbortError" || version !== reading) return;
      state.update((previous) => ({ ...previous, loading: false, error }));
    }
  }

  // One write at a time, in order: a save made while another is still being
  // applied — the daemon re-declares its profile on some changes, which can
  // take seconds — waits its turn instead of being dropped. The answer is
  // the new document; errors propagate so the form that asked can show them.
  function save(changes, { refresh: again = true } = {}) {
    const run = writes.then(() => write(changes, again));
    writes = run.catch(() => {});
    return run;
  }

  async function write(changes, again) {
    if (signal.aborted) return null;
    const document = await call("/settings", { method: "PATCH", body: changes });
    if (signal.aborted) return null;
    state.update((previous) => ({ ...previous, document }));
    if (again) await refresh();
    return document;
  }

  function watchFocus() {
    const onFocus = () => {
      const now = Date.now();
      if (now - lastFocus < FOCUS_INTERVAL) return;
      lastFocus = now;
      refresh();
    };
    window.addEventListener("focus", onFocus, { signal });
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") onFocus();
    }, { signal });
  }

  return { state, refresh, save, progress, watchFocus, dispose() { reading += 1; } };
}
