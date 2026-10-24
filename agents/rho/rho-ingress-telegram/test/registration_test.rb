require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class TelegramRegistrationTest < Minitest::Test
  TOKEN = "registration-synthetic-token".freeze
  CLI = Data.define(:core, :out)
  CONNECTION = "019a1111-2222-7333-8444-555555555551".freeze
  BOT = "019a1111-2222-7333-8444-555555555552".freeze

  class Control
    attr_reader :requests

    def initialize(document)
      @document = document
      @requests = []
    end

    def require_daemon = :test_daemon

    def get(daemon, path)
      @requests << [daemon, path]
      @document
    end

    def parse(response) = response
  end

  def setup
    @directory = Dir.mktmpdir("rho-telegram-registration")
    @apis = []
  end

  def teardown
    @apis.each { |api| api.lifecycle.each { |hook| hook.handler.call if hook.event == :shutdown } }
    FileUtils.remove_entry(@directory)
  end

  def test_enabled_daemon_registers_one_worker_and_bearer_status_without_starting_it
      api = load_extension
      assert_equal ["rho.ingress_telegram"], api.background_tasks.map(&:name)
      assert_equal [:shutdown], api.lifecycle.map(&:event)
      assert_equal %i[conversation_binding member_connection configuration_change], api.daemon_hooks.map(&:event)
      assert_empty api.agents, "the plugin does not declare a hidden Main or group identity"
      route = api.routes.find { |row| row.path == "/telegram/connections" }
      assert_equal ["GET", "/telegram/connections", :bearer], [route.method, route.path, route.auth]
      code, document = route.handler.call(nil, nil)
      status = document.fetch("connections").fetch(0)
      assert_equal 200, code
      assert_equal true, status.fetch("enabled")
      assert_equal "waiting_for_nexus", status.fetch("connection")
      refute status.key?("bot_id")
      refute_path_exists File.join(@directory, "telegram", "state.json")
      refute_includes JSON.generate(status), TOKEN

      api.lifecycle.find { |hook| hook.event == :shutdown }.handler.call
      assert_equal "stopped", route.handler.call(nil, nil).last.fetch("connections").fetch(0).fetch("connection")
  end

  def test_cli_loader_registers_status_but_no_telegram_worker_or_shutdown
    api = load_extension(serving_tools: false)
    assert_empty api.background_tasks
    assert_empty api.lifecycle
    assert_empty api.daemon_hooks
    refute_path_exists File.join(@directory, "telegram", "state.json")
    command = api.commands.fetch(0)
    assert_equal "telegram", command.name

    output = StringIO.new
    control = Control.new({ "connections" => [{ "public_id" => CONNECTION, "enabled" => true, "connection" => "running", "bot" => { "id" => 42 } }] })
    result = command.handler.call(CLI.new(core: control, out: output), ["status"], {})
    assert_equal [[:test_daemon, "/telegram/connections"]], control.requests
    assert_equal result, JSON.parse(output.string)
    refute_includes output.string, TOKEN
    error = assert_raises(Rho::Error) do
      command.handler.call(CLI.new(core: control, out: output), ["allow", "42"], {})
    end
    assert_includes error.message, "rho setup"
    assert_equal 1, control.requests.length
  end

  def test_enabled_binding_without_a_member_connection_is_absent
    api = load_extension
    hook = api.daemon_hooks.find { |row| row.event == :conversation_binding }
    assert_nil hook.handler.call("conversation")
  end

  def test_missing_token_keeps_management_and_idle_worker_available
    api = load_extension(token: nil)
    assert_equal ["rho.ingress_telegram"], api.background_tasks.map(&:name)
    assert_equal [:shutdown], api.lifecycle.map(&:event)
    assert_empty api.agents
    status = api.routes.find { |row| row.path == "/telegram/connections" }.handler.call(nil, nil).last.fetch("connections").fetch(0)
    assert status.fetch("enabled")
    assert_equal "configuration_error", status.fetch("connection")
    assert_equal({ "present" => false }, status.fetch("token"))
    refute status.key?("access"), "transport status does not own Bot admission"
  end

  def test_daemon_register_the_browser_module_shipped_in_the_gem
    root = File.realpath(File.expand_path("../webui", __dir__))
      browser = load_extension.webui_module
      assert_equal Rho::IngressTelegram::NAME, browser.extension
      assert_equal root, browser.root
      assert_match %r{\A/modules/rho\.ingress_telegram/\h{12}/index\.js\z}, browser.entry
  end

  def test_the_gem_ships_every_browser_module_file
    gem_root = File.expand_path("..", __dir__)
    spec = Gem::Specification.load(File.join(gem_root, "rho-ingress-telegram.gemspec"))
    browser_files = Dir.glob("webui/**/*", base: gem_root).select { |path| File.file?(File.join(gem_root, path)) }

    assert_includes browser_files, "webui/index.js"
    assert_empty browser_files - spec.files
  end

  private

    def load_extension(**options)
      result = load_result(**options)
      assert_predicate result, :ok?, result.failures.inspect
      result.committed.fetch(0).tap { |api| @apis << api }
    end

    def load_result(serving_tools: true, token: TOKEN)
      config = Rho::Config.from_hash({ "plugins" => { Rho::IngressTelegram::NAME => {
        "enabled" => true, "configuration" => {
          "connections" => { CONNECTION => { "token" => token, "name" => "Shared" } },
          "bots" => { BOT => { "enabled" => true, "connection_public_id" => CONNECTION, "target" => { "chat_id" => "42" }, "owner_id" => "42" } },
        },
      } } })
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: @directory)
      host = Rho::Extensions::Host.new(home: home, log: nil, clock: -> { Time.now },
        config: config, processes: nil, serving_tools: serving_tools,
        member_plane: ->(**) {
          profile = Struct.new(:store_entries).new(TelegramStateSupport.store(home))
          client = Struct.new(:profile).new(profile)
          Rho::Extensions::MemberPlane.new(client: client, workspace_public_id: nil)
        })
      Rho::Env::Extensions::Loader.call(gems: ["rho/ingress-telegram"], api_class: Rho::Extensions::Api,
        api_options: { host: host })
    end
end
