import { KEYS, formatAddress, parseAddress } from "../kernel/address.js";

// The page's address — `panel`, `conversation`, `workspace`, `plugin` — read
// from and written to the location's path (`kernel/address.js` spells it).
// Reading is always from `location`, so a popstate needs no replayed state.
export function createRouter({ win = globalThis } = {}) {
  const listeners = new Set();
  const read = () => parseAddress(new URL(win.location.href).pathname);
  // A change names the keys it sets; a panel address carries no conversation
  // and a conversation address no panel, so the path says one thing.
  function href(changes) {
    const next = read();
    for (const key of KEYS) {
      if (!Object.hasOwn(changes, key)) continue;
      next[key] = changes[key] === undefined || changes[key] === "" ? null : changes[key];
    }
    return formatAddress(next);
  }
  // The query string rides along unchanged: it is not the page's to route
  // on, so a switch someone typed into it survives navigation.
  const current = () => win.location.pathname + win.location.search;
  const target = (changes) => href(changes) + win.location.search;
  const notify = () => { const address = read(); for (const listener of [...listeners]) listener(address); };
  const onPop = () => notify();
  win.addEventListener("popstate", onPop);
  return {
    read,
    // Own pushes are silent by default: the caller already knows. `notify`
    // tells subscribers too, for a change made on another part of the page.
    push(changes, { notify: tell = false } = {}) {
      const next = target(changes);
      if (next !== current()) win.history.pushState(null, "", next);
      if (tell) notify();
    },
    replace(changes, { notify: tell = false } = {}) {
      const next = target(changes);
      if (next !== current()) win.history.replaceState(null, "", next);
      if (tell) notify();
    },
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    dispose() { win.removeEventListener("popstate", onPop); listeners.clear(); },
  };
}
