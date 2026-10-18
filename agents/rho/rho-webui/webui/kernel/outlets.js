import { placeChildren } from "./dom.js";

// An outlet is where a slot owner renders the registrations of one slot.
// Components follow one protocol: `component(props)` returns
// `{ element, update?(props), dispose?() }`. A throwing component costs only
// its own cell — the owner's page keeps rendering — and the failure is
// reported to the owner so the module can be marked.
function instantiate(registration, props, onError) {
  try {
    const instance = registration.component(props);
    if (!instance?.element?.nodeType) throw new Error("component returned no element");
    return instance;
  } catch (error) {
    onError(error, { registration, phase: "render" });
    return null;
  }
}

function release(entry) {
  try { entry.instance.dispose?.(); } catch { /* a failing dispose must not block the owner */ }
  entry.instance.element.remove();
}

// Repaint one instance with new props: `update` when the component offers it,
// otherwise a fresh instance in the same position.
function repaint(entry, props, onError) {
  if (typeof entry.instance.update !== "function") {
    const next = instantiate(entry.registration, props, onError);
    if (next) entry.instance.element.replaceWith(next.element);
    release(entry);
    return next ? { ...entry, instance: next } : null;
  }
  try {
    entry.instance.update(props);
    return entry;
  } catch (error) {
    onError(error, { registration: entry.registration, phase: "render" });
    release(entry);
    return null;
  }
}

export function listOutlet(slots, name, container, props, { onError = () => {} } = {}) {
  const mounted = new Map();
  let current = props;

  function render() {
    const wanted = slots.entries(name);
    for (const [registration, entry] of mounted) {
      if (!wanted.includes(registration)) { release(entry); mounted.delete(registration); }
    }
    const nodes = [];
    for (const registration of wanted) {
      if (!mounted.has(registration)) {
        const instance = instantiate(registration, current, onError);
        if (instance) mounted.set(registration, { registration, instance });
      }
      const entry = mounted.get(registration);
      if (entry) nodes.push(entry.instance.element);
    }
    placeChildren(container, nodes);
  }

  const unsubscribe = slots.subscribe(name, render);
  render();
  return {
    update(next) {
      current = next;
      for (const [registration, entry] of mounted) {
        const kept = repaint(entry, current, onError);
        if (kept) mounted.set(registration, kept); else mounted.delete(registration);
      }
      render();
    },
    dispose() {
      unsubscribe();
      for (const entry of mounted.values()) release(entry);
      mounted.clear();
    },
  };
}

// `show(key, props)` mounts the winner of that cell, or `fallback` when the
// cell is empty or its component failed. `retain` keeps previously shown
// instances mounted but hidden, each told `visible: false`.
export function keyedOutlet(slots, name, container, { fallback = null, retain = false, onError = () => {} } = {}) {
  const shown = new Map();
  let key = null;
  let current = null;

  function withVisibility(props, visible) {
    return retain ? { ...props, visible } : props;
  }

  function mount(cell, props) {
    const registration = slots.winner(name, cell);
    let instance = registration ? instantiate(registration, props, onError) : null;
    if (!instance && fallback) instance = instantiate({ component: fallback, owner: "rho.webui", cell, name }, props, onError);
    if (!instance) return null;
    container.append(instance.element);
    return { registration, instance };
  }

  // Every mounted cell follows its registration, the kept hidden ones too:
  // a page whose module went away leaves at once, not when next shown.
  function render() {
    for (const [cell, entry] of [...shown]) {
      if (entry.registration !== slots.winner(name, cell)) { release(entry); shown.delete(cell); }
    }
    if (key === null) return;
    if (!shown.has(key)) {
      const mounted = mount(key, withVisibility(current, true));
      if (mounted) shown.set(key, mounted);
    }
  }

  const unsubscribe = slots.subscribe(name, render);
  return {
    show(next, props) {
      current = props;
      for (const [cell, entry] of shown) {
        if (cell === next) continue;
        if (!retain) { release(entry); shown.delete(cell); continue; }
        entry.instance.element.hidden = true;
        const kept = repaint(entry, withVisibility(props, false), onError);
        // A component without `update` is re-instantiated by the repaint:
        // the fresh element is hidden too, or it would stack under the shown one.
        if (kept) { kept.instance.element.hidden = true; shown.set(cell, kept); } else shown.delete(cell);
      }
      key = next;
      const existing = shown.get(next);
      if (existing) {
        existing.instance.element.hidden = false;
        const kept = repaint(existing, withVisibility(props, true), onError);
        if (kept) shown.set(next, kept); else shown.delete(next);
      }
      render();
    },
    update(props) {
      current = props;
      for (const [cell, entry] of shown) {
        const kept = repaint(entry, withVisibility(props, cell === key), onError);
        if (kept) shown.set(cell, kept); else shown.delete(cell);
      }
      render();
    },
    dispose() {
      unsubscribe();
      for (const entry of shown.values()) release(entry);
      shown.clear();
      key = null;
    },
  };
}
