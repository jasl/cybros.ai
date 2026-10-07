require_relative "test_helper"

class SettingsTest < Minitest::Test
  include T3Test

  def test_native_service_selection_is_local_and_durable_values_exclude_bearer
    config = settings(workspace: { "type" => "worktree", "baseRef" => "main", "branch" => "fix-parser" })
    assert_equal "http://localhost:3773", config.environment.fetch("url")
    assert_equal "worktree", config.environment.dig("workspaceStrategy", "type")
    refute_includes JSON.generate(config.environment), config.token
    assert_equal "approval-required", config.environment.fetch("runtimeMode")
    assert_equal "Codex", config.default_agent
    refute config.environment.key?("modelSelection"), "each assignment selects its own native provider and model"
    assert_nil settings(default_agent: nil).default_agent
  end

  def test_missing_credentials_are_setup_state_and_malformed_configuration_is_refused
    incomplete = Rho::T3::Settings.parse({}, env: {})
    refute incomplete.configured?
    assert_equal 3, incomplete.issues.length
    assert_raises(Rho::T3::Error) { incomplete.require_connection }
    assert_raises(Rho::T3::Error) { settings(url: "file:///tmp/t3") }
    assert_raises(Rho::T3::Error) { settings(url: "https://user:secret@example.com") }
    assert_raises(Rho::T3::Error) { settings(workspace: { "type" => "worktree" }) }
    assert_raises(Rho::T3::Error) { settings(workspace: { "type" => "inferred" }) }
  end

  def test_local_port_is_the_only_url_authority
    local = settings(server: "local", listen_port: 4773, url: "http://stale.example")
    assert local.local?
    assert_equal "http://127.0.0.1:4773", local.url
    assert_raises(Rho::T3::Error) { settings(server: "local", listen_port: 0) }
    assert_raises(Rho::T3::Error) { settings(server: "local", listen_port: 65_536) }
    assert_raises(Rho::T3::Error) { settings(server: "sidecar") }
  end

  def test_standalone_tools_refuse_without_a_conversation
    assert_raises(Rho::T3::Error) { Rho::T3::Session.new(member_plane: ->(**) { flunk }, context: nil) }
  end

  def test_registered_tools_validate_as_agent_tools_and_control_inputs_are_explicit
    factory = ->(_) { nil }
    tools = [Rho::T3::Tools.delegate(factory), Rho::T3::Tools.control(factory)]
    tools.each do |tool|
      assert_respond_to Rho::Runner::Extensions::Tool.validate(tool, extension: "test"), :validate
    end
    assert_equal [3_600_000, 60_000], tools.map { |tool| tool::TIMEOUT_MS },
      "the delegation window fits the ordinary claim-extension bound"
  end
end
