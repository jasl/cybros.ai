require "test_helper"
require "net/http"
require "tmpdir"

# THE DAEMON'S HALF OF THE PLANE. rho-runner owns the contract, the
# registry and the tool hooks, because a runner on a second machine needs
# all of them with no daemon in the process. What a daemon adds is what
# only a daemon has: a lifetime to run background work in, and an operator
# to surface commands to.
class RhoExtensionsTest < Minitest::Test
  def extension(name, &block)
    Module.new do
      const_set(:NAME, name)
      define_singleton_method(:register) { |api| block.call(api) }
    end
  end

  def tool_class(name)
    Class.new do
      const_set(:NAME, name)
      const_set(:DESCRIPTION, "does #{name}")
      const_set(:SCHEMA, { "type" => "object", "properties" => {} })
      const_set(:EFFECT_PROFILE, {
        "kind" => "read_only", "destructive" => false, "world" => "closed",
        "idempotency" => "intrinsic", "reconciliation" => "none",
      })
      define_method(:initialize) { |env:| @env = env }
      define_method(:call) { |_args| Rho::Runner::Result.ok("ok") }
    end
  end

  def write_extension(dir, file, body)
    path = File.join(dir, file)
    File.write(path, body)
    path
  end

  def host = RhoTest.host

  class RecordingLog
    attr_reader :lines

    def initialize = @lines = []
    def info(event, **fields) = @lines << [event, fields]
    def warn(event, **fields) = @lines << [event, fields]
  end

  # A daemon booted with the given extension bodies, stopped before the
  # directory holding its home and their files goes away.
  def with_daemon(*bodies)
    Dir.mktmpdir do |dir|
      paths = bodies.each_with_index.map { |body, index| write_extension(dir, "ext#{index}.rb", body) }
      daemon = Rho::Daemon.boot(
        home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(dir, "home")),
        config: Rho::Config.from_hash("extension_paths" => paths)
      )
      begin
        yield daemon
      ensure
        daemon.stop
      end
    end
  end

  def get(daemon, path, bearer: nil)
    uri = URI.join(daemon.endpoint, path)
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{bearer}" if bearer
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  def post(daemon, path, bearer:, body:, content_type: "application/json")
    uri = URI.join(daemon.endpoint, path)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{bearer}"
    request["Content-Type"] = content_type
    request.body = body
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  def test_the_default_set_is_what_rho_integrates
    loaded = Rho::Extensions.load(host: host)

    assert_predicate loaded, :ok?
    # The seven, the four that make a dev server a background task, the
    # delegate summarizer the kernel addresses by policy, the
    # person's two reads through the relay (`files_bytes`, `process_log`), the kernel's skill load (`skill`) and the checkpoint store's two (`checkpoints`, `world_restore` — registered because the test host hands the store's member), described to nobody, and the todo tracker's `todo_write`,
    # the agent's own.
    # `environment_bind`: the hidden runner
    # tool a host elsewhere relays a conversation's root set through.
    assert_equal %w[bash checkpoints edit environment_bind file_import file_publish files_bytes find grep list_processes ls manage_scheduled_job process_log read
                    read_process read_scheduled_jobs skill start_process stop_process summarize_history todo_write world_restore write],
      loaded.registry.names.sort
    # Every route that is not the core's lifecycle or one of its three verbs, by its owner
    # (the standalone author and followed-set reads belong to Ops).
    assert_equal({
      "rho.processes" => ["GET /processes", "POST /processes/stop", "GET /processes/log"],
      # The daemon default's two, the runner report, and the conversation's
      # environment door with the live table.
      "rho.environment" => ["GET /environment", "POST /environment", "GET /runner",
                            "GET /conversations/environment", "POST /conversations/environment", "GET /environments"],
      "rho.console_link" => ["POST /console/code", "POST /console/session"],
      "rho.handoff" => ["GET /runners", "POST /handoff"],
      "rho.ops" => ["POST /loops", "GET /loops", "GET /loops/follow",
                    "POST /loops/attach", "POST /answer", "GET /asks", "POST /loops/retry", "POST /loops/abandon",
                    "POST /loops/approve", "POST /loops/deny", "GET /rules",
                    "POST /loops/delete", "POST /loops/pause", "POST /loops/resume", "POST /loops/subscribe",
                    "POST /loops/unsubscribe", "GET /loops/result", "GET /loops/transcript", "GET /loops/task",
                    "POST /loops/relay", "GET /loops/graph", "GET /loops/request",
                    "POST /loops/append", "GET /loops/phases", "GET /inputs", "POST /inputs/delete", "POST /inputs/update",
                    "PUT /conversations/access", "POST /conversations/prompt_preview", "GET /prompt/documents",
                    "POST /conversations/rewind", "POST /conversations/regenerate",
                    "GET /conversations/variants", "POST /conversations/activate", "POST /conversations/variant",
                    # The replay's spine: the turns
                    # listing behind `Core#turns` and `rho turns`.
                    "GET /conversations/turns", "GET /loops/events",
                    "GET /skills", "POST /skills/push", "GET /skills/show", "POST /skills/rm",
                    "POST /one_shots", "GET /one_shots", "POST /one_shots/subscribe", "POST /one_shots/unsubscribe", "GET /uploads/bytes",
                    "GET /files/bytes", "GET /models", "GET /conversations", "GET /conversations/detail",
                    "PATCH /conversations", "POST /conversations/archive", "POST /conversations/unarchive",
                    "GET /conversations/search", "GET /conversations/history", "POST /conversations/turns/edit",
                    "POST /conversations/turns/delete", "POST /conversations/turns/view",
                    "GET /workspaces", "GET /workspaces/detail", "POST /workspaces", "POST /workspaces/select",
                    "GET /conversations/memory", "POST /conversations/memory/read", "POST /conversations/memory/write",
                    "POST /conversations/memory/edit", "POST /conversations/memory/delete", "POST /conversations/memory/grep",
                    "POST /conversations/memory_context",
                    "GET /conversations/scheduled_jobs", "GET /conversations/scheduled_jobs/detail",
                    "GET /conversations/scheduled_jobs/executions", "POST /conversations/scheduled_jobs/create",
                    "POST /conversations/scheduled_jobs/update", "POST /conversations/scheduled_jobs/pause",
                    "POST /conversations/scheduled_jobs/resume", "POST /conversations/scheduled_jobs/cancel"],
      # The named sub-agents' four: the
      # listing, the edge past its tuple, the publish, the removal.
      "rho.agents" => ["GET /agents", "POST /agents/sync", "POST /agents/publish", "POST /agents/rm"],
      "rho.setup" => ["GET /installation"],
      "rho.settings" => ["GET /settings", "PATCH /settings", "GET /settings/status"],
    }, loaded.routes.group_by(&:extension).transform_values { |routes| routes.map { |r| "#{r.method} #{r.path}" } })
    assert_equal [:none], loaded.routes.select { |r| r.path == "/console/session" }.map(&:auth),
      "the redeem door is the one open route an extension serves"
    # Every shipped extension verb, by its owner. Ops supplies model
    # discovery; the conversation debugging verbs belong to rho-dev.
    assert_equal %w[agents console env handoff jobs kill logs memory models processes runner runners settings setup workspaces], loaded.commands.map(&:name).sort
    assert_equal %w[rho.processes rho.environment rho.console_link rho.ops rho.handoff rho.agents rho.setup rho.settings],
      loaded.commands.map(&:extension).uniq, "listed in load order, which is the order `rho help` prints"
    # The check's two flags on `run`, the one conversation verb a product
    # home has; rho-dev's `do` declares its own.
    assert_equal [["rho.until", %i[until attempts]]], loaded.flags.map { |flags| [flags.extension, flags.options.keys] }
    assert_equal %w[run], loaded.flags.map(&:command).uniq
    # The two turn hooks, in the order they fire.
    assert_equal [["rho.until", :turn_author], ["rho.until", :turn_follow]],
      loaded.daemon_hooks.map { |hook| [hook.extension, hook.event] }
    # The committed set is the whole default set: every extension registers
    # something — Images nothing without an `image_model`, committed all
    # the same — the same list `rho runner` shows.
    assert_equal %w[rho.coding rho.guard rho.checkpoints rho.processes rho.conventions rho.until
                    rho.environment rho.console_link rho.ops rho.handoff rho.compaction rho.todo rho.scheduled_jobs rho.agents
                    rho.images rho.setup rho.settings],
      loaded.inventory.map { |entry| entry.fetch("name") }
    assert_equal [], loaded.inventory.find { |entry| entry.fetch("name") == "rho.images" }.fetch("tools"), "no image model, no tool"
  end

  # THE THREE DAEMON EVENTS — the two turn events and the host's end
  # (`:host_ended`) — land beside the daemon's other registrations;
  # the runner's events and the lifecycle pair still go where they went.
  def test_the_daemon_events_register_on_the_daemon_handle_beside_the_runners_own
    api = Rho::Extensions::Api.new(host: host, extension_name: "rho.shaper", source: "<test>")
    api.on(:turn_author) { |draft, _ctx| draft }
    api.on(:turn_follow) { |_loop_public_id, _notes, _ctx| nil }
    api.on(:host_ended) { |_host_public_id| nil }
    api.on(:member_connection) { |_connection| nil }
    api.on(:tool_call) { |_name, _arguments| nil }
    api.on(:shutdown) { nil }

    assert_equal %i[turn_author turn_follow host_ended member_connection], api.daemon_hooks.map(&:event)
    assert_equal ["rho.shaper"], api.daemon_hooks.map(&:extension).uniq
    assert_equal [:tool_call], api.hooks.map(&:event)
    assert_equal [:shutdown], api.lifecycle.map(&:event)
    assert_raises(Rho::Runner::Extensions::RegistrationError) { api.on(:turn_author) }
    assert_raises(Rho::Runner::Extensions::RegistrationError) { api.on(:host_ended) }
    assert_raises(Rho::Runner::Extensions::RegistrationError) { api.on(:member_connection) }
    assert_raises(Rho::Runner::Extensions::RegistrationError) { api.on(:loop_author) { nil } }
    api.freeze
    assert_raises(FrozenError) { api.on(:turn_follow) { nil } }
    assert_raises(FrozenError) { api.on(:host_ended) { nil } }
  end

  # WHAT A VERB CARRIES TO THE DISPATCHER: its usage, its options as Thor
  # option hashes, its aliases — and a flag set carries the fold that puts
  # its values on a core verb's request body.
  def test_a_command_and_a_flag_set_carry_what_the_dispatcher_installs
    api = Rho::Extensions::Api.new(host: host, extension_name: "rho.ship", source: "<test>")
    api.register_command("ship", usage: "ship TARGET", description: "Ship it", aliases: %w[sh],
      options: { dry: { type: :boolean, default: false, desc: "Only say what would ship" } }) { |_cli, _args, _o| nil }
    api.register_flags("do", region: { type: :string, desc: "Where" }) do |body, options|
      options[:region] ? body.merge("region" => options[:region]) : body
    end

    command = api.commands.fetch(0)
    assert_equal ["ship", "ship TARGET", "Ship it", ["sh"], "rho.ship"],
      [command.name, command.usage, command.description, command.aliases, command.extension]
    assert_equal({ dry: { type: :boolean, default: false, desc: "Only say what would ship" } }, command.options)
    flags = api.flags.fetch(0)
    assert_equal ["do", %i[region], "rho.ship"], [flags.command, flags.options.keys, flags.extension]
    assert_equal({ "prompt" => "p", "region" => "eu" }, flags.fold.call({ "prompt" => "p" }, { region: "eu" }))
    assert_equal({ "prompt" => "p" }, flags.fold.call({ "prompt" => "p" }, {}))
  end

  # A flag set with nothing to fold, or no fold, is a registration error
  # like every other half-said registration.
  def test_flags_need_options_and_a_fold
    api = Rho::Extensions::Api.new(host: host, extension_name: "rho.x", source: "<test>")

    assert_raises(Rho::Runner::Extensions::RegistrationError) { api.register_flags("do") { |body, _o| body } }
    assert_raises(Rho::Runner::Extensions::RegistrationError) { api.register_flags("do", x: { type: :string }) }
    assert_raises(Rho::Runner::Extensions::RegistrationError) { api.register_command("x") }
  end

  # ONE `register(api)` WORKS UNDER BOTH HOSTS. The daemon's handle is a
  # SUBCLASS of the runner's, which is the whole mechanism — an extension
  # author never branches on which host it got.
  def test_a_daemon_handle_accepts_the_verbs_a_standalone_runner_only_logs
    Dir.mktmpdir do |dir|
      path = write_extension(dir, "ops.rb", <<~RUBY)
        module OpsExtension
          NAME = "rho.ops"
          def self.register(api)
            api.register_command("deploy", description: "Ship it") do |cli, (target), _options|
              cli.out.puts "deployed \#{target}"
            end
            api.background("watcher") { :running }
            api.on(:startup) { :started }
            api.register_route("GET", "/ops") { |_request, _ctx| [200, {}] }
          end
        end
      RUBY

      loaded = Rho::Extensions.load(host: host, paths: [path])

      assert_predicate loaded, :ok?
      command = loaded.command("deploy")
      assert_equal "rho.ops", command.extension
      assert_equal "Ship it", command.description
      # Its own watcher, beside the built-in process table's validity sweep
      # and the table's progress pump.
      assert_equal ["watcher"], loaded.background_tasks.select { |task| task.extension == "rho.ops" }.map(&:name)
      assert_equal 3, loaded.background_tasks.length
      assert_includes loaded.routes.map { |route| [route.extension, route.method, route.path, route.auth] },
        ["rho.ops", "GET", "/ops", :bearer]
      # Its own startup, beside the built-in process table's pair.
      assert_equal 1, loaded.lifecycle.count { |hook| hook.extension == "rho.ops" }
    end
  end

  # A command's handler takes what the dispatcher hands it — the core
  # client, the words after the verb, the parsed options — and prints
  # through the client; its answer is its own.
  def test_a_command_handler_takes_the_client_the_words_and_the_options
    Dir.mktmpdir do |dir|
      path = write_extension(dir, "echo.rb", <<~RUBY)
        module EchoExtension
          NAME = "rho.echo"
          def self.register(api)
            api.register_command("echo", usage: "echo WORD") do |cli, (word), options|
              cli.out.puts "\#{word}\#{options[:loud] ? "!" : ""}"
              word
            end
          end
        end
      RUBY

      command = Rho::Extensions.load(host: host, paths: [path]).command("echo")
      out = StringIO.new
      client = Rho::Cli::Terminal.new(home: host.home, out: out)

      assert_equal "hi", command.handler.call(client, ["hi"], { loud: true })
      assert_equal "hi!\n", out.string
    end
  end

  # NOTHING HALF-REGISTERED SURVIVES, on this side either. A factory that
  # raised had its tools correctly discarded; reading every handle the
  # loader built would have kept its COMMANDS, FLAGS and ROUTES anyway.
  def test_a_factory_that_raised_contributes_no_commands_flags_or_routes
    Dir.mktmpdir do |dir|
      path = write_extension(dir, "broken.rb", <<~RUBY)
        module BrokenExtension
          NAME = "rho.broken"
          def self.register(api)
            api.register_command("ghost") { |_cli, _args, _options| nil }
            api.register_flags("do", ghost: { type: :string }) { |body, _options| body }
            api.register_route("GET", "/ghost") { |_request, _ctx| nil }
            api.on(:turn_author) { |draft, _ctx| draft }
            raise "boom"
          end
        end
      RUBY

      loaded = Rho::Extensions.load(host: host, paths: [path])

      refute_predicate loaded, :ok?
      assert_nil loaded.command("ghost"),
        "a command from a factory nobody vouched for is a command nobody vouched for"
      refute_includes loaded.flags.map(&:extension), "rho.broken"
      refute_includes loaded.routes.map(&:extension), "rho.broken"
      refute_includes loaded.daemon_hooks.map(&:extension), "rho.broken"
      refute_includes loaded.inventory.map { |entry| entry.fetch("name") }, "rho.broken"
    end
  end

  # A FAILURE IS A PRODUCT FACT. An operator whose extension did not load
  # must see WHICH one and why without reading a log file.
  def test_a_failure_names_its_source_and_its_reason
    Dir.mktmpdir do |dir|
      path = write_extension(dir, "bad.rb", "module BadExtension; NAME='rho.bad'; " \
        "def self.register(_api) = raise(ArgumentError, 'nope'); end")

      loaded = Rho::Extensions.load(host: host, paths: [path])

      failure = loaded.failures.first
      assert_equal path, failure.source
      assert_equal "ArgumentError", failure.error_class
      assert_match(/nope/, failure.message)
    end
  end

  # The inventory a control surface serves and a UI renders: names,
  # descriptions and effect profiles — never handlers.
  def test_the_inventory_carries_what_a_ui_can_render_and_nothing_it_cannot
    Dir.mktmpdir do |dir|
      path = write_extension(dir, "net.rb", <<~RUBY)
        module NetExtension
          NAME = "rho.net"
          class Fetch
            NAME = "net_fetch"
            DESCRIPTION = "fetches"
            SCHEMA = { "type" => "object", "properties" => {} }.freeze
            EFFECT_PROFILE = {
              "kind" => "read_only", "destructive" => false, "world" => "open",
              "idempotency" => "none", "reconciliation" => "none"
            }.freeze
            def initialize(env:) = @env = env
            def call(_args) = Rho::Runner::Result.ok("fetched")
          end
          def self.register(api)
            api.register_tool(Fetch)
            api.register_command("ping", description: "Ping a host") { |_cli, _args, _options| nil }
          end
        end
      RUBY

      inventory = Rho::Extensions.load(host: host, paths: [path]).inventory
      net = inventory.find { |entry| entry["name"] == "rho.net" }

      assert_equal "open", net.dig("tools", 0, "effect_profile", "world")
      assert_equal path, net.fetch("source")
      assert_equal "Ping a host", net.dig("commands", 0, "description")
      refute_includes JSON.generate(inventory), "handler"
      # An extension that registered only a hook is committed and listed too.
      guard = inventory.find { |entry| entry["name"] == "rho.guard" }
      assert_equal [[], [], "<built-in>"], [guard.fetch("tools"), guard.fetch("commands"), guard.fetch("source")]
    end
  end

  # ---- routes: the door every extension shares with the core ----

  # ONE OWNER PER ROUTE. An extension claiming a path the core serves would
  # be a silent takeover of the daemon's own door, so the daemon refuses to
  # boot and names both claimants.
  def test_a_route_collision_is_a_load_error_that_names_both_owners
    Dir.mktmpdir do |dir|
      path = write_extension(dir, "squatter.rb", <<~RUBY)
        module SquatterExtension
          NAME = "rho.squatter"
          def self.register(api)
            api.register_route("get", "/healthz") { |_request, _ctx| [200, {}] }
          end
        end
      RUBY

      error = assert_raises(Rho::Runner::Extensions::RegistrationError) do
        Rho::Daemon.boot(
          home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(dir, "home")),
          config: Rho::Config.from_hash("extension_paths" => [path])
        )
      end

      assert_match(%r{rho\.squatter registers GET /healthz, already registered by rho\b}, error.message)
    end
  end

  # `auth: :bearer` is the default and it means what it means for every
  # core route: no bearer, no answer. `:none` is said out loud.
  def test_an_extension_route_carries_the_bearer_unless_it_says_none
    body = <<~RUBY
      module DoorsExtension
        NAME = "rho.doors"
        def self.register(api)
          api.register_route("GET", "/doors/open", auth: :none) { |_request, _ctx| [200, { door: "open" }] }
          api.register_route("GET", "/doors/locked") { |_request, _ctx| [200, { door: "locked" }] }
        end
      end
    RUBY

    with_daemon(body) do |daemon|
      open = get(daemon, "/doors/open")
      assert_equal "200", open.code
      assert_equal({ "door" => "open" }, JSON.parse(open.body))
      assert_equal "401", get(daemon, "/doors/locked").code
      assert_equal "200", get(daemon, "/doors/locked", bearer: daemon.bearer).code
    end
  end

  # WHAT A ROUTE SEES: the host at register time through `api.host`, and the
  # daemon's context per request — the same home, and the facts only a
  # running daemon has.
  def test_a_route_reaches_the_host_at_register_time_and_the_context_per_request
    body = <<~RUBY
      module HomeExtension
        NAME = "rho.home"
        def self.register(api)
          registered = api.host.home.root
          api.register_route("GET", "/home") do |_request, ctx|
            [200, { registered: registered, requested: ctx.home.root,
                    endpoint: ctx.endpoint, page: ctx.page?, stopping: ctx.stopping? }]
          end
        end
      end
    RUBY

    with_daemon(body) do |daemon|
      answer = JSON.parse(get(daemon, "/home", bearer: daemon.bearer).body)
      assert_equal daemon.home.root, answer.fetch("registered")
      assert_equal daemon.home.root, answer.fetch("requested")
      assert_equal daemon.endpoint, answer.fetch("endpoint")
      assert_equal daemon.page?, answer.fetch("page")
      refute answer.fetch("stopping")
      assert_same daemon.context, daemon.context, "one context for the daemon's life"
    end
  end

  # THE ONE GUARD MAPS FOR EVERY ROUTE, an extension's included: a kernel
  # refusal crosses with its own status and code, a body that is not JSON
  # is a 400, and no handler spells either envelope itself.
  def test_a_kernel_refusal_and_a_malformed_body_are_mapped_by_the_one_guard
    body = <<~RUBY
      module RelayExtension
        NAME = "rho.relay"
        def self.register(api)
          api.register_route("GET", "/relay/missing") do |_request, _ctx|
            raise CybrosAgent::Api::NotFound.new("nothing there", code: "loop_not_found")
          end
          api.register_route("POST", "/relay/echo") do |request, _ctx|
            [200, Rho::ControlServer.json_body(request)]
          end
        end
      end
    RUBY

    with_daemon(body) do |daemon|
      missing = get(daemon, "/relay/missing", bearer: daemon.bearer)
      assert_equal "404", missing.code
      assert_equal "loop_not_found", JSON.parse(missing.body).dig("error", "code")

      malformed = post(daemon, "/relay/echo", bearer: daemon.bearer, body: "{", content_type: "text/plain")
      assert_equal "400", malformed.code
      assert_equal "malformed_body", JSON.parse(malformed.body).dig("error", "code")
      assert_equal "200", post(daemon, "/relay/echo", bearer: daemon.bearer, body: "{}").code
    end
  end

  # A HANDLER THAT RAISES COSTS ITS OWN REQUEST, never the daemon.
  def test_a_raising_handler_answers_500_and_the_daemon_keeps_serving
    body = <<~RUBY
      module BoomExtension
        NAME = "rho.boom"
        def self.register(api)
          api.register_route("GET", "/boom") { |_request, _ctx| raise "boom" }
        end
      end
    RUBY

    with_daemon(body) do |daemon|
      response = get(daemon, "/boom", bearer: daemon.bearer)
      assert_equal "500", response.code
      assert_equal "internal_error", JSON.parse(response.body).dig("error", "code")
      assert_equal "200", get(daemon, "/healthz").code
      assert_predicate daemon, :running?
    end
  end
