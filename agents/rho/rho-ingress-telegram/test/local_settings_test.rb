require "support/runtime"

class TelegramLocalSettingsTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_settings_are_shared_and_reply_references_do_not_change_the_bot_current_workspace
    receive(mention(1, user: 1))
    receive(mention(2, user: 2))
    @state.change do |document|
      document.fetch("routes").fetch("#{CONNECTION}:-10:4").merge!(
        "model" => "shared/model", "workspace_public_id" => "workspace-project", "voice" => "all")
      document.fetch("rooms")["#{CONNECTION}:-10:4"] = { "observe" => true }
    end
    routes = @state.read.fetch("routes")
    requests = @state.read.fetch("requests")

    receive(telegram_message(3, "/settings", chat: -10, topic: 4, reply_to: 2, reply_user: 2))
    receive(telegram_message(4, "/settings", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 1))
    receive(telegram_message(5, "/observe status", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 1))
    receive(telegram_message(6, "/observe off", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 1))

    [3, 4].each do |id|
      assert_includes feedback(id), "shared/model"
      assert_includes feedback(id), "Home (workspace-home)"
      assert_includes feedback(id), "Voice: all"
      refute_includes feedback(id), "workspace-project"
    end
    assert_includes feedback(5), "Observe: on"
    assert_includes feedback(6), "Only the bot owner"
    assert_equal true, @state.read.fetch("rooms").dig("#{CONNECTION}:-10:4", "observe")
    assert_equal "#{CONNECTION}:-10:4", @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:3:reply").fetch("route_key")
    assert_equal "#{CONNECTION}:-10:4", @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:4:reply").fetch("route_key")
    assert_equal routes, @state.read.fetch("routes")
    assert_equal requests, @state.read.fetch("requests")
    assert_equal 2, @bridge.inputs.length
    assert_empty @bridge.stops
  end

  def test_settings_and_observe_queries_ignore_unknown_bot_reply_targets
    @client.admin = true
    receive(telegram_message(1, "/observe on", chat: -10, topic: 4))
    ["/settings", "/observe", "/observe status"].each_with_index do |command, index|
      id = index + 2
      receive(telegram_message(id, command, user: 2, chat: -10, topic: 4, reply_to: 999))
      assert_includes feedback(id), "Observe: on"
      assert_equal "#{CONNECTION}:-10:4", @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:#{id}:reply").fetch("route_key")
    end

    assert_empty @state.read.fetch("routes")
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
  end

  def test_observe_replies_change_only_the_original_topic_and_keep_task_authority
    @client.admin = true
    receive(mention(1, user: 2))
    receive(telegram_message(2, "/observe on", chat: -10, topic: 4, reply_to: 1, reply_user: 2))
    assert_equal true, @state.read.fetch("rooms").dig("#{CONNECTION}:-10:4", "observe")
    assert_equal "#{CONNECTION}:-10:4", @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:2:reply").fetch("route_key")

    receive(telegram_message(3, "/observe status", user: 2, chat: -10, topic: 4, reply_to: 999))
    assert_includes feedback(3), "Observe: on"
    receive(telegram_message(4, "/observe off", chat: -10, topic: 5, reply_to: 1, reply_user: 2))
    assert_equal true, @state.read.fetch("rooms").dig("#{CONNECTION}:-10:4", "observe")
    assert_equal false, @state.read.fetch("rooms").dig("#{CONNECTION}:-10:5", "observe")
    receive(telegram_message(5, "/observe off", chat: -10, topic: 4, reply_to: 999))
    assert_equal false, @state.read.fetch("rooms").dig("#{CONNECTION}:-10:4", "observe")

    receive(telegram_message(6, "/stop", user: 2, chat: -10, topic: 4, reply_to: 999))
    assert_includes feedback(6), "not linked to a known task"
    assert_empty @bridge.stops
    assert_equal 1, @bridge.inputs.length
    assert_equal ["#{CONNECTION}:-10:4"], @state.read.fetch("routes").keys
    refute @state.read.fetch("routes").fetch("#{CONNECTION}:-10:4").key?("current")
    assert_equal "conversation-1", @bridge.bot_detail.dig("current", "public_id")
  end

  def test_observe_change_and_result_survive_a_reply_failure_without_reapplying
    @client.admin = true
    change = @state.method(:change)
    interrupt = true
    @state.define_singleton_method(:change) do |&block|
      result = change.call(&block)
      if read.fetch("rooms").dig("#{CONNECTION}:-10:4", "observe") && interrupt
        interrupt = false
        raise Rho::ConnectionError, "process stopped after observation settings reached disk"
      end
      result
    end
    update = telegram_message(1, "/observe on", chat: -10, topic: 4, reply_to: 999)
    assert_raises(Rho::ConnectionError) { receive(update) }
    persisted = @state.read
    assert_equal true, persisted.fetch("rooms").dig("#{CONNECTION}:-10:4", "observe")
    assert_equal "applied", persisted.fetch("pending_update").fetch("control_status")
    result = persisted.fetch("pending_update").fetch("control_result")
    refute persisted.fetch("deliveries").key?("control:telegram:#{BOT}:#{CONNECTION}:42:1:reply")
    @state.change { |document| document.fetch("rooms").fetch("#{CONNECTION}:-10:4")["observe"] = false }
    calls = @client.calls.dup
    @client.admin = false
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    receive(update)
    receive(update)

    assert_equal false, @state.read.fetch("rooms").dig("#{CONNECTION}:-10:4", "observe")
    assert_equal result, feedback(1)
    assert_equal calls, @client.calls
    assert_nil @state.read["pending_update"]
    assert_equal 2, @connection_state.read.fetch("offset")
    assert_empty @bridge.inputs
  end

  def test_observe_change_refuses_a_different_staged_update_without_writing
    @state.stage("update" => telegram_message(1, "/observe on", chat: -10, topic: 4))
    update = Rho::IngressTelegram::Update.new(telegram_message(2, "/observe on", chat: -10, topic: 4))
    before = @state.read

    error = assert_raises(Rho::Error) { @runtime.set_observe(update, true, result: "Observe: on") }

    assert_includes error.message, "does not match the staged update"
    assert_equal before, @state.read
  end

  private

    def mention(id, user:)
      telegram_message(id, "@rho_bot task #{id}", user: user, chat: -10, topic: 4,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    end

    def feedback(id) = @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:#{id}:reply").fetch("text")
end
