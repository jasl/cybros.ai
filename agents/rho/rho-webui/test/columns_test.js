import { test, expect } from "bun:test";
import { SIDEBAR, CENTER_MIN, DOCK, computeColumns, defaultDockWidth } from "../webui/shell/columns.js";

test("a wide viewport keeps the chosen sidebar width and gives the dock its track", () => {
  const columns = computeColumns(1440, { sidebar: 300, collapsed: false, dock: 500 });
  expect(columns).toEqual({ sidebar: 300, center: 640, dock: 500, sidebarMode: "expanded", dockMode: "docked" });
  expect(computeColumns(1440, { sidebar: 1000, collapsed: false }).sidebar).toBe(SIDEBAR.max);
  expect(computeColumns(1440, { sidebar: 10, collapsed: false }).sidebar).toBe(SIDEBAR.min);
});

test("the dock shrinks to protect the centre and then hangs over it instead of taking a track", () => {
  const squeezed = computeColumns(1100, { sidebar: 280, collapsed: false, dock: 700 });
  expect(squeezed.dockMode).toBe("docked");
  expect(squeezed.center).toBe(CENTER_MIN);
  expect(squeezed.dock).toBe(1100 - 280 - CENTER_MIN);
  const overlay = computeColumns(900, { sidebar: 280, collapsed: false, dock: 400 });
  expect(overlay.dockMode).toBe("overlay");
  expect(overlay.dock).toBe(0);
  expect(overlay.center).toBe(900 - 280);
});

test("the dock never exceeds its share of the viewport or falls under its floor", () => {
  expect(computeColumns(2000, { collapsed: true, dock: 1900 }).dock).toBe(Math.floor(2000 * DOCK.maxRatio));
  expect(computeColumns(2000, { collapsed: true, dock: 100 }).dock).toBe(DOCK.min);
  expect(defaultDockWidth(1440)).toBe(648);
});

test("below 1024 the sidebar is a rail unless the person expanded it; below 768 it is hidden", () => {
  expect(computeColumns(1000, {}).sidebarMode).toBe("rail");
  expect(computeColumns(1000, { collapsed: false }).sidebarMode).toBe("expanded");
  expect(computeColumns(1200, { collapsed: true })).toMatchObject({ sidebar: SIDEBAR.rail, sidebarMode: "rail" });
  expect(computeColumns(700, { collapsed: false, dock: 0 })).toEqual({ sidebar: 0, center: 700, dock: 0, sidebarMode: "hidden", dockMode: "closed" });
  expect(computeColumns(700, { dock: 300 }).dockMode).toBe("fullscreen");
});
