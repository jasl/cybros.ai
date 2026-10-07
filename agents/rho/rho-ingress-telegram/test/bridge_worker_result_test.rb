require "test_helper"
require "support/bridge"

class TelegramBridgeWorkerResultTest < Minitest::Test
  include TelegramBridgeSupport

  def setup
    @core = Core.new
    @variants = [
      { "public_id" => "original", "active" => false, "status" => "completed", "content" => "Canonical final", "run_public_id" => "original-loop" },
      { "public_id" => "new", "active" => true, "status" => "completed", "content" => "Later manual edit" },
    ]
    variants = @variants
    @core.define_singleton_method(:variants) do |id, turn, **options|
      @calls << [:variants, id, turn, options]
      variants
    end
    @bridge = Rho::IngressTelegram::Bridge.new(host: Host.new(home: nil, member_plane: nil), core: @core)
    @source = { "conversation_public_id" => "child", "input_public_id" => "input", "turn_public_id" => "turn", "variant_public_id" => "original" }
  end

  def test_result_reads_the_frozen_variant_and_its_own_capture_owner
    result = @bridge.worker_result(@source, workspace_public_id: "original-workspace")

    assert_equal "Canonical final", result.fetch("text")
    assert_equal "original-loop", result.fetch("run_public_id")
    assert_equal "original", result.fetch("variant_public_id")
    assert_equal [[:variants, "child", "turn", { workspace_public_id: "original-workspace" }]], @core.calls
  end

  def test_missing_or_unfinished_original_does_not_select_another_variant
    @variants.first["status"] = "running"
    assert_nil @bridge.worker_result(@source, workspace_public_id: "workspace")
    @variants.shift
    assert_nil @bridge.worker_result(@source, workspace_public_id: "workspace")
  end

  def test_busy_child_read_is_one_latest_turn_and_preserves_input_and_callback_sources
    sources = [{ "input_public_id" => "callback", "result" => @source }]
    @core.turn_rows = [{ "public_id" => "turn", "input_public_id" => "input", "position" => 5,
      "kind" => "direct_reply", "status" => "running", "sender_conversation_public_id" => "parent",
      "sender_run_public_id" => "parent-loop", "sender_task_key" => "r2.send", "callback_sources" => sources,
      "active_variant" => { "public_id" => "original", "run_public_id" => "original-loop" } }]

    result = @bridge.worker_request("child", workspace_public_id: "workspace")

    assert_equal "input", result.fetch("input_public_id")
    assert_equal "parent-loop", result.fetch("sender_run_public_id")
    assert_equal sources, result.fetch("callback_sources")
    assert_equal [:turns, "child", { latest: true, limit: 1, workspace_public_id: "workspace" }], @core.calls.last
  end
end
