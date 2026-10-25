import { test, expect } from "bun:test";
import { installDocument } from "../../../rho-webui/test/support/dom.js";
import { el } from "../../../rho-webui/webui/kernel/dom.js";
import { primitives } from "../../../rho-webui/webui/primitives/index.js";
import { translator } from "../../../rho-webui/webui/kernel/i18n.js";
import { terminalPanel } from "../../webui/terminal/panel.js";
import english from "../../webui/terminal/locales/en.js";
import "../../webui/terminal/vendor/xterm/xterm.js";
const wait = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

test("reconnect preserves history; unrecoverable output clears the display without sending shell input", async () => {
  const restore = installDocument();
  const saved = [globalThis.Terminal, globalThis.RTCPeerConnection, globalThis.ResizeObserver];
  let terminal, peer, panel, active = false;
  const calls = [];
  globalThis.Terminal = class {
    constructor(options) { this.options = options; this.content = ""; this.resets = 0; terminal = this; }
    open(screen) { screen.append(el("div", { class: "xterm-screen" })); }
    onData() {} focus() {} dispose() {}
    reset() { this.content = ""; this.resets++; }
    write(bytes, done) { this.content += new TextDecoder().decode(bytes); done(); }
  };
  globalThis.ResizeObserver = class { observe() {} disconnect() {} };
  globalThis.RTCPeerConnection = class {
    constructor() { peer = this; }
    connectionState = "new";
    iceGatheringState = "complete";
    localDescription = { sdp: "answer" };
    data = { readyState: "connecting", bufferedAmount: 0, sent: [], send(value) { this.sent.push(JSON.parse(value)); } };
    createDataChannel(name) { return name === "terminal" ? this.data : { readyState: "connecting", close() {} }; }
    async setRemoteDescription() {} async setLocalDescription() {}
    async createAnswer() { return this.localDescription; }
    close() { this.connectionState = "closed"; }
  };
  try {
    panel = terminalPanel({ el, primitives }, translator({ en: english }), {
      target: { public_id: "same-run", task_key: "terminal" },
      async call(path, options = {}) {
        calls.push(path);
        if (path === "/realtime/ice_servers") return { ice_servers: [] };
        if (options.method === "PUT") active = true;
        return { realtime: { status: active ? "active" : "waiting", max_age_ms: 1000,
          connection_id: "same-peer", offer_sdp: "offer", answer_sdp: active ? "answer" : null } };
      },
    });
    await wait();
    peer.connectionState = "connected"; peer.data.readyState = "open"; peer.data.onopen();
    await wait(520);
    const [status, notice] = panel.element.children;
    expect(panel.element.dataset.connection).toBe("connected");
    expect(notice.hidden).toBe(true);
    const receive = (frame) => peer.data.onmessage({ data: JSON.stringify(frame) });
    await receive({ type: "output", offset: 0, data: btoa("old screen") });
    peer.connectionState = "disconnected"; peer.onconnectionstatechange();
    expect(status.textContent).toContain("Connection interrupted. Reconnecting");
    expect(terminal.options.disableStdin).toBe(true);
    peer.connectionState = "connected"; peer.onconnectionstatechange();
    expect(notice.textContent).toContain("Reconnected to the same terminal");
    expect(terminal.content).toBe("old screen");
    expect(terminal.resets).toBe(0);
    notice.querySelector("button").click();
    peer.onconnectionstatechange();
    expect(notice.hidden).toBe(true);
    await receive({ type: "gap", from: 10, to: 90 });
    expect(terminal.content).toBe("");
    expect(terminal.resets).toBe(1);
    expect(notice.textContent).toContain("Screen cleared");
    expect(notice.textContent).not.toContain("80");
    peer.onconnectionstatechange();
    expect(notice.textContent).toContain("Screen cleared");
    await receive({ type: "gap", from: 10, to: 90 });
    expect(terminal.resets).toBe(1);
    await receive({ type: "output", offset: 90, data: btoa("new output") });
    expect(terminal.content).toBe("new output");
    expect(peer.data.sent.filter((frame) => frame.type === "input")).toEqual([]);
    expect(calls.some((path) => /cancel|stop|terminals/.test(path))).toBe(false);
    notice.querySelector("button").click();
    await wait(520);
    expect(notice.hidden).toBe(true);
  } finally {
    panel?.dispose();
    [globalThis.Terminal, globalThis.RTCPeerConnection, globalThis.ResizeObserver] = saved;
    restore();
  }
});
