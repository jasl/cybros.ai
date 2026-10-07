require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

class TelegramRegistrationTest < Minitest::Test
  TOKEN_ENV = "RHO_TELEGRAM_REGISTRATION_TEST_TOKEN_#{Process.pid}".freeze
  TOKEN = "registration-synthetic-token".freeze
  CLI = Data.define(:core, :out)

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
    ENV[TOKEN_ENV] = TOKEN
    @apis = []
  end

  def teardown
    @apis.each { |api| api.lifecycle.each { |hook| hook.handler.call if hook.event == :shutdown } }
    ENV.delete(TOKEN_ENV)
    FileUtils.remove_entry(@directory)
  end

  def test_enabled_daemon_registers_one_worker_and_bearer_status_without_starting_it
    %w[full agent].each do |mode|
      api = load_extension(mode: mode)
      assert_equal ["rho.ingress_telegram"], api.background_tasks.map(&:name)
      assert_equal [:shutdown], api.lifecycle.map(&:event)
      assert_equal %i[conversation_binding member_connection configuration_change], api.daemon_hooks.map(&:event)
      assert_equal ["telegram-group"], api.agents.map(&:name)
      route = api.routes.fetch(0)
      assert_equal ["GET", "/telegram", :bearer], [route.method, route.path, route.auth]
      code, status = route.handler.call(nil, nil)
      assert_equal 200, code
      assert_equal true, status.fetch("enabled")
      assert_equal "waiting_for_nexus", status.fetch("connection")
      refute status.key?("bot_id")
      refute_path_exists File.join(@directory, "telegram", "state.json")
      refute_includes JSON.generate(status), TOKEN

      api.lifecycle.find { |hook| hook.event == :shutdown }.handler.call
      assert_equal "stopped", route.handler.call(nil, nil).last.fetch("connection")
    end
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
    control = Control.new({ "enabled" => true, "connection" => "running", "bot_id" => "42" })
    result = command.handler.call(CLI.new(core: control, out: output), ["status"], {})
    assert_equal [[:test_daemon, "/telegram"]], control.requests
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
    ENV.delete(TOKEN_ENV)
    api = load_extension
    assert_equal ["rho.ingress_telegram"], api.background_tasks.map(&:name)
    assert_equal [:shutdown], api.lifecycle.map(&:event)
    assert_empty api.agents
    status = api.routes.fetch(0).handler.call(nil, nil).last
    assert status.fetch("enabled")
    assert_equal "configuration_error", status.fetch("connection")
    assert_equal({ "present" => false, "source" => "none" }, status.fetch("token"))
    assert_nil status.fetch("access")
  end

  def test_runner_refuses_the_extension_before_registering_any_contribution
    result = load_result(mode: "runner")
    refute_predicate result, :ok?
    assert_empty result.committed
    failure = result.failures.fetch(0)
    assert_equal "Rho::ConfigurationError", failure.error_class
    assert_includes failure.message, "needs mode full or agent"
    refute_includes failure.message, TOKEN
  end

  private

    def load_extension(**options)
      result = load_result(**options)
      assert_predicate result, :ok?, result.failures.inspect
      result.committed.fetch(0).tap { |api| @apis << api }
    end

    def load_result(mode: "full", serving_tools: true)
      config = Rho::Config.from_hash({ "mode" => mode, "plugins" => { Rho::IngressTelegram::NAME => {
        "enabled" => true, "configuration" => { "token_env" => TOKEN_ENV, "owner_id" => "42" },
      } } })
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: @directory)
      host = Rho::Extensions::Host.new(home: home, log: nil, clock: -> { Time.now },
        config: config, processes: nil, serving_tools: serving_tools,
        member_plane: ->(**) {
          profile = Struct.new(:store_entries).new(TelegramStateSupport.store(home))
          client = Struct.new(:profile).new(profile)
          Rho::Extensions::MemberPlane.new(client: client, workspace_public_id: nil)
        })
      Rho::Runner::Extensions::Loader.call(gems: ["rho/ingress-telegram"], api_class: Rho::Extensions::Api,
        api_options: { host: host })
    end
end
