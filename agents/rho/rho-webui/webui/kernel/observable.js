// One value with subscribers. Listeners run synchronously after a change,
// in subscription order; a listener removed during notification is skipped.
export function observable(initial) {
  let value = initial;
  const listeners = new Set();
  const source = {
    get: () => value,
    set(next) {
      if (Object.is(next, value)) return;
      value = next;
      for (const listener of [...listeners]) if (listeners.has(listener)) listener(value);
    },
    update(change) { source.set(change(value)); },
    subscribe(listener, { immediate = false } = {}) {
      listeners.add(listener);
      if (immediate) listener(value);
      return () => { listeners.delete(listener); };
    },
  };
  return source;
}
