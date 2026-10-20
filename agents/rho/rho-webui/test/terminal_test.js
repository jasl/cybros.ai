import { test, expect } from "bun:test";
import { TerminalStream } from "../webui/kernel/terminal_stream.js";
import { terminalConnection } from "../webui/kernel/terminal_connection.js";
const output = (offset, text) => JSON.stringify({ type: "output", offset, data: btoa(text) });
const gap = (from, to) => JSON.stringify({ type: "gap", from, to });
const wait = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

test("output receiver trims replay, preserves byte cursors and reports gaps once", () => {
  const stream = new TerminalStream();
  expect([...stream.receive(output(0, "abc")).data]).toEqual([97, 98, 99]);
  expect([...stream.receive(output(1, "bcde")).data]).toEqual([100, 101]);
  expect(stream.receive(output(0, "abc")).data.length).toBe(0);
  expect(stream.receive(gap(5, 9))).toEqual({ gap: 4 });
  expect(stream.receive(gap(5, 9))).toEqual({ gap: 0 });
  expect(JSON.parse(stream.resume()).offset).toBe(9);
  expect(() => stream.receive(output(10, "lost"))).toThrow();
  expect(() => stream.receive(gap(10, 20))).toThrow();
  expect(() => stream.receive(output(9, "a".repeat(8193)))).toThrow();
  const frames = stream.input("中".repeat(4000)).map(JSON.parse);
  expect(frames).toHaveLength(2);
  expect(frames.map((f) => atob(f.data).length)).toEqual([8192, 3808]);
});
class Peer {
  connectionState = "new";
  iceGatheringState = "complete";
  localDescription = { sdp: "answer" };
  data = { readyState: "connecting", bufferedAmount: 0, sent: [], send(value) { this.sent.push(JSON.parse(value)); } };
  createDataChannel(name, options) {
    if (name === "permission") return { readyState: "connecting", close() {} };
    this.options = [name, options]; return this.data;
  }
  async setRemoteDescription(value) { this.remote = value; }
  async createAnswer() { return this.localDescription; }
  async setLocalDescription() {}
  open() { this.connectionState = "connected"; this.data.readyState = "open"; this.data.onopen(); }
  close() { this.closed = true; this.connectionState = "closed"; this.data.readyState = "closed"; }
}
function fixture({ render, servers = [] } = {}) {
  const peers = [], states = [], outputs = [], gaps = [], calls = [], inputs = [];
  let clock = 0, error = null;
  let projection = { status: "waiting", max_age_ms: 0, connection_id: "one", offer_sdp: "offer", answer_sdp: null };
  const target = { public_id: "run", task_key: "tool", workspace_public_id: "workspace" };
  const link = terminalConnection({ target, now: () => clock,
    peer(configuration) { const p = new Peer(); p.configuration = configuration; peers.push(p); return p; },
    input: (value) => inputs.push(value),
    output: (bytes) => { outputs.push(new TextDecoder().decode(bytes)); return render?.(bytes); }, state: (s) => states.push(s), gap: (n) => gaps.push(n),
    async call(path, options) {
      calls.push([path, options]);
      if (error) throw error;
      if (path === "/realtime/ice_servers") return { ice_servers: servers };
      if (options.method === "PUT") projection = { ...projection, status: "active", max_age_ms: 1000, answer_sdp: "answer" };
      return { realtime: projection };
    },
  });
  return { link, peers, states, outputs, gaps, calls, inputs, setClock: (n) => { clock = n; }, fail: (e) => { error = e; },
    next: () => { projection = { ...projection, status: "waiting", max_age_ms: 0, connection_id: "two", answer_sdp: null }; } };
}

