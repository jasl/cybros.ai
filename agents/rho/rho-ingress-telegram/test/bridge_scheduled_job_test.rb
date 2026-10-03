require "test_helper"
require "support/bridge"

class TelegramBridgeScheduledJobTest < Minitest::Test
  include TelegramBridgeSupport

  def setup
    @core, @client = Core.new, Member.new
    host = Host.new(home: nil, member_plane: ->(**) do
      Rho::Extensions::MemberPlane.new(client: @client, workspace_public_id: "workspace")
    end)
    @bridge = Rho::IngressTelegram::Bridge.new(host: host, core: @core)
  end

  def test_create_forwards_the_frozen_answerer_tool_policy_and_receipt_key
    calls = @core.calls
    @core.define_singleton_method(:create_scheduled_job) do |id, **fields|
      calls << [id, fields]
      { "public_id" => "job" }
    end
    command = Rho::ScheduledJobCommands.parse("create every 20m inspect the report", now: 1_000)
    result = @bridge.scheduled_job_command("main", command: command, workspace_public_id: "original",
      model: "vendor/model", to: "group", speaker_actor_public_id: "speaker", tool_names: ["read"], idempotency_key: "receipt")
    assert_equal({ "public_id" => "job" }, result)
    assert_equal ["main", { prompt: "inspect the report", rule: {
      "kind" => "interval", "every_seconds" => 1_200, "starts_at" => "1970-01-01T00:36:40Z",
    }, model: "vendor/model", approval_mode: nil, to: "group", speaker_actor_public_id: "speaker",
      tool_names: ["read"], idempotency_key: "receipt", workspace_public_id: "original" }], calls.last
  end

  def test_durable_history_projection_preserves_callback_source_identity
    @core.turn_rows = [{ "public_id" => "callback", "position" => 3, "kind" => "direct_reply", "status" => "completed",
      "sender_conversation_public_id" => "scheduled-child", "sender_agent_loop_public_id" => "scheduled-loop",
      "sender_task_key" => "r3.mail", "active_variant" => { "public_id" => "variant", "agent_loop_public_id" => "main-loop", "content" => "Report" } }]
    row = @bridge.turns("main", workspace_public_id: "original").first
    assert_equal "scheduled-child", row.fetch("sender_conversation_public_id")
    assert_equal "scheduled-loop", row.fetch("sender_agent_loop_public_id")
    assert_equal "r3.mail", row.fetch("sender_task_key")
    assert_equal "main-loop", row.fetch("loop_public_id")
  end

  def test_read_only_job_requires_the_actual_group_profile_and_an_explicit_tool_subset
    profile = Data.define(:name, :public_id, :derived_from_public_id, :configuration)
    @client.named_agents = [profile.new(name: "telegram-group", public_id: "group", derived_from_public_id: "own",
      configuration: Configuration.new(tool_definitions: [{ "name" => "read" }, { "name" => "bash" }]))]
    row = { "answering_user_public_id" => "group", "tool_names" => ["read"] }
    assert @bridge.read_only_scheduled_job?(row)
    assert @bridge.read_only_scheduled_job?(row.merge("tool_names" => []))
    refute @bridge.read_only_scheduled_job?(row.merge("tool_names" => nil))
    refute @bridge.read_only_scheduled_job?(row.merge("tool_names" => ["bash"]))
    refute @bridge.read_only_scheduled_job?(row.merge("answering_user_public_id" => "own"))
    assert_equal "group", @bridge.scheduled_job_answerer(isolated: true)
    assert_nil @bridge.scheduled_job_answerer(isolated: false)
  end
end
