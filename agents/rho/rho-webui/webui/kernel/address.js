// The page's address is its path, spelled as a REST client would spell the
// resources it shows. The query string is not routing: the daemon's OAuth
// callback uses it, and a debugging switch may, so a link's meaning is all in
// its path.
//
//   /                                        the hero, in the daemon's default workspace
//   /workspaces/<id>                         the hero, in another workspace
//   /workspaces/<id>/conversations/<id>      a conversation, in its workspace
//   /conversations/<id>                      a conversation whose workspace the link did not name
//   /plugins                                 the Plugins panel
//   /plugins/<id>                            one plugin's page
//   /panels/<key>                            the main page a plugin brings (its `main` slot key)
//   /panels/<key>/<item>                     one item of that page (a Bot's page under Bots)
//
// The daemon answers an exact control route before it serves the page, so
// page paths keep to these shapes and never a control route's spelling. An
// address is the five keys below; a path that fits no shape is the hero.
export const KEYS = ["panel", "conversation", "workspace", "plugin", "item"];

const EMPTY = Object.freeze({ panel: null, conversation: null, workspace: null, plugin: null, item: null });

export function parseAddress(pathname) {
  const parts = pathname.split("/").filter(Boolean).map((part) => {
    try { return decodeURIComponent(part); } catch { return part; }
  });
  const [head, first, second, third] = parts;
  if (parts.length === 0) return { ...EMPTY };
  if (head === "plugins" && parts.length <= 2) return { ...EMPTY, panel: "plugins", plugin: first ?? null };
  if (head === "panels" && (parts.length === 2 || parts.length === 3)) return { ...EMPTY, panel: first, item: second ?? null };
  if (head === "workspaces" && parts.length === 2) return { ...EMPTY, workspace: first };
  if (head === "workspaces" && parts.length === 4 && second === "conversations") return { ...EMPTY, workspace: first, conversation: third };
  if (head === "conversations" && parts.length === 2) return { ...EMPTY, conversation: first };
  return { ...EMPTY };
}

export function formatAddress({ panel = null, conversation = null, workspace = null, plugin = null, item = null } = {}) {
  const segment = (value) => encodeURIComponent(String(value));
  if (panel === "plugins") return plugin ? `/plugins/${segment(plugin)}` : "/plugins";
  if (panel && panel !== "conversation") return item ? `/panels/${segment(panel)}/${segment(item)}` : `/panels/${segment(panel)}`;
  const base = workspace ? `/workspaces/${segment(workspace)}` : "";
  if (conversation) return `${base}/conversations/${segment(conversation)}`;
  return base || "/";
}

// Where a sidebar row's panel lives, for the link it is.
export const panelPath = (key) => formatAddress({ panel: key });
