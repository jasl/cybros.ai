// The slot catalog is closed: each name has one owner that renders an outlet
// for it, and every contribution — the shell's own features and a running
// extension's module alike — arrives through `register`. A `list` slot shows
// every cell in order; a `keyed` slot shows the cell the owner asks for.
// Within a cell the lowest `priority` wins, so a module may deliberately
// shadow a built-in; the same priority twice is a collision and refused.
export const SLOTS = Object.freeze({
  "main": Object.freeze({ kind: "keyed" }),
  "sidebar.panellist": Object.freeze({ kind: "list" }),
  "settings.section": Object.freeze({ kind: "keyed", meta: ["label"] }),
  "bots.item.config": Object.freeze({ kind: "list" }),
  "plugins.item.config": Object.freeze({ kind: "keyed" }),
  "dock.tab": Object.freeze({ kind: "keyed", meta: ["title"] }),
  "conversation.header.utilities": Object.freeze({ kind: "list" }),
});

const byRank = (left, right) => left.priority - right.priority || left.seq - right.seq;
const byOrder = (left, right) => left.order - right.order || left.seq - right.seq;

export function createSlots({ catalog = SLOTS } = {}) {
  const cells = new Map();
  const listeners = new Map();
  let seq = 0;

  function spec(name) {
    const found = catalog[name];
    if (!found) throw new Error(`Unknown slot ${name}`);
    return found;
  }

  function notify(name) {
    for (const listener of [...(listeners.get(name) || [])]) listener();
  }

  // Throws synchronously for every mistake a contributor can make, so a
  // module's `register` fails loudly instead of rendering nothing.
  function register(name, options = {}, component, owner = "rho.webui") {
    const { kind, meta = [] } = spec(name);
    if (typeof component !== "function") throw new Error(`${name}: a component must be a function`);
    const cellName = kind === "list" ? "id" : "key";
    const cell = options[cellName];
    if (typeof cell !== "string" || cell === "") throw new Error(`${name}: ${cellName} is required`);
    for (const field of meta) {
      if (options[field] === undefined) throw new Error(`${name}: ${field} is required`);
    }
    const priority = options.priority ?? 0;
    if (!cells.has(name)) cells.set(name, new Map());
    const rows = cells.get(name).get(cell) || [];
    const occupant = rows.find((row) => row.priority === priority);
    if (occupant) throw new Error(`${name}: ${cell} is already registered by ${occupant.owner}`);

    const registration = Object.freeze({
      name, cell, order: options.order ?? 0, priority, owner, component, seq: ++seq, meta: Object.freeze({ ...options }),
    });
    cells.get(name).set(cell, [...rows, registration].sort(byRank));
    notify(name);

    let disposed = false;
    return () => {
      if (disposed) return;
      disposed = true;
      const remaining = (cells.get(name).get(cell) || []).filter((row) => row !== registration);
      if (remaining.length) cells.get(name).set(cell, remaining); else cells.get(name).delete(cell);
      notify(name);
    };
  }

  // The winner of one cell, or null while nothing occupies it.
  function winner(name, cell) {
    spec(name);
    return cells.get(name)?.get(cell)?.[0] || null;
  }

  // Every cell's winner, in display order. A keyed owner uses this to list its
  // cells (settings navigation, the dock guide).
  function entries(name) {
    spec(name);
    return [...(cells.get(name)?.values() || [])].map((rows) => rows[0]).sort(byOrder);
  }

  function subscribe(name, listener) {
    spec(name);
    if (!listeners.has(name)) listeners.set(name, new Set());
    listeners.get(name).add(listener);
    return () => { listeners.get(name).delete(listener); };
  }

  return { catalog, register, winner, entries, subscribe };
}
