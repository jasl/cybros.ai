require_relative "test_helper"
require "stringio"

class RegistrationTest < Minitest::Test
  PROJECT = { "id" => "fixture-project", "title" => "Fixture", "workspaceRoot" => "/work/fixture" }.freeze
  CLI = Data.define(:core, :out)

  # The T3 service as the setup operations read it: the provider directory,
  # the project directory and explicit creation, each failing on demand.
  class Service
    attr_reader :calls, :created
    attr_accessor :unreachable, :directory_failure, :uncertain_create

    def initialize
      @rows, @calls, @created = [PROJECT], [], []
    end

    def call(method, _params, **)
      @calls << method
      raise Rho::T3::Uncertain, Rho::T3::Bridge::UNAVAILABLE if unreachable

      { "providers" => T3Test.provider_catalog }
    end

    def projects
      @calls << "projects"
      raise Rho::T3::Error, "T3 project request failed (HTTP 404)" if unreachable || directory_failure

      @rows
    end

    def create_project(path:, title:)
      @calls << "create"
      raise Rho::T3::Uncertain, "lost response" if uncertain_create

      row = { "id" => "created-project", "title" => title, "workspaceRoot" => path }
      @created << row
      @rows += [row]
      row
    end
  end

  # What a route sees of the daemon: its live settings and the plugin
  # settings writer.
  class Context
    attr_reader :config, :saved
    attr_accessor :failure

    def initialize(config)
      @config, @saved = config, []
    end

    def configure_plugin(id, operations:)
      @saved << [id, operations]
      raise failure if failure
    end
  end

  def setup
    @root = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_an_unconfigured_extension_registers_no_tools
    api = registration({})

    Rho::T3.register(api)

    assert_empty api.tools
    assert_empty Rho::Env::Extensions::Registry.new.commit(api).announcement
  end

  def test_configured_tools_are_announced_on_the_agent_address_without_connecting
    api = registration(configured)

    Rho::T3.register(api)

    registry = Rho::Env::Extensions::Registry.new.commit(api)
    assert_equal %w[coding_work delegate_coding], registry.serving(:agent).names.sort
    assert_empty registry.serving(:runner).names
  end

  def test_partial_or_missing_credential_configuration_exposes_setup_without_tools
    [{ "url" => "http://127.0.0.1:1" }, configured.merge("token" => "")].each do |value|
      api = registration(value)

      Rho::T3.register(api)
      assert_empty api.tools
      assert_includes api.commands.map(&:name), "t3"
      assert_equal [%w[GET /t3], %w[POST /t3/project], %w[POST /t3/token]], api.routes.map { |route| [route.method, route.path] }
    end
  end

  # The saved bearer registers the tools; the page document names it as saved and never carries it.
  def test_a_saved_bearer_registers_the_tools_and_never_leaves_the_daemon
    api = registration(configured)
    Rho::T3.register(api)
    assert_equal %w[coding_work delegate_coding], api.tools.map(&:name).sort
    assert api.readiness.fetch(:ready)
    document = page_document(api, Context.new(api.host.config)).last
    assert_equal "saved", document.dig("status", "bearer")
    refute document.fetch("configuration").key?("token"), "the page document never carries the bearer"
    refute_includes JSON.generate(document), "fixture-registration-bearer"
  end

  def test_configured_delegation_still_requires_an_agent_address
    api = registration(configured)
    api.define_singleton_method(:serves?) { |_role| false }

    error = assert_raises(Rho::T3::Error) { Rho::T3.register(api) }

    assert_equal "T3 delegation requires an application Agent service", error.message
    assert_empty api.tools
  end

  def test_local_registration_is_restart_only_and_unready_until_its_owned_service_starts
    api = registration(configured.merge("server" => "local"))
    Rho::T3.register(api)
    assert api.restart_only?
    refute api.readiness.fetch(:ready)
    assert_includes api.readiness.fetch(:issues), "The local T3 service is not running"
    assert_equal %i[startup shutdown], api.lifecycle.map(&:event)
    refute File.exist?(File.join(@root, "plugins", Rho::T3::NAME)), "registration does not start native programs"
  end

  def test_host_registration_has_no_local_process_lifecycle
    api = registration(configured)
    Rho::T3.register(api)
    refute api.restart_only?
    assert_empty api.lifecycle
    assert api.readiness.fetch(:ready)
  end

  def test_the_t3_command_saves_a_project_through_the_cli_and_prints_its_answer
    serving do |api, _ctx, service|
      saved = []
      answer = { "saved" => true, "applied" => false, "published" => false, "restart_required" => true }
      core = Object.new
      core.define_singleton_method(:configure_extension) do |id, operations:|
        saved << [id, operations]
        answer
      end
      out = StringIO.new
      command = api.commands.find { |row| row.name == "t3" }

      assert_equal answer, command.handler.call(CLI.new(core: core, out: out), %w[project fixture-project], {})
      assert_equal "#{JSON.pretty_generate(answer)}\n", out.string
      assert_equal [[Rho::T3::NAME, [{ "op" => "set", "path" => ["project_id"], "value" => "fixture-project" }]]], saved
      assert_equal ["projects"], service.calls
    end
  end

  def test_the_page_document_carries_status_saved_settings_and_both_t3_directories
    serving(configured.merge("default_agent" => "Codex")) do |api, ctx, service|
      assert_equal [["GET", "/t3", :bearer], ["POST", "/t3/project", :bearer], ["POST", "/t3/token", :bearer]],
        api.routes.map { |route| [route.method, route.path, route.auth] }

      status, document = page_document(api, ctx)

      assert_equal 200, status
      assert_equal %w[status configuration service projects providers], document.keys
      assert_equal({ "reachable" => true, "orchestration_protocol" => 2 }, document.fetch("service"))
      assert_equal [PROJECT], document.fetch("projects")
      assert_equal ["Codex", "Claude Code"], document.fetch("providers").map { |row| row.fetch("agent") }
      assert_equal "fixture-code", document.fetch("providers").first.fetch("default_model")
      assert_equal "fixture-project", document.dig("status", "project_id")
      assert_equal ctx.config.plugin_configuration(Rho::T3::NAME).except("token"), document.fetch("configuration")
      assert_equal [3773, "Codex", { "type" => "root" }], document.fetch("configuration").values_at("listen_port", "default_agent", "workspace")
      assert_equal ["server.getConfig", "projects"], service.calls
    end
  end

  def test_an_unreachable_service_leaves_both_directories_null_beside_its_reason
    service = Service.new
    service.unreachable = true
    serving(configured, service) do |api, ctx|
      status, document = page_document(api, ctx)

      assert_equal 200, status
      assert_equal({ "reachable" => false, "error" => Rho::T3::Bridge::UNAVAILABLE }, document.fetch("service"))
      assert_nil document.fetch("projects")
      assert_nil document.fetch("providers")
      assert_equal "fixture-project", document.dig("status", "project_id")
    end
  end

  def test_unset_connection_settings_are_named_without_connecting
    api = registration({ "project_id" => "fixture-project", "token" => "fixture-registration-bearer" })
    Rho::T3.register(api)

    status, document = page_document(api, Context.new(api.host.config))

    assert_equal 200, status
    assert_equal({ "reachable" => false, "error" => "Set the host T3 service URL first" }, document.fetch("service"))
    assert_nil document.fetch("projects")
    assert_nil document.fetch("providers")
    assert_includes document.dig("status", "issues"), "Set the host T3 service URL"
  end

  def test_a_failed_project_directory_does_not_hide_the_coding_agents
    service = Service.new
    service.directory_failure = true
    serving(configured, service) do |api, ctx|
      _status, document = page_document(api, ctx)

      assert document.dig("service", "reachable")
      assert_nil document.fetch("projects")
      assert_equal 2, document.fetch("providers").length
    end
  end

  def test_choosing_a_listed_project_saves_its_id_through_the_plugin_settings
    serving do |api, ctx, service|
      status, answer = choose(api, ctx, { "id" => "fixture-project" })

      assert_equal 200, status
      assert_equal({ "project" => PROJECT, "saved" => true, "applied" => true, "restart_required" => false }, answer)
      assert_equal [[Rho::T3::NAME, [{ "op" => "set", "path" => ["project_id"], "value" => "fixture-project" }]]], ctx.saved
      assert_empty service.created
    end
  end

  def test_a_path_selects_its_existing_project_or_creates_one
    serving do |api, ctx, service|
      _status, reused = choose(api, ctx, { "path" => " /work/fixture " })
      assert_equal PROJECT, reused.fetch("project")
      assert_empty service.created

      _status, created = choose(api, ctx, { "path" => "/work/new" })
      assert_equal({ "id" => "created-project", "title" => "new", "workspaceRoot" => "/work/new" }, created.fetch("project"))
      assert_equal 1, service.created.length
      assert_equal %w[fixture-project created-project], ctx.saved.map { |(_id, operations)| operations.first.fetch("value") }
    end
  end

  def test_a_body_without_exactly_one_known_choice_is_refused_before_saving
    serving do |api, ctx, service|
      [{}, { "id" => "fixture-project", "path" => "/work/fixture" }, { "id" => "fixture-project", "title" => "Fixture" },
       { "path" => "work/relative" }, { "id" => "unknown-project" }].each do |body|
        status, document = choose(api, ctx, body)

        assert_equal 400, status, body.inspect
        assert_equal "malformed_body", document.dig(:error, :code)
      end
      assert_empty ctx.saved
      assert_empty service.created
      assert_equal ["projects"], service.calls, "only the unknown id needed the directory"
    end
  end

  def test_t3_failures_answer_bad_gateway_and_save_nothing
    service = Service.new
    service.uncertain_create = true
    serving(configured, service) do |api, ctx|
      status, document = choose(api, ctx, { "path" => "/work/new" })
      assert_equal [502, "t3_uncertain"], [status, document.dig(:error, :code)]
      assert_equal "T3 project creation was not confirmed; inspect rho t3 projects before creating again", document.dig(:error, :message)

      service.unreachable = true
      status, document = choose(api, ctx, { "id" => "fixture-project" })
      assert_equal [502, "t3_unavailable"], [status, document.dig(:error, :code)]
      assert_empty ctx.saved
    end
  end

  def test_a_host_bearer_is_saved_from_the_route_and_the_cli_without_ever_being_shown
    serving do |api, ctx|
      status, answer = post(api, ctx, "/t3/token", { "token" => " host-issued-bearer " })
      assert_equal 200, status
      assert_equal({ "bearer" => "saved", "saved" => true, "applied" => true, "restart_required" => false }, answer)
      assert_equal [[Rho::T3::NAME, [{ "op" => "set", "path" => ["token"], "value" => "host-issued-bearer" }]]], ctx.saved

      [{}, { "token" => "" }, { "token" => "two words" }, { "token" => "x", "extra" => 1 }].each do |body|
        status, document = post(api, ctx, "/t3/token", body)
        assert_equal 400, status, body.inspect
        assert_equal "malformed_body", document.dig(:error, :code)
      end
      assert_equal 1, ctx.saved.length

      # The CLI reads a host bearer from stdin — one line of a pipe here — and prints only the outcome.
      saved = []
      core = Object.new
      core.define_singleton_method(:configure_extension) { |id, operations:| saved << [id, operations]; { "saved" => true } }
      command = api.commands.find { |row| row.name == "t3" }
      out = StringIO.new
      previous = $stdin
      $stdin = StringIO.new("piped-bearer\n")
      begin
        command.handler.call(CLI.new(core: core, out: out), %w[token], {})
      ensure
        $stdin = previous
      end
      assert_equal [[Rho::T3::NAME, [{ "op" => "set", "path" => ["token"], "value" => "piped-bearer" }]]], saved
      refute_includes out.string, "piped-bearer"
    end
  end

  def test_a_choice_awaiting_restart_is_saved_and_other_apply_failures_still_say_saved
    serving do |api, ctx|
      ctx.failure = Rho::Settings::ApplyError.new("Settings were saved. Restart rho to apply the changes.", restart_required: true)
      status, answer = choose(api, ctx, { "id" => "fixture-project" })
      assert_equal 200, status
      assert_equal [true, false, true], answer.values_at("saved", "applied", "restart_required")

      ctx.failure = Rho::Settings::ApplyError.new("Settings were saved, but applying them failed.")
      status, document = choose(api, ctx, { "id" => "fixture-project" })
      assert_equal [503, "settings_apply_failed", true], [status, document.dig(:error, :code), document.dig(:error, :saved)]
    end
  end

  def test_the_application_registers_the_browser_module_shipped_in_the_gem
    root = File.realpath(File.expand_path("../webui", __dir__))
    api = registration({})
    Rho::T3.register(api)

    assert_equal Rho::T3::NAME, api.webui_module.extension
    assert_equal root, api.webui_module.root
    assert_match %r{\A/modules/rho\.t3/\h{12}/index\.js\z}, api.webui_module.entry
  end

  def test_the_gem_ships_every_browser_module_file
    gem_root = File.expand_path("..", __dir__)
    spec = Gem::Specification.load(File.join(gem_root, "rho-t3.gemspec"))
    browser_files = Dir.glob("webui/**/*", base: gem_root).select { |path| File.file?(File.join(gem_root, path)) }

    assert_includes browser_files, "webui/index.js"
    assert_empty browser_files - spec.files
  end

  private

    def configured
      { "url" => "http://127.0.0.1:1", "project_id" => "fixture-project", "token" => "fixture-registration-bearer" }
    end

    def registration(value)
      home = Rho::Home.new(root: @root, base_url: "http://localhost:7777", work_root: File.join(@root, "work"))
      host = Rho::Extensions::Host.new(home: home, log: nil, clock: -> { Time.now }, processes: nil,
        config: Rho::Config.from_hash({
          "plugins" => { Rho::T3::NAME => { "enabled" => true, "configuration_version" => 1, "configuration" => value } } }),
        member_plane: ->(**) { flunk "registration must not connect" })
      Rho::Extensions::Api.new(extension_name: Rho::T3::NAME, source: "gem:rho/t3", host: host)
    end

    # The registered routes and command, reading `service` wherever setup
    # would open a connection to T3.
    def serving(value = configured, service = Service.new)
      Rho::T3::Bridge.define_singleton_method(:new) { |_settings| service }
      api = registration(value)
      Rho::T3.register(api)
      yield api, Context.new(api.host.config), service
    ensure
      Rho::T3::Bridge.singleton_class.remove_method(:new)
    end

    def page_document(api, ctx)
      api.routes.find { |route| route.path == "/t3" }.handler.call(nil, ctx).to_a
    end

    def choose(api, ctx, body) = post(api, ctx, "/t3/project", body)

    def post(api, ctx, path, body)
      request = Protocol::HTTP::Request["POST", path, { "content-type" => "application/json" }, [JSON.generate(body)]]
      api.routes.find { |route| route.path == path }.handler.call(request, ctx).to_a
    end
end
