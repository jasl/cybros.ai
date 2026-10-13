import { observable } from "../../kernel/observable.js";

const PAGE_SIZE = 40;
const query = (path, values) => `${path}?${new URLSearchParams(values)}`;

// The sidebar's conversation list: one page at a time, active or archived,
// of the page's current workspace (`workspace()`; null before it is known
// means the daemon's own). A read that finishes after the view changed
// (archived toggled, a newer refresh) is discarded; failures stay in the
// state for the browser to show.
export function createList({ call, signal, workspace = () => null, ready = async () => {} }) {
  // `loaded` turns true once the first read answers either way: until then
  // the sidebar shows nothing final, never "no conversations yet".
  const state = observable({ rows: [], next: null, archived: false, loading: false, loaded: false, error: null });
  let reading = 0;

  async function refresh({ more = false } = {}) {
    const { archived, next, loading } = state.get();
    if (signal.aborted || (more && (!next || loading))) return;
    const version = ++reading;
    state.update((value) => ({ ...value, loading: true }));
    try {
      // A remembered workspace is read against the account's listing first,
      // so a stale one never asks the kernel for conversations it cannot name.
      await ready();
      if (signal.aborted || version !== reading) return;
      const scope = workspace();
      const values = { scope: "main", limit: PAGE_SIZE, archived: archived ? "1" : "0", ...(scope ? { workspace_public_id: scope } : {}), ...(more ? { after: next } : {}) };
      const result = await call(query("/conversations", values));
      if (signal.aborted || version !== reading) return;
      state.update((value) => ({ ...value, rows: more ? [...value.rows, ...result.conversations] : result.conversations,
        next: result.pagination?.next_after || null, loading: false, loaded: true, error: null }));
    } catch (error) {
      if (signal.aborted || version !== reading || error.name === "AbortError") return;
      state.update((value) => ({ ...value, loading: false, loaded: true, error }));
    }
  }

  function setArchived(flag) {
    if (state.get().archived === !!flag) return refresh();
    state.update((value) => ({ ...value, archived: !!flag, rows: [], next: null, error: null }));
    return refresh();
  }

  // A detail read of an open conversation refreshes its row (title, running
  // turn, attention) without waiting for the next list read.
  function merge(conversation) {
    const { rows } = state.get();
    const index = rows.findIndex((row) => row.public_id === conversation.public_id);
    if (index === -1) return;
    const row = { ...rows[index], ...conversation };
    if (JSON.stringify(row) === JSON.stringify(rows[index])) return;
    state.update((value) => ({ ...value, rows: value.rows.map((entry, position) => (position === index ? row : entry)) }));
  }

  return { state, refresh, setArchived, merge };
}
