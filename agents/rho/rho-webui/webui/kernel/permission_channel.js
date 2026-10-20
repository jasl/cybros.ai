// Observe the Runner's remaining Nexus window over the already bound peer.
// Anchoring at probe send time discounts all handler and network delay.
export function permissionChannel({ peer, now, current, grant }) {
  const channel = peer.createDataChannel("permission", { negotiated: true, id: 1, ordered: true });
  let sequence = 0, pending, timer, closed = false;
  const ready = () => !closed && current() && channel.readyState === "open" && peer.connectionState === "connected";
  function probe() {
    if (closed) return;
    if (ready() && (!pending || now() - pending.started >= 500) && channel.bufferedAmount < 1024) {
      pending = { nonce: ++sequence, started: now() };
      try { channel.send(JSON.stringify(pending.nonce)); }
      catch { pending = null; grant(0); }
    }
    timer = setTimeout(probe, 250);
  }
  channel.onopen = () => { clearTimeout(timer); probe(); };
  channel.onmessage = ({ data }) => {
    if (!ready() || typeof data !== "string" || data.length > 128) return;
    let reply;
    try { reply = JSON.parse(data); } catch { return; }
    if (!pending || reply?.nonce !== pending.nonce || !Number.isInteger(reply.max_age_ms) ||
        reply.max_age_ms < 0 || reply.max_age_ms > 1000) return;
    const started = pending.started;
    pending = null;
    grant(reply.max_age_ms > 0 ? started + reply.max_age_ms : 0);
  };
  channel.onclose = channel.onerror = () => { if (!closed && current()) grant(0); };
  return {
    ready,
    close() { closed = true; pending = null; clearTimeout(timer); channel.close(); },
  };
}
