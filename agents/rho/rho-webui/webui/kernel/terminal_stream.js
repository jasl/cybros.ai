// One receiver survives peer replacement. Offsets count bytes, not UTF-16
// characters; xterm consumes Uint8Array so split UTF-8 remains intact.
export class TerminalStream {
  offset = 0;
  inputId = 0;
  resume() { return JSON.stringify({ type: "resume", offset: this.offset }); }
  input(text) {
    const bytes = new TextEncoder().encode(text);
    const frames = [];
    for (let i = 0; i < bytes.length; i += 8192) {
      frames.push(JSON.stringify({ type: "input", id: ++this.inputId, data: btoa(String.fromCharCode(...bytes.subarray(i, i + 8192))) }));
    }
    return frames;
  }
  receive(raw, consumeOutput = true) {
    if (typeof raw !== "string" || raw.length > 16384) throw new Error("invalid terminal frame");
    const frame = JSON.parse(raw);
    const offset = (n) => Number.isSafeInteger(n) && n >= 0;
    if (frame.type === "receipt") {
      if (!offset(frame.id) || !frame.id || !offset(frame.sequence) || !frame.sequence ||
          !["received", "written"].includes(frame.status) || !offset(frame.bytes) || frame.bytes > 8192 ||
          (frame.status === "received" && !frame.bytes)) throw new Error("invalid input receipt");
      return { receipt: frame };
    }
    if (!consumeOutput) return {};
    if (frame.type === "output") {
      if (!offset(frame.offset) || frame.offset > this.offset || typeof frame.data !== "string") throw new Error("invalid output offset");
      const bytes = Uint8Array.from(atob(frame.data), (c) => c.charCodeAt(0));
      const end = frame.offset + bytes.length;
      if (!bytes.length || bytes.length > 8192 || !offset(end)) throw new Error("invalid output block");
      const data = bytes.subarray(Math.min(bytes.length, this.offset - frame.offset));
      this.offset = Math.max(this.offset, end);
      return { data };
    }
    if (frame.type === "gap" && offset(frame.from) && offset(frame.to) && frame.to > frame.from && frame.from <= this.offset) {
      const gap = Math.max(0, frame.to - this.offset);
      this.offset = Math.max(this.offset, frame.to);
      return { gap };
    }
    throw new Error("invalid terminal frame");
  }
}
