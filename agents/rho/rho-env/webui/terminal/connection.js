import { TerminalStream } from "./stream.js";
import { realtimeConnection } from "./realtime.js";

export function terminalConnection({ output, gap, input = () => {}, ...options }) {
  const stream = new TerminalStream();
  let access, connection, channel, rendering = false, size, sentSize;
  let inputTimer, receiptTimer, inputText = "", inputExpires = 0, inputPending;
  function clearInput() {
    clearTimeout(inputTimer);
    inputTimer = null;
    inputText = "";
  }
  function abandonInput() {
    sentSize = null;
    clearTimeout(receiptTimer);
    if (inputPending) input({ status: "unknown", id: inputPending.id });
    else if (inputText) input({ status: "unsent" });
    inputPending = null;
    clearInput();
  }
  function scheduleInput() {
    if (inputText && !inputPending && !inputTimer) inputTimer = setTimeout(flushInput, 16);
  }
  function receipt(frame) {
    if (!inputPending || frame.id !== inputPending.id) return;
    if (frame.bytes > inputPending.bytes || (frame.status === "received" && frame.bytes !== inputPending.bytes) ||
        (inputPending.sequence && frame.sequence !== inputPending.sequence)) throw new Error("mismatched input receipt");
    inputPending.sequence = frame.sequence;
    input({ ...frame, total: inputPending.bytes });
    if (frame.status === "written") { clearTimeout(receiptTimer); inputPending = null; scheduleInput(); }
  }
  function flushInput() {
    const text = inputText;
    clearInput();
    if (!access.allowed() || access.now() >= inputExpires || channel?.readyState !== "open" || connection.connectionState === "disconnected") { input({ status: "unsent" }); return; }
    // Two frames at most: resume precedes input even when permission just
    // recovered. Never retry an input after an uncertain send.
    try {
      channel.send(stream.resume());
      const frame = stream.input(text)[0];
      inputPending = { id: stream.inputId, bytes: new TextEncoder().encode(text).length };
      input({ status: "sent", id: inputPending.id });
      receiptTimer = setTimeout(() => { access.reconnect(); }, 5000);
      channel.send(frame);
    } catch { if (!inputPending) input({ status: "unsent" }); access.reconnect(); }
  }
  function resume() {
    if (!rendering && access.allowed() && channel?.readyState === "open" && channel.bufferedAmount < 16384) {
      channel.send(stream.resume());
      if (size && size !== sentSize) { channel.send(size); sentSize = size; }
    }
  }
  const link = realtimeConnection({ ...options, prepare(current, controls) {
    access = controls; connection = current; sentSize = null;
    const data = channel = current.createDataChannel("terminal", { negotiated: true, id: 0, ordered: true });
    data.binaryType = "arraybuffer";
    data.onopen = () => { if (controls.current()) controls.refresh(); };
    data.onmessage = async ({ data: raw }) => {
      if (!controls.current() || !controls.allowed()) return;
      let ownsRendering = false;
      try {
        const event = stream.receive(raw instanceof ArrayBuffer ? new TextDecoder("utf-8", { fatal: true }).decode(raw) : raw, !rendering);
        if (event.receipt) { receipt(event.receipt); return; }
        if (rendering) return;
        ownsRendering = rendering = true;
        if (event.gap) gap(event.gap);
        if (event.data?.length) await output(event.data);
      } catch { if (controls.current()) controls.fail(); }
      finally { if (ownsRendering) { rendering = false; resume(); } }
    };
    return {
      ready: () => data.readyState === "open", resume, pause: abandonInput,
      close() { abandonInput(); channel = connection = null; },
    };
  } });
  return { ...link,
    resize(cols, rows) {
      if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols < 2 || cols > 500 || rows < 2 || rows > 200) throw new Error("invalid terminal dimensions");
      size = JSON.stringify({ type: "resize", cols, rows });
      if (access) resume();
    },
    send(text) {
      if (!access?.allowed() || channel?.readyState !== "open" || connection.connectionState === "disconnected") return false;
      if (!text) return true;
      // Coalesce a burst of key events into one block for the helper's
      // bounded receive queue. A batch waits 16ms and for the previous receipt;
      // expiry, peer replacement and Stop discard it rather than replay it.
      const next = inputText + text;
      if (new TextEncoder().encode(next).length > 8192 || channel.bufferedAmount > 16384) return false;
      if (!inputText) inputExpires = access.expires();
      inputText = next;
      scheduleInput();
      return true;
    },
  };
}
