# Realtime capacity probe

Manual, local measurements of the existing Nexus HTTP projection and Pion TURN
fixture. This is not part of CI and does not optimize production code.

Build from `e2e/manual/realtime_transport` to reuse its locked Go dependencies:

```sh
mkdir -p ../../artifacts/realtime_capacity
go build -o ../../artifacts/realtime_capacity/load ../realtime_capacity/load.go
go build -o ../../artifacts/realtime_capacity/turn ./cmd/turnfixture
```

From `e2e/`, run the two workloads separately:

```sh
E2E_ASSETS_PREPARED=1 bundle exec ruby -Itest manual/realtime_capacity/nexus.rb
python3 manual/realtime_capacity/turn.py
```

Use `E2E_ASSETS_PREPARED=1` only after the ordinary E2E asset build. The Nexus
probe additionally precompiles production assets under the existing asset lock.
It boots one production Puma process with one request thread, isolated primary,
queue, cable and cache databases, and the existing background hosts. All Task
creation, claiming and signaling use public APIs. Each group of at most 20 Tasks
shares one Agent/Runner credential pair. Bootstrap is outside the measured
interval; large sweeps can encounter the unchanged API-key issuance budget.

`CAPACITY_TIERS=50,60 CAPACITY_SECONDS=60` selects tiers and duration for either
script. Each tier warms for five seconds. Scripts stop at the first failed tier.
Nexus failures mean an HTTP/semantic error, p99 ≥500 ms or ≥1% permission gaps.
A gap is a response arriving after that endpoint's previous authorization window
expired; its fraction is per poll, not percentage of elapsed time. The driver
uses each request's start time plus the returned `max_age_ms`, as current clients
do, and waits 500 ms after each response. Throughput therefore decreases when
requests queue.

TURN creates one allocation and one peer socket per session. It sends 1200-byte
payloads at 1 Mbit/s through each allocation to its peer; every tenth packet is
echoed back through TURN. This is approximately 104.17 forward packets/s plus
10.42 echo packets/s per allocation. Packet counters include only payloads sent
during the measurement, with a one-second drain. RTT measures sampled echoes.
Failure means any send error, <99% delivery, p99 ≥100 ms or <99% of the intended
offered packet rate. Low offered rate is a generator limit, not server capacity.
This excludes ICE/DTLS/SCTP, screen capture, video encoding and real WAN/NIC limits.

JSON, binaries and logs go to ignored `e2e/artifacts/realtime_capacity/`.
The temporary endpoint file contains only synthetic credentials for this isolated
world and is removed on exit. The sampler uses macOS `ps`, `lsof`, and the local
PostgreSQL client. CPU percentages are process CPU seconds divided by elapsed
seconds: 100% means one full core, not the whole machine. Resource averages cover
warmup and measurement; JSON retains the underlying samples. Database observations
select only the probe's four database names and explain behavior without creating
success conditions.

## Connected-viewer measurements

For the connected viewer's relayed-permission path, use `CAPACITY_READERS=1`.
That measures one Runner HTTP reader per session; both credentials and the full
execution authority remain checked by each read. The default `CAPACITY_READERS=2`
retains the original two-reader baseline. Real browser/Runner integration separately
verifies that connected viewers stop HTTP polling and enforce relayed expiry.

`CAPACITY_THREADS` selects request threads in one Puma process (default `1`).
`CAPACITY_REQUIRE_SUCCESS=1` fails unless errors and permission gaps are zero and
p99 is below 250 ms. For final acceptance use `CAPACITY_TIERS=100 CAPACITY_SECONDS=120`.
