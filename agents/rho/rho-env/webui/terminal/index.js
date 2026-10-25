import english from "./locales/en.js";
import { terminalsPanel } from "./picker.js";
import { terminalSession } from "./session.js";
import { taskTerminal } from "./task.js";

// The running plugin owns every terminal contribution and its assets.
// Re-enabling creates a fresh handle even when this ES module is cached.
export function register(ui) {
  const t = ui.translator({ en: english });
  const { el } = ui;
  const styles = ["terminal.css", "vendor/xterm/xterm.css"].map((path) =>
    el("link", { rel: "stylesheet", href: new URL(path, import.meta.url).href }));
  document.head.append(...styles);
  ui.signal.addEventListener("abort", () => styles.forEach((style) => style.remove()), { once: true });

  ui.slots.register("dock.tab", { key: "terminal", title: (params) => [params.title || t("terminal.title"), params.status].filter(Boolean).join(" · "), fill: true, icon: "terminal" },
    (props) => terminalSession(ui, t, props));
  ui.slots.register("dock.tab", { key: "terminals", title: () => t("terminals.title"), description: () => t("terminals.description"), requiresConversation: false, icon: "terminal" },
    (props) => {
      let workspace = props.conversation.workspace;
      let panel = terminalsPanel(ui, t, props);
      const element = el("div", {}, panel.element);
      return { element,
        update(next) {
          if (next.conversation.workspace === workspace) return;
          workspace = next.conversation.workspace;
          panel.dispose();
          panel = terminalsPanel(ui, t, next);
          element.replaceChildren(panel.element);
        },
        dispose() { panel.dispose(); },
      };
    });
  ui.slots.register("conversation.header.utilities", { id: "terminals", order: 15 }, () => ({
    element: ui.primitives.button({ label: t("terminals.title"), size: "sm", onClick: () => ui.dock.open("terminals") }),
  }));
  ui.slots.register("task.detail", { id: "terminal" }, (props) => taskTerminal(ui, t, props));
}
