import { test, expect } from "bun:test";
import { permissionChannel } from "../../webui/terminal/permission.js";
import { realtimeConnection } from "../../webui/terminal/realtime.js";
const wait = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

test("a permission response spends the probe delay and never accepts another nonce or an overlong budget", () => {
  let clock = 100, current = true;
  const grants = [], sent = [];
  const channel = { readyState: "open", bufferedAmount: 0, send: (value) => sent.push(JSON.parse(value)), close() {} };
  const peer = { connectionState: "connected", createDataChannel: () => channel };
  const link = permissionChannel({ peer, now: () => clock, current: () => current, grant: (until) => grants.push(until) });
  try {
    channel.onopen();
    clock = 400;
    channel.onmessage({ data: JSON.stringify({ nonce: sent[0] + 1, max_age_ms: 1000 }) });
    channel.onmessage({ data: JSON.stringify({ nonce: sent[0], max_age_ms: 1001 }) });
    expect(grants).toEqual([]);
    channel.onmessage({ data: JSON.stringify({ nonce: sent[0], max_age_ms: 600 }) });
    expect(grants).toEqual([700]);
    channel.onmessage({ data: JSON.stringify({ nonce: sent[0], max_age_ms: 1000 }) });
    expect(grants).toEqual([700]);
    clock = 800;
    channel.onopen();
    channel.onmessage({ data: JSON.stringify({ nonce: sent.at(-1), max_age_ms: 0 }) });
    expect(grants.at(-1)).toBe(0);
    current = false;
    expect(link.ready()).toBe(false);
  } finally { link.close(); }
});

test("bound viewers stop HTTP polling, expire locally on silence and resume only from the original peer", async () => {
  let clock = 0, reads = 0, paused = 0, resumed = 0, nonce;
  const channel = { readyState: "connecting", bufferedAmount: 0, send(value) { nonce = JSON.parse(value); }, close() { this.readyState = "closed"; } };
  const peer = { connectionState: "new", iceGatheringState: "complete", localDescription: { sdp: "answer" },
    createDataChannel: () => channel, async setRemoteDescription() {}, async setLocalDescription() {},
    async createAnswer() { return this.localDescription; }, close() { this.connectionState = "closed"; } };
  const link = realtimeConnection({ target: {}, now: () => clock, peer: () => peer, state() {},
    prepare: () => ({ ready: () => true, pause() { paused++; }, resume() { resumed++; }, close() {} }),
    async call(path, options = {}) {
      if (path === "/realtime/ice_servers") return { ice_servers: [] };
      if (options.method === "PUT") return {};
      reads++;
      return { realtime: { status: "waiting", connection_id: "one", offer_sdp: "offer" } };
    },
  });
  try {
    await wait();
    peer.connectionState = "connected"; channel.readyState = "open"; channel.onopen();
    channel.onmessage({ data: JSON.stringify({ nonce, max_age_ms: 300 }) });
    expect(resumed).toBeGreaterThan(0);
    const initialReads = reads;
    clock = 301;
    const before = paused;
    await wait(550);
    expect(paused).toBeGreaterThan(before);
    expect(reads).toBe(initialReads);
    channel.onmessage({ data: JSON.stringify({ nonce, max_age_ms: 500 }) });
    expect(resumed).toBeGreaterThan(1);
    link.dispose();
    const after = resumed;
    channel.onmessage({ data: JSON.stringify({ nonce, max_age_ms: 1000 }) });
    expect(resumed).toBe(after);
  } finally { link.dispose(); }
});
