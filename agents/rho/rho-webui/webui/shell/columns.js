// Column geometry, as numbers only. The frame asks for widths it would like
// and gets the widths the viewport allows: the sidebar is a rail below 1024px
// by default and hidden below 768px; the dock shrinks, then loses its track,
// before the centre falls under its protected width.
export const SIDEBAR = Object.freeze({ default: 280, min: 264, max: 420, rail: 56 });
export const CENTER_MIN = 400;
export const DOCK = Object.freeze({ min: 300, maxRatio: 0.7, defaultRatio: 0.45 });
export const NARROW = 768;
export const COMPACT = 1024;

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

export function computeColumns(viewport, { sidebar = SIDEBAR.default, collapsed = null, dock = 0 } = {}) {
  if (viewport < NARROW) {
    return { sidebar: 0, center: viewport, dock: 0, sidebarMode: "hidden", dockMode: dock > 0 ? "fullscreen" : "closed" };
  }
  const rail = collapsed ?? viewport < COMPACT;
  const sidebarWidth = rail ? SIDEBAR.rail : clamp(sidebar, SIDEBAR.min, SIDEBAR.max);
  if (dock <= 0) {
    return { sidebar: sidebarWidth, center: viewport - sidebarWidth, dock: 0, sidebarMode: rail ? "rail" : "expanded", dockMode: "closed" };
  }
  const wanted = clamp(dock, DOCK.min, Math.floor(viewport * DOCK.maxRatio));
  const room = viewport - sidebarWidth - CENTER_MIN;
  if (room >= DOCK.min) {
    const width = Math.min(wanted, room);
    return { sidebar: sidebarWidth, center: viewport - sidebarWidth - width, dock: width, sidebarMode: rail ? "rail" : "expanded", dockMode: "docked" };
  }
  return { sidebar: sidebarWidth, center: viewport - sidebarWidth, dock: 0, sidebarMode: rail ? "rail" : "expanded", dockMode: "overlay" };
}

// The first opening takes a share of the viewport; later openings keep the
// person's pixel width.
export const defaultDockWidth = (viewport) => Math.round(viewport * DOCK.defaultRatio);
