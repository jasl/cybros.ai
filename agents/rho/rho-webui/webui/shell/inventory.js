import { observable } from "../kernel/observable.js";
import { t, pluginText } from "../kernel/i18n.js";

const FOCUS_INTERVAL = 1000;

// The one owner of `GET /extensions`. The Plugins page reads it, the module
// loader follows it (`capabilities.webui` names each running plugin's browser
// entry), and a mutation's answer is applied in place so the page never
// shows a stale row after its own write.
export function createInventory({ call, signal, modules, toast, openPlugin }) {
  const state = observable({ plugins: [], failures: [], loading: false, error: null, loaded: false });
  let reading = 0;
  let pending = null;
  let lastFocus = 0;
  const reported = new Set();

  function rows(plugins) {
    return plugins.filter((plugin) => plugin.capabilities?.webui).map((plugin) => ({ id: plugin.id, name: pluginText(plugin, "name"), entry: plugin.capabilities.webui }));
  }

  // A module that failed is said once per page, with a way to its row.
  function announceFailures() {
    for (const [id, facts] of modules.state.get()) {
      if (facts.status !== "failed" || reported.has(id)) continue;
      reported.add(id);
      toast(t("shell.module_failed_toast", { name: facts.name }), { tone: "error",
        action: { label: t("shell.module_failed_view"), onClick: () => openPlugin(id) } });
    }
  }

  async function apply(answer) {
    state.update((previous) => ({ ...previous, ...answer, loading: false, error: null, loaded: true }));
    await modules.sync(rows(answer.plugins));
    announceFailures();
  }

  function refresh() {
    if (pending) return pending;
    const version = ++reading;
    state.update((previous) => ({ ...previous, loading: true }));
    pending = call("/extensions").then(async (answer) => {
      if (signal.aborted || version !== reading) return;
      await apply(answer);
    }).catch((error) => {
      if (signal.aborted || error.name === "AbortError") return;
      state.update((previous) => ({ ...previous, loading: false, error }));
    }).finally(() => { pending = null; });
    return pending;
  }

  // An enable/disable/configure answer carries the plugin's new row.
  function accept(answer) {
    if (!answer?.plugin) return refresh();
    const plugins = state.get().plugins.map((row) => (row.id === answer.plugin.id ? answer.plugin : row));
    if (!plugins.some((row) => row.id === answer.plugin.id)) plugins.push(answer.plugin);
    return apply({ ...state.get(), plugins });
  }

  function watchFocus() {
    const onFocus = () => {
      const now = Date.now();
      if (now - lastFocus < FOCUS_INTERVAL) return;
      lastFocus = now;
      refresh();
    };
    window.addEventListener("focus", onFocus, { signal });
  }

  return {
    state, refresh, accept, watchFocus,
    plugin: (id) => state.get().plugins.find((row) => row.id === id) || null,
    dispose() { reading += 1; },
  };
}
