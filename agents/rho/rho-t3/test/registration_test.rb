require_relative "test_helper"

class RegistrationTest < Minitest::Test
  TOKEN_ENV = "RHO_T3_REGISTRATION_TEST_TOKEN".freeze

  def setup
    @root = Dir.mktmpdir
    @previous_token = ENV[TOKEN_ENV]
    ENV[TOKEN_ENV] = "fixture-registration-bearer"
  end

  def teardown
    ENV[TOKEN_ENV] = @previous_token
    FileUtils.remove_entry(@root)
  end

  def test_an_unconfigured_extension_registers_no_tools
    %w[full agent].each do |mode|
      api = registration({}, mode: mode)

      Rho::T3.register(api)

      assert_empty api.tools
      assert_empty Rho::Runner::Extensions::Registry.new.commit(api).announcement
    end
  end

  def test_configured_tools_are_announced_on_the_agent_address_without_connecting
    %w[full agent].each do |mode|
      api = registration(configured, mode: mode)

      Rho::T3.register(api)

      registry = Rho::Runner::Extensions::Registry.new.commit(api)
      assert_equal %w[coding_work delegate_coding], registry.serving(:agent).names.sort
      assert_empty registry.serving(:runner).names
    end
  end

  def test_partial_or_missing_credential_configuration_exposes_setup_without_tools
    [{ "url" => "http://127.0.0.1:1" }, configured.merge("token_env" => "")].each do |value|
      api = registration(value)

      Rho::T3.register(api)
      assert_empty api.tools
      assert_includes api.commands.map(&:name), "t3"
    end
  end

  def test_configured_delegation_still_requires_an_agent_address
    api = registration(configured, mode: "runner")

    error = assert_raises(Rho::T3::Error) { Rho::T3.register(api) }

    assert_equal "T3 delegation requires rho agent or full mode", error.message
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

  private

    def configured
      { "url" => "http://127.0.0.1:1", "project_id" => "fixture-project", "token_env" => TOKEN_ENV }
    end

    def registration(value, mode: "full")
      home = Rho::Home.new(root: @root, base_url: "http://localhost:7777", work_root: File.join(@root, "work"))
      host = Rho::Extensions::Host.new(home: home, log: nil, clock: -> { Time.now }, processes: nil,
        config: Rho::Config.from_hash({ "mode" => mode,
          "plugins" => { Rho::T3::NAME => { "enabled" => true, "configuration_version" => 1, "configuration" => value } } }),
        member_plane: ->(**) { flunk "registration must not connect" })
      Rho::Extensions::Api.new(extension_name: Rho::T3::NAME, source: "gem:rho/t3", host: host)
    end
end
