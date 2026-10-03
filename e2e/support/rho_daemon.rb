require "fileutils"
require "json"
require "net/http"
require "rho/home"
require "uri"
require_relative "device_authorization_budget"
require_relative "process_registry"

module E2E
  # The rho daemon as a spawned product subprocess: its own bundle, its own RHO_HOME, found through
  # the same announcement file every local client reads. Lifecycle plumbing only — scenario
  # assertions stay in the lanes.
  class RhoDaemon
    RHO_ROOT = File.expand_path("../../agents/rho/rho", __dir__)
    # THE DEVELOPMENT GEM: the conversation verbs the mock journeys type — `do`, `say`, `watch`,
    # `retry`, … — are `rho-dev`'s, a gem the distribution never carries. The harness hands its
    # `lib` to every rho child through `RUBYLIB` (Bundler keeps a raw RUBYLIB directory on the load
    # path under the frozen bundle), and a home that wrote no settings names it
    # (`write_settings_if_absent!`); the product-shaped lanes write `[]` and drive `run`. A
    # developer's shell exports the same directory.
    RHO_DEV_LIB = File.expand_path("../../agents/rho/rho-dev/lib", __dir__)
    DEV_SETTINGS = { "extensions" => ["rho/dev"] }.freeze
    READY_TIMEOUT = 60
    POLL = 0.2
    # THE KERNEL'S RECOVERY FLOOR: a wake the kernel loses is recovered by
    # its recurring sweeps, scheduled `every minute`
    # (`nexus/config/recurring.yml`, `sweep_agent_loop_schedules`).
    KERNEL_FLOOR_SECONDS = 60
    # Every mock journey's `rho watch --timeout`: twice the floor, so a watcher never gives up under
    # a recovery the kernel is still owed — a watch bound BELOW the floor pins the kernel's latency,
    # never the verb's output. A lane that waits on a wake it expects to be lost keeps its own
    # explicit pin.
    WATCH_TIMEOUT = 2 * KERNEL_FLOOR_SECONDS
    # THE MAIL-WINDOW HOLD: the smallest hold a mock turn keeps so one pair of CLI verbs — each
    # `bundle exec ruby exe/rho`, a second or two warm, whole seconds under two worlds — lands
    # INSIDE it. The journeys derive every longer hold from this one number.
    HOLD_SECONDS = 10

    # Both halves of rho's bundle are pinned and frozen so the child can
    # never resolve against — or rewrite — the harness's own lockfile.
    CHILD_BUNDLE_ENV = {
      "BUNDLE_GEMFILE" => File.join(RHO_ROOT, "Gemfile"),
      "BUNDLE_LOCKFILE" => File.join(RHO_ROOT, "Gemfile.lock"),
      "BUNDLE_FROZEN" => "true",
    }.freeze
    # rho-dev's `lib` first on the child's RUBYLIB, the process's own
    # (if any) behind it — for every child that runs `exe/rho`, this
    # class's and the few a lane spawns by hand.
    CHILD_DEV_ENV = {
      "RUBYLIB" => [RHO_DEV_LIB, ENV["RUBYLIB"]].compact.reject(&:empty?).join(File::PATH_SEPARATOR),
    }.freeze

    # THE DEFINITIONS' DIRECTORY: the first of the two the daemon scans at its environment root.
    DEFINITIONS_DIRECTORY = ".agents/agents".freeze

    attr_reader :home, :log_path, :pid, :tools_root

    # `env` is what a journey adds to the child's environment beyond the
    # bundle and RHO_HOME — an extension's own knob, say, that the daemon
    # reads and the journey must pin so the machine's globals cannot
    # decide the outcome. It is merged UNDER the bundle pins: a frozen
    # lockfile is the harness's correctness, not a journey's to relax.
    #
    # `tools_root` points the daemon's ENVIRONMENT ROOT (the settings' `tools_root`, here as
    # `RHO_TOOLS_ROOT`) at a directory the journey owns — outside the home, so the floor and the
    # incubation denies (which protect `$RHO_HOME` whole) have no opinion on the project the model
    # works in. `definitions` (name → file text) are written under it as `.agents/agents/<name>.md`
    # BEFORE the boot, so the boot's own declare edge reads them.
    def initialize(base_url:, home:, env: {}, tools_root: nil, definitions: {})
      @base_url = base_url
      @home = home
      @env = env
      @tools_root = tools_root
      @definitions = definitions
      @log_path = File.join(home, "daemon.log")
      @pid = nil
      raise ArgumentError, "definitions need a tools_root to live under" if !definitions.empty? && tools_root.nil?
    end

    def start
      write_settings_if_absent!
      @definitions.each { |name, text| write_definition(name, text) }
      @pid = ProcessRegistry.spawn(
        child_env,
        Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho",
        "server", "--nexus-url", @base_url,
        chdir: RHO_ROOT, in: File::NULL, out: [@log_path, "a"], err: [@log_path, "a"], pgroup: true
      )
      await("the daemon never announced itself") do
        document = announcement
        document && document["endpoint"] ? document : nil
      end
    end

    def stop
      return if @pid.nil?

      ProcessRegistry.terminate(@pid)
      @pid = nil
    end

    # ---- the definition files under the environment root ----

    # The file a definition NAME lives in; the journey edits the files
    # between edges (`rho agents sync` reads them again) and pins the
    # paths the verbs print.
    def definition_path(name)
      raise "no tools_root: definitions have nowhere to live" if @tools_root.nil?

      File.join(@tools_root, DEFINITIONS_DIRECTORY, "#{name}.md")
    end

    def write_definition(name, text)
      path = definition_path(name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text, encoding: Encoding::UTF_8)
      path
    end

    def delete_definition(name)
      FileUtils.rm_f(definition_path(name))
    end

    # A RHO THAT DIES HOLDING A CLAIM: KILL to the whole group — the daemon and whatever it spawned
    # — so a row it claimed is answered by NOBODY and only the kernel's clock can settle it. `stop`
    # is the other thing: a stop cancels the handler and answers the claim. The
    # `ExecutorProcess#kill!` shape verbatim: KILL cannot be ignored, the wait is on our direct
    # child, and `stop` afterwards is a no-op.
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

    # ---- rho's structured log (`RHO_HOME/log/rho.log`), one fact a line ----

    def rho_log_path = File.join(@home, "log", "rho.log")

    # UTF-8 by name: the test process inherits the machine's empty locale.
    def log_text
      File.file?(rho_log_path) ? File.read(rho_log_path, encoding: Encoding::UTF_8) : ""
    end

    # Every line as `{event, field, …}` — the log's own `key=value` grammar,
    # a quoted value being Ruby's `String#dump` of the text.
    def log_lines
      log_text.each_line.filter_map do |line|
        fields = line.scan(LOG_FIELD).to_h { |key, value| [key, value.start_with?('"') ? value.undump : value] }
        fields if fields.key?("event")
      end
    end

    # The claims this daemon's runner was granted, oldest first — the
    # runner's `runner_task_claimed` line with the task key, the tool and
    # the park's `deadline_at`: the mark a journey waits on before it kills
    # the daemon mid-work.
    def claims = log_lines.select { |line| line["event"] == "runner_task_claimed" }

    def claimed_keys = claims.map { |line| line.fetch("task") }

    # READINESS BY ANNOUNCEMENT (r-modes M1; X4′): an address is ready to
    # be addressed once its `executor.announced` line is in the log — a
    # runner-mode rho adopts no workspace, so nothing else says so.
    ANNOUNCED_RUNNER = /event=executor\.announced tools=\d+ address=runner\b/

    def await_announced(address:)
      pattern = /event=executor\.announced tools=\d+ address=#{Regexp.escape(address)}\b/
      await("the #{address} address never announced its tools") { log_text.match?(pattern) ? true : nil }
    end

    LOG_FIELD = /(\w+)=("(?:[^"\\]|\\.)*"|\S+)/

    def status
      control(:get, "/status")
    end

    def host_cache_path
      profile = status.fetch("identity").fetch("user_public_id")
      Rho::Home.new(base_url: @base_url, root: @home, work_root: Rho::Home.default_work_root(@home))
        .host_cache_path(profile)
    end

    # The first `/device/start` on a disconnected daemon reaches Nexus's
    # rate-limited device-authorization endpoint, so the shared budget is
    # consumed here — a later click on a pending ceremony costs nothing.
    # The announcement can precede connection bootstrap. Only that explicit
    # refusal is safe to retry: the daemon has not begun a ceremony yet.
    def start_ceremony
      DeviceAuthorizationBudget.consume
      await("the daemon never finished bootstrapping its connection") do
        document = control(:post, "/device/start")
        document unless document.dig("error", "code") == "connection_bootstrapping"
      end
    end

    # Bounded readiness polling over a real signal; raises on the deadline so a stuck daemon is a
    # named harness failure, not a hang.
    def await(message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT
      loop do
        result = yield
        return result if result
        raise message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL
      end
    end

    private

    # The child's environment, the same for the daemon and every verb: the
    # journey's knobs, the tools root when one is set, then the bundle pins,
    # the development gem's lib and the home on top.
    def child_env
      tools = @tools_root ? { "RHO_TOOLS_ROOT" => @tools_root } : {}
      @env.merge(tools).merge(CHILD_BUNDLE_ENV).merge(CHILD_DEV_ENV).merge("RHO_HOME" => @home)
    end

    # THE THREE KINDS OF HOME: a BARE home — no settings written — gets rho-dev by this write, so
    # the lanes that type `do` and `watch` need no line each; a SELF-WRITING home (an extension lane
    # naming `rho/browser`, `rho/mcp`, …, or a lane pinning `adaptations`/`compaction` before the
    # boot) wrote its own set and adds `rho/dev` itself where it drives a dev verb —
    # `DEV_SETTINGS.merge(...)` is the spelling, and `rho_daemon_harness_test` reads every lane for
    # it; a PRODUCT-SHAPED home wrote `[]` and drives `run` alone. Never a merge, never an option: a
    # file that exists is the lane's own word.
    def write_settings_if_absent!
      path = File.join(@home, "settings.json")
      return if File.exist?(path)

      FileUtils.mkdir_p(@home)
      File.write(path, JSON.generate(DEV_SETTINGS), encoding: Encoding::UTF_8)
    end

    # One RHO_HOME is one Nexus, so the announcement has one fixed path.
    def announcement
      JSON.parse(File.read(File.join(@home, "tmp", "announcement.json")))
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    # PUBLIC: a journey reads the daemon's own report of itself — "is this
    # machine taking work?" is a question about the product, not an internal.
    # THE SHIPPED BINARY, against this daemon. A journey that only drives
    # the HTTP surface proves the routes and not the thing an operator
    # actually types — and the CLI is the entry point that makes a
    # capability debuggable before its UI exists.
    #
    # STDIN IS /dev/null FOR EVERY CLI CHILD: the child runs in its own
    # process group, so under a terminal (a tmux'd run on the box) it is a
    # BACKGROUND job of that terminal, and the first thing that touches the
    # terminal — Thor's `stty size` for help's width — stops the whole
    # group with SIGTTOU/SIGTTIN (state T, `do_signal_stop`) and the read
    # here never returns (the box's group 3, 22 minutes at zero CPU). A verb
    # under test never reads the runner's terminal; nohup on the Mac hid it.
    public def cli(*arguments)
      output = nil
      status = nil
      IO.popen(
        child_env,
        [Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho",
         *arguments, "--nexus-url", @base_url],
        chdir: RHO_ROOT, in: File::NULL, err: [:child, :out]
      ) do |io|
        # UTF-8 BY NAME: the test process inherits the machine's empty
        # locale, and rho prints an em-dash in its failure lines — the
        # diagnosis path must not be the one thing that cannot be read.
        output = io.read.force_encoding(Encoding::UTF_8).scrub
        io.close
        status = $?
      end
      [output.to_s, status]
    end

    # THE SHIPPED BINARY, BYTES OUT: `rho fetch` writes an upload's bytes to stdout whole, and a PNG
    # is not UTF-8 — the scrub above would rewrite what the pin compares. Binary, unscrubbed; stderr
    # is NOT merged into it (a warning line would corrupt the bytes) — it inherits the test
    # process's own, where the run log shows a refusal's words.
    public def cli_bytes(*arguments)
      output = nil
      status = nil
      IO.popen(
        child_env,
        [Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho",
         *arguments, "--nexus-url", @base_url],
        chdir: RHO_ROOT, in: File::NULL
      ) do |io|
        io.binmode
        output = io.read.b
        io.close
        status = $?
      end
      [output.to_s.b, status]
    end

    # A VERB THAT DOES NOT RETURN. `follow` streams until the loop settles,
    # so its output has to be read WHILE the work is still happening — the
    # blocking helper above would sit on it until the loop was over and
    # prove nothing about a stream.
    public def cli_background(*arguments)
      IO.popen(
        child_env,
        [Gem.ruby, Gem.bin_path("bundler", "bundle"), "exec", "ruby", "exe/rho",
         *arguments, "--nexus-url", @base_url],
        chdir: RHO_ROOT, in: File::NULL, err: [:child, :out]
      )
    end

    public def control(verb, path, body: nil)
      document = announcement
      raise "the rho daemon has no announcement to address" unless document

      uri = URI.join(document.fetch("endpoint"), path)
      request = (verb == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      request["Authorization"] = "Bearer #{document.fetch("bearer")}"
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
      JSON.parse(response.body)
    end
  end
end