test("waiting offer is answered, expiry blocks input, replacement resumes the cursor without replaying input", async () => {
  const f = fixture();
  try {
    await wait();
    expect(f.peers).toHaveLength(1);
    expect(f.peers[0].options).toEqual(["terminal", { negotiated: true, id: 0, ordered: true }]);
    f.peers[0].open();
    expect(f.link.send("before permission")).toBe(false);
    await wait(520);
    expect(f.link.send("once\n")).toBe(true);
    await wait(25);
    expect(f.peers[0].data.sent.filter((p) => p.type === "input").map((p) => atob(p.data))).toEqual(["once\n"]);
    await f.peers[0].data.onmessage({ data: new TextEncoder().encode(output(0, "hello")).buffer });
    expect(f.outputs).toEqual(["hello"]);
    f.setClock(1001);
    expect(f.link.send("expired\n")).toBe(false);
    f.peers[0].data.onmessage({ data: output(5, "not permitted") });
    expect(f.outputs).toEqual(["hello"]);
    f.next();
    await wait(520);
    expect(f.peers).toHaveLength(2);
    expect(f.peers[0].closed).toBe(true);
    expect(f.inputs.at(-1).status).toBe("unknown");
    f.peers[1].open();
    await wait(520);
    expect(f.peers[1].data.sent.filter((p) => p.type === "input")).toEqual([]);
    expect(f.peers[1].data.sent.find((p) => p.type === "resume").offset).toBe(5);
    await f.peers[1].data.onmessage({ data: gap(5, 20) });
    await f.peers[1].data.onmessage({ data: output(20, "back") });
    expect(f.gaps).toEqual([15]);
    expect(f.outputs).toEqual(["hello", "back"]);
    expect(f.states).toContain("reconnecting");
  } finally { f.link.dispose(); }
});

test("detach only closes the peer; Stop cancels the original task and a failed Stop stays unconfirmed", async () => {
  const detached = fixture();
  await wait();
  detached.link.dispose();
  expect(detached.peers[0].closed).toBe(true);
  expect(detached.calls.some(([path]) => path.endsWith("cancel"))).toBe(false);
  const f = fixture();
  try {
    await wait();
    f.fail(new Error("unreachable"));
    await f.link.stop();
    expect(f.states.at(-1)).toBe("stop_failed");
    expect(f.link.send("never")).toBe(false);
    f.fail(null);
    await f.link.stop();
    expect(f.states.at(-1)).toBe("closed");
    expect(f.calls.at(-1)[1].body).toEqual({ public_id: "run", task_key: "tool", workspace_public_id: "workspace" });
  } finally { f.link.dispose(); }
});


test("a burst becomes one input frame; expiry and detach discard an unsent batch", async () => {
  const f = fixture();
  try {
    await wait();
    f.peers[0].open();
    await wait(520);
    for (const character of "burst\n") expect(f.link.send(character)).toBe(true);
    await wait(25);
    const inputs = () => f.peers[0].data.sent.filter((p) => p.type === "input");
    expect(inputs().map((p) => atob(p.data))).toEqual(["burst\n"]);
    expect(f.link.send("x".repeat(8193))).toBe(false);
    expect(f.link.send("expired before send")).toBe(true);
    f.setClock(1001);
    await wait(25);
    expect(inputs()).toHaveLength(1);
    f.setClock(0);
    expect(f.link.send("detached before send")).toBe(true);
    f.link.dispose();
    await wait(25);
    expect(inputs()).toHaveLength(1);
  } finally { f.link.dispose(); }
});

test("a late permission response does not gain a new second at receipt", async () => {
  let clock = 0, resolve;
  const states = [];
  const response = new Promise((done) => { resolve = done; });
  const link = terminalConnection({ target: { public_id: "run", task_key: "tool" }, now: () => clock,
    call: () => response, state: (value) => states.push(value), output() {}, gap() {}, peer: () => new Peer() });
  try {
    clock = 1001;
    resolve({ realtime: { status: "active", max_age_ms: 1000, connection_id: "old", answer_sdp: "already answered" } });
    await wait();
    expect(states.at(-1)).toBe("paused");
    expect(link.send("late")).toBe(false);
  } finally { link.dispose(); }
});

