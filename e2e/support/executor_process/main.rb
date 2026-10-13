# THE HARNESS EXECUTOR: a runner process that is not rho. It holds ONE credential — the
# executor-transport credential a person granted in the browser — and nothing else: no member token,
# no workspace, no daemon. It announces echo handlers, then follows its own inbox on the executor
# plane by POLLING alone (the sweep is the truth; the cable is proven by rho's journeys), and writes
# one JSON line per event to stdout so a journey can read what it did.
#
# Spawned under rho-runner's own bundle by `E2E::ExecutorProcess`; the
# credential arrives on stdin (one line), never on argv or in the
# environment.
require "bundler/setup"
require "json"
require "optparse"
require "rho/runner"
require "delegate"
require "stringio"
require_relative "echo_tools"
require_relative "memory_tools"
require_relative "../red_square_png"

module E2E
  module ExecutorMain
    # The runner's `log` duck (`info`/`warn`/… with an event and fields),
    # as JSON lines: the journey greps events by name and reads the
    # per-sweep status line's meters.
    class JsonLog
      def initialize(io)
        @io = io
        @mutex = Mutex.new
      end

      %i[debug info warn error].each do |level|
        define_method(level) do |event, **fields|
          line = JSON.generate({ "level" => level.to_s, "event" => event.to_s }.merge(fields.transform_keys(&:to_s)))
          @mutex.synchronize { @io.puts(line) }
          nil
        end
      end
    end

    # The machine kinds a transport credential can name: the loop below is the same on either — a
    # provider is a runner process whose rows come from a pool.
    KINDS = %w[runner tool_provider].freeze

    # THE CAPTURE DOOR: the SDK's executor client with ONE difference — a commit on a `capture` row
    # stages the red-square PNG on the executor plane (`uploads.create_io`) and names it with a
    # `resource_link` block beside the handler's text, plus `title` and `metadata`; the block is
    # this script's own hash (the runner gem has its own upload site). A foreign `link_to` meets the
    # kernel's `422 unknown_result_upload` — logged, then the SAME token commits the text alone,
    # which is the park-standing property the journey pins. Every other row commits untouched: the
    # runner gem's claim, extension and commit path is what runs.
    class CaptureExecutor < SimpleDelegator
      def initialize(executor, log)
        super(executor)
        @log = log
        @claims = {}
        @claims_lock = Mutex.new
      end

      def inbox_task(run_public_id:, task_key:)
        CaptureDoor.new(__getobj__.inbox_task(run_public_id: run_public_id, task_key: task_key),
          self, @log, [run_public_id, task_key])
      end

      # The runner gem opens a NEW door for each verb (claim, extend, commit),
      # so the claim's row — its tool name and input — is remembered HERE,
      # keyed by the task, for the door that later commits it.
      def remember_claim(key, claimed) = @claims_lock.synchronize { @claims[key] = claimed }
      def claim_for(key) = @claims_lock.synchronize { @claims[key] }
    end

    class CaptureDoor < SimpleDelegator
      TOOL = "capture".freeze
      FILENAME = "square.png".freeze
      # A NON-MEDIA capture: the bytes staged under a `filename` that is not a picture — a log — so
      # the link's type is text and no picture rides the next request.
      TEXT_BYTES = "line one\nline two\n".freeze
      REFUSAL = "unknown_result_upload".freeze

      def initialize(door, executor, log, key)
        super(door)
        @executor = executor
        @log = log
        @key = key
      end

      # THE INBOX ROW'S FACTS, as the claim answered them (the `skills` journey): a `skill` row
      # addressed to this announcer lists with `tool_name: "skill"`, the model's `tool_alias` and a
      # `scope` stamp — read here off the granted claim, the one place a journey can see an
      # executor-plane row.
      def claim
        __getobj__.claim.tap do |claimed|
          @executor.remember_claim(@key, claimed)
          @log.info("inbox_claimed", loop: @key.first, task: @key.last, tool_name: claimed.task.tool_name,
            tool_alias: claimed.task.tool_alias, scope_present: !claimed.task.scope.nil?)
        end
      end

      # `Kernel#extend` survives on a delegator and would shadow the
      # claimant's extension verb (a Hash where a Module was expected):
      # forwarded by name so a long tool's `extend` reaches the kernel.
      def extend(**fields) = __getobj__.extend(**fields)

      def commit(**fields)
        claimed = @executor.claim_for(@key)
        return __getobj__.commit(**fields) unless capture_commit?(claimed, fields)

        input = claimed.task.tool_input.is_a?(Hash) ? claimed.task.tool_input : {}
        filename = input["filename"].to_s.empty? ? FILENAME : input["filename"].to_s
        bytes = filename == FILENAME ? E2E::RedSquarePng.bytes : TEXT_BYTES
        upload = @executor.uploads.create_io(StringIO.new(bytes), filename: filename)
        linked = input["orphan"] ? nil : (input["link_to"] || upload.public_id)
        @log.info("captured", loop: @key.first, task: @key.last, upload_public_id: upload.public_id, linked: linked)
        return __getobj__.commit(**fields) if linked.nil?

        text = { "type" => "text", "text" => fields.fetch(:content).to_s }
        link = { "type" => "resource_link", "uri" => "nexus://uploads/#{linked}", "name" => filename,
                 "mimeType" => upload.content_type, "size" => upload.byte_size, "title" => "a red square" }
        begin
          __getobj__.commit(**fields, content: [text, link], title: "capture",
            metadata: { "checkpoint" => { "step" => 1 }, "upload_public_id" => upload.public_id })
        rescue CybrosAgent::Api::InvalidRequest => error
          raise unless error.code == REFUSAL

          @log.warn("capture_link_refused", loop: @key.first, task: @key.last, code: error.code, linked: linked)
          __getobj__.commit(**fields)
        end
      end

      private

        def capture_commit?(claimed, fields)
          claimed&.task&.tool_name == TOOL && fields[:outcome] == "completed" && !fields[:is_error]
        end
    end

    # THE WORLD HOST: under `--world ROOT` the process serves the REAL coding set — rho-runner's
    # `Extensions::Coding`, whole, no narrowing list to drift (M-simp4) — bound to ROOT, and under
    # `--checkpoints DIR` beside it opens a `Checkpoints::Store` for that root under DIR, hands it
    # to the tools through the env and to the checkpoints extension through this host duck
    # (`Processes`' shape: the extension reads `api.host.checkpoints`), so `checkpoint_restore` and
    # `checkpoints` are announced beside the eight. A `--world` alone — the negative half's restart
    # — serves the coding set with NO store: nothing registers, nothing is announced, no capture
    # happens.
    Host = Data.define(:checkpoints, :processes)

    # What a run announces and serves, assembled once from the options. `hooks` is the registry's
    # tool-call chain: under a world with a store it carries the checkpoints extension's capture, so
    # the runner is built with it; the harness set has none (an empty host). `env` is the world's
    # `ToolEnv` — the ONE placement this process serves (a runner without the rho gem binds no
    # per-conversation root) — nil for the harness set, whose tools take none.
    Assembly = Data.define(:env, :toolset, :announcement, :environment, :documents, :store, :world, :hooks)

    module_function

    def parse(argv)
      options = { kind: "runner", tools: nil, environment_root: nil, world: nil, checkpoints: nil, artifacts: nil }
      OptionParser.new do |parser|
        parser.on("--nexus-url URL") { |url| options[:base_url] = url }
        parser.on("--kind KIND") { |kind| options[:kind] = kind }
        parser.on("--tools NAMES") { |names| options[:tools] = names.split(",").map(&:strip).reject(&:empty?) }
        # The root this process's relative paths resolve against: announced beside the tools, read
        # back by discovery, and rendered as the lead of a turn a rho elsewhere opens on it.
        parser.on("--environment-root ROOT") { |root| options[:environment_root] = root }
        # The real coding set on a real root, the shadow store beside it, and where the tools spill
        # (never inside the world).
        parser.on("--world ROOT") { |root| options[:world] = root }
        parser.on("--checkpoints DIR") { |dir| options[:checkpoints] = dir }
        parser.on("--artifacts DIR") { |dir| options[:artifacts] = dir }
      end.parse!(argv)
      raise ArgumentError, "--nexus-url is required" if options[:base_url].to_s.empty?
      raise ArgumentError, "kind #{options[:kind].inspect} is not one of #{KINDS.join(", ")}" unless KINDS.include?(options[:kind])
      raise ArgumentError, "--checkpoints needs --world" if options[:checkpoints] && options[:world].nil?
      raise ArgumentError, "--tools does not apply under --world: the coding set is served whole" if options[:world] && options[:tools]

      options[:tools] ||= EchoTools.names unless options[:world]
      options
    end

    # The environment the announcement carries: the root's document, or
    # nothing at all when no root was given (the kernel then stores `{}`).
    def environment_for(root)
      return nil if root.to_s.empty?

      EchoTools.environment(root)
    end

    def credential_from_stdin
      credential = $stdin.gets.to_s.strip
      raise ArgumentError, "no credential arrived on stdin" if credential.empty?

      credential
    end

    # THE HARNESS REGISTRY, holding every module's tools through the loader so the tool contract is
    # checked at load (all four load — the echo set, the memory set, the guarded and the skill echo
    # — and the names asked for pick from any); a name none of them serves refuses here, where
    # somebody can still read it.
    def harness_registry(names, log)
      loaded = Rho::Runner::Extensions::Loader.call(builtin: HarnessTools::MODULES, log: log)
      raise "harness tools failed to load: #{loaded.failures.inspect}" unless loaded.ok?

      unknown = names - loaded.registry.names
      raise ArgumentError, "unknown harness tools: #{unknown.join(", ")}" unless unknown.empty?

      loaded.registry
    end

    # The toolset narrowed to the announced names; the default is still the
    # echo set.
    def toolset_for(names, log) = narrow_toolset(harness_registry(names, log), names)

    def narrow_toolset(registry, names)
      full = registry.toolset(env: nil)
      Rho::Runner::Toolset.new(names.to_h { |name| [name, full.fetch(name)] })
    end

    # THE WORLD'S ASSEMBLY: the store (when asked), the env bound to the
    # root, the coding set and the checkpoints extension through the
    # loader, and the announcement rendered by the registry's own renderer
    # (`Registry#announcement`, the one rho's daemon uses) — the
    # environment the real `Coding::Report` fragment, the documents the
    # root's skills.
    def world_assembly(options, log)
      root = File.realpath(options.fetch(:world))
      artifacts = options[:artifacts] || File.join(options[:checkpoints] || Dir.tmpdir, "artifacts")
      store = options[:checkpoints] && Rho::Runner::Checkpoints::Store.open(
        dir: options.fetch(:checkpoints), root: root, log: log, excluded: [File.expand_path(artifacts)]
      )
      env = Rho::Runner::ToolEnv.new(root: root, artifacts_dir: artifacts, checkpoints: store)
      loaded = Rho::Runner::Extensions::Loader.call(
        builtin: [Rho::Runner::Extensions::Coding, Rho::Runner::Extensions::Checkpoints],
        api_options: { host: Host.new(checkpoints: store, processes: nil) }, log: log
      )
      raise "the coding set failed to load: #{loaded.failures.inspect}" unless loaded.ok?

      registry = loaded.registry
      local = Rho::Runner::Environment.local(root: root)
      environment = { "root" => root, "fragments" => registry.environment_fragments(local) }
      Assembly.new(env: env, toolset: registry.toolset(env: env), announcement: registry.announcement,
        environment: environment, documents: registry.documents(local), store: store, world: root,
        hooks: registry.hooks)
    end

    # THE HARNESS SET'S ASSEMBLY: the toolset narrowed to the names asked for, and the announcement
    # rendered by the registry's own renderer (`Registry#announcement`, as `world_assembly` renders
    # and rho's daemon does) narrowed to the same names — so every entry's `timeout_ms` is the
    # class's own `TIMEOUT_MS`, the park the served `Tool` carries and the runner asks to extend.
    def harness_assembly(options, log)
      names = options.fetch(:tools)
      registry = harness_registry(names, log)
      announcement = registry.announcement.select { |entry| names.include?(entry.fetch("name")) }
      Assembly.new(env: nil, toolset: narrow_toolset(registry, names), announcement: announcement,
        environment: environment_for(options[:environment_root]), documents: HarnessTools.documents(names),
        store: nil, world: nil, hooks: nil)
    end

    def assemble(options, log)
      options[:world] ? world_assembly(options, log) : harness_assembly(options, log)
    end

    # THE ONE PLACEMENT: every claimed row lands on the assembly's env and toolset —
    # `Toolsets.fixed`, the constant resolver a runner without the rho gem is — so the world's
    # relative paths resolve against its root and the capture hook reads the world's store off the
    # context's placement.
    def toolsets(assembly) = Rho::Runner::Toolsets.fixed(env: assembly.env, toolset: assembly.toolset)

    def run(argv)
      $stdout.sync = true
      options = parse(argv)
      credential = credential_from_stdin
      log = JsonLog.new($stdout)

      executor = CybrosAgent::ExecutorClient.new(base_url: options.fetch(:base_url), credential: credential)
      address = executor.executor.executor
      # The kind is the registration's, minted at the grant: a script asked
      # to be a provider and handed a runner's credential would serve from
      # the binding, not a pool, and say nothing — so it refuses instead.
      unless address.kind == options.fetch(:kind)
        raise ArgumentError, "the credential names a #{address.kind}, not the #{options.fetch(:kind)} asked for"
      end
      assembly = assemble(options, log)
      toolset = assembly.toolset
      environment = assembly.environment
      documents = assembly.documents
      executor.announce(tools: assembly.announcement, environment: environment, documents: documents)
      log.info("announced", tools: toolset.names.sort, executor_public_id: address.public_id,
        kind: address.kind, credential_epoch: address.credential_epoch, environment_root: environment&.fetch("root"),
        documents: Array(documents).map { |document| document.fetch("name") },
        world: assembly.world, checkpoints: assembly.store&.path)

      runner = nil
      # The runner's own sleeper seam: a status line before every wait, so
      # the journey reads the meters as they move.
      sleeper = lambda do |seconds|
        log.info("status", **runner.snapshot.to_h)
        sleep(seconds)
      end
      runner = Rho::Runner.new(executor: CaptureExecutor.new(executor, log), toolsets: toolsets(assembly), log: log,
        sleeper: sleeper, hooks: assembly.hooks)

      signals = Thread::Queue.new
      %w[TERM INT].each { |name| trap(name) { signals << name } }
      Thread.new do
        runner.follow
        signals << "ended"
      end
      reason = signals.pop
      runner.stop
      log.info("status", **runner.snapshot.to_h)
      log.info("stopped", reason: reason)
    end
  end
end

E2E::ExecutorMain.run(ARGV) if $PROGRAM_NAME == __FILE__
