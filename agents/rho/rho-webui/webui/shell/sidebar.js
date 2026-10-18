import { el } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";
import { listOutlet } from "../kernel/outlets.js";
import { panelPath } from "../kernel/address.js";
import { icon, iconButton } from "../primitives/button.js";
import { conversationBrowser } from "../features/conversation/browser.js";
import { workspaceSwitcher } from "./workspace_switcher.js";

const CONNECTED_HOLD = 2000;

// The left column: the brand row with the collapse toggle, the workspace
// switcher, New conversation, global panels, the conversation browser and
// Settings. As a rail it keeps the same order as one column of icons — the
// toggle first, then the workspace mark — each icon where the expanded row's
// icon stands; below the narrow breakpoint it is a drawer the frame opens
// over the page.
export function createSidebar({ slots, shell, ui, toggle, closeDrawer }) {
  let props = { collapsed: false, drawer: false, current: "conversation" };
  const toggleButton = iconButton({ icon: "sidebar", label: t("shell.collapse_sidebar"), onClick: toggle, attrs: { class: "btn btn--ghost btn--icon sidebar__toggle" } });
  const closeButton = iconButton({ icon: "close", label: t("shell.close_sidebar"), onClick: closeDrawer, attrs: { class: "btn btn--ghost btn--icon sidebar__close" } });
  const wordmark = el("span", { class: "sidebar__wordmark", text: t("brand.rho") });
  // Labels are hidden on the rail, so the accessible name is always explicit.
  const newButton = el("button", { type: "button", class: "sidebar__new", "aria-label": t("common.new_conversation"), "data-tip": t("common.new_conversation"),
    onclick: () => { shell.navigate("conversation"); shell.conversations.startNew(); } },
    icon("new"), el("span", { class: "sidebar__new-label", text: t("common.new_conversation") }));
  const panels = el("nav", { class: "sidebar__panels", "aria-label": t("shell.panels") });
  const panelOutlet = listOutlet(slots, "sidebar.panellist", panels, props, { onError: shell.renderError });
  const browser = conversationBrowser({ conversations: shell.conversations });
  const connection = el("span", { class: "sidebar__connection tag tag--warning", role: "status", hidden: true });
  // The foot keeps the two administration pages in reach, apart from the
  // panels above: Nexus — the account's — over Settings — rho's own.
  const footLink = (key, glyph, label, open) => el("a", { class: "sidebar__settings", href: panelPath(key), "aria-label": label, "data-tip": label,
    onclick: (event) => {
      if ((event.button ?? 0) !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      open();
    } }, icon(glyph), el("span", { class: "sidebar__settings-label", text: label }));
  const nexusButton = footLink("nexus", "gauge", t("brand.nexus"), () => shell.navigate("nexus"));
  const settingsButton = footLink("settings", "settings", t("common.settings"), () => shell.settings.open());
  const switcher = workspaceSwitcher({ shell });
  const element = el("aside", { class: "sidebar", "aria-label": t("shell.main_navigation") },
    el("div", { class: "sidebar__brand" }, wordmark, el("span", { class: "grow" }), toggleButton, closeButton),
    switcher.element, newButton, panels, el("div", { class: "sidebar__browser" }, browser.element),
    el("div", { class: "sidebar__foot" }, nexusButton, el("div", { class: "sidebar__foot-row" }, settingsButton, connection)));

  // The pill appears only while the daemon is not adopted, and says
  // "Connected" for a moment after a return from that state.
  let wasAdopted = null;
  let hold = null;
  function paintConnection(state) {
    const adopted = state.daemon?.workspace?.state === "adopted";
    const offline = !!state.error && !state.daemon;
    if (!state.daemon && !offline) return;
    clearTimeout(hold);
    if (adopted && wasAdopted === false) {
      connection.className = "sidebar__connection tag tag--success"; connection.textContent = t("shell.connection_connected"); connection.hidden = false;
      hold = setTimeout(() => { connection.hidden = true; }, CONNECTED_HOLD);
    } else if (!adopted && (state.daemon || offline)) {
      connection.className = `sidebar__connection tag ${offline ? "tag--danger" : "tag--warning"}`;
      connection.textContent = offline ? t("shell.connection_offline") : t("shell.connection_connecting"); connection.hidden = false;
    } else if (adopted) {
      connection.hidden = true;
    }
    wasAdopted = adopted;
  }
  const unsubscribe = shell.setup.state.subscribe(paintConnection, { immediate: true });

  function update(next) {
    props = { ...props, ...next };
    element.classList.toggle("sidebar--rail", props.collapsed);
    element.classList.toggle("sidebar--drawer", props.drawer);
    toggleButton.setAttribute("aria-label", props.collapsed ? t("shell.expand_sidebar") : t("shell.collapse_sidebar"));
    toggleButton.dataset.tip = toggleButton.getAttribute("aria-label");
    toggleButton.hidden = props.drawer;
    closeButton.hidden = !props.drawer;
    panelOutlet.update({ current: props.current, collapsed: props.collapsed });
    for (const [key, link] of [["settings", settingsButton], ["nexus", nexusButton]]) {
      if (props.current === key) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current");
    }
    browser.update({ collapsed: props.collapsed });
  }
  update(props);

  return {
    element, update,
    dispose() { unsubscribe(); clearTimeout(hold); switcher.dispose(); panelOutlet.dispose(); browser.dispose?.(); element.remove(); },
  };
}
