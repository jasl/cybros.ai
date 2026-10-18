import { observable } from "../kernel/observable.js";

export const WORKSPACE_KEY = "rho.workspace";

// The page's current workspace: the one whose conversations the sidebar
// lists and where a new conversation starts. It begins as the address's
// `workspace`, else the one this browser remembered, else the daemon's own
// choice; the daemon's choice (Defaults › Default workspace) is what the
// CLI and ingresses use, and switching here never changes it. A remembered
// workspace the account no longer lists falls back to the daemon's.
export function createWorkspaces({ call, signal, router, storage = globalThis.localStorage }) {
  const remembered = read(storage);
  const state = observable({ rows: [], current: router.read().workspace || remembered || null, selection: null, loaded: false, error: null });
  let reading = 0;
  // The first listing's promise: a reader that would name a remembered
  // workspace waits for it, so a stale memory is corrected before it asks.
  let settle = null;
  const ready = new Promise((resolve) => { settle = resolve; });

  const get = () => state.get();
  const listed = (id) => get().rows.some((row) => row.public_id === id);

  async function refresh() {
    if (signal.aborted) return get();
    const version = ++reading;
    try {
      const answer = await call("/workspaces", { signal });
      if (signal.aborted || version !== reading) return get();
      const rows = answer.workspaces || [];
      const selection = answer.workspace?.public_id || null;
      const wanted = get().current;
      const current = rows.some((row) => row.public_id === wanted) ? wanted : selection;
      state.set({ rows, current, selection, loaded: true, error: null });
      remember(storage, current, selection);
      settle();
      // The address says what the page shows, so Back can bring it back: a
      // remembered workspace is written into a hero address, a stale one
      // written out. An opened conversation's address is the conversation's
      // and a panel's names only the panel.
      const address = router.read();
      if (!address.conversation && !address.panel && (address.workspace || null) !== addressed()) router.replace({ workspace: addressed() });
    } catch (error) {
      if (signal.aborted || version !== reading || error.name === "AbortError") return get();
      state.update((value) => ({ ...value, error }));
      settle();
    }
    return get();
  }

  // Make `id` the current workspace. The address keeps `workspace` only
  // when it differs from the daemon's choice, so ordinary links stay short.
  function switchTo(id, { navigate = true } = {}) {
    if (!id || id === get().current) return false;
    state.update((value) => ({ ...value, current: id }));
    remember(storage, id, get().selection);
    if (navigate) router.push({ panel: null, plugin: null, conversation: null, workspace: addressed() }, { notify: true });
    return true;
  }

  // A conversation opened from elsewhere belongs to its own workspace; the
  // page follows it there without rewriting the address.
  function adopt(id) {
    if (!id || id === get().current) return;
    if (listed(id) || !get().loaded) { switchTo(id, { navigate: false }); return; }
    // A Bot's Home or historical workspace may have been created since the
    // first listing. Reread before refusing it, without following a link the
    // person has already left while that read was in flight.
    refresh().then(() => {
      if (!signal.aborted && router.read().workspace === id && listed(id)) switchTo(id, { navigate: false });
    });
  }

  const addressed = () => (get().current && get().current !== get().selection ? get().current : null);

  // Back and Forward move the address; the page's workspace follows it. A
  // hero or conversation address without `workspace` names the daemon's own
  // choice; a panel's address says nothing about the workspace.
  const unsubscribe = router.subscribe((address) => {
    if (address.panel) return;
    const wanted = address.workspace || get().selection;
    if (wanted && wanted !== get().current && (listed(wanted) || !get().loaded)) switchTo(wanted, { navigate: false });
  });
  signal.addEventListener("abort", unsubscribe, { once: true });

  async function create(name) {
    const answer = await call("/workspaces", { method: "POST", body: { name }, signal });
    await refresh();
    switchTo(answer.workspace.public_id);
    return answer.workspace;
  }

  return {
    state, refresh, switchTo, adopt, create, addressed,
    ready: () => ready,
    current: () => get().current,
    row: (id = get().current) => get().rows.find((row) => row.public_id === id) || null,
  };
}

function read(storage) {
  try { return storage?.getItem(WORKSPACE_KEY) || null; } catch { return null; }
}

// Remember a choice other than the daemon's; the daemon's own needs no memory.
function remember(storage, current, selection) {
  try {
    if (current && current !== selection) storage?.setItem(WORKSPACE_KEY, current); else storage?.removeItem(WORKSPACE_KEY);
  } catch { /* storage may be unavailable; the address still carries the choice */ }
}
