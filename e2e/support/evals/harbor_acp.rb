require "date"
require "fileutils"
require "json"
require "shellwords"
require "uri"
require_relative "bench"
require_relative "docker"
require_relative "plan"
require_relative "records"
require_relative "report_line"
require_relative "scorecard"
require_relative "terminal_bench"

module E2E
  module Evals
    # THE HARBOR CELL — THE BENCHMARK DOOR: rho as the ACP HOST validated by harbor driving it —
    # `harbor run -a acp:rho` over a registry entry read off the gem's own file
    # (`agents/rho/rho-acp/registry/rho/agent.json`; kept in the tree, not submitted) whose `local`
    # distribution the cell overlays with the evals image's `/opt/rho/libexec/rho-acp-launch`
    # (`e2e/evals/docker/rho-acp-launch`: the daemon, the pairing document, then `rho-acp`),
    # `auth_policy: disabled`, `permission_mode: allow`, the cell's model on harbor's `-m` (→
    # `HARBOR_ACP_REQUESTED_MODEL` → `set_config_option model`). harbor's own runner drives
    # `rho-acp` with the task as ONE prompt and scores with its verifier; `acp-events.jsonl` becomes
    # its trajectory and lands in the runs ledger. Acceptance: the cell scores within the plain
    # driver's band on the same model — an outside measurement, never a proof gate. One calibration
    # cell, landing last.
    #
    # THE IMAGE HARBOR RUNS IS NOT THE CORPUS'S: harbor starts each task on
    # the task's own image (`task.toml`'s `docker_image`, the alexgshaw
    # base) — where no launcher is. The plain driver's DERIVED image
    # (`Docker.tag_for_base`, the box's prebuild of the 21) has it, but its
    # ENTRYPOINT (`tini → docker-entrypoint → rho "$@"`) would swallow
    # harbor's own container command. So the cell writes an OVERLAY CORPUS
    # under its job dir before harbor runs (`write_overlay`): one task dir
    # per selected task copied from the corpus — everything but
    # `environment/` — with `docker_image` DROPPED from the copied
    # `task.toml` and an `environment/Dockerfile` FROM the derived tag with
    # a neutral ENTRYPOINT (`overlay_dockerfile`); harbor's `-p` names the
    # overlay. The Dockerfile form, not `docker_image = <derived tag>`: only
    # a build can put a new ENTRYPOINT in front of the tag, and TB2 ships
    # BOTH keys per task (the image is the Dockerfile's published build), so
    # the two are alternatives — with the key gone harbor has one thing to
    # do, a two-instruction build on a local tag (seconds, no context).
    #
    # THREE PIECES, each without the other two: `Cell` (the plan — the
    # registry entry, the command line, the overlay, the tags, the label;
    # pure, printed by `rake "evals_harbor_acp[dry]"`), `Sidecar` (the PAIRING: every
    # running container on the box (`docker ps`, by id — never by image:
    # the box cell 2026-09-19-harbor-acp-dry's third launch paired 0
    # containers on `--filter ancestor=<derived tag>`, since BuildKit
    # images record no parent chain) probed for its ceremony document
    # THROUGH the container (`docker exec <id> cat`, the driver's shape)
    # and confirmed with the steward (`E2E::Ceremony.confirm`) ONCE per
    # container; every docker call an argv through one injectable
    # spawner, the confirm a callable) and `import` (harbor's job dir read
    # into the ledger's records shape — one record per trial, the
    # verifier's reward as `task_pass`, no reach dimension, `driver:
    # harbor-acp`, style `acp` so the cell reads as its own row beside the
    # plain driver's on the same task and model).
    #
    # THE RUN IS A LANE'S (`evals/harbor_acp_lane_test.rb`, under `rake
    # "evals_harbor_acp[run]"`): the harness boots its worlds inside a
    # Minitest lane (`run_e2e_tests` → `E2E::NexusServer`), and the pricing,
    # the provider and the hosts are the lane's steps
    # (`LiveJourney#price_and_open_lane!`), so `run!` takes the BOOTED world
    # (`base_url:`) and the lane's steward as its confirm, and the cell's
    # `nexus_url` is that world AS HARBOR'S CONTAINERS REACH IT
    # (`Cell#with_world` → `Cell.nexus_url`): on the box its LAN IP under
    # the world's port, the world bound 0.0.0.0 (E2E_NEXUS_BIND) — harbor's
    # containers run on harbor's own compose bridge, never the plain
    # driver's `--network host`. The pairing document comes back at that
    # origin and is rewritten to the steward's before the browser visits
    # it (`pairing_for_steward`: the device page is a signed-in member's).
    #
    # WHAT THE FACTS SHEET DOES NOT SAY is spelled once here as constants
    # and named in the dry run: harbor's task flag (`-i`, the
    # orchestrator's box pattern), the job-dir flags, the trial dir layout
    # (`<job>/<trial>/agent/acp-events.jsonl`, `result.json`,
    # `verifier/reward.txt`), the registry entry's optional keys.
    module HarborAcp
      # `-a acp` — the bare ACP agent: harbor 0.23.0 derives a registry SPEC from the `acp:<id>`
      # shorthand and refuses it beside `registry_entry_path` ("Provide only one of registry_spec,
      # registry_entry, or registry_entry_path", acp.py:424 on the box); the design's `acp:rho` is
      # the spelling of a SUBMITTED entry.
      AGENT = "acp".freeze
      LAUNCHER = "/opt/rho/libexec/rho-acp-launch".freeze
      LAUNCHER_SOURCE = File.expand_path("../../evals/docker/rho-acp-launch", __dir__)
      # The gem's registry entry, the base of the cell's (the harness reaches
      # every rho tree by its repo-relative path, `RhoDaemon::RHO_ROOT`'s way).
      REGISTRY_ENTRY_SOURCE = File.expand_path("../../../agents/rho/rho-acp/registry/rho/agent.json", __dir__)
      TOOLS_ROOT = Docker::APP
      CEREMONY = File.join(Docker::HOME, "tmp", "acp-ceremony.json").freeze
      REGISTRY_ENTRY_FILE = "rho-agent.json".freeze
      # The exception types harbor raises when the agent runs past its budget.
      TIMEOUT_EXCEPTIONS = %w[AgentTimeoutError TimeoutError].freeze
      HARBOR_LOG = "harbor.log".freeze
      # harbor's `--agent-kwarg`s: no login (the home is paired by the sidecar), every permission
      # request allowed (the runner's `allow` picks the first allow_once/allow_always option).
      KWARGS = { "auth_policy" => "disabled", "permission_mode" => "allow" }.freeze
      # harbor's flags as the orchestrator's box pattern spells them
      # (`harbor run -a <agent> -m <model> -k <n> -i <task>…`); the job-dir
      # pair is harbor's own naming, unverified from the facts sheet.
      # harbor 0.23.0 (`harbor run --help` on the box, 2026-09-18): `-p` names the
      # local task or dataset directory ONCE and `-i` includes a task by NAME
      # (a glob) — never a task directory per `-i`.
      CORPUS_FLAG = "-p".freeze
      TASK_FLAG = "-i".freeze
      JOBS_DIR_FLAG = "--jobs-dir".freeze
      JOB_NAME_FLAG = "--job-name".freeze
      # harbor's per-trial outputs: the events file is the trajectory's source, the summary holds
      # initialize/auth/session/prompt_response/ errors, the verifier's reward its own file;
      # `result.json` is harbor's trial result when it writes one (its keys read tolerantly).
      EVENTS = "acp-events.jsonl".freeze
      SUMMARY = "acp-summary.json".freeze
      RESULT = "result.json".freeze
      AGENT_DIR = "agent".freeze
      VERIFIER_DIR = "verifier".freeze
      FAMILY = TerminalBench::FAMILY
      DRIVER = "harbor-acp".freeze
      STYLE = "acp".freeze
      LABEL_WORD = "harbor-acp".freeze
      ENV_JOBS_DIR = "E2E_EVALS_HARBOR_JOBS_DIR".freeze
      ENV_NEXUS_URL = "E2E_EVALS_HARBOR_NEXUS_URL".freeze
      ENV_NEXUS_HOST = "E2E_EVALS_HARBOR_NEXUS_HOST".freeze
      # The plan's address before the lane boots the world: port 0, nobody's.
      PLACEHOLDER_URL = "http://127.0.0.1:0".freeze
      DEFAULT_JOBS_DIR = File.expand_path("../../artifacts/evals/harbor-jobs", __dir__)
      # THE OVERLAY CORPUS under the job dir: harbor's task dirs, one per
      # selected task, each `environment/Dockerfile` FROM its derived tag.
      OVERLAY_DIR = "corpus".freeze
      ENVIRONMENT_DIR = "environment".freeze
      DOCKERFILE = "Dockerfile".freeze
      DOCKER_IMAGE_KEY = "docker_image".freeze
      DOCKER_IMAGE_LINE = /\A\s*#{DOCKER_IMAGE_KEY}\s*=/
      # The derived image's PID 1 (its ENTRYPOINT's first word), kept alone.
      TINI = "/usr/bin/tini".freeze
      # A document the sidecar confirms: a code, and the URL the steward's
      # browser visits (at the steward's own origin first: `pairing_for_steward`).
      PAIRING_KEYS = %w[user_code verification_uri_complete].freeze
      PLAIN_TOKEN = %r{\A[\w./:@=+,-]+\z}

      # THE PLAN: pure over the corpus and the env, printed whole by the dry
      # run, executed by `run!`.
      Cell = Data.define(:model, :runs, :tasks, :corpus_dir, :overlay_dir, :job_dir, :job_name, :nexus_url, :nexus_url_source,
        :label, :runs_dir, :bench) do
        # The task list is the terminal-bench family's (E2E_EVALS_TB_CORPUS,
        # the bench's 21 filtered by E2E_EVALS_TASKS); the model the cell's
        # (E2E_EVALS_MODELS's first, a bench id; else the default cell's
        # first floor); k the cell's cap unless E2E_EVALS_RUNS names fewer.
        def self.plan(bench:, env: ENV, today: Date.today, corpus: nil)
          corpus ||= TerminalBench.load(env[TerminalBench::ENV_CORPUS], bench: bench)
          tasks = corpus.select(env.fetch("E2E_EVALS_TASKS", "*"))
          raise ArgumentError, "harbor acp: E2E_EVALS_TASKS=#{env["E2E_EVALS_TASKS"].inspect} names no terminal-bench task" if tasks.empty?

          policy = tasks.first.policy
          model = env["E2E_EVALS_MODELS"].to_s.split(",").map(&:strip).reject(&:empty?).first || policy.cell_models.first
          raise ArgumentError, "#{model.inspect} is not a model the bench names: #{bench.models.join(", ")}" unless bench.models.include?(model)

          runs = [Integer(env.fetch("E2E_EVALS_RUNS", policy.runs_cap(model))), policy.runs_cap(model)].min
          label = env["E2E_EVALS_LABEL"].to_s.empty? ? "#{today.iso8601}-#{LABEL_WORD}-#{Bench.slug(model)}" : env["E2E_EVALS_LABEL"]
          url, source = nexus_url(env)
          jobs = env[ENV_JOBS_DIR].to_s.empty? ? DEFAULT_JOBS_DIR : File.expand_path(env[ENV_JOBS_DIR])
          job_dir = File.join(jobs, label)
          new(model: model, runs: runs, tasks: tasks, corpus_dir: corpus.dir, overlay_dir: File.join(job_dir, OVERLAY_DIR),
            job_dir: job_dir, job_name: label, nexus_url: url, nexus_url_source: source, label: label, runs_dir: bench.runs_dir,
            bench: bench)
        end

        # NEXUS AS HARBOR'S TASK CONTAINERS REACH IT — three sources, the
        # first that answers: E2E_EVALS_HARBOR_NEXUS_URL named whole; else
        # E2E_EVALS_HARBOR_NEXUS_HOST under the BOOTED world's port — on the
        # box its LAN IP (10.0.0.115): harbor's containers run on harbor's
        # own compose bridge, never the plain driver's `--network host`, so
        # the world's 127.0.0.1 is the container itself there and no
        # `host.docker.internal` resolves on a Linux bridge, and the world
        # binds 0.0.0.0 for it (E2E_NEXUS_BIND, `support/nexus_server.rb`);
        # else the world's URL as it is (its own host). The world is the
        # LANE's, handed in by `with_world` once booted — never read off the
        # environment at plan time: the dry run carries a placeholder whose
        # source line names the three.
        def self.nexus_url(env, world_url: nil)
          return [env[ENV_NEXUS_URL], ENV_NEXUS_URL] unless env[ENV_NEXUS_URL].to_s.empty?

          host = env[ENV_NEXUS_HOST].to_s
          return [PLACEHOLDER_URL, placeholder_source(host)] if world_url.nil?
          return [world_url, "the booted world's URL as it is (#{ENV_NEXUS_HOST} unset)"] if host.empty?

          [URI::HTTP.build(host: host, port: URI(world_url).port).to_s, "#{ENV_NEXUS_HOST}=#{host} under the booted world's port"]
        end

        def self.placeholder_source(host)
          "placeholder until the lane boots the world — then #{ENV_NEXUS_URL} whole when set, else " \
            "#{ENV_NEXUS_HOST} (#{host.empty? ? "unset: the world's own host" : host}) under the world's port"
        end

        # THE BOOTED WORLD as the lane reaches it (E2E_BASE_URL): the same
        # cell with Nexus's address for the containers derived from it.
        def with_world(world_url, env: ENV)
          url, source = self.class.nexus_url(env, world_url: world_url)
          with(nexus_url: url, nexus_url_source: source)
        end

        # THE WORLD'S PATIENCE, sized as `Plan.journey_seconds` sizes the
        # plain driver's: twice each trial's deadline (harbor's agent timeout
        # is the task's own `agent.timeout_sec`, the number `deadline_seconds`
        # reads), tasks × k, plus the boot-and-teardown slack; no image
        # slack — the derived tags are the box's prebuild and the overlay's
        # build is two instructions on a local tag. harbor runs trials
        # concurrently, so the serial sum is the bound, never the estimate.
        def journey_seconds = 2 * runs * tasks.sum(&:deadline_seconds) + Plan::BOOT_AND_TEARDOWN_SLACK_SECONDS

        def entry_path = File.join(job_dir, REGISTRY_ENTRY_FILE)
        def log_path = File.join(job_dir, HARBOR_LOG)
        def run_dir = File.join(runs_dir, label)
        def registry_entry = HarborAcp.registry_entry(nexus_url: nexus_url)
        def jobs_dir = File.dirname(job_dir)
        # harbor reads the OVERLAY, never the corpus (`corpus_dir` is the
        # overlay's source): under the job dir, absolute already — harbor is
        # spawned FROM the job dir (`run!`).
        def argv
          HarborAcp.run_argv(entry_path: entry_path, model: model, runs: runs, corpus_dir: overlay_dir,
            task_names: tasks.map(&:name), jobs_dir: jobs_dir, job_name: job_name)
        end
        # The argv as one line a shell reads back: a token of plain path,
        # flag and `key=value` characters rides bare, anything else escaped.
        def command = argv.map { |token| token.match?(PLAIN_TOKEN) ? token : Shellwords.escape(token) }.join(" ")

        # A task's derived tag: the plain driver's, one per base, the app
        # tree's owner the family's (terminal-bench: the base's) — what the
        # overlay's Dockerfile is FROM (the sidecar never watches a tag).
        def tag_for(task) = Docker.tag_for_base(task.image, app_owner: Docker.app_owner_for(container_user: task.container_user))
        def tags = tasks.map { |task| tag_for(task) }.uniq
        def overlay_task_dir(task) = File.join(overlay_dir, task.name)

        def describe
          first = tasks.first
          lines = ["harbor acp cell — the benchmark door (ACP design r2 §5.3)",
                   "  model:       #{model}   k: #{runs}   tasks: #{tasks.size} (#{tasks.map(&:name).join(", ")})",
                   "  corpus:      #{corpus_dir}",
                   "  overlay:     #{overlay_dir}   (harbor's #{CORPUS_FLAG}: the corpus's task dirs copied, each FROM its derived tag; written by run!)",
                   "  job dir:     #{job_dir}   (harbor's #{JOBS_DIR_FLAG} #{jobs_dir} #{JOB_NAME_FLAG} #{job_name})",
                   "  nexus url:   #{nexus_url}   (#{nexus_url_source})",
                   "  records:     #{run_dir}/#{Records::FILE}   (then: rake evals_ledger)",
                   "",
                   "registry entry → #{entry_path}:",
                   JSON.pretty_generate(registry_entry),
                   "",
                   "command (from #{job_dir}; no env file — the model's credential is Nexus's):",
                   "  #{command}",
                   "",
                   "overlay task → #{overlay_task_dir(first)} (one of #{tasks.size}; #{TerminalBench::INSTRUCTION}, #{TerminalBench::TESTS_DIR}/ " \
                   "and solution/ copied as they are, #{ENVIRONMENT_DIR}/ replaced):",
                   "  #{TerminalBench::TASK_TOML} (#{DOCKER_IMAGE_KEY} gone — its bytes otherwise):",
                   *indent(HarborAcp.overlay_task_toml(File.read(File.join(first.dir, TerminalBench::TASK_TOML), encoding: Encoding::UTF_8),
                     name: first.name)),
                   "  #{ENVIRONMENT_DIR}/#{DOCKERFILE}:",
                   *indent(HarborAcp.overlay_dockerfile(tag_for(first))),
                   "  the #{tags.size} derived tag(s) the overlay is FROM (the box's prebuild, on no registry):",
                   *tags.map { |tag| "    #{tag}" },
                   "",
                   "sidecar (E2E::Evals::HarborAcp::Sidecar, beside harbor while it runs):",
                   "  polls  #{Sidecar.ps_argv.join(" ")}  every #{Sidecar::POLL_SECONDS} s — every running container on the box, by id, never by image,",
                   "  probes #{Docker.cat_argv("<container>", CEREMONY).join(" ")}  for each one not yet paired (no file: silence, asked again),",
                   "  confirms a document carrying a code with the steward (E2E::Ceremony.confirm) ONCE per container,",
                   "  and the launcher inside waits for /status workspace adopted, then execs rho-acp.",
                   "",
                   "assumptions the dry run cannot check (report them from the box):",
                   "  - harbor accepts the overlay's layout: a task dir whose #{TerminalBench::TASK_TOML} names no #{DOCKER_IMAGE_KEY} and whose",
                   "    #{ENVIRONMENT_DIR}/#{DOCKERFILE} it BUILDS (the two are alternatives — TB2 ships both, the image the Dockerfile's published",
                   "    build), and its build takes the local FROM as it is (the derived tags are the box's prebuild, on no registry: a `--pull` would miss them),",
                   "  - HANDLED, no longer assumed: the derived image's ENTRYPOINT (tini → docker-entrypoint → `rho \"$@\"`) would have swallowed",
                   "    harbor's own container command — the overlay's Dockerfile keeps tini alone in front of it, and USER #{TerminalBench::CONTAINER_USER}",
                   "    restores the base's default (the plain driver's `--user #{TerminalBench::CONTAINER_USER}`; the recipe's last USER is the install's 1000),",
                   "  - the sidecar's probe is one docker exec per unpaired running container per poll (every container on the box, by id: the box cell",
                   "    2026-09-19-harbor-acp-dry paired none by `ancestor=<derived tag>` — a BuildKit image records no parent chain — while the launcher waited its 300 s),",
                   "  - harbor 0.23.0 read on the box: `#{CORPUS_FLAG} <corpus>` + `#{TASK_FLAG} <task name>` select the tasks, `#{JOBS_DIR_FLAG}`/`#{JOB_NAME_FLAG}` place the job, `--agent-kwarg registry_entry_path=` is the entry (confirmed);",
                   "  - a trial lands as <job>/<trial>/#{AGENT_DIR}/#{EVENTS} beside #{RESULT} or #{VERIFIER_DIR}/#{Docker::REWARD},",
                   "  - the lane (evals/harbor_acp_lane_test.rb) boots the world, prices it and enables the cell's provider; on the box the",
                   "    world binds 0.0.0.0 (E2E_NEXUS_BIND) and the containers reach it by the LAN IP (#{ENV_NEXUS_HOST}=10.0.0.115) —",
                   "    harbor's compose bridge, never the plain driver's --network host — and the pairing URL comes back at that origin,",
                   "    rewritten to the steward's before the browser visits it (the device page is a signed-in member's)."]
          lines.join("\n")
        end

        # A file's lines under the plan's indent, a blank one left blank.
        def indent(text) = text.lines(chomp: true).map { |line| line.empty? ? "" : "    #{line}" }
      end

      module_function

      # THE REGISTRY ENTRY harbor reads: the gem's file is the BASE — `id`, `name`, `version` (rho's
      # own, pinned there), `description`, `repository`, the license and the authors as the file has
      # them — and the cell's OVERLAY is its `distribution`: a `local` one — the launcher already in
      # the image — with the env the launcher needs: full mode, the tools root the image's
      # WorkingDir, Nexus as the cell reaches it. harbor 0.23.0 validates the file with its
      # `AcpRegistryEntry` pydantic model (acp.py, read on the box): `id`, `name`, `version`,
      # `description`, `distribution` required; `repository`, `authors`, `license`, `website`,
      # `icon` optional; no `extra="forbid"`, so the registry's `license_url` passes through
      # ignored.
      def registry_entry(nexus_url:)
        base = JSON.parse(File.read(REGISTRY_ENTRY_SOURCE, encoding: Encoding::UTF_8))
        base.merge("distribution" => {
          "local" => {
            "cmd" => LAUNCHER, "args" => [],
            "env" => { "RHO_MODE" => "full", "RHO_TOOLS_ROOT" => TOOLS_ROOT, "RHO_NEXUS_URL" => nexus_url },
          },
        })
      end

      def write_registry_entry(cell)
        FileUtils.mkdir_p(cell.job_dir)
        File.write(cell.entry_path, "#{JSON.pretty_generate(cell.registry_entry)}\n", encoding: Encoding::UTF_8)
        cell.entry_path
      end

      # THE OVERLAY'S DOCKERFILE: FROM the derived tag (the box's prebuild,
      # local); ENTRYPOINT tini ALONE — the derived image's own goes on to
      # `docker-entrypoint`, which execs `rho "$@"` and would swallow
      # harbor's container command (its own, e.g. a `sleep infinity` under
      # compose), so tini stays as PID 1 (the process-group rule) and the
      # command is harbor's; CMD the default should harbor pass none; USER
      # the base's default — root, the plain driver's `--user 0`
      # (`TerminalBench::CONTAINER_USER`: several of the 21 assume it and
      # the verifier apt-installs) — because the recipe's LAST `USER` is
      # the install's 1000, and harbor runs the agent as the image's default
      # user (the launcher's root door counts on that being root here).
      def overlay_dockerfile(tag, user: TerminalBench::CONTAINER_USER)
        "FROM #{tag}\nENTRYPOINT [\"#{TINI}\", \"--\"]\nCMD [\"sleep\", \"infinity\"]\nUSER #{user}\n"
      end

      # THE COPIED task.toml with its `docker_image` line gone and THEIR
      # BYTES otherwise (the comments, the order, the rest of
      # `[environment]`): a line edit, never a re-serialization. Refused by
      # name when the key survives the line rule (an inline table, a
      # spelling the rule misses) — harbor would then take the base image
      # over the Dockerfile.
      def overlay_task_toml(text, name:)
        rewritten = text.lines.reject { |line| line.match?(DOCKER_IMAGE_LINE) }.join
        TerminalBench.refuse(name, "#{TerminalBench::TASK_TOML}'s #{DOCKER_IMAGE_KEY} survived the overlay") unless
          TomlRB.parse(rewritten).dig(ENVIRONMENT_DIR, DOCKER_IMAGE_KEY).nil?
        rewritten
      end

      # ONE OVERLAY TASK, a pure function of (the corpus task dir, the
      # derived tag, the overlay task dir): every entry of the task dir but
      # `environment/` copied with its modes (instruction.md byte-identical,
      # tests/ whole — the verifier's, hidden by harbor as before —
      # solution/ when present), the copied task.toml rewritten, the
      # Dockerfile written. An overlay task already there (a rerun under
      # one label) is replaced whole. Answers the overlay task dir.
      def write_overlay_task(task_dir, tag:, into:)
        FileUtils.rm_rf(into)
        FileUtils.mkdir_p(File.join(into, ENVIRONMENT_DIR))
        Dir.children(task_dir).sort.each do |entry|
          next if entry == ENVIRONMENT_DIR

          FileUtils.cp_r(File.join(task_dir, entry), File.join(into, entry), preserve: true)
        end
        toml = File.join(into, TerminalBench::TASK_TOML)
        rewritten = overlay_task_toml(File.read(toml, encoding: Encoding::UTF_8), name: File.basename(task_dir))
        File.write(toml, rewritten, encoding: Encoding::UTF_8)
        File.write(File.join(into, ENVIRONMENT_DIR, DOCKERFILE), overlay_dockerfile(tag), encoding: Encoding::UTF_8)
        into
      end

      # The cell's overlay: its tasks, each onto its derived tag.
      def write_overlay(cell)
        cell.tasks.each { |task| write_overlay_task(task.dir, tag: cell.tag_for(task), into: cell.overlay_task_dir(task)) }
        cell.overlay_dir
      end

      # `harbor run -a acp:rho -m <ref> -k <n> --agent-kwarg … <jobs> -p <corpus> -i <task>…`
      # (the calibration cell's own spelling on the box).
      # THE HARBOR COMMAND is the host's spelling: `harbor` on PATH by default,
      # `uvx --from harbor harbor` on the box (E2E_EVALS_HARBOR_COMMAND, split on
      # whitespace — the box's calibration cell ran exactly that; the first
      # cell there died Errno::ENOENT on a bare `harbor`).
      ENV_HARBOR_COMMAND = "E2E_EVALS_HARBOR_COMMAND".freeze
      DEFAULT_HARBOR_COMMAND = %w[harbor].freeze

      def harbor_command(env = ENV)
        spelled = env[ENV_HARBOR_COMMAND].to_s.split
        spelled.empty? ? DEFAULT_HARBOR_COMMAND : spelled.freeze
      end

      def run_argv(entry_path:, model:, runs:, corpus_dir:, task_names:, jobs_dir:, job_name:, harbor: harbor_command)
        [*harbor, "run", "-a", AGENT, "-m", model, "-k", runs.to_s,
         "--agent-kwarg", "registry_entry_path=#{entry_path}",
         *KWARGS.flat_map { |key, value| ["--agent-kwarg", "#{key}=#{value}"] },
         JOBS_DIR_FLAG, jobs_dir, JOB_NAME_FLAG, job_name,
         CORPUS_FLAG, corpus_dir,
         *task_names.flat_map { |name| [TASK_FLAG, name] }]
      end

      # THE PAIRING DOCUMENT FOR THE STEWARD'S BROWSER: Nexus builds the two
      # URLs from the Host header the daemon asked with — the containers'
      # address (`cell.nexus_url`: the box's LAN IP, `host.docker.internal`
      # on a Desktop bridge) — while the steward's session cookie lives on
      # the harness's own origin (E2E_BASE_URL, 127.0.0.1:<port>) and the
      # device page is a signed-in member's (`OAuth::BrowserController`), so
      # a URL at the containers' origin is rewritten to the harness's; one
      # already elsewhere rides as it is. A new document, never the answer
      # mutated (the plain driver's `Docker.pairing_from_container` rewrites
      # one NAME; this rewrites the origin the cell chose).
      def pairing_for_steward(document, nexus_url:, base_url:)
        from = URI(nexus_url)
        to = URI(base_url)
        rewritten = Docker::PAIRING_URL_KEYS.filter_map do |key|
          value = document[key]
          next if value.nil?

          uri = URI(value)
          next unless [uri.host, uri.port] == [from.host, from.port]

          [key, URI::HTTP.build(host: to.host, port: to.port, path: uri.path, query: uri.query).to_s]
        end
        document.merge(rewritten.to_h)
      end

      # THE PAIRING SIDECAR. `confirm` is called with the pairing document
      # (the daemon's `/device/start` answer, at the steward's origin:
      # `pairing_for_steward` over `nexus_url`/`base_url` when both are
      # given) once per container; `docker` is the argv spawner
      # (`Docker.run!` by default; a test records). A document with no code
      # — 409 already_connected, a half-written file (unparseable), a file
      # not there yet (the launcher has not written it, or a foreign
      # container that never will) — is not confirmed and the container is
      # asked again at the next poll.
      #
      # DISCOVERY BY THE DOCUMENT, NOT THE IMAGE (the box cell
      # 2026-09-19-harbor-acp-dry, third launch): harbor ran the trial, the
      # task container started from the overlay image — built FROM the
      # derived tag with BuildKit — and the launcher inside wrote the
      # ceremony document and waited its full 300 s ("the workspace was not
      # adopted within 300 s (last: pending); is the pairing sidecar
      # running?") while this sidecar reported "paired 0 container(s)":
      # BuildKit images record no parent chain, so docker's `ancestor=`
      # filter does not see a container of an image built FROM a local tag
      # (and harbor deletes its environment image after the trial — the
      # box's `docker images` shows the base and the derived tag alone). So
      # every poll lists EVERY running container by id — the box runs only
      # our workloads — and probes each unpaired one for the file, which is
      # the launcher's alone.
      class Sidecar
        POLL_SECONDS = 3
        # The log names a code by its TAIL — its last four characters,
        # enough to match against the steward's browser — beside the id.
        CODE_TAIL = 4

        attr_reader :confirmed, :calls

        def initialize(confirm:, docker: Docker.method(:run!), nexus_url: nil, base_url: nil, log: $stdout)
          @confirm = confirm
          @docker = docker
          @nexus_url = nexus_url
          @base_url = base_url
          @log = log
          @confirmed = {}
          @calls = []
        end

        def self.ps_argv = %w[docker ps --format {{.ID}}]

        # One pass: every running container, each unpaired one probed for
        # the document (a non-zero exit is silence: no such file yet, or a
        # foreign container) and, when its document carries a code,
        # confirmed ONCE. Answers the ids seen this pass.
        def poll
          ids = running_ids
          ids.each do |id|
            next if @confirmed.key?(id)

            document = ceremony_of(id)
            next unless pairing?(document)

            started = @nexus_url && @base_url ? HarborAcp.pairing_for_steward(document, nexus_url: @nexus_url, base_url: @base_url) : document
            @confirm.call(started)
            @confirmed[id] = started["user_code"]
            @log.puts "sidecar: paired #{id} (code ending #{tail(started["user_code"])})"
          end
          ids
        end

        # Polls until `done` answers true (harbor's process gone), one last
        # poll after it.
        def run(done:, every: POLL_SECONDS)
          loop do
            poll
            break if done.call

            sleep every
          end
          poll
          @confirmed.keys
        end

        private

          def running_ids
            output, status = call(self.class.ps_argv)
            status.success? ? output.to_s.lines(chomp: true).map(&:strip).reject(&:empty?).uniq : []
          end

          def tail(code) = code[-CODE_TAIL..] || code

          def ceremony_of(id)
            output, status = call(Docker.cat_argv(id, CEREMONY))
            return nil unless status.success?

            Hash.try_convert(JSON.parse(output.to_s))
          rescue JSON::ParserError
            nil
          end

          def pairing?(document) = !document.nil? && PAIRING_KEYS.all? { |key| !String.try_convert(document[key]).to_s.empty? }

          def call(argv)
            @calls << argv
            @docker.call(argv)
          end
      end

      # THE IMPORT: every trial under the job dir (`**/acp-events.jsonl`) as
      # one record in the ledger's shape, the trials of one task numbered in
      # directory order; the reward from `result.json` when harbor wrote
      # one, else `verifier/reward.txt` (the plain driver's read: a Float
      # ≥ 1 passes, absent or unparseable is red BY NAME); no reach
      # dimension (`reached`/`succeeded` nil — the family's rule); the
      # summary's `errors` and a missing prompt response are the record's
      # `error` (a lane bug by the scorecard's rule), everything else the
      # model's conduct. `known` names (the corpus's) resolve a trial dir
      # to its task; without them the dir's name before `__` or a `.<n>`
      # suffix is the task.
      def import(job_dir, model:, bench:, known: [])
        trials = Dir.glob(File.join(job_dir, "**", EVENTS)).sort.map { |events| Trial.read(events, known: known) }
        trials.group_by(&:task).sort.flat_map do |_task, rows|
          rows.sort_by(&:dir).each_with_index.map { |trial, index| record(trial, index: index + 1, model: model, bench: bench) }
        end
      end

      def import!(cell)
        records = import(cell.job_dir, model: cell.model, bench: cell.bench, known: cell.tasks.map(&:name))
        records.each { |record| Records.append(cell.run_dir, record) }
        records
      end

      def record(trial, index:, model:, bench:)
        record = {
          "task" => trial.task, "family" => FAMILY, "capability" => "#{FAMILY}.#{trial.task}", "driver" => DRIVER,
          "model" => model, "style" => STYLE, "run" => index, "bench_digest" => bench.digest,
          "started_at" => trial.started_at, "seconds" => trial.seconds, "loops" => [],
          "verdict" => { "reached" => nil, "succeeded" => nil, "task_pass" => trial.pass?, "class" => nil },
          "reason" => trial.reason, "error" => trial.error,
          "facts" => trial.facts, "efficiency" => {}, "conduct" => {}, "stopped" => trial.stopped, "artifact" => trial.events,
        }.compact
        record["verdict"]["class"] = Scorecard.classify(record, bench: bench)
        record
      end

      # One harbor trial, read off its files.
      Trial = Data.define(:task, :dir, :events, :reward, :reward_line, :summary, :counts, :started_at, :seconds,
        :exception) do
        def self.read(events, known: [])
          agent_dir = File.dirname(events)
          dir = File.basename(agent_dir) == AGENT_DIR ? File.dirname(agent_dir) : agent_dir
          result = read_json(File.join(dir, RESULT))
          reward, line = reward_of(result, dir)
          exception = exception_of(result)
          summary = read_json(File.join(agent_dir, SUMMARY)) || {}
          started, finished = times_of(result, events)
          new(task: task_of(File.basename(dir), result, known), dir: dir, events: events, reward: reward, reward_line: line,
            summary: summary, counts: counts_of(events), started_at: started&.utc&.iso8601,
            seconds: (started && finished ? (finished - started).round : nil), exception: exception)
        end

        def self.read_json(path)
          return nil unless File.file?(path)

          Hash.try_convert(JSON.parse(File.read(path, encoding: Encoding::UTF_8)))
        rescue JSON::ParserError
          nil
        end

        # harbor's result first (`verifier_result.rewards`, a name→float
        # table, or a bare `reward`), else the verifier's own file.
        def self.reward_of(result, dir)
          rewards = Hash.try_convert(result&.dig("verifier_result", "rewards"))
          value = rewards.nil? ? result&.dig("reward") : rewards.values.first
          reward = TerminalBench.number_as_written(value)
          return [Float(reward), "#{RESULT}: #{value}"] unless reward.nil?

          path = File.join(dir, VERIFIER_DIR, Docker::REWARD)
          return [nil, "no #{RESULT} reward and no #{VERIFIER_DIR}/#{Docker::REWARD} was written"] unless File.file?(path)

          text = File.read(path, encoding: Encoding::UTF_8)
          reward = Docker.reward_of(text)
          [reward, reward.nil? ? "#{Docker::REWARD} holds #{text.strip.inspect}, not a number" : "#{Docker::REWARD}: #{reward}"]
        end

        # `exception_info` is harbor's; its spelling of the type key has
        # moved between versions, so both are read and neither is required.
        def self.exception_of(result)
          info = (result && (result["exception_info"] || result["exception"])).to_h
          value = (info["exception_type"] || info["type"]).to_s
          value.empty? ? nil : value
        end

        def self.task_of(name, result, known)
          declared = String.try_convert(result&.dig("task_name") || result&.dig("task_id")).to_s
          return declared.delete_prefix(TerminalBench::NAME_PREFIX) unless declared.empty?

          match = known.select { |task| name == task || name.start_with?("#{task}__", "#{task}.") }.max_by(&:length)
          match || name.split("__").first.sub(/\.\d+(?:-of-\d+)?\z/, "")
        end

        # harbor's own clock when the result carries it, else the events
        # file's birth (its mtime where the filesystem keeps none) and mtime.
        def self.times_of(result, events)
          [time_of(result, "started_at") || HarborAcp.first_seen(events), time_of(result, "finished_at") || File.mtime(events)]
        end

        def self.time_of(result, key)
          Time.iso8601((result && result[key]).to_s)
        rescue ArgumentError
          nil
        end

        # Harbor wraps callbacks as event_type/payload; raw ACP captures
        # carry params/update or method instead. Preserve metadata kinds so
        # a connection alone never counts as model work.
        def self.counts_of(events)
          File.readlines(events, encoding: Encoding::UTF_8, chomp: true).reject(&:empty?).each_with_object(Hash.new(0)) do |line, tally|
            item = Hash.try_convert(JSON.parse(line))
            next if item.nil?

            kind = item.dig("payload", "update", "sessionUpdate") || item.dig("params", "update", "sessionUpdate") ||
              item.dig("update", "sessionUpdate") || item["method"] || item["event_type"] || item["type"] || "other"
            tally[kind.to_s] += 1
          rescue JSON::ParserError
            tally["unparseable"] += 1
          end
        end

        def pass? = !reward.nil? && reward >= 1
        def stop_reason = summary.dig("prompt_response", "stopReason")
        def errors = Array(summary["errors"]).map(&:to_s)

        def error
          return "harbor: #{errors.join("; ")[0, 300]}" unless errors.empty?
          return "harbor: no prompt response in #{SUMMARY}" if summary.key?("prompt_response") && summary["prompt_response"].nil?

          nil
        end

        def reason = pass? ? nil : [exception, reward_line].compact.join(" — ")

        # HARBOR'S OWN WORD FOR HOW THE TRIAL ENDED (`result.json`'s
        # `exception_info`): without it a trial harbor cut at its agent
        # budget reads as a bare failed reward and the scorecard files it
        # under the model's conduct — the 2026-09-18 cells carried sixteen
        # of them (floor 5, glm 6, kimi 5, every one 919–1 024 s against a
        # 900 s budget) with nothing on the record to say so.
        def stopped = TIMEOUT_EXCEPTIONS.include?(exception) ? Scorecard::DEADLINE : nil

        def facts
          { "harbor_trial" => dir, "reward" => reward, "stop_reason" => stop_reason, "events" => counts,
            "harbor_exception" => exception, "verification_output" => reward_line }.compact
        end
      end

      # THE RUN'S OUTCOME: harbor's exit status, the containers the sidecar
      # paired (id → code) and the records imported — the trials that
      # landed are imported whatever the exit; the lane judges the exit.
      Outcome = Data.define(:status, :paired, :records)

      # THE RUN (paid; the box), PURE OF THE WORLD: the entry and the overlay
      # written, harbor spawned from the job dir with its output in
      # `harbor.log`, the sidecar polling beside it with the steward's
      # browser as the confirm, the trials imported once harbor exits.
      # `base_url` is the BOOTED world as the harness reaches it — the
      # lane's (`evals/harbor_acp_lane_test.rb` boots it, prices it, enables
      # the provider and hands its own steward as `confirm`); the cell's
      # `nexus_url` is that world as harbor's containers reach it
      # (`Cell#with_world`) — the plan's placeholder is refused by name.
      def run!(cell, base_url:, docker: Docker.method(:run!), spawn: Process.method(:spawn), confirm: nil, out: $stdout)
        raise ArgumentError, "harbor acp: the cell's nexus url is the plan's placeholder — `Cell#with_world` the booted world first" if
          cell.nexus_url == PLACEHOLDER_URL

        write_registry_entry(cell)
        write_overlay(cell)
        confirm ||= steward_confirm(base_url)
        sidecar = Sidecar.new(confirm: confirm, docker: docker, nexus_url: cell.nexus_url, base_url: base_url, log: out)
        out.puts "harbor acp: overlay corpus → #{cell.overlay_dir} (#{cell.tasks.size} task(s), each FROM its derived tag)"
        out.puts "harbor acp: #{cell.command}"
        out.puts "harbor acp: harbor's output → #{cell.log_path}"
        pid = spawn.call(*cell.argv, chdir: cell.job_dir, in: File::NULL, out: cell.log_path, err: [:child, :out])
        finished = false
        watcher = Thread.new { sidecar.run(done: -> { finished }) }
        _, status = Process.wait2(pid)
        finished = true
        watcher.join
        out.puts "harbor acp: harbor exited #{status.exitstatus.inspect}; paired #{sidecar.confirmed.size} container(s)"
        Outcome.new(status: status, paired: sidecar.confirmed, records: import!(cell))
      end

      # A file's birth where the filesystem keeps one, its mtime elsewhere.
      def first_seen(path)
        File.birthtime(path)
      rescue NotImplementedError, SystemCallError
        File.mtime(path)
      end

      # The steward's browser as the confirm (the plain driver's pairing,
      # `E2E::Ceremony.confirm`), loaded only here: capybara and selenium
      # never ride the dry run.
      def steward_confirm(base_url)
        require "minitest"
        require_relative "../actor_provisioning"
        require_relative "../ceremony"
        require_relative "../steward_session"
        actor = E2E::StewardSession.actor(base_url: base_url, human: E2E::ActorProvisioning.world(base_url).rho_steward)
        ->(started) { E2E::Ceremony.confirm(actor: actor, started: started, status: nil) }
      end
    end
  end
end
