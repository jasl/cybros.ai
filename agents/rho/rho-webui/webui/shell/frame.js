import { el, icon } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";
import { observable } from "../kernel/observable.js";
import { keyedOutlet } from "../kernel/outlets.js";
import { emptyState } from "../primitives/feedback.js";
import { SIDEBAR, NARROW, computeColumns, defaultDockWidth } from "./columns.js";
import { createSidebar } from "./sidebar.js";
import { createDock } from "./dock.js";

const LAYOUT_KEY = "rho.layout";
const STEP = 16;

function readLayout() {
  try { return { ...JSON.parse(localStorage.getItem(LAYOUT_KEY) || "{}") }; } catch { return {}; }
}
function writeLayout(layout) {
  try { localStorage.setItem(LAYOUT_KEY, JSON.stringify(layout)); } catch { /* private mode */ }
}

// The three columns and the overlay rules between them. Widths and open
// state are display preferences of this browser; the dock's tab sets are
// the dock's own.
export function createFrame({ root, slots, shell, ui }) {
  const saved = readLayout();
  const layout = observable({
    sidebar: saved.sidebar ?? SIDEBAR.default,
    collapsed: saved.collapsed ?? null,
    dock: saved.dock ?? 0,
    dockOpen: saved.dockOpen ?? false,
    drawer: false,
  });
  const persist = () => {
    const { sidebar, collapsed, dock, dockOpen } = layout.get();
    writeLayout({ sidebar, collapsed, dock, dockOpen });
  };

  const main = el("main", { class: "frame__main", id: "main" });
  const panels = el("div", { class: "frame__panels" });
  // The leading control exists only while the sidebar is hidden: the one
  // way to the drawer that needs no keyboard.
  const leading = el("button", { type: "button", class: "btn btn--ghost btn--icon btn--sm frame__leading", "aria-label": t("shell.open_sidebar"),
    "data-tip": t("shell.open_sidebar"), hidden: true, onclick: () => setDrawer(true) }, icon("sidebar"));
  main.append(leading, panels);
  const mainOutlet = keyedOutlet(slots, "main", panels, { retain: true, onError: shell.renderError,
    fallback: () => ({ element: emptyState({ title: t("shell.panels"), description: "" }) }) });
  const dock = createDock({ slots, shell, layout });
  const sidebar = createSidebar({ slots, shell, ui, toggle: toggleSidebar, closeDrawer: () => setDrawer(false) });
  const sidebarHandle = handle(t("shell.resize_sidebar"), (delta) => setSidebar(layout.get().sidebar + delta),
    () => setSidebar(SIDEBAR.min), () => setSidebar(SIDEBAR.max));
  const dockHandle = handle(t("shell.resize_side_panel"), (delta) => resizeDock(layout.get().dock - delta),
    () => resizeDock(innerWidth), () => resizeDock(0));
  // Pointer-only: the keyboard has Escape and the drawer's own close button.
  const scrim = el("button", { type: "button", class: "frame__scrim", "aria-hidden": "true", tabindex: "-1", hidden: true,
    onclick: () => setDrawer(false) });
  const frame = el("div", { class: "frame" }, sidebar.element, sidebarHandle.element, main, dockHandle.element, dock.element, scrim);

  function handle(label, move, toMin, toMax) {
    const element = el("div", { class: "frame__handle", role: "separator", "aria-orientation": "vertical", "aria-label": label, tabindex: "0" });
    let dragging = null;
    element.addEventListener("pointerdown", (event) => {
      dragging = { x: event.clientX }; element.setPointerCapture?.(event.pointerId); frame.classList.add("frame--dragging");
    });
    element.addEventListener("pointermove", (event) => {
      if (!dragging) return;
      move(event.clientX - dragging.x); dragging.x = event.clientX;
    });
    const stop = () => { if (dragging) { dragging = null; frame.classList.remove("frame--dragging"); persist(); } };
    element.addEventListener("pointerup", stop);
    element.addEventListener("pointercancel", stop);
    element.addEventListener("keydown", (event) => {
      if (event.key === "ArrowLeft") { event.preventDefault(); move(-STEP); persist(); }
      else if (event.key === "ArrowRight") { event.preventDefault(); move(STEP); persist(); }
      else if (event.key === "Home") { event.preventDefault(); toMin(); persist(); }
      else if (event.key === "End") { event.preventDefault(); toMax(); persist(); }
    });
    return { element };
  }

  function setSidebar(width) {
    layout.update((state) => ({ ...state, sidebar: Math.min(SIDEBAR.max, Math.max(SIDEBAR.min, Math.round(width))) }));
  }
  function resizeDock(width) {
    layout.update((state) => ({ ...state, dock: Math.max(0, Math.round(width)) }));
  }
  function setDrawer(open) {
    const was = layout.get().drawer;
    layout.update((state) => ({ ...state, drawer: open }));
    if (!open && was) leading.focus();
  }
  // Opening the dock beside an expanded sidebar that leaves no room for a
  // third column collapses the sidebar to its rail when that gives the dock
  // a track; the person can expand it again and get the overlay instead.
  function makeRoomForDock() {
    const state = layout.get();
    if (state.collapsed === true || innerWidth < NARROW) return;
    const dockWidth = state.dock || defaultDockWidth(innerWidth);
    if (computeColumns(innerWidth, { ...state, dock: dockWidth }).dockMode !== "overlay") return;
    if (computeColumns(innerWidth, { ...state, collapsed: true, dock: dockWidth }).dockMode === "docked") {
      layout.update((current) => ({ ...current, collapsed: true }));
    }
  }
  // Below the narrow breakpoint the toggle opens the drawer; above it, it
  // flips between the expanded column and the rail.
  function toggleSidebar() {
    if (innerWidth < NARROW) { setDrawer(!layout.get().drawer); return; }
    const columns = computeColumns(innerWidth, layout.get());
    layout.update((state) => ({ ...state, collapsed: columns.sidebarMode !== "rail" }));
    persist();
  }

  function paint() {
    const state = layout.get();
    const dockWidth = state.dockOpen ? (state.dock || defaultDockWidth(innerWidth)) : 0;
    const columns = computeColumns(innerWidth, { ...state, dock: dockWidth });
    frame.style.setProperty("--sidebar-width", `${columns.sidebar}px`);
    frame.style.setProperty("--dock-width", `${columns.dockMode === "docked" ? columns.dock : 0}px`);
    frame.style.setProperty("--dock-float-width", `${Math.min(dockWidth || defaultDockWidth(innerWidth), Math.floor(innerWidth * 0.7))}px`);
    frame.dataset.sidebar = columns.sidebarMode;
    frame.dataset.dock = columns.dockMode;
    frame.classList.toggle("frame--drawer", state.drawer && columns.sidebarMode === "hidden");
    scrim.hidden = !(state.drawer && columns.sidebarMode === "hidden");
    main.inert = state.drawer && columns.sidebarMode === "hidden";
    root.toggleAttribute("data-dock-open", columns.dockMode !== "closed");
    leading.hidden = columns.sidebarMode !== "hidden";
    main.classList.toggle("frame__main--leading", columns.sidebarMode === "hidden");
    sidebarHandle.element.hidden = columns.sidebarMode !== "expanded";
    dockHandle.element.hidden = columns.dockMode !== "docked";
    sidebar.update({ collapsed: columns.sidebarMode === "rail", drawer: state.drawer && columns.sidebarMode === "hidden", current: shell.navigation.get() });
    dock.update({ mode: columns.dockMode });
  }

  const disposers = [];
  function mount() {
    root.replaceChildren(frame);
    disposers.push(layout.subscribe(paint));
    disposers.push(shell.navigation.subscribe((key) => { mainOutlet.show(key, { visible: true }); sidebar.update({ current: key }); if (layout.get().drawer) setDrawer(false); }, { immediate: true }));
    disposers.push(shell.router.subscribe(({ panel }) => shell.navigation.set(panel || "conversation")));
    // Choosing a conversation from the drawer is a navigation too. "No
    // conversation" has one spelling here whether the controller has started.
    let selected = shell.conversations.selection.get().id ?? null;
    disposers.push(shell.conversations.selection.subscribe((context) => {
      const id = context.id ?? null;
      if (id !== selected) { selected = id; if (layout.get().drawer) setDrawer(false); }
    }));
    const onResize = () => paint();
    const onKey = (event) => {
      if (event.key.toLowerCase() === "b" && (event.metaKey || event.ctrlKey) && event.altKey) { event.preventDefault(); toggleSidebar(); }
      if (event.key === "Escape" && layout.get().drawer) setDrawer(false);
    };
    window.addEventListener("resize", onResize, { signal: shell.signal });
    window.addEventListener("keydown", onKey, { signal: shell.signal });
    paint();
  }

  return {
    element: frame, mount, layout,
    dock: {
      open: (key, options) => { makeRoomForDock(); dock.open(key, options); },
      close: () => dock.close(),
      toggle: () => { if (!layout.get().dockOpen) makeRoomForDock(); dock.toggle(); },
      get state() { return dock.state; },
    },
    dispose() {
      for (const dispose of disposers) dispose();
      mainOutlet.dispose(); dock.dispose(); sidebar.dispose();
      frame.remove();
    },
  };
}
