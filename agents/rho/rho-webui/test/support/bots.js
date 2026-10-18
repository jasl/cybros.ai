import { observable } from "../../webui/kernel/observable.js";

// A bots store for tests: rho's own row and the bots given, shaped as
// `shell/bots.js` shapes them; `set` replaces the listed rows.
export function fakeBots({ own = { public_id: "u-rho", name: "rho", display_name: "rho", own: true, model_standing: "available" },
  bots = [] } = {}) {
  const state = observable({ bots: bots.map((row) => ({ model_standing: "available", ...row })), loaded: true, loading: false, error: null });
  const refreshes = [];
  const rows = () => [own, ...state.get().bots];
  return {
    state, rows, refreshes,
    own: () => own,
    byId: (id) => (id ? rows().find((row) => row.public_id === id) || null : null),
    startable: (bot) => !!bot && (bot.own || (bot.model_standing !== "unset" && !bot.registered)),
    refresh: async () => { refreshes.push(state.get()); return state.get(); },
    set: (next) => state.update((value) => ({ ...value, ...next })),
    dispose() {},
  };
}
