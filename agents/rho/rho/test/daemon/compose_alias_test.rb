require "support/daemon_loop_helpers"

class DaemonComposeAliasTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  def test_compose_off_withholds_workflow_on_the_input_when_the_boot_row_replaces_compose
    api = kernel_api
    mock_row("workflow", tool_style: ["workflow"])
    daemon = member_ready(boot(config: tiered("default_model" => "dev/mock-text")), api)

    code, answer = open(daemon, { "prompt" => "fix it" })

    assert_equal "201", code, answer.inspect
    assert_equal({ "on" => false, "source" => "row workflow" }, answer.fetch("compose"))
    assert_equal names_without_compose, api.conversation_inputs.fetch(0).dig("input", "tool_names")
    assert_equal false, store.rows.fetch(0).compose
    assert_empty api.configuration_declarations, "the turn narrows its tools without rewriting the profile"
  end
end
