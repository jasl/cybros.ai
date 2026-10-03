# Container evaluations and installation journeys

This page is §8 of the [evaluation runbook](evals-runbook.md): the two external task-pass corpora,
each run through the one evals lane inside its own container, and the installation journeys of the
gate's group 3. Its sections continue the runbook's numbering (§8a–§8c); any other section number
below (§1.1) names the runbook's.

The harness supports two external task-pass corpora — Agents-on-Rails (rails/ai-evals: 42 tasks, one
`rails_anchor` each; §8a) and Terminal-Bench (harbor's `terminal-bench@2.0` filtered to FrontierHarness's
21; §8b) — each in ITS OWN FORM, run through OUR runner inside THEIR container, THROUGH THE ONE EVALS
LANE ( the task's image is a member of the daemon configuration; no second lane
file). Their tasks state the work and the runner's tools are rho's, so there is no reach dimension: the
reach and success columns read `—` ("not read" — never a red; `Scorecard.red?` reads `reached: false`
alone) and TASK PASS is the one number. A yardstick beside the capability bench, never a substitute:
the comparison with their published numbers is a runs-ledger NOTE, never a pass condition and never a
text tune (their agent, prompts, harness, cold-start checkpoint and pricing table differ; our topology is
their `external-service` shape — the model call leaves the container to Nexus — never an air-gap).

**What ran on the BUILD side (2026-09-15).** Every hook is an argv with a unit test
(`e2e/test/evals_docker_test.rb`, `evals_agents_on_rails_test.rb`, `evals_terminal_bench_test.rb`); the
lane's container branch is code, not a paid run. What the verifier then proved on this Mac with NO model
and NO Nexus: **proof 1** — the derived image builds for one terminal-bench base
(`rho-evals-alexgshaw-chess-best-move-20251031`, amd64 emulated, ≈ 2 min, `rho doctor --strict` green as
the recipe's last step) after ONE recipe fix (`ubuntu:24.04` bases carry `ubuntu` on uid 1000 — §8b's
pre-flight paragraph); the fizzy base never built. **The verify chain** — a container of that image as
root, `TerminalBench::Task#verify_in` → `Daemon#verify_reward!` exactly as the lane calls it: the tests
copied in after "the turn", `bash /tests/test.sh` as root in `/app`, `reward.txt` read off the
bind-mounted host dir, `pass=false reward=0.0` with the whole output on the record, the container
removed and its home deleted by the host user — twice (the untouched image, then after their own
`solution/solve.sh` wrote the mating moves to `/app/move.txt`). BOTH read 0 for one reason that is not
the lane's: **`uvx` segfaults under QEMU on this Mac** (`qemu: uncaught target signal 11`) after apt and
the uv installer succeed, so their pytest never runs and `test.sh` writes `0` — every terminal-bench
reward in that historical Mac experiment read 0; the paid cell therefore required native amd64.
This is a 2026-09-15 observation, not a diagnosis of every current Mac environment. **The pairing** (proof 2) was proved on the install GROUP's container lane (§8c: the
`rho-install-test:rho` image over a bind-mounted home, branch B, one call) — the same `Docker::Daemon`
the evals lane uses — after its first three worlds found three lane-only defects, each a bridge-path
fact the argv pins could not see: `rho server --bind 0.0.0.0` refuses to boot without
`RHO_ACCESS_PASSPHRASE` (`Docker.run_argv` now hands it to the container, and a container that exits
before announcing is a raise at once with its stdout, never a patience); Rails' development host
authorization blocks the `host.docker.internal:<port>` Host header (`E2E::NexusServer` boots the world
with `RAILS_DEVELOPMENT_HOSTS`); and Nexus builds the pairing URL from that same header, which the
steward's browser on the host cannot resolve (`Daemon#start_ceremony` rewrites it back to the harness's
host — the announcement's rewrite, in the other direction). The RUN
half — the END's paid window, on the native box — proves, in this order, before any number is read:
(1) the image builds there for one terminal-bench base and for `lemans-writebook:v1.2.1`; (2) the
terminal-bench container pairs (branch B, `await_announced`, `rho status` through `docker exec`); (3) ONE
task passes end to end on the floor: `chess-best-move` (`tests/test.sh` → `reward.txt`) and
`ac-throttle-search` (rails); then the cells below. Every first-boot lane of round I was red on a
lane-only defect: read (1)–(3) as the fix loop they are.

