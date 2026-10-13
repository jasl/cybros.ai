require "test_helper"
require "support/bridge"

class TelegramBridgeConversationTest < Minitest::Test
  include TelegramBridgeSupport

  def test_first_turn_selection_never_sends_a_negative_position_cursor
    core = Core.new
    bridge = Rho::IngressTelegram::Bridge.new(host: nil, core: core)
    core.turn_rows = [{ "public_id" => "first-turn", "position" => 0 }]
    assert_equal "first-turn", bridge.history_turn("conversation", reference: "0", workspace_public_id: "original").fetch("public_id")
    assert_equal [:turns, "conversation", { after_position: nil, limit: 1, workspace_public_id: "original" }], core.calls.last

    core.turn_rows = [{ "public_id" => "later-turn", "position" => 8 }]
    assert_equal "later-turn", bridge.history_turn("conversation", reference: "8", workspace_public_id: "original").fetch("public_id")
    assert_equal 7, core.calls.last.last.fetch(:after_position)
    assert_nil bridge.history_turn("conversation", reference: "7", workspace_public_id: "original")
  end

  def test_context_preview_uses_the_bound_bot_and_this_requests_speaker
    core = Core.new
    calls = core.calls
    core.define_singleton_method(:prompt_preview) do |id, **fields|
      calls << [id, fields]
      {}
    end
    bridge = Rho::IngressTelegram::Bridge.new(host: nil, core: core, agent_public_id: "bound-bot")
    %w[first-speaker second-speaker].each do |speaker|
      bridge.context_preview("conversation", model: nil, speaker_public_id: speaker, workspace_public_id: "original")
      assert_equal ["conversation", { model: nil, to: "bound-bot", speaker_public_id: speaker, workspace_public_id: "original" }], calls.last
    end
  end
end
