require_relative "test_helper"
require "support/bridge"

class TelegramBridgeSideTest < Minitest::Test
  include TelegramBridgeSupport

  def test_open_side_uses_the_existing_tools_none_surface_without_a_non_idempotent_question
    core = Core.new
    core.define_singleton_method(:open_side) do |**options|
      @calls << [:side, options]
      { "side" => { "public_id" => "side" } }
    end
    bridge = Rho::IngressTelegram::Bridge.new(host: Host.new(home: nil, member_plane: nil), core: core)

    assert_equal "side", bridge.open_side(parent: "parent")
    assert_equal [[:side, { parent: "parent", tools: "none" }]], core.calls
  end

  def test_isolated_side_keeps_its_fixed_answerer_without_sending_to
    core = Core.new
    calls = core.calls
    core.define_singleton_method(:conversation) do |id, **options|
      calls << [:conversation, id, options]
      { "answering_user_public_id" => "group" }
    end
    bridge = Rho::IngressTelegram::Bridge.new(host: Host.new(home: nil, member_plane: nil), core: core)
    bridge.define_singleton_method(:group_agent) { "group" }

    bridge.submit("side", text: "Explain", speaker: "speaker", idempotency_key: "side-input",
      isolated: true, side: true, tool_names: [], workspace_public_id: "original")

    assert_equal [:conversation, "side", { workspace_public_id: "original" }], calls.first
    assert_equal :say, calls.last.first
    refute calls.last.last.key?(:to)
    assert_empty calls.last.last.fetch(:tool_names)
  end

  def test_legacy_isolated_side_with_owner_answerer_refuses_before_admission
    core = Core.new
    core.define_singleton_method(:conversation) { |_id, **_options| { "answering_user_public_id" => "owner" } }
    bridge = Rho::IngressTelegram::Bridge.new(host: Host.new(home: nil, member_plane: nil), core: core)
    bridge.define_singleton_method(:group_agent) { "group" }

    error = assert_raises(Rho::Error) do
      bridge.submit("legacy-side", text: "Explain", speaker: "speaker", idempotency_key: "side-input",
        isolated: true, side: true, tool_names: [], workspace_public_id: "original")
    end

    assert_includes error.message, "/new"
    assert_empty core.calls
  end

  def test_side_turn_projection_preserves_inherited_rows_for_cursor_advancement
    core = Core.new
    core.turn_rows = [{ "public_id" => "old", "position" => 0, "kind" => "direct_reply", "status" => "completed",
      "inherited" => true, "active_variant" => { "content" => "Parent answer" } }]
    bridge = Rho::IngressTelegram::Bridge.new(host: Host.new(home: nil, member_plane: nil), core: core)

    assert_equal true, bridge.turns("side").first.fetch("inherited")
  end
end
