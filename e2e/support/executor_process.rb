require "json"
require_relative "executor_process/echo_tools"
require_relative "executor_process/memory_tools"
require_relative "process_registry"
require_relative "secret_hygiene"

module E2E
  # A SECOND EXECUTOR BESIDE RHO: the harness's own runner process, spawned under rho-runner's
  # bundle pins the way `RhoDaemon` spawns rho, in its own process group under `ProcessRegistry`. It
  # holds only the transport credential a person granted in the browser (`RunnerGrant`), handed to
  # the child on stdin — never argv, never the environment — and registered for redaction so a
  # dumped log stays readable. Lifecycle plumbing only; the script under `executor_process/` is the
  # product-shaped part, and the journeys hold the assertions.
  class ExecutorProcess
    RUNNER_ROOT = File.expand_path("../../agents/rho/rho-runner", __dir__)
    SCRIPT = File.expand_path("executor_process/main.rb", __dir__)
    READY_TIMEOUT = 60
    POLL = 0.2
    # The two machine kinds the ceremony mints: a `runner` is the host's binding for a loop; a
    # `tool_provider` serves its announced names from a POOL — a row addressed to the role, taken
    # by whichever eligible provider claims first. The kind lives in the credential's registration;
    # the process is the same loop on either.
    KINDS = %i[runner tool_provider].freeze

    # The child resolves against rho-runner's frozen lockfile, never the
    # harness's own.
    CHILD_BUNDLE_ENV = {
      "BUNDLE_GEMFILE" => File.join(RUNNER_ROOT, "Gemfile"),
      "BUNDLE_LOCKFILE" => File.join(RUNNER_ROOT, "Gemfile.lock"),
      "BUNDLE_FROZEN" => "true",
    }.freeze

    attr_reader :home, :log_path, :pid, :kind, :tools, :environment, :world, :checkpoints

    # `environment` is the ROOT this process announces its relative paths resolve against — a
    # string, or nil for a process that announces no environment (the provider journeys). It is the
    # one environment fact the script carries; the sentence shape is the echo tools'
    # (`EchoTools.environment`). `world` is a ROOT the process serves the REAL coding set on —
    # `--tools` does not apply then, the set is whole — and `checkpoints` a directory for its shadow
    # store beside it (a world without one serves the set with no store: the negative half's
    # restart). The tools spill under this home, never inside the world.
    def initialize(base_url:, home:, credential:, kind: :runner, tools: EchoTools.names, environment: nil,
                   world: nil, checkpoints: nil)
      raise ArgumentError, "unknown executor kind #{kind.inspect}" unless KINDS.include?(kind)
      raise ArgumentError, "checkpoints: needs world:" if checkpoints && world.nil?

      @base_url = base_url
      @home = home
      @credential = SecretHygiene.register(credential.to_s)
      @kind = kind
      @tools = Array(tools).map(&:to_s)
      @environment = environment&.to_s
      @world = world&.to_s
      @checkpoints = checkpoints&.to_s
      @log_path = File.join(home, "executor.log")
      @pid = nil
      @lines_before_start = 0
    end

    # Spawns the script and waits for its announcement line: the process is
    # usable only once its address has announced what it serves. CALLABLE
    # AGAIN after `kill!` or `stop`, on the SAME credential — a dead
    # process's transport credential is valid until somebody re-pairs, so a
    # restart costs no grant: it re-announces the same list and its inbox
    # lists any row the dead process held as `claimed: true`, which the
    # runner leaves to the clock. The log is appended; the readers below
    # speak for THIS process, from its own spawn on.
    def start
      raise "the executor process is already running (pid #{@pid})" unless @pid.nil?

      @lines_before_start = events.length
      reader, writer = IO.pipe
      @pid = ProcessRegistry.spawn(
        CHILD_BUNDLE_ENV,
        Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", SCRIPT,
        "--nexus-url", @base_url, "--kind", @kind.to_s, *argv_tail,
        chdir: RUNNER_ROOT, in: reader, out: [@log_path, "a"], err: [@log_path, "a"], pgroup: true
      )
      reader.close
      writer.puts(@credential)
      writer.close
      await("the executor process never announced its tools") { event("announced") }
      self
    end

    # A GRACEFUL END: TERM, which the script traps into `runner.stop` — a
    # handler mid-flight is cancelled and its claim ANSWERED `failed`
    # interrupted before the process exits.
    def stop
      return if @pid.nil?

      ProcessRegistry.terminate(@pid)
      @pid = nil
    end

    # A RUNNER THAT DIES: KILL to the whole group — the script and whatever it spawned — so a claim
    # it holds is answered by NOBODY and only the kernel's clock can settle it. `stop` is the other
    # thing; a death is the one shape that reaches the sweep's expiry rule. Bounded: KILL cannot be
    # ignored, and the wait is on our direct child.
    def kill!
      return if @pid.nil?

      pid = @pid
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
      ProcessRegistry.unregister(pid)
      @pid = nil
    end

    # The rest of the script's argv: the harness set by name, or the world
    # and its store (the coding set is whole there, so no `--tools`).
    def argv_tail
      return ["--tools", @tools.join(","), *(["--environment-root", @environment] if @environment)] if @world.nil?

      ["--world", @world, *(["--checkpoints", @checkpoints] if @checkpoints),
       "--artifacts", File.join(@home, "artifacts"), *(["--environment-root", @environment] if @environment)]
    end

    # ---- what THIS process said about itself (its own spawn on) ----

    def announced = event("announced")&.fetch("tools")

    # The world root and the store path THIS process announced, nil for a harness-set process.
    def announced_world = event("announced")&.fetch("world", nil)
    def announced_checkpoints = event("announced")&.fetch("checkpoints", nil)

    # THE STORE'S OWN LOG LINES: every capture — `{loop, hash, store, files, skipped, nested}` —
    # every skip, and every restore — `{loop, store, from, to, files, removed}` — as the store wrote
    # them.
    def captures = since_start.select { |line| line["event"] == "checkpoint_captured" }
    def skips = since_start.select { |line| line["event"] == "checkpoint_skipped" }
    def restores = since_start.select { |line| line["event"] == "checkpoint_restored" }

    def executor_public_id = event("announced")&.fetch("executor_public_id")

    # The root THIS process announced, as its own log says — nil when it
    # announced no environment.
    def announced_environment_root = event("announced")&.fetch("environment_root", nil)

    # The kind the ADDRESS carries, as nexus described it at announcement —
    # the registration's fact, which the script checked against the kind
    # it was asked to be.
    def announced_kind = event("announced")&.fetch("kind")

    # The document names THIS process announced under `documents` — `[]` for a process that names no
    # `skill`.
    def announced_documents = event("announced")&.fetch("documents", [])

    # The inbox rows this process claimed, as the claims answered them:
    # `tool_name`, `tool_alias` and whether a `scope` stamp rode the row.
    def inbox_claims = since_start.select { |line| line["event"] == "inbox_claimed" }

    # Every per-sweep status line, oldest first; `claimed` reads the latest.
    def statuses = since_start.select { |line| line["event"] == "status" }

    def claimed = statuses.last&.fetch("claimed") || 0

    # The claims this process was granted, oldest first — the runner's
    # `runner_task_claimed` line, with the task key and the park's
    # `deadline_at` as the kernel answered them. The mark a journey waits
    # on before it kills the process mid-work.
    def claims = since_start.select { |line| line["event"] == "runner_task_claimed" }

    def claimed_keys = claims.map { |line| line.fetch("task") }

    # The lines written since this process's own spawn: a restart appends
    # to one log, and what the dead process said is not this one's.
    def since_start = events.drop(@lines_before_start)

    # The WHOLE log, every process that wrote to it.
    def events
      return [] unless File.file?(@log_path)

      File.foreach(@log_path, encoding: Encoding::UTF_8).filter_map do |line|
        parsed = JSON.parse(line)
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end

    def log_text
      File.file?(@log_path) ? File.read(@log_path, encoding: Encoding::UTF_8) : ""
    end

    private

      def event(name) = since_start.find { |line| line["event"] == name }

      def await(message)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT
        loop do
          result = yield
          return result if result
          raise "#{message}:\n#{SecretHygiene.redact(log_text)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep POLL
        end
      end
  end
end