test("a mainline cancel refusal never escalates into stopping other work", async () => {
  const f = fixture();
  try {
    await wait();
    f.fail(Object.assign(new Error("not a branch"), { code: "not_a_branch" }));
    await f.link.stop();
    expect(f.states.at(-1)).toBe("stop_run");
    expect(f.calls.at(-1)[0]).toBe("/runs/task/cancel");
    expect(f.calls.some(([path]) => path === "/runs/stop")).toBe(false);
  } finally { f.link.dispose(); }
});

test("a dedicated terminal stops its original Run without a task cancellation fallback", async () => {
  const calls = [];
  const target = { public_id: "run", task_key: "call_tool", workspace_public_id: "workspace" };
  const link = terminalConnection({ target, stopRun: true, output() {}, state() {}, gap() {},
    async call(path, options) { calls.push([path, options]); return { realtime: { status: "waiting" } }; },
  });
  await link.stop();
  const mutation = calls.find(([, options]) => options.method === "POST");
  expect(mutation[0]).toBe("/stop");
  expect(mutation[1].body).toEqual({ public_id: "run", workspace_public_id: "workspace", host_type: "run", force: true });
  expect(calls.some(([path]) => path === "/runs/task/cancel")).toBe(false);
  link.dispose();
});


test("a stalled renderer applies backpressure while Stop remains available", async () => {
  let rendered;
  const f = fixture({ render: () => new Promise((resolve) => { rendered = resolve; }) });
  try {
    await wait(); f.peers[0].open(); await wait(520);
    const channel = f.peers[0].data;
    const pending = channel.onmessage({ data: output(0, "x".repeat(8192)) });
    const requests = channel.sent.filter((p) => p.type === "resume").length;
    await wait(550);
    expect(channel.sent.filter((p) => p.type === "resume")).toHaveLength(requests);
    expect(f.outputs).toHaveLength(1);
    await f.link.stop();
    expect(f.states.at(-1)).toBe("closed");
    rendered(); await pending;
    expect(channel.sent.filter((p) => p.type === "resume")).toHaveLength(requests);
    expect(f.calls.at(-1)[0]).toBe("/runs/task/cancel");
  } finally { rendered?.(); f.link.dispose(); }
});


test("receipts progress independently of stalled output; queued input waits for the PTY receipt", async () => {
  let rendered;
  const f = fixture({ render: () => new Promise((resolve) => { rendered = resolve; }) });
  try {
    await wait(); f.peers[0].open(); await wait(520);
    const channel = f.peers[0].data;
    expect(f.link.send("first")).toBe(true);
    await wait(25);
    const sent = () => channel.sent.filter((frame) => frame.type === "input");
    const id = sent()[0].id;
    const rendering = channel.onmessage({ data: output(0, "busy") });
    expect(f.link.send("second")).toBe(true);
    await wait(25);
    expect(sent()).toHaveLength(1);
    const receipt = (status, bytes) => channel.onmessage({ data: JSON.stringify({ type: "receipt", id, sequence: 7, status, bytes }) });
    await receipt("received", 5);
    expect(f.inputs.at(-1).status).toBe("received");
    expect(sent()).toHaveLength(1);
    await receipt("written", 3);
    expect(f.inputs.at(-1)).toMatchObject({ status: "written", bytes: 3, total: 5 });
    await wait(25);
    expect(sent().map((frame) => atob(frame.data))).toEqual(["first", "second"]);
    await f.link.stop();
    expect(f.inputs.at(-1).status).toBe("unknown");
    rendered(); await rendering;
  } finally { rendered?.(); f.link.dispose(); }
});