**How the lane runs a container family** (`e2e/evals/lane_test.rb`, the same `run_and_record` /
`build_record` / artifact writer / world-log copy as every run): a group is one derived image
(`Configuration#image`, its slug in the test method's name); the group builds the image once per base —
cached by tag, else `docker pull --platform linux/amd64`, the PRE-FLIGHT (`command -v apt-get`; the
derived image installs the compiler itself from the manifest's prerequisites row), `docker build` — every
line to `artifacts/evals/<label>/logs/<tag>.build.log`, and a failure anywhere is `build_failed` on EVERY
run of the group (a lane-bug record with the log named, never a lost group); reads the base's WorkingDir
(`docker image inspect --format '{{.Config.WorkingDir}}'` — 20 of the 21 `/app`, `sanitize-git-repo`
`/app/dclm`; never assumed); pairs the container as the group's runner-mode home
(`start_runner_rho!(daemon: Docker::Daemon)`, branch B). Then PER RUN: a FRESH container over the SAME
home (`Daemon#restart!` — the pairing and the runner id live in the bind-mounted home, the image's tree
starts clean: one container per run, harbor's shape, without a ceremony per run), the task's `prepare`
(the rails patch; nothing for terminal-bench), the RUNNER's tools pointed at the WorkingDir (`POST
/environment` on the container; the HOST daemon's runner slot is never pointed — it stays silent),
`rho do "<their instruction>" --model M --dir <workdir> --runner <id>` on the host's full-mode daemon
(`--dir` describes; the tree lives in the container), the loop awaited under THEIR deadline
(`[agent].timeout_sec` / `agent.timeout`) and the family's cost stop, the trace read, `rho stop`, the
task's `verify_in` inside the container, the record. The lane is `plain` only (the container's rho
streams nothing). On a Linux host the container joins the host's network (`--network host`: the harness
Nexus binds 127.0.0.1 and no bridge reaches it); on this Mac a bridge with `host.docker.internal`.

## 8a. Agents-on-Rails

- **Their corpus.** Clone it and point `E2E_EVALS_RAILS_CORPUS=<dir>` at the checkout (`bench.yml` at
  its root, `tasks/<name>/` beside it: `instruction.md` with front-matter `name, description, difficulty,
  tags, category, rails_anchor` and their canary GUID on a line of its own; `environment.patch`;
  `solution.patch` (a reference, never applied by the runner); `verification_test.rb`).
  `E2E::Evals::AgentsOnRails.load(dir)` reads it into `rails`-family tasks (`capability:
  rails.<rails_anchor>`, driver `plain`, verification true, strong tier only, the deadline THEIR
  `agent.timeout`) and asserts THEIR canary in every instruction. Two readings of their config the loader
  ASSUMES until the real repo is beside it (the sample fixture under `e2e/support/fixtures/agents_on_rails/`
  pins them): the canary is a top-level `canary` key of their `bench.yml`; a task's image profile is the
  tag or category naming one of `environment.profiles`, else the first profile. Correct the loader, not
  the corpus, when the real file differs. With the env set, `rake evals_tasks` lists the family and
  `rake "evals[rails/*,<model>]"` (or a task name) runs it.
- **The derived image.** `e2e/evals/docker/Dockerfile` — `ARG BASE`, `FROM --platform=linux/amd64`
  the task's base, then THE SAME `install/install.sh` the host runs, profile `runner`, into `/opt/rho`
  as uid 1000 (created there; their `/app` is root-owned and is chowned to it for `git apply`), tini as
  PID 1, `RHO_MODE=runner`, `RHO_HOME=/var/lib/rho` on a volume. The installer runs ON their base rather
  than `COPY --from` the rho image because the native gems must be compiled against the base's own glibc.
  `E2E::Evals::Docker.build_argv(base: "ghcr.io/evilmartians/lemans-writebook:v1.2.1", tag:
  "rho-evals-writebook")` spells the build (their bases: `lemans-writebook:v1.2.1`, `lemans-fizzy:8112b3d`;
  `:latest` does not exist on ghcr and both are amd64-only, so an arm64 host emulates).
- **The container.** `Docker.run_argv` — `docker run -d --name <n> -p 127.0.0.1:N:N -v <host home>:/var/lib/rho
  -v <task dir>:/tests:ro --add-host host.docker.internal:host-gateway -e RHO_MODE=runner <tag> server
  --bind 0.0.0.0 --port N --nexus-url http://host.docker.internal:<nexus port> --unsafe-plaintext`.
  The home is bind-mounted so the announcement (`tmp/announcement.json`), the pairing and `log/rho.log`
  are readable from the harness; `E2E::Evals::Docker::Daemon` (a `RhoDaemon` subclass) rewrites the
  announced endpoint's host to `127.0.0.1` and runs every `cli` verb through `docker exec <n> rho …`
  (the prefix is on the image's PATH); `stop` saves the container's stdout as `daemon.log`, releases
  the home's files to the host user and removes the container.
- **One task.** `prepare` = `git apply /tests/environment.patch` in `/app`; the turn as above; then
  `verify_in` = their three steps: `git checkout -- test bin config/environments/test.rb` (their
  `verifier.restore`), `bin/rails test` (their `preverify`), `ruby -Itest /tests/verification_test.rb`
  (their `command` with `-report-lemans` dropped — the exit status is the verdict). Start with
  `ac-throttle-search` (`rate_limit`, easy). The record's `task_pass` is that exit; reach and success read `—`.

## 8b. terminal-bench

- **The dataset — NOT vendored: one checkout the person makes, named by the env.** harbor's registry
  (github.com/laude-institute/harbor, `registry.json`: name `terminal-bench`, version `2.0`, 89 tasks;
  there is no 2.1 entry — FrontierHarness labels its board `terminal-bench-2-1` over the same tasks)
  resolves every task to `https://github.com/laude-institute/terminal-bench-2.git` at commit
  `69671fbaac6d67a7ef0dfec016cc38a64ef7a77c`, FLAT at the repo root (`<name>/{instruction.md, task.toml,
  environment/Dockerfile, solution/solve.sh, tests/test.sh, tests/test_outputs.py}`; ≈ 47 MB, no LFS):

  ```sh
  git clone https://github.com/laude-institute/terminal-bench-2.git references/terminal-bench-2   # references/ is git-ignored
  git -C references/terminal-bench-2 checkout 69671fbaac6d67a7ef0dfec016cc38a64ef7a77c
  export E2E_EVALS_TB_CORPUS=$PWD/references/terminal-bench-2
  ```

  `E2E::Evals::TerminalBench.load(dir, bench:)` filters the checkout to the 21 names `bench.yml`
  freezes (`terminal_bench.tasks` — FrontierHarness's `benchmark.json` ids with the `terminal-bench/`
  prefix dropped; a name the checkout lacks is refused by name) and reads each task in THEIR form: the
  name is the DIRECTORY (`task.toml` at the pinned commit is `version = "1.0"` with no `[task]` table;
  TB2 `main` and FrontierHarness's copies are `schema_version = "1.1"` with `[task] name =
  "terminal-bench/<dir>"` — read as a check, never as the name), `[environment].docker_image` the base
  (`alexgshaw/<name>:20251031`, single-manifest linux/amd64 on Docker Hub), `[agent].timeout_sec` THE
  DEADLINE (theirs: 17 × 900 s, `code-from-image` and `constraints-scheduling` 1200, `dna-insert` 1800,
  `modernize-scientific-stack` 600 — Σ 20 100 s per pass, ≈ 16.8 h serial worst case at the configured n=3; never the
  bench's 600), `[verifier].timeout_sec` the verifier's bound, `[metadata].difficulty` a fact column
  (all 21 `medium`), `instruction.md` the model's bytes VERBATIM (no canary appended — their form
  carries none in it; the mock corpus's last-line rule is that corpus's alone), `tests/test.sh` required.
  `bundle exec rake evals_tasks` lists the 21 under `terminal-bench` when the env is set and says
  `not loaded` when it is not (a `rake "evals[*]"` never becomes docker-bound by accident).
- **The verifier is theirs and runs as ROOT with the network.** Every `tests/test.sh` apt-installs
  curl, fetches uv from astral.sh and pytest from PyPI (FrontierHarness's README says the same of its
  trials), then writes `/logs/verifier/reward.txt` — `1` or `0` (harbor's reward is a float). So the
  lane runs the CONTAINER as root (`docker run --user 0`: harbor runs the agent as the image's default
  user, root, and several of the 21 assume it — `openssl-selfsigned-cert`, `kv-store-grpc`'s ports,
  `db-wal-recovery`, `git-leak-recovery`, `polyglot-c-py`'s apt installs); the image is still built as
  uid 1000 (the installer's root guard reads BuildKit's RUN as no container). The hidden check stays
  hidden: nothing is mounted at `/tests` for the turn; `verify_in` copies the task's `tests/` in
  AFTER the turn (`docker cp`, harbor's shape), runs `docker exec -u 0 -e HOME=/root -w <workdir> bash
  /tests/test.sh` under `[verifier].timeout_sec`, and reads `reward.txt` off the host — the run's
  `artifacts/evals/<label>/logs/<run>/verifier/` is bind-mounted at `/logs/verifier`, so `reward.txt`
  and `ctrf.json` land in the artifact. Pass = the reward parses to a Float ≥ 1; absent or unparseable
  is red BY NAME (`no /logs/verifier/reward.txt was written`, `reward.txt holds "…", not a number`) —
  never a raise; the record's `facts.reward` carries the number.
- **The configured cells.** `bench.yml` pins 21 tasks. The default cell selects
  `deepseek/deepseek-flash` at 3 runs per task; the optional cell accepts
  `openrouter/moonshotai/kimi-k3` and `openrouter/z-ai/glm-5.3`, also at 3 runs. Optional models
  run only when explicitly selected. `E2E_EVALS_RUNS` may narrow those counts for a smoke.
  Each run uses the corpus deadline and the $20 family stop threshold. Across 63 runs, the sum
  of those thresholds is $1,260 per model; polling and in-flight calls can overshoot, so this is
  a planning bound rather than a billing cap. Historical $100–150 estimates referred to the
  earlier, smaller cell and are not a current forecast.

  ```sh
  # the default cell (floor, n=3; E2E_EVALS_RUNS=1 narrows)
  E2E_LIVE=1 E2E_EVALS_TB_CORPUS=$PWD/references/terminal-bench-2 E2E_EVALS_LABEL=tb-floor \
    bundle exec rake "evals[terminal-bench/*,deepseek/deepseek-flash]"
  # proof 3 first: one task, one run
  E2E_LIVE=1 E2E_EVALS_TB_CORPUS=$PWD/references/terminal-bench-2 E2E_EVALS_RUNS=1 E2E_EVALS_LABEL=tb-proof \
    bundle exec rake "evals[chess-best-move,deepseek/deepseek-flash]"
  # the optional comparison cell (kimi-k3, n=3, $20/run stop threshold)
  E2E_LIVE=1 E2E_EVALS_TB_CORPUS=$PWD/references/terminal-bench-2 E2E_EVALS_LABEL=tb-kimi \
    bundle exec rake "evals[terminal-bench/*,openrouter/moonshotai/kimi-k3]"
  ```

  The wall: each task's group builds its own derived image the first time (an emulated amd64 installer
  run: minutes per base on this Mac, ×21 the first time, cached by tag after — `Plan.journey_seconds`
  adds 1800 s per distinct image), then n fresh containers; 21 groups × the ceremony; the evals task
  sizes the world's patience from the plan. ONE world, never beside `rake e2e`, a live lane or the
  nexus suite (§1.1). `rake "evals_scorecard[<label>]"` then prints task pass % with `—` on reach and
  success; `rake evals_ledger` shows the family's rows as `r— s— p<n>/<N>` under the matching bench digest.
- **A ledger note for a new family:** after the cell,
  the local ledger at `e2e/artifacts/evals/runs/LEDGER.md` can support a reviewed
  report deriving `effective cost per pass` = Σ
  `efficiency.cost_amount` / passes off the same records, beside their published spread, with the
  caveat above (not directly comparable: agent, prompts, harness, checkpoint, and pricing differ);
  the deliberate red (a task run without `tests/test.sh`, a stopped run) is a record with its trace,
  never an edit.
- **The pre-flight and what is NOT a rho code path.** A base without `apt-get` (a musl base, out of
  scope) or one naming no WorkingDir fails the group as `build_failed` with the reason on every record;
  `cc`/`git`/`uv` inside the image are the installer manifest's rows (`RHO_APT_PREREQUISITES`), never a
  lane workaround. A base that already has a user on uid/gid 1000 (`ubuntu:24.04` ships `ubuntu` there —
  eight of the 21; proof 1 on `chess-best-move` failed on it, `groupadd: GID '1000' already exists`) is
  RENAMED to `rho` by the recipe, its home moved to `/home/rho`: the uid is what the recipe needs, never
  the base's name for it. Known emulation limits: git-lfs's postinst and `uv --version` under QEMU on
  the Mac used for the historical build — native amd64 avoids that emulation path.

## 8c. Installation journeys

`install_container`, `install_compose`, and `install_host` run in group 3 of
`e2e/support/journey_groups.rb`; `E2E::InstallLane` supplies their shared setup. An installed rho
pairs with the mock world's Nexus as a runner and serves one tool call. `rake e2e` includes them;
`rake "e2e_group[3]"` runs their group along with its other journeys. Each journey skips with a
reason when prerequisites are absent. A skip provides no evidence that installation works.

- **`install_container`** — the PRE-BUILT image `rho-install-test:rho` (`RHO_INSTALL_TEST_IMAGE` names
  another; `RHO_INSTALL_TEST_DOCKER=1 install/test/run.sh` or `docker build -f install/docker/Dockerfile
  --target rho -t rho-install-test:rho .` builds it OUTSIDE the gate — the group's weight is a `docker
  run`, never a 446 MB build): `rho doctor --strict` through the image's one door, the container as a
  runner over a bind-mounted home (`Docker::Daemon`'s shape, `/tests:ro` carrying a marker file, the
  `0.0.0.0` bind's `RHO_ACCESS_PASSPHRASE` minted per daemon — rho refuses the wider bind without one), the
  ceremony on branch B, `rho status` through `docker exec`, one `read` an agent-mode host rho names it
  for — the row addressed to and claimed by the container's runner, the marker in the answer.
  Run it locally on macOS or Linux with Docker. The image must exist before the full
  `bundle exec rake` gate or this lane skips; GitHub product smoke does not build the image or
  run the installation journeys.
- **`install_compose`** — the shipped `install/docker/compose.yml` with an override naming the local
  image (no CI-driven publishing), the control port published on loopback, the home bound, the passphrase
  in `environment` (the shipped file's `rho-full` service binds `0.0.0.0` the same way and needs the same
  variable from whoever brings it up — `docker compose config` cannot see that); `docker
  compose exec rho-runner rho status`, the same one call, then the ORPHAN COUNT BEFORE THE STOP (a
  double-forked sleep whose group leader died re-parents to PID 1 and is reaped, zero zombies, `ps` in
  the container — PID 1 is `docker-init` here, the file's own `init: true`, with the image's tini beneath
  it; under `docker run` it is tini itself) and `docker compose stop -t 30` inside the file's grace period.
- **`install_host`** — LOCAL-ONLY, opt-in `E2E_INSTALL_HOST=1` (never in CI): `install/install.sh
  --profile full` into a temporary prefix (the network and minutes; `RHO_INSTALL_TEST_CACHE` keeps the
  downloads), `rho version`, `rho doctor --strict`, the installed `bin/rho` as a runner paired with the
  world serving one call, `rho uninstall`. The update ladder stays `install/test/install_test.sh`'s.
