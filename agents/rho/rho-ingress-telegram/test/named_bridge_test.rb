require "test_helper"
require "support/bridge"

class TelegramNamedBridgeTest < Minitest::Test
  include TelegramBridgeSupport

  BOT_ID = "019a0000-0000-7000-8000-000000000001"

  def setup
    @core, @client, @store = Core.new, Member.new, TelegramStateSupport::Store.new
    store = @store
    @client.define_singleton_method(:store_entries) { store }
    host = Host.new(home: nil, member_plane: ->(**) { Rho::Extensions::MemberPlane.new(client: @client, workspace_public_id: nil) })
    @bridge = Rho::IngressTelegram::Bridge.new(host: host, core: @core, agent_public_id: BOT_ID)
  end

  def test_home_is_read_fresh_and_does_not_fall_back_to_the_daemon_workspace
    @core.bot["home_workspace_public_id"] = nil
    error = assert_raises(Rho::Error) { @bridge.default_workspace }
    assert_includes error.message, "Telegram page"
    assert_equal [[:bot_detail, { agent_public_id: BOT_ID }]], @core.calls
    @core.bot["home_workspace_public_id"] = "home-a"
    assert_equal "home-a", @bridge.default_workspace.fetch("public_id")
    @core.bot["home_workspace_public_id"] = "home-b"
    assert_equal "home-b", @bridge.default_workspace.fetch("public_id")
    @core.bot["home_workspace_public_id"] = nil
    assert_raises(Rho::Error) { @bridge.default_workspace }
  end

  def test_audience_is_read_from_the_live_daemon_projection
    @core.bot["audience"] = "owner"
    assert_equal "owner", @bridge.bot_audience
    @core.bot["audience"] = "external"
    assert_equal "external", @bridge.bot_audience
    assert_equal [[:bot_detail, { agent_public_id: BOT_ID }]] * 2, @core.calls
    refusal = Rho::Core::Refused.new("Connect first", code: "not_connected", status: 409)
    @core.define_singleton_method(:bot_detail) { |**| raise refusal }
    assert_same refusal, assert_raises(Rho::Core::Refused) { @bridge.bot_audience }
  end

  def test_the_same_person_has_the_same_speaker_on_two_named_bots
    other = Rho::IngressTelegram::Bridge.new(host: @bridge.instance_variable_get(:@host), core: @core,
      agent_public_id: "019a0000-0000-7000-8000-000000000002")
    person = { "id" => 42, "first_name" => "Visitor" }
    assert_equal @bridge.register_speaker(user: person), other.register_speaker(user: person)
    calls = @client.calls.select { |row| row.first == :register_ingress_speaker }
    assert_equal ["telegram:own", "telegram:own"], calls.map { |row| row.last.fetch(:channel_key) }
    assert_equal ["42", "42"], calls.map { |row| row.last.fetch(:external_id) }
  end

  def test_every_answering_surface_preserves_the_named_bot_uuid
    calls = @core.calls
    @core.define_singleton_method(:prompt_preview) do |id, **fields|
      calls << [:preview, id, fields]
      {}
    end
    @core.define_singleton_method(:create_schedule) do |id, **fields|
      calls << [:schedule, id, fields]
      { "public_id" => "job" }
    end
    @bridge.new_bot_conversation(operation_id: "open", home_workspace_public_id: "home-a")
    assert_equal BOT_ID, calls.last.last.fetch(:agent_public_id)
    @bridge.submit("conversation", text: "hello", speaker: "speaker", idempotency_key: "input", workspace_public_id: "home-a")
    assert_equal BOT_ID, calls.last.last.fetch(:to)
    assert_nil calls.last.last.fetch(:model)
    @bridge.context_preview("conversation", model: nil, speaker_public_id: "current-speaker", workspace_public_id: "home-a")
    assert_equal BOT_ID, calls.last.last.fetch(:to)
    command = Rho::ScheduleCommands.parse("create once in 30m inspect", now: 1_000)
    @bridge.schedule_command("conversation", command: command, workspace_public_id: "home-a", to: "other")
    assert_equal BOT_ID, calls.last.last.fetch(:to)
    assert_empty @client.calls, "all work uses the bound Bot through Core"
  end
end
