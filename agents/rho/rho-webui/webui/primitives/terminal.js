import { el } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";
import { button } from "./button.js";
import { terminalConnection } from "../kernel/terminal_connection.js";

export function terminalPanel({ call, target, stopRun = false }) {
  const status = el("p", { class: "terminal__status", role: "status", text: t("terminal.connecting") });
  const notice = el("p", { class: "terminal__notice", role: "status" });
  const delivery = el("p", { class: "terminal__input", role: "status" });
  const screen = el("div", { class: "terminal__screen", "aria-label": t("terminal.screen") });
  const stop = button({ label: t("terminal.stop"), variant: "danger", size: "sm", onClick: () => link?.stop() });
  const element = el("section", { class: "terminal", "aria-label": t("terminal.title") },
    el("div", { class: "terminal__head" }, status, stop), notice, delivery, screen);
  let disposed = false, ended = false, terminal, link;
  import("../vendor/xterm/xterm.js").then(() => {
    if (disposed || ended) return;
    terminal = new globalThis.Terminal({ cols: 80, rows: 24, scrollback: 2000, fontSize: 13, screenReaderMode: true, disableStdin: true });
    terminal.open(screen);
    link = terminalConnection({ call, target, stopRun,
      state(value) {
        status.textContent = t(`terminal.${value}`);
        terminal.options.disableStdin = value !== "connected";
        stop.disabled = ["stopping", "closed", "stop_run"].includes(value);
      },
      input: (receipt) => { delivery.textContent = t(`terminal.input_${receipt.status}`, receipt); },
      output: (bytes) => new Promise((resolve) => terminal.write(bytes, resolve)),
      gap(bytes) {
        const text = t("terminal.gap", { bytes });
        notice.textContent = text;
        terminal.write(`\r\n[${text}]\r\n`);
      },
    });
    terminal.onData((data) => { if (!link?.send(data)) delivery.textContent = t("terminal.input_unsent"); });
    terminal.focus();
  }).catch(() => { if (!disposed && !ended) status.textContent = t("terminal.error"); });
  return { element,
    finish() {
      ended = true; link?.dispose(); link = null;
      if (terminal) terminal.options.disableStdin = true;
      status.textContent = t("terminal.closed"); stop.disabled = true;
    },
    dispose() { disposed = true; link?.dispose(); terminal?.dispose(); } };
}
