import { observable } from "../kernel/observable.js";
import { t } from "../kernel/i18n.js";

// The daemon lists persistent Bot identities with their selected Preset and
// effective model. The main Agent identity comes from setup status.
export function createBots({ call, signal, setup }) {
  const state = observable({ bots: [], loaded: false, loading: false, error: null });
  let reading = 0;

  async function refresh() {
    if (signal.aborted) return state.get();
    const version = ++reading;
    state.update((value) => ({ ...value, loading: true }));
    try {
      const answer = await call("/agents", { signal });
      if (signal.aborted || version !== reading) return state.get();
      const byName = (a, b) => (a.display_name || a.name).localeCompare(b.display_name || b.name);
      state.set({ bots: [...(answer.bots || [])].sort(byName), loaded: true, loading: false, error: null });
    } catch (error) {
      if (signal.aborted || version !== reading || error.name === "AbortError") return state.get();
      // Before the daemon adopts a workspace there are no bots to list;
      // the shape stays readable and the next adoption refreshes it.
      state.update((value) => ({ ...value, loading: false, loaded: error.code === "member_plane_unavailable" || value.loaded, error }));
    }
    return state.get();
  }

  // rho's own row, shaped like a bot: the handle Nexus knows it by, or the
  // brand before the identity is read.
  function own() {
    const identity = setup.state.get().daemon?.identity;
    return { public_id: identity?.user_public_id || null, name: identity?.handle || t("brand.rho"), display_name: identity?.handle || t("brand.rho"),
      own: true, description: t("agents.own_description"), model_standing: "available" };
  }

  // Every bot a conversation may be started with, rho first.
  const rows = () => [own(), ...state.get().bots];
  const byId = (id) => (id ? rows().find((row) => row.public_id === id) || null : null);
  // Whether a conversation may start with the bot: rho always; a bot with a
  // model; never an extension's registered row (its ingress owns it).
  const startable = (bot) => !!bot && (bot.own || (bot.model_standing !== "unset" && !bot.registered));

  // A re-adopted workspace or a reconnected daemon lists other rows.
  let adopted = null;
  const stop = setup.state.subscribe((value) => {
    const next = value.daemon?.workspace?.state === "adopted" ? value.daemon.identity?.user_public_id || true : null;
    if (next === adopted) return;
    adopted = next;
    if (next) refresh();
  }, { immediate: true });

  return { state, refresh, own, rows, byId, startable, dispose() { stop(); } };
}
