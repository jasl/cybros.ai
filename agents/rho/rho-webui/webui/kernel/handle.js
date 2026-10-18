// The `ui` handle is the whole platform a module sees. Everything it
// registers is owned by the handle, so disposing the handle — because its
// plugin stopped, changed version or the page signed out — removes every
// contribution and aborts every request it started.
export function createHandle({ id, slots, call, toast, navigate, dock, primitives, el, translator, inventory }) {
  const controller = new AbortController();
  const disposers = new Set();

  const ui = Object.freeze({
    id,
    signal: controller.signal,
    slots: Object.freeze({
      register(name, options, component) {
        const dispose = slots.register(name, options, component, id);
        disposers.add(dispose);
        return () => { disposers.delete(dispose); dispose(); };
      },
    }),
    // Requests default to the handle's signal; a module may narrow further
    // with its own controller.
    call: (path, options = {}) => call(path, { ...options, signal: options.signal ?? controller.signal }),
    translator,
    el,
    primitives,
    toast,
    navigate,
    dock,
    // The plugin inventory is the shell's one reader of `/extensions`; a
    // module whose save changes its plugin's readiness asks for a re-read.
    inventory: Object.freeze({ refresh: () => inventory.refresh() }),
  });

  return {
    ui,
    dispose() {
      for (const dispose of [...disposers]) dispose();
      disposers.clear();
      controller.abort();
    },
  };
}
