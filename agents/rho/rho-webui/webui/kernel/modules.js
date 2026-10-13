import { observable } from "./observable.js";

// Browser modules of running extensions. `sync(rows)` makes the loaded set
// match `rows` (`{ id, name, entry }` for every plugin whose inventory row
// carries `capabilities.webui`): new entries are imported and registered,
// rows that disappear or change entry are disposed. Runs are serialized and
// coalesced to the latest desired set.
//
// An ES module instance is cached per URL for the life of the document, so a
// plugin enabled again with the same entry has `register` called again on
// the same instance with a fresh handle; a new entry URL (another installed
// version) is a new import. A failed module stays failed until its entry
// changes or the page reloads — there is no retry that could half-register.
export function createModules({ makeHandle, importer = (url) => import(url), onError = () => {} }) {
  const state = observable(new Map());
  const live = new Map();
  let pending = null;
  let queued = null;

  function record(id, facts) {
    state.update((previous) => {
      const next = new Map(previous);
      if (facts === null) next.delete(id); else next.set(id, { ...next.get(id), ...facts });
      return next;
    });
  }

  function remove(id) {
    const entry = live.get(id);
    if (!entry) return;
    live.delete(id);
    entry.handle?.dispose();
    record(id, null);
  }

  async function load(row) {
    const handle = makeHandle(row.id);
    const entry = { entry: row.entry, handle };
    live.set(row.id, entry);
    record(row.id, { id: row.id, name: row.name, entry: row.entry, status: "loading", phase: "import", message: "" });
    let phase = "import";
    try {
      const module = await importer(row.entry);
      if (live.get(row.id) !== entry) return;
      if (typeof module?.register !== "function") throw new Error("does not export register(ui)");
      phase = "register";
      record(row.id, { phase });
      await module.register(handle.ui);
      if (live.get(row.id) !== entry) return;
      record(row.id, { status: "ready", phase: null });
    } catch (error) {
      if (live.get(row.id) !== entry) return;
      handle.dispose();
      entry.handle = null;
      record(row.id, { status: "failed", phase, message: error?.message || String(error) });
      onError(error, { id: row.id, phase });
    }
  }

  async function run(rows) {
    const desired = new Map(rows.map((row) => [row.id, row]));
    for (const [id, entry] of [...live]) {
      const want = desired.get(id);
      if (!want || want.entry !== entry.entry) remove(id);
    }
    await Promise.all([...desired.values()].filter((row) => !live.has(row.id)).map(load));
  }

  function sync(rows) {
    if (pending) { queued = rows; return pending; }
    pending = run(rows).finally(() => {
      pending = null;
      if (queued) { const next = queued; queued = null; sync(next); }
    });
    return pending;
  }

  // A contribution that threw while rendering: the module keeps its other
  // registrations, and its row shows the failure.
  function report(id, error) {
    if (!live.has(id)) return;
    record(id, { status: "failed", phase: "render", message: error?.message || String(error) });
  }

  return {
    state,
    sync,
    report,
    dispose() { for (const id of [...live.keys()]) remove(id); },
  };
}
