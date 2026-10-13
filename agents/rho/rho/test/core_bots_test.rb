require "test_helper"

class CoreBotsTest < Minitest::Test
  include RhoTest::CliHarness

  def test_new_conversation_preserves_omitted_null_and_explicit_home
    seen = []
    selected = { "public_id" => "c-new", "workspace_public_id" => "ws-home" }
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /bots/new" => [[200, { "selected" => selected, "current" => selected, "replayed" => false }]]))

    core.new_bot_conversation(agent_public_id: "bot-1", operation_id: "keep-home")
    core.new_bot_conversation(agent_public_id: "bot-1", operation_id: "clear-home", home_workspace_public_id: nil)
    core.new_bot_conversation(agent_public_id: "bot-1", operation_id: "set-home", home_workspace_public_id: "ws-other")

    bodies = seen.grep(/\APOST \/bots\/new /).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [
      { "agent_public_id" => "bot-1", "operation_id" => "keep-home" },
      { "agent_public_id" => "bot-1", "operation_id" => "clear-home", "home_workspace_public_id" => nil },
      { "agent_public_id" => "bot-1", "operation_id" => "set-home", "home_workspace_public_id" => "ws-other" },
    ], bodies
  end
end