test("lost written receipt is unknown on disconnect and stale peer receipts cannot settle new input", async () => {
  const f = fixture();
  try {
    await wait(); f.peers[0].open(); await wait(520);
    f.link.send("once"); await wait(25);
    const old = f.peers[0];
    await old.data.onmessage({ data: JSON.stringify({ type: "receipt", id: 1, sequence: 1, status: "received", bytes: 4 }) });
    old.connectionState = "disconnected"; old.onconnectionstatechange();
    expect(f.inputs.at(-1).status).toBe("unknown");
    f.next(); await wait(520); f.peers[1].open(); await wait(520);
    expect(f.peers[1].data.sent.filter((p) => p.type === "input")).toHaveLength(0);
    f.link.send("new"); await wait(25);
    const last = f.inputs.at(-1);
    await old.data.onmessage({ data: JSON.stringify({ type: "receipt", id: 1, sequence: 1, status: "written", bytes: 4 }) });
    expect(f.inputs.at(-1)).toBe(last);
  } finally { f.link.dispose(); }
});

test("receipt parser rejects invalid counts and identifiers", () => {
  const stream = new TerminalStream();
  const frame = { type: "receipt", id: 1, sequence: 1, status: "written", bytes: 0 };
  expect(stream.receive(JSON.stringify(frame))).toEqual({ receipt: frame });
  for (const change of [{ id: 0 }, { sequence: 1.5 }, { bytes: 8193 }, { status: "executed" }, { status: "received" }]) {
    expect(() => stream.receive(JSON.stringify({ ...frame, ...change }))).toThrow();
  }
});


test("missing receipts on a live peer become unknown without replay or task cancellation", async () => {
  const f = fixture();
  try {
    await wait(); f.peers[0].open(); await wait(520);
    f.link.send("uncertain"); await wait(25);
    f.link.send("queued");
    await wait(5100);
    expect(f.inputs.at(-1).status).toBe("unknown");
    expect(f.peers[0].closed).toBe(true);
    expect(f.peers[0].data.sent.filter((p) => p.type === "input").map((p) => atob(p.data))).toEqual(["uncertain"]);
    expect(f.calls.some(([path]) => path.endsWith("cancel") || path === "/stop")).toBe(false);
  } finally { f.link.dispose(); }
}, 10000);

test("each new peer reads browser ICE configuration without sharing task credentials", async () => {
  const servers = [{ urls: ["turn:relay.example:3478?transport=tcp"], username: "viewer", credential: "synthetic-turn-password" }];
  const f = fixture({ servers });
  try {
    await wait();
    expect(f.peers[0].configuration).toEqual({ iceServers: servers });
    f.next(); await wait(520);
    expect(f.peers[1].configuration).toEqual({ iceServers: servers });
    expect(f.calls.filter(([path]) => path === "/realtime/ice_servers")).toHaveLength(2);
    expect(f.calls.filter(([, options]) => options.method === "PUT").every(([, options]) => !JSON.stringify(options.body).includes("synthetic-turn-password"))).toBe(true);
  } finally { f.link.dispose(); }
});

test("detach during ICE configuration fetch cannot create a late peer", async () => {
  let resolve, created = 0;
  const configuration = new Promise((done) => { resolve = done; });
  const link = terminalConnection({ target: { public_id: "run", task_key: "tool" }, output() {}, state() {}, gap() {},
    peer: () => { created++; return new Peer(); },
    call: (path) => path === "/realtime/ice_servers" ? configuration : Promise.resolve({ realtime: { status: "waiting", connection_id: "one", offer_sdp: "offer" } }),
  });
  await wait(); link.dispose(); resolve({ ice_servers: [] }); await wait();
  expect(created).toBe(0);
});

test("ICE configuration failure does not silently create a direct-only peer", async () => {
  let created = 0;
  const states = [];
  const link = terminalConnection({ target: { public_id: "run", task_key: "tool" }, output() {}, state: (s) => states.push(s), gap() {},
    peer: () => { created++; return new Peer(); },
    call: async (path) => {
      if (path === "/realtime/ice_servers") throw new Error("unavailable");
      return { realtime: { status: "waiting", connection_id: "one", offer_sdp: "offer" } };
    },
  });
  try { await wait(); expect(created).toBe(0); expect(states.at(-1)).toBe("error"); }
  finally { link.dispose(); }
});
