# WebRTC transport experiment

Manual, isolated Linux experiment for direct UDP WebRTC versus forced UDP TURN.
The peer has three DataChannels: ordered input/ack, ordered synthetic terminal
load, and unordered non-retransmitted synthetic frame chunks. Input acknowledgments
come from a separate process attached to a real PTY. The load generator is not a
terminal application, video encoder, desktop capture or renderer.

Requires Docker, Python 3, and, for the Nexus probe, the existing E2E Ruby bundle
and its ordinary isolated database/browser prerequisites. No model calls occur.

From this directory:

```sh
docker build -t cybros-e2e/realtime-transport:poc .
python3 bench.py --samples 300 --duration 30 --rounds 2 --output ../../artifacts/realtime_transport/baseline.json
python3 bench.py --samples 100 --duration 10 --rounds 1 --delay-ms 10 --output ../../artifacts/realtime_transport/delay.json
```

From `e2e/`:

```sh
bundle exec ruby -Itest manual/realtime_transport/nexus_probe.rb
bundle exec rubocop --no-server manual/realtime_transport/nexus_probe.rb
```

The harness creates its own Docker network and three containers, exposes harness
HTTP only on random loopback ports, and removes those exact resources in `finally`.
The fixed TURN credentials are synthetic and used only inside that network. Do not
deploy this image as a service: its HTTP endpoints deliberately have no production
authentication. No Windows host or Runner installation is touched.

`bench.py` uses synthetic gate refreshes. `nexus_probe.rb` separately provisions an
Agent and private Runner through public APIs, creates/claims/extends a standalone
ToolTask, and uses current Run and exact-claim reads to drive the fixture gates. It
checks expiry without task cancellation, revoked member credentials, wrong claim,
and public force Stop followed by PTY reaping. The coordinator holds no persistent
execution state. Sequential reads do not provide the proposed atomic authorization
projection; signaling and local gate delivery remain test seams. This is not a
shipped Runner handler, permission protocol or SDK feature.

Measurements:

- Five warmups precede each round. Raw input timings use the Agent process's
  monotonic clock from DataChannel send to actual PTY-child acknowledgment.
- Mixed traffic is 16 KiB terminal chunks at 16 Hz and 64 KiB synthetic frames at
  10 Hz, beside the requested input sampling rate. Frame timing is send to complete
  receive plus acknowledgment, not one-way frame age or display latency.
- CPU is process CPU seconds divided by elapsed seconds (one core = 1.0). RSS is
  sampled at boundaries, not a continuously measured maximum. Container/OS CPU,
  Nexus CPU and real codec cost are outside these measurements.
- TURN counters sum its listening and allocation UDP sockets. With both peers
  forced to relay, internal allocation forwarding is counted too. These are
  socket-processing bytes, not unique payload bytes or physical NIC billing.
  Auto mode can send small TURN setup/cleanup traffic even when data is direct.
- `--delay-ms` applies netem to all three container egress interfaces, including
  harness HTTP. Direct input/ack crosses two delayed egresses; forced relay crosses
  four. This deliberately models a longer relay path, not equal end-to-end RTT.
- Reconnection explicitly builds a new PeerConnection while retaining the PTY.
  The failure probe blocks direct UDP, confirms an auto-selected relay candidate,
  rejects a stale connection identifier, and kills/reaps the child on fixture Stop.
  It does not establish seamless same-connection ICE migration or Internet NAT
  traversal. Unacknowledged input is not replayed.

Raw evidence belongs in ignored `e2e/artifacts/realtime_transport/`. Durable
conclusions and limitations belong in the design/results documents. No throughput
or production-readiness threshold is inferred from passing this script.