end

# ---- the shipped set is per mode ----
class ExtensionsPerModeTest < Minitest::Test
  def tool_class(name)
    Class.new do
      const_set(:NAME, name)
      const_set(:DESCRIPTION, "does #{name}")
      const_set(:SCHEMA, { "type" => "object", "properties" => {} })
      const_set(:EFFECT_PROFILE, {
        "kind" => "read_only", "destructive" => false, "world" => "closed",
        "idempotency" => "intrinsic", "reconciliation" => "none",
      })
      define_method(:initialize) { |env:| @env = env }
      define_method(:call) { |_args| Rho::Runner::Result.ok("ok") }
    end
  end

  def extension(name, &block)
    Module.new do
      const_set(:NAME, name)
      define_singleton_method(:register) { |api| block.call(api) }
    end
  end

  def host(mode)
    Rho::Extensions::Host.new(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(Dir.tmpdir, "rho-test-host")),
      log: nil, clock: -> { Time.now }, config: Rho::Config.from_hash("mode" => mode), processes: nil
    )
  end

  # THE HOST FACT "this process will serve tools": true by default — every daemon and standalone site is untouched
  # — and false where the CLI learns the verbs (`exe/rho`), so an
  # extension that connects to list its tools spawns nothing there. The
  # member, not `processes.nil?`: that is nil under a standalone runner too.
  def test_the_host_states_whether_it_serves_tools_and_defaults_to_true
    assert_equal true, host("full").serving_tools
    silent = Rho::Extensions::Host.new(
      home: host("full").home, log: nil, clock: -> { Time.now }, config: Rho::Config.from_hash({}), processes: nil,
      serving_tools: false
    )
    assert_equal false, silent.serving_tools
    assert_nil silent.processes, "a standalone runner's host is processes-nil AND serves — the member is the fact"
    exe = File.read(File.expand_path("../exe/rho", __dir__), encoding: Encoding::UTF_8)
    assert_includes exe, "serving_tools: false", "the CLI's host must state it serves no tool"
  end

  # THE STORE'S MEMBER: nil by default — the CLI's host, a
  # standalone runner's, a test's without one — so the checkpoints
  # extension registers nothing there; a daemon hands a CALLABLE answering
  # the store of the moment (the runner root is known at placement), and
  # the shipped set carries the extension between the guard and the
  # process table (a veto first; the capture never runs for a vetoed call).
  def test_the_host_carries_the_checkpoint_stores_member_and_the_shipped_set_the_extension
    assert_nil host("full").checkpoints
    store = Object.new
    handed = Rho::Extensions::Host.new(
      home: host("full").home, log: nil, clock: -> { Time.now }, config: Rho::Config.from_hash({}), processes: nil,
      checkpoints: -> { store }
    )
    assert_same store, handed.checkpoints.call
    shipped = Rho::Extensions::DEFAULT_EXTENSIONS
    assert_equal [Rho::Extensions::Guard, Rho::Runner::Extensions::Checkpoints, Rho::Extensions::Processes],
      shipped[shipped.index(Rho::Extensions::Guard), 3]

    bare = Rho::Extensions.load(host: host("full").with(checkpoints: nil)).registry
    refute_includes bare.names, "world_restore", "no member: the extension registers nothing"
    assert_includes Rho::Extensions.load(host: host("full").with(checkpoints: -> { store })).registry.names, "world_restore"
    assert_includes Rho::Extensions.load(host: RhoTest.host).registry.names, "checkpoints"
  end

  # DEFAULT_EXTENSIONS SURVIVES as the full set: the e2e preludes swap the
  # constant through RUBYOPT, and `defaults_for` reads it at call time so
  # the swapped list flows through to every mode.
  def test_defaults_for_derives_the_agent_and_runner_subsets_from_the_full_set
    full = Rho::Extensions::DEFAULT_EXTENSIONS
    assert_equal full, Rho::Extensions.defaults_for("full")
    assert_equal full, Rho::Extensions.defaults_for(:full)

    agent = Rho::Extensions.defaults_for("agent")
    assert_equal full - [Rho::Runner::Extensions::Coding], agent
    refute_includes agent, Rho::Runner::Extensions::Coding
    # Processes loads in agent mode for its VERBS (`rho ps` reads a bound runner's table through the relay); its tools go to no address there.
    assert_includes agent, Rho::Extensions::Processes

    runner = Rho::Extensions.defaults_for("runner")
    assert_equal full - [Rho::Extensions::Ops, Rho::Extensions::Compaction, Rho::Extensions::Todo, Rho::Extensions::ScheduledJobs,
                         Rho::Extensions::ConsoleLink, Rho::Extensions::Until, Rho::Extensions::Conventions,
                         Rho::Extensions::Handoff, Rho::Extensions::Agents, Rho::Extensions::Images], runner
    assert_equal [Rho::Runner::Extensions::Coding, Rho::Extensions::Guard, Rho::Runner::Extensions::Checkpoints,
                  Rho::Extensions::Processes, Rho::Extensions::Environment, Rho::Extensions::Setup, Rho::Extensions::Settings], runner
    assert_includes agent, Rho::Extensions::Environment, "Guard and Environment serve both"
    assert_includes runner, Rho::Extensions::Guard
  end

  # WHICH ADDRESS A HOST SERVES, asked before a tool is registered: the
  # daemon by its mode, the base handle the runner's alone.
  def test_serves_answers_by_mode_and_the_base_handle_serves_the_runner_alone
    full = Rho::Extensions::Api.new(host: host("full"), extension_name: "t", source: "<test>")
    assert full.serves?(:runner)
    assert full.serves?(:agent)
    agent = Rho::Extensions::Api.new(host: host("agent"), extension_name: "t", source: "<test>")
    refute agent.serves?(:runner)
    assert agent.serves?(:agent)
    runner = Rho::Extensions::Api.new(host: host("runner"), extension_name: "t", source: "<test>")
    assert runner.serves?(:runner)
    refute runner.serves?(:agent)
    base = Rho::Runner::Extensions::Api.new(extension_name: "t", source: "<test>")
    assert base.serves?(:runner)
    refute base.serves?(:agent)
  end

  def test_a_swapped_constant_flows_through_defaults_for
    original = Rho::Extensions::DEFAULT_EXTENSIONS
    Rho::Extensions.send(:remove_const, :DEFAULT_EXTENSIONS)
    Rho::Extensions.const_set(:DEFAULT_EXTENSIONS, [Rho::Extensions::Ops].freeze)

    assert_equal [Rho::Extensions::Ops], Rho::Extensions.defaults_for("agent")
    assert_equal [Rho::Extensions::Ops], Rho::Extensions.defaults_for("full")
    assert_empty Rho::Extensions.defaults_for("runner")
  ensure
    Rho::Extensions.send(:remove_const, :DEFAULT_EXTENSIONS)
    Rho::Extensions.const_set(:DEFAULT_EXTENSIONS, original)
  end

  # THE TWO ANNOUNCEMENTS, from one registry: the runner address serves the
  # environment tools, the agent address its own (the delegate summarizer).
  def test_the_registry_partitions_the_default_set_into_the_two_addresses
    registry = Rho::Extensions.load(host: host("full")).registry

    runner = Rho::LoopRequest.announcement(registry: registry.serving(:runner))
    agent = Rho::LoopRequest.announcement(registry: registry.serving(:agent))
    assert_equal %w[bash edit environment_bind file_import file_publish files_bytes find grep list_processes ls process_log read read_process skill
                    start_process stop_process write],
      runner.map { |entry| entry.fetch("name") }
    refute(runner.any? { |entry| entry.key?("timeout_ms") })
    assert_equal [["manage_scheduled_job", 30_000], ["read_scheduled_jobs", 30_000],
                  ["summarize_history", 120_000], ["todo_write", 30_000]],
      agent.map { |entry| entry.values_at("name", "timeout_ms") }, "the delegate, todo tracker and scheduled job tools"
    assert_equal Rho::LoopRequest.tool_entries(Rho::LoopRequest.announcement(registry: registry)),
      Rho::LoopRequest.tool_entries(runner + agent),
      "the declaration reads the whole registry: both addresses' announcements are one set"
  end

  # AN OPERATOR-NAMED EXTENSION OF THE WRONG SOURCE IS REFUSED AT LOAD (S-7):
  # the failure names the extension, the tool, the mode and the ways out —
  # only verbs that exist at landing.
  def test_a_runner_tool_under_agent_mode_and_an_agent_tool_under_runner_mode_are_load_failures
    agent_mode = Rho::Extensions.load(host: host("agent"), extensions: [
      extension("rho.net") { |api| api.register_tool(tool_class("net_fetch")) },
    ])
    refute_predicate agent_mode, :ok?
    assert_equal ["rho.net registers `net_fetch` for the runner; this rho runs in mode agent — " \
                  "use mode full, or name a runner: `rho run … --runner ID`"], agent_mode.failures.map(&:message)
    assert_empty agent_mode.registry.names

    runner_mode = Rho::Extensions.load(host: host("runner"), extensions: [
      extension("rho.summary") { |api| api.register_tool(tool_class("summarize"), serves: :agent) },
    ])
    assert_equal ["rho.summary registers `summarize` for the agent; this rho runs in mode runner — " \
                  "use mode full or agent"], runner_mode.failures.map(&:message)

    full_mode = Rho::Extensions.load(host: host("full"), extensions: [
      extension("rho.both") do |api|
        api.register_tool(tool_class("net_fetch"))
        api.register_tool(tool_class("summarize"), serves: :agent)
      end,
    ])
    assert_predicate full_mode, :ok?
    assert_equal %w[net_fetch], full_mode.registry.serving(:runner).names
    assert_equal %w[summarize], full_mode.registry.serving(:agent).names
  end

  # In runner mode there is no `Loops` to fire a turn hook or a host's end
  # (a runner follows no conversation; the parity with the processes table's own gap, stated) and no `do` to carry a
  # flag: all answer the base handle's `unavailable`, logged.
  def test_daemon_hooks_and_flags_are_unavailable_in_runner_mode_not_a_load_error
    log = RhoExtensionsTest::RecordingLog.new
    loaded = Rho::Extensions.load(host: host("runner"), log: log, extensions: [
      extension("rho.hooky") do |api|
        api.on(:turn_author) { |draft, _ctx| draft }
        api.on(:host_ended) { |_host_public_id| nil }
        api.register_flags("do", until: { type: :string }) { |body, _options| body }
        api.register_tool(tool_class("net_fetch"))
      end,
    ])

    assert_predicate loaded, :ok?
    assert_empty loaded.daemon_hooks
    assert_empty loaded.flags
    assert_equal %w[net_fetch], loaded.registry.names
    details = log.lines.select { |event, _| event == "extension_verb_unavailable" }.map { |_, fields| fields[:detail] }
    assert_equal ["hook turn_author is not surfaced by a standalone runner",
                  "hook host_ended is not surfaced by a standalone runner",
                  "flags on do is not surfaced by a standalone runner"], details
    assert_equal %i[turn_author host_ended], Rho::Extensions.load(host: host("full"), extensions: [
      extension("rho.hooky") do |api|
        api.on(:turn_author) { |draft, _ctx| draft }
        api.on(:host_ended) { |_host_public_id| nil }
      end,
    ]).daemon_hooks.map(&:event)
  end

  # THE ONE REGISTRAR FOR AN EDITOR'S MCP SERVERS: an extension registers
  # the block that turns a conversation's `mcpServers` list into the set
  # the agent slot serves, and `Loaded` carries it; a SECOND extension
  # asking is refused BY NAME — its load fails, listed, the first stands;
  # in runner mode there is no agent slot to serve on, so the verb
  # answers the base handle's `unavailable`, logged, and the extension
  # still loads.
  def test_the_conversation_servers_registrar_is_one_per_daemon_and_unavailable_in_runner_mode
    loaded = Rho::Extensions.load(host: host("full"), extensions: [
      extension("rho.first") { |api| api.register_conversation_servers { |anchor, entries| [anchor, entries] } },
      extension("rho.second") { |api| api.register_conversation_servers { |_anchor, _entries| nil } },
    ])

    assert_equal "rho.first", loaded.conversation_servers.extension
    assert_equal ["c-1", []], loaded.conversation_servers.handler.call("c-1", [])
    assert_equal ["Rho::Runner::Extensions::RegistrationError"], loaded.failures.map(&:error_class)
    assert_match(/rho\.second registers conversation servers; rho\.first already did — one registrar per daemon/,
      loaded.failures.first.message)
    assert_equal ["rho.first"], loaded.extensions.map(&:name), "the second is not committed"

    log = RhoExtensionsTest::RecordingLog.new
    runner = Rho::Extensions.load(host: host("runner"), log: log, extensions: [
      extension("rho.first") do |api|
        api.register_conversation_servers { |_anchor, _entries| nil }
        api.register_tool(tool_class("net_fetch"))
      end,
    ])
    assert_predicate runner, :ok?
    assert_nil runner.conversation_servers
    assert_equal %w[net_fetch], runner.registry.names
    assert_includes log.lines.map { |_, fields| fields[:detail] }, "conversation servers is not surfaced by a standalone runner"

    error = assert_raises(Rho::Runner::Extensions::RegistrationError) do
      Rho::Extensions::Api.new(extension_name: "rho.x", source: "x", host: host("full")).register_conversation_servers
    end
    assert_match(/register_conversation_servers needs a block/, error.message)
    assert_nil Rho::Extensions.load(host: host("full"), extensions: [extension("rho.plain") { |_api| nil }]).conversation_servers,
      "nobody registered: nil, the door's 422"
  end
end
