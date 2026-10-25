import { terminalConnection } from "./connection.js";

export function terminalPanel(ui, t, { call, target, stopRun = false }) {
  const { el } = ui;
  const { iconButton, alert } = ui.primitives;
  const status = alert({ tone: "info", text: t("terminal.connecting") });
  function dismissible(tone) {
    const message = alert({ tone });
    message.element.append(iconButton({ icon: "close", label: t("terminal.dismiss_notice"), onClick: () => message.hide() }));
    return message;
  }
  const notice = dismissible("info");
  const delivery = dismissible("warning");
  const screen = el("div", { class: "terminal__screen", "aria-label": t("terminal.screen") });
  const stop = iconButton({ icon: "stop", label: t("terminal.stop"), onClick: () => link?.stop() });
  let control = false;
  const keys = el("div", { class: "terminal__keys", role: "group", "aria-label": t("terminal.keys") });
  const ctrl = el("button", { type: "button", text: t("terminal.key_ctrl"), "aria-pressed": "false", onclick: () => {
    control = !control; ctrl.setAttribute("aria-pressed", String(control)); ctrl.classList.toggle("is-active", control); terminal?.focus();
  } });
  function send(data) {
    if (control) {
      if (data.length === 1 && /[a-z@\[\\\]\^_?]/i.test(data)) data = data === "?" ? "\x7f" : String.fromCharCode(data.toUpperCase().charCodeAt(0) & 31);
      control = false; ctrl.setAttribute("aria-pressed", "false"); ctrl.classList.remove("is-active");
    }
    if (!link?.send(data)) delivery.show(t("terminal.input_unsent"));
  }
  for (const [name, data] of [["esc", "\x1b"], ["tab", "\t"], ["ctrl", null], ["left", "\x1b[D"], ["down", "\x1b[B"], ["up", "\x1b[A"], ["right", "\x1b[C"]]) {
    const key = name === "ctrl" ? ctrl : el("button", { type: "button", text: t(`terminal.key_${name}`), "aria-label": t(`terminal.key_${name}_label`), onclick: () => { send(data); terminal?.focus(); } });
    key.disabled = true;
    key.addEventListener("pointerdown", (event) => event.preventDefault());
    keys.append(key);
  }
  const element = el("section", { class: "terminal", "aria-label": t("terminal.title") },
    status.element, notice.element, delivery.element, screen, keys);
  let disposed = false, ended = false, terminal, link, observer;
  let wasConnected = false, recovering = false, screenRefreshed = false;
  const viewport = globalThis.visualViewport;
  function fitViewport() {
    element.style.maxHeight = innerWidth < 768
      ? `${Math.max(0, viewport.height + viewport.offsetTop - element.getBoundingClientRect().top)}px` : "";
  }
  viewport?.addEventListener("resize", fitViewport);
  viewport?.addEventListener("scroll", fitViewport);
  import("./vendor/xterm/xterm.js").then(() => {
    if (disposed || ended) return;
    const style = getComputedStyle(screen);
    terminal = new globalThis.Terminal({ theme: { background: style.backgroundColor, foreground: style.color }, cols: 80, rows: 24, scrollback: 2000, fontSize: 13, screenReaderMode: true, disableStdin: true });
    terminal.open(screen);
    if (viewport) fitViewport();
    link = terminalConnection({ call, target, stopRun,
      state(value) {
        if (["connecting", "reconnecting", "paused", "error"].includes(value) && wasConnected && !recovering) {
          recovering = true;
          screenRefreshed = false;
          notice.hide();
        }
        if (value === "connected") {
          if (recovering && !screenRefreshed) notice.show(t("terminal.reconnected"), "success");
          wasConnected = true;
          recovering = false;
        }
        element.dataset.connection = value;
        if (["connected", "closed"].includes(value)) status.hide();
        else status.show(t(`terminal.${value}`), ["error", "stop_failed"].includes(value) ? "error" : "info");
        terminal.options.disableStdin = value !== "connected";
        for (const key of keys.children) key.disabled = value !== "connected";
        stop.disabled = ["stopping", "closed", "stop_run"].includes(value);
      },
      input: (receipt) => { element.dataset.inputReceipt = receipt.status; if (["unknown", "unsent"].includes(receipt.status)) delivery.show(t(`terminal.input_${receipt.status}`, receipt)); else delivery.hide(); },
      output: (bytes) => new Promise((resolve) => terminal.write(bytes, resolve)),
      gap() {
        terminal.reset();
        screenRefreshed = true;
        notice.show(t("terminal.screen_refreshed"));
      },
    });
    function fit() {
      if (disposed || ended) return;
      const grid = screen.querySelector(".xterm-screen");
      const bounds = grid.getBoundingClientRect();
      if (!bounds.width || !bounds.height || !screen.clientWidth || !screen.clientHeight) return;
      const cols = Math.max(2, Math.min(500, Math.floor((screen.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)) / (bounds.width / terminal.cols))));
      const rows = Math.max(2, Math.min(200, Math.floor((screen.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom)) / (bounds.height / terminal.rows))));
      if (terminal.cols !== cols || terminal.rows !== rows) terminal.resize(cols, rows);
      link.resize(cols, rows);
    }
    observer = new ResizeObserver(fit);
    observer.observe(screen);
    fit();
    terminal.onData(send);
    terminal.focus();
  }).catch(() => { if (!disposed && !ended) status.show(t("terminal.error"), "error"); });
  return { element, stop,
    finish() {
      ended = true; observer?.disconnect(); link?.dispose(); link = null;
      if (terminal) terminal.options.disableStdin = true;
      element.dataset.connection = "closed";
      status.hide(); stop.hidden = keys.hidden = true;
    },
    dispose() { disposed = true; viewport?.removeEventListener("resize", fitViewport); viewport?.removeEventListener("scroll", fitViewport); observer?.disconnect(); link?.dispose(); terminal?.dispose(); } };
}
