require "test_helper"

class CliAPIKeysTest < Minitest::Test
  include RhoTest::CliHarness

  def keys
    { "access_token" => NexusDoubles::MEMBER_TOKEN,
      "executor_access_token" => NexusDoubles::TRANSPORT_TOKEN,
      "runner_access_token" => NexusDoubles::RUNNER_TOKEN }
  end

  def test_stdin_import_uses_the_daemon_and_never_prints_keys
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(oauth: oauth)
    cli.connect(api_key_stdin: true, input: StringIO.new(JSON.generate(keys)))

    assert_equal :active, daemon.phase
    assert_equal "api_key", daemon.lineage.credentials.agent.authentication_kind
    assert_empty oauth.requests
    keys.values.each { |key| refute_includes @out.string, key }
  end

  def test_prompt_import_uses_getpass_for_each_plane
    daemon = boot
    prompts = []
    values = keys.values.dup
    input = Object.new
    input.define_singleton_method(:tty?) { true }
    input.define_singleton_method(:getpass) { |prompt| prompts << prompt; values.shift }

    cli.connect(api_key: true, input: input)

    assert_equal :active, daemon.phase
    assert_equal ["Agent member API key: ", "Executor API key: ", "Private Runner API key: "], prompts
    keys.values.each { |key| refute_includes @out.string, key }
  end

  def test_prompt_uses_the_live_daemon_mode
    daemon = boot(config: Rho::Config.from_hash({ "mode" => "agent" }))
    prompts = []
    values = keys.values.first(2)
    input = Object.new
    input.define_singleton_method(:tty?) { true }
    input.define_singleton_method(:getpass) { |prompt| prompts << prompt; values.shift }

    cli.connect(api_key: true, input: input)

    assert_equal :active, daemon.phase
    assert_equal 2, prompts.size
    refute daemon.lineage.credentials.runner?
  end

  def test_invalid_json_does_not_echo_input_or_start_a_connection
    error = assert_raises(Rho::ConnectionError) do
      cli.connect(api_key_stdin: true, input: StringIO.new('{"access_token":"secret-never-render'))
    end
    assert_equal "API key input must be a JSON object", error.message
    refute_includes @out.string, "secret-never-render"
  end

  def test_prompt_and_stdin_flags_are_mutually_exclusive
    assert_raises(Rho::ConnectionError) { cli.connect(api_key: true, api_key_stdin: true) }
  end
end
