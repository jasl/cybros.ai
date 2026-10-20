import { permissionChannel } from "./permission_channel.js";

// The viewer owns peer state only. The original Task owns work and retry offers.
export function realtimeConnection({ call, target, state, prepare, stopRun = false,
  peer = (configuration) => new RTCPeerConnection(configuration), now = () => performance.now() }) {
  const reads = new AbortController();
  let connection, media, permission, connectionId, pending = false, disposed = false, stopped = false;
  let expires = 0, timer, expiryTimer, connected = false, waiting = true;
  const path = `/runs/task/realtime?${new URLSearchParams(target)}`;
  const allowed = () => !disposed && !stopped && now() < expires;
  const status = () => {
    if (disposed || stopped) return;
    const ready = media?.ready() && connection?.connectionState !== "disconnected";
    if (ready) connected = true;
    if (!allowed() || connection?.connectionState === "disconnected") media?.pause();
    state(waiting ? (connected ? "reconnecting" : "connecting") : !allowed() ? "paused" :
      ready ? "connected" : connected ? "reconnecting" : "connecting");
  };
  function closePeer() {
    permission?.close(); permission = null; expires = 0;
    media?.close(); media = null;
    if (connection) { connection.onconnectionstatechange = null; connection.close(); }
    connection = null;
  }
  function resume() { if (allowed()) media?.resume(); }
  async function attach(projection) {
    closePeer();
    let current;
    try {
      const { ice_servers } = await call("/realtime/ice_servers", { signal: AbortSignal.any([reads.signal, AbortSignal.timeout(5000)]) });
      if (disposed || stopped) return;
      connectionId = projection.connection_id;
      current = connection = peer({ iceServers: ice_servers });
      permission = permissionChannel({ peer: current, now, current: () => current === connection && !disposed && !stopped,
        grant(until) {
          expires = until; waiting = false;
          clearTimeout(expiryTimer);
          if (expires > now()) expiryTimer = setTimeout(status, expires - now() + 1);
          status(); resume();
        },
      });
      media = prepare(current, {
        allowed, now, expires: () => expires, current: () => current === connection,
        refresh() { status(); resume(); },
        reconnect() { closePeer(); status(); },
        fail() { expires = 0; closePeer(); state("error"); },
      });
      current.onconnectionstatechange = () => {
        if (current !== connection) return;
        if (["failed", "closed"].includes(current.connectionState)) closePeer();
        status(); resume();
      };
      await current.setRemoteDescription({ type: "offer", sdp: projection.offer_sdp });
      await current.setLocalDescription(await current.createAnswer());
      await new Promise((resolve, reject) => {
        if (current.iceGatheringState === "complete") return resolve();
        const timeout = setTimeout(() => finish(new Error("ICE timeout")), 10000);
        const finish = (error) => {
          clearTimeout(timeout);
          current.removeEventListener("icegatheringstatechange", changed);
          reads.signal.removeEventListener("abort", aborted);
          error ? reject(error) : resolve();
        };
        const changed = () => { if (current.iceGatheringState === "complete") finish(); };
        const aborted = () => finish(new Error("detached"));
        current.addEventListener("icegatheringstatechange", changed);
        reads.signal.addEventListener("abort", aborted, { once: true });
      });
      if (current !== connection || disposed || stopped) return;
      await call("/runs/task/realtime", { method: "PUT", body: { ...target, connection_id: connectionId, sdp: current.localDescription.sdp }, signal: reads.signal });
      if (current === connection) resume();
    } catch {
      if (!disposed && !stopped && (!current || current === connection)) { closePeer(); expires = 0; state("error"); }
    }
  }
  async function poll() {
    if (disposed || stopped) return;
    // The Runner still checks both original credentials and execution facts.
    // Once bound, only it polls Nexus; the viewer observes that same window.
    if (permission?.ready()) { timer = setTimeout(poll, 500); return; }
    const started = now();
    let nextPoll = 500;
    try {
      const { realtime: projection } = await call(path, { signal: AbortSignal.any([reads.signal, AbortSignal.timeout(5000)]) });
      if (disposed || stopped) return;
      if (permission?.ready()) { timer = setTimeout(poll, 500); return; }
      if (connection && projection.connection_id !== connectionId) closePeer();
      clearTimeout(expiryTimer);
      waiting = projection.status === "waiting";
      expires = projection.status === "active" ? started + Math.min(1000, projection.max_age_ms) : 0;
      if (projection.status === "closed") { stopped = true; closePeer(); state("closed"); return; }
      if (expires > now()) expiryTimer = setTimeout(status, expires - now() + 1);
      resume(); status();
      if (["waiting", "active"].includes(projection.status) && projection.offer_sdp && projection.connection_id !== connectionId && !projection.answer_sdp && !pending) {
        pending = true;
        attach(projection).finally(() => { pending = false; });
      }
    } catch (error) {
      // Unknown results do not renew the previous authorization window.
      if (disposed || stopped) return;
      if ([401, 403, 404].includes(error.status)) { stopped = true; closePeer(); state("closed"); return; }
      nextPoll = Math.max(500, (Number(error.details?.retry_after) || 0) * 1000);
      waiting = false; status();
    }
    timer = setTimeout(poll, nextPoll);
  }
  state("connecting");
  poll();
  return {
    async stop() {
      stopped = true; expires = 0; closePeer(); clearTimeout(timer); clearTimeout(expiryTimer);
      state("stopping");
      try {
        await call(stopRun ? "/stop" : "/runs/task/cancel", { method: "POST",
          body: stopRun ? { public_id: target.public_id, workspace_public_id: target.workspace_public_id, host_type: "run", force: true } : target, signal: reads.signal });
        if (!disposed) state("closed");
      } catch (error) { if (!disposed) state(error.code === "not_a_branch" ? "stop_run" : "stop_failed"); }
    },
    dispose() { disposed = true; expires = 0; reads.abort(); clearTimeout(timer); clearTimeout(expiryTimer); closePeer(); },
  };
}
