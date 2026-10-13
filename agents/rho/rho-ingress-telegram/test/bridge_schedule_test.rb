require "test_helper"
require "support/bridge"

class TelegramBridgeScheduleTest < Minitest::Test
  include TelegramBridgeSupport

  def setup
    @core, @client = Core.new, Member.new
    host = Host.new(home: nil, member_plane: ->(workspace_public_id: nil, **) do
      Rho::Extensions::MemberPlane.new(client: @client, workspace_public_id: workspace_public_id || "workspace")
    end)
    @bridge = Rho::IngressTelegram::Bridge.new(host: host, core: @core, agent_public_id: "bound-bot")
  end

  def test_create_forwards_the_frozen_answerer_tool_policy_and_receipt_key
    calls = @core.calls
    @core.define_singleton_method(:create_schedule) do |id, **fields|
      calls << [id, fields]
      { "public_id" => "job" }
    end
    command = Rho::ScheduleCommands.parse("create every 20m inspect the report", now: 1_000)
    result = @bridge.schedule_command("main", command: command, workspace_public_id: "original",
      model: "vendor/model", to: "unrelated", speaker_public_id: "speaker", tool_names: ["read"], idempotency_key: "receipt")
    assert_equal({ "public_id" => "job" }, result)
    assert_equal ["main", { prompt: "inspect the report", rule: {
      "kind" => "interval", "every_seconds" => 1_200, "starts_at" => "1970-01-01T00:36:40Z",
    }, model: "vendor/model", approval_mode: nil, to: "bound-bot", speaker_public_id: "speaker",
      tool_names: ["read"], idempotency_key: "receipt", workspace_public_id: "original" }], calls.last
  end

  def test_durable_history_projection_preserves_callback_source_identity
    @core.turn_rows = [{ "public_id" => "callback", "position" => 3, "kind" => "direct_reply", "status" => "completed",
      "sender_conversation_public_id" => "scheduled-child", "sender_run_public_id" => "scheduled-loop",
      "sender_task_key" => "r3.mail", "active_variant" => { "public_id" => "variant", "run_public_id" => "main-loop", "content" => "Report" } }]
    row = @bridge.turns("main", workspace_public_id: "original").first
    assert_equal "scheduled-child", row.fetch("sender_conversation_public_id")
    assert_equal "scheduled-loop", row.fetch("sender_run_public_id")
    assert_equal "r3.mail", row.fetch("sender_task_key")
    assert_equal "main-loop", row.fetch("run_public_id")
  end

  def test_schedule_reads_preserve_the_recorded_workspace_and_page
    @bridge.schedules("old", after: "page", workspace_public_id: "original")
    assert_equal [:schedules, "old", { after: "page", workspace_public_id: "original" }], @core.calls.last
    assert_empty @client.calls, "execution policy belongs to the Bot declaration captured by Nexus"
  end
end
