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

  def test_isolated_context_preview_uses_the_registered_group_answerer
    core, client = Core.new, Member.new
    client.named_agents = [Agent.new(name: "telegram-group", public_id: "isolated-group", derived_from_public_id: "own")]
    host = Host.new(home: nil, member_plane: ->(**) { Rho::Extensions::MemberPlane.new(client: client, workspace_public_id: "original") })
    calls = core.calls
    core.define_singleton_method(:prompt_preview) do |id, **fields|
      calls << [id, fields]
      {}
    end
    bridge = Rho::IngressTelegram::Bridge.new(host: host, core: core)
    bridge.context_preview("legacy", model: nil, isolated: true, workspace_public_id: "original")
    assert_equal ["legacy", { model: nil, to: "isolated-group", workspace_public_id: "original" }], calls.last
  end

  def test_isolated_history_requires_the_original_group_answerer_and_explicit_frozen_memory_bindings
    client = Member.new
    client.named_agents = [Agent.new(name: "telegram-group", public_id: "isolated-group", derived_from_public_id: "own")]
    host = Host.new(home: nil, member_plane: ->(**) { Rho::Extensions::MemberPlane.new(client: client, workspace_public_id: "original") })
    bridge = Rho::IngressTelegram::Bridge.new(host: host, core: Core.new)
    turn = { "answering_user_public_id" => "isolated-group", "active_variant" => { "memory_context" => { "bindings" => [] } } }

    assert bridge.isolated_history_turn?(turn), "explicitly disabled memory remains isolated"
    refute bridge.isolated_history_turn?(turn.merge("answering_user_public_id" => "own"))
    refute bridge.isolated_history_turn?(turn.merge("active_variant" => { "memory_context" => nil }))
    refute bridge.isolated_history_turn?(turn.merge("active_variant" => {}))
  end
end
